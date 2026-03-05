import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class AppViewModelA0Tests: XCTestCase {
    private enum StubError: Error {
        case timedOut
        case exhausted
    }

    private struct SnapshotStep {
        let delayMs: UInt64
        let result: Result<AgtmuxSnapshot, Error>
    }

    private actor StubSnapshotClient: LocalSnapshotClient {
        private var steps: [SnapshotStep]

        init(steps: [SnapshotStep]) {
            self.steps = steps
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            guard !steps.isEmpty else { throw StubError.exhausted }
            let step = steps.removeFirst()
            if step.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(step.delayMs))
            }
            switch step.result {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                throw error
            }
        }
    }

    private actor StubInventoryClient: LocalPaneInventoryClient {
        private let panes: [AgtmuxPane]

        init(panes: [AgtmuxPane]) {
            self.panes = panes
        }

        func fetchPanes() async throws -> [AgtmuxPane] {
            panes
        }
    }

    private func waitUntil(timeout: TimeInterval = 2.0,
                           intervalMs: UInt64 = 25,
                           condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return await condition()
    }

    private func makeInventoryPane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: .unknown,
            presence: .unmanaged,
            evidenceMode: .none,
            currentCmd: "zsh"
        )
    }

    private func makeManagedMetadataPane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: .running,
            presence: .managed,
            provider: .codex,
            evidenceMode: .deterministic,
            conversationTitle: "Implement A0",
            currentCmd: "node"
        )
    }

    @MainActor
    func testFetchAllReturnsInventoryWithoutWaitingMetadata() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let snapshot = AgtmuxSnapshot(version: 1, panes: [metadataPane])

        let model = AppViewModel(
            localClient: StubSnapshotClient(steps: [
                SnapshotStep(delayMs: 700, result: .success(snapshot)),
            ]),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        let started = Date()
        await model.fetchAll()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            0.35,
            "inventory-first path must not block on delayed metadata fetch"
        )
        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)

        let overlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(overlayApplied, "metadata overlay should apply asynchronously without next poll")
        XCTAssertEqual(model.panes.first?.provider, .codex)
    }

    @MainActor
    func testMetadataFailureDoesNotClearPreviousOverlay() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let snapshot = AgtmuxSnapshot(version: 1, panes: [metadataPane])

        let model = AppViewModel(
            localClient: StubSnapshotClient(steps: [
                SnapshotStep(delayMs: 20, result: .success(snapshot)),
                SnapshotStep(delayMs: 20, result: .failure(StubError.timedOut)),
            ]),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let firstOverlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(firstOverlayApplied)

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            model.panes.first?.presence,
            .managed,
            "metadata timeout/failure must not destructively clear cached overlay"
        )
        XCTAssertEqual(model.panes.first?.provider, .codex)
    }
}
