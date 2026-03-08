import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

@MainActor
final class WorkbenchV2DocumentTileTests: XCTestCase {
    func testLoadRequestDefersReachabilitySensitiveRemoteLoadsUntilInventoryIsReady() {
        let request = WorkbenchV2DocumentLoadRequest(
            token: WorkbenchV2DocumentLoadToken(
                tileID: UUID(),
                ref: DocumentRef(target: .remote(hostKey: "docs"), path: "/srv/spec.md")
            ),
            offlineHostnames: [],
            inventoryReady: false
        )
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "docs",
                displayName: "Docs",
                hostname: "docs.example.com",
                user: nil,
                transport: .ssh
            )
        ])

        XCTAssertTrue(request.shouldDeferLoad(hostsConfig: hostsConfig))
    }

    func testLoadRequestDoesNotDeferMissingRemoteHostBecauseConfigIssueIsImmediate() {
        let request = WorkbenchV2DocumentLoadRequest(
            token: WorkbenchV2DocumentLoadToken(
                tileID: UUID(),
                ref: DocumentRef(target: .remote(hostKey: "missing"), path: "/srv/spec.md")
            ),
            offlineHostnames: [],
            inventoryReady: false
        )

        XCTAssertFalse(request.shouldDeferLoad(hostsConfig: .empty))
    }

    func testRebindTargetOptionsKeepMissingRemoteSelectionExplicit() {
        let options = WorkbenchDocumentRebindSheetV2.targetOptions(
            hostsConfig: .empty,
            initialRef: DocumentRef(target: .remote(hostKey: "missing"), path: "/srv/spec.md")
        )

        XCTAssertEqual(
            options.first,
            WorkbenchDocumentRebindTargetOptionV2(
                id: WorkbenchDocumentRebindTargetOptionV2.missingTargetIDPrefix + "missing",
                label: "Unavailable: missing",
                target: nil
            )
        )
        XCTAssertEqual(options.dropFirst().map(\.id), ["local"])
    }

    func testPreflightIssueMapsMissingRemoteHostToHostMissing() {
        let ref = DocumentRef(target: .remote(hostKey: "missing"), path: "/srv/spec.md")

        let issue = WorkbenchV2DocumentRestoreIssue.preflightIssue(
            ref: ref,
            hostsConfig: .empty,
            offlineHostnames: []
        )

        XCTAssertEqual(issue, .hostMissing("missing"))
    }

    func testPreflightIssueMapsOfflineRemoteHostToHostOffline() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "docs",
                displayName: "Docs",
                hostname: "docs.example.com",
                user: nil,
                transport: .ssh
            )
        ])
        let ref = DocumentRef(target: .remote(hostKey: "docs"), path: "/srv/spec.md")

        let issue = WorkbenchV2DocumentRestoreIssue.preflightIssue(
            ref: ref,
            hostsConfig: hostsConfig,
            offlineHostnames: ["docs.example.com"]
        )

        XCTAssertEqual(issue, .hostOffline("docs"))
    }

    func testLoadIssueMapsFileNotFoundToPathMissing() {
        let ref = DocumentRef(target: .local, path: "/tmp/missing.md")

        let issue = WorkbenchV2DocumentRestoreIssue.loadIssue(
            for: WorkbenchV2DocumentLoadError.fileNotFound("/tmp/missing.md"),
            ref: ref
        )

        XCTAssertEqual(issue, .pathMissing("/tmp/missing.md"))
    }

    func testLoadIssueMapsGenericFailureToAccessFailed() {
        let ref = DocumentRef(target: .local, path: "/tmp/spec.md")

        let issue = WorkbenchV2DocumentRestoreIssue.loadIssue(
            for: StubDocumentLoadError(message: "permission denied"),
            ref: ref
        )

        XCTAssertEqual(issue, .accessFailed("permission denied"))
    }

    func testLoadIssueMapsRemoteFileNotFoundToPathMissing() {
        let ref = DocumentRef(target: .remote(hostKey: "docs"), path: "/srv/spec.md")

        let issue = WorkbenchV2DocumentRestoreIssue.loadIssue(
            for: WorkbenchV2DocumentLoadError.remoteCommandFailed(
                hostKey: "docs",
                message: "file not found"
            ),
            ref: ref
        )

        XCTAssertEqual(issue, .pathMissing("/srv/spec.md"))
    }

    func testLateCompletionForOldTokenDoesNotOverwriteNewerTokenPhase() async {
        let loader = ControlledDocumentLoader()
        let coordinator = WorkbenchV2DocumentLoadCoordinator(loader: { ref, hostsConfig in
            try await loader.load(ref: ref, hostsConfig: hostsConfig)
        })
        let ref = DocumentRef(target: .local, path: "/tmp/readme.md")
        let oldToken = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref)
        let newToken = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref)
        let staleTask = Task { @MainActor in
            await coordinator.load(token: oldToken, ref: ref, hostsConfig: .empty)
        }

        await loader.waitForRegisteredCalls(1)

        let currentTask = Task { @MainActor in
            await coordinator.load(token: newToken, ref: ref, hostsConfig: .empty)
        }
        await loader.waitForRegisteredCalls(2)

        let currentSnapshot = WorkbenchV2DocumentSnapshot(text: "replacement", targetLabel: "local")
        await loader.resolve(callAt: 1, with: .success(currentSnapshot))
        await currentTask.value

        XCTAssertEqual(coordinator.phase, .loaded(currentSnapshot))

        let staleSnapshot = WorkbenchV2DocumentSnapshot(text: "stale", targetLabel: "local")
        await loader.resolve(callAt: 0, with: .success(staleSnapshot))
        await staleTask.value

        XCTAssertEqual(coordinator.phase, .loaded(currentSnapshot))
    }

    func testCancelledCompletionIsIgnored() async {
        let loader = ControlledDocumentLoader()
        let coordinator = WorkbenchV2DocumentLoadCoordinator(loader: { ref, hostsConfig in
            try await loader.load(ref: ref, hostsConfig: hostsConfig)
        })
        let ref = DocumentRef(target: .local, path: "/tmp/spec.md")
        let token = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref)
        let task = Task { @MainActor in
            await coordinator.load(token: token, ref: ref, hostsConfig: .empty)
        }

        await loader.waitForRegisteredCalls(1)
        task.cancel()

        let snapshot = WorkbenchV2DocumentSnapshot(text: "cancelled", targetLabel: "local")
        await loader.resolve(callAt: 0, with: .success(snapshot))
        await task.value

        XCTAssertEqual(coordinator.phase, .loading)
    }

    func testCurrentTokenSuccessCommitsLoadedPhase() async {
        let loader = ControlledDocumentLoader()
        let coordinator = WorkbenchV2DocumentLoadCoordinator(loader: { ref, hostsConfig in
            try await loader.load(ref: ref, hostsConfig: hostsConfig)
        })
        let ref = DocumentRef(target: .local, path: "/tmp/guide.md")
        let token = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref)
        let task = Task { @MainActor in
            await coordinator.load(token: token, ref: ref, hostsConfig: .empty)
        }

        await loader.waitForRegisteredCalls(1)

        let snapshot = WorkbenchV2DocumentSnapshot(text: "loaded", targetLabel: "local")
        await loader.resolve(callAt: 0, with: .success(snapshot))
        await task.value

        XCTAssertEqual(coordinator.phase, .loaded(snapshot))
    }

    func testCurrentTokenFailureCommitsFailedPhase() async {
        let loader = ControlledDocumentLoader()
        let coordinator = WorkbenchV2DocumentLoadCoordinator(loader: { ref, hostsConfig in
            try await loader.load(ref: ref, hostsConfig: hostsConfig)
        })
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "devbox",
                displayName: "Devbox",
                hostname: "devbox.example.com",
                user: nil,
                transport: .ssh
            )
        ])
        let ref = DocumentRef(target: .remote(hostKey: "devbox"), path: "/srv/app/README.md")
        let token = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref)
        let task = Task { @MainActor in
            await coordinator.load(token: token, ref: ref, hostsConfig: hostsConfig)
        }

        await loader.waitForRegisteredCalls(1)
        await loader.resolve(callAt: 0, with: .failure(StubDocumentLoadError(message: "remote fetch failed")))
        await task.value

        XCTAssertEqual(coordinator.phase, .failed(.accessFailed("remote fetch failed")))
    }

    func testRetryTokenCanRecoverFromFailedIssueToLoaded() async {
        let loader = ControlledDocumentLoader()
        let coordinator = WorkbenchV2DocumentLoadCoordinator(loader: { ref, hostsConfig in
            try await loader.load(ref: ref, hostsConfig: hostsConfig)
        })
        let ref = DocumentRef(target: .local, path: "/tmp/spec.md")
        let initialToken = WorkbenchV2DocumentLoadToken(tileID: UUID(), ref: ref, attempt: 0)
        let retryToken = WorkbenchV2DocumentLoadToken(tileID: initialToken.tileID, ref: ref, attempt: 1)

        let firstTask = Task { @MainActor in
            await coordinator.load(token: initialToken, ref: ref, hostsConfig: .empty)
        }
        await loader.waitForRegisteredCalls(1)
        await loader.resolve(callAt: 0, with: .failure(StubDocumentLoadError(message: "temporary failure")))
        await firstTask.value

        XCTAssertEqual(coordinator.phase, .failed(.accessFailed("temporary failure")))

        let retryTask = Task { @MainActor in
            await coordinator.load(token: retryToken, ref: ref, hostsConfig: .empty)
        }
        await loader.waitForRegisteredCalls(2)
        let snapshot = WorkbenchV2DocumentSnapshot(text: "recovered", targetLabel: "local")
        await loader.resolve(callAt: 1, with: .success(snapshot))
        await retryTask.value

        XCTAssertEqual(coordinator.phase, .loaded(snapshot))
    }
}

private actor ControlledDocumentLoader {
    private var nextCallIndex = 0
    private var registeredCallCount = 0
    private var continuations: [Int: CheckedContinuation<WorkbenchV2DocumentSnapshot, Error>] = [:]
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func load(
        ref: DocumentRef,
        hostsConfig: HostsConfig
    ) async throws -> WorkbenchV2DocumentSnapshot {
        let callIndex = nextCallIndex
        nextCallIndex += 1

        return try await withCheckedThrowingContinuation { continuation in
            continuations[callIndex] = continuation
            registeredCallCount += 1
            resumeReadyWaiters()
        }
    }

    func waitForRegisteredCalls(_ expectedCount: Int) async {
        guard registeredCallCount < expectedCount else {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters[expectedCount, default: []].append(continuation)
        }
    }

    func resolve(
        callAt index: Int,
        with result: Result<WorkbenchV2DocumentSnapshot, Error>
    ) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            preconditionFailure("Missing document load continuation for call \(index)")
        }

        switch result {
        case .success(let snapshot):
            continuation.resume(returning: snapshot)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func resumeReadyWaiters() {
        let readyCounts = callWaiters.keys.filter { registeredCallCount >= $0 }
        for readyCount in readyCounts {
            guard let waiters = callWaiters.removeValue(forKey: readyCount) else {
                continue
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

private struct StubDocumentLoadError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
