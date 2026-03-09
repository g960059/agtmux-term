import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalMetadataRefreshCoordinatorTests: XCTestCase {
    private enum StubError: Error {
        case exhausted
        case transportFailure
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private actor StubMetadataClient: LocalMetadataClient {
        private var bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>]
        private var bootstrapV2Results: [Result<AgtmuxSyncV2Bootstrap, Error>]
        private var changesV3Results: [Result<AgtmuxSyncV3ChangesResponse, Error>]
        private var changesV2Results: [Result<AgtmuxSyncV2ChangesResponse, Error>]
        private(set) var bootstrapV3Calls = 0
        private(set) var bootstrapV2Calls = 0
        private(set) var changesV3Calls = 0
        private(set) var changesV2Calls = 0

        init(
            bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>] = [],
            bootstrapV2Results: [Result<AgtmuxSyncV2Bootstrap, Error>] = [],
            changesV3Results: [Result<AgtmuxSyncV3ChangesResponse, Error>] = [],
            changesV2Results: [Result<AgtmuxSyncV2ChangesResponse, Error>] = []
        ) {
            self.bootstrapV3Results = bootstrapV3Results
            self.bootstrapV2Results = bootstrapV2Results
            self.changesV3Results = changesV3Results
            self.changesV2Results = changesV2Results
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.exhausted
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapV3Calls += 1
            guard !bootstrapV3Results.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3")
            }
            switch bootstrapV3Results.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap {
            bootstrapV2Calls += 1
            guard !bootstrapV2Results.isEmpty else { throw StubError.exhausted }
            switch bootstrapV2Results.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            changesV3Calls += 1
            guard !changesV3Results.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.changes.v3")
            }
            switch changesV3Results.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse {
            changesV2Calls += 1
            guard !changesV2Results.isEmpty else { throw StubError.exhausted }
            switch changesV2Results.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func resetUIChangesV2() async {}
        func resetUIChangesV3() async {}

        func callCounts() -> (bootstrapV3: Int, bootstrapV2: Int, changesV3: Int, changesV2: Int) {
            (bootstrapV3Calls, bootstrapV2Calls, changesV3Calls, changesV2Calls)
        }
    }

    func testRunStepBootstrapsV3AndPublishesManagedCache() async throws {
        let client = StubMetadataClient(
            bootstrapV3Results: [.success(makeBootstrapV3())]
        )
        let bridge = LocalMetadataTransportBridge()
        let coordinator = LocalMetadataRefreshCoordinator(
            client: client,
            transportBridge: bridge,
            now: { self.now }
        )

        let execution = try await coordinator.runStep(
            context: makeContext(syncPrimed: false, transportVersion: nil, inventoryCount: 1),
            overlayStore: makeOverlayStore()
        )

        XCTAssertEqual(execution.preApplyLogMessages, [])
        XCTAssertEqual(execution.replayResetVersions, [])
        XCTAssertEqual(execution.plan.state.syncPrimed, true)
        XCTAssertEqual(execution.plan.state.transportVersion, .v3)
        XCTAssertEqual(execution.plan.state.nextRefreshAt, now.addingTimeInterval(1.0))
        XCTAssertEqual(execution.plan.cacheAction, .replace(LocalMetadataOverlayCache(
            metadataByPaneKey: ["local:visible-session:@1:%1": makeExpectedV3Pane()],
            presentationByPaneKey: ["local:visible-session:@1:%1": PanePresentationState(snapshot: makeV3Snapshot())]
        )))
    }

    func testRunStepReturnsDeferredClearWhenBootstrapIsEmptyWithInventory() async throws {
        let client = StubMetadataClient(
            bootstrapV3Results: [
                .success(
                    AgtmuxSyncV3Bootstrap(
                        version: 3,
                        panes: [],
                        generatedAt: now,
                        replayCursor: AgtmuxSyncV3Cursor(seq: 0)
                    )
                )
            ]
        )
        let bridge = LocalMetadataTransportBridge()
        let coordinator = LocalMetadataRefreshCoordinator(
            client: client,
            transportBridge: bridge,
            now: { self.now }
        )

        let execution = try await coordinator.runStep(
            context: makeContext(syncPrimed: false, transportVersion: nil, inventoryCount: 2),
            overlayStore: makeOverlayStore()
        )

        XCTAssertEqual(execution.replayResetVersions, [.v3])
        XCTAssertEqual(execution.plan.cacheAction, .clear)
        XCTAssertEqual(execution.plan.state.syncPrimed, false)
        XCTAssertNil(execution.plan.state.transportVersion)
        XCTAssertEqual(execution.plan.logMessage, "sync-v3 bootstrap not ready; local inventory has 2 panes but bootstrap returned panes=0")
        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 1)
        XCTAssertEqual(counts.bootstrapV2, 0)
    }

    func testRunStepThrowsWhenBootstrapV3IsUnsupportedInsteadOfFallingBackToV2() async {
        let client = StubMetadataClient(
            bootstrapV3Results: [.failure(LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3"))],
            bootstrapV2Results: [.success(makeBootstrapV2())]
        )
        let bridge = LocalMetadataTransportBridge()
        let coordinator = LocalMetadataRefreshCoordinator(
            client: client,
            transportBridge: bridge,
            now: { self.now }
        )

        do {
            _ = try await coordinator.runStep(
                context: makeContext(syncPrimed: false, transportVersion: nil, inventoryCount: 1),
                overlayStore: makeOverlayStore()
            )
            XCTFail("expected unsupported ui.bootstrap.v3 to throw")
        } catch let error as LocalMetadataClientError {
            guard case let .unsupportedMethod(method) = error else {
                return XCTFail("unexpected local metadata error: \(error)")
            }
            XCTAssertEqual(method, "ui.bootstrap.v3")
        } catch {
            XCTFail("expected LocalMetadataClientError.unsupportedMethod, got \(error)")
        }

        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 1)
        XCTAssertEqual(counts.bootstrapV2, 0)
        XCTAssertEqual(counts.changesV3, 0)
        XCTAssertEqual(counts.changesV2, 0)
    }

    func testRunStepThrowsWhenChangesV3IsUnsupportedInsteadOfFallingBackToV2() async {
        let client = StubMetadataClient(
            changesV3Results: [.failure(LocalMetadataClientError.unsupportedMethod("ui.changes.v3"))],
            changesV2Results: [.success(.changes(makeChangesV2()))]
        )
        let bridge = LocalMetadataTransportBridge()
        let coordinator = LocalMetadataRefreshCoordinator(
            client: client,
            transportBridge: bridge,
            now: { self.now }
        )

        do {
            _ = try await coordinator.runStep(
                context: makeContext(syncPrimed: true, transportVersion: .v3, inventoryCount: 1),
                overlayStore: makeOverlayStore()
            )
            XCTFail("expected unsupported ui.changes.v3 to throw")
        } catch let error as LocalMetadataClientError {
            guard case let .unsupportedMethod(method) = error else {
                return XCTFail("unexpected local metadata error: \(error)")
            }
            XCTAssertEqual(method, "ui.changes.v3")
        } catch {
            XCTFail("expected LocalMetadataClientError.unsupportedMethod, got \(error)")
        }

        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 0)
        XCTAssertEqual(counts.bootstrapV2, 0)
        XCTAssertEqual(counts.changesV3, 1)
        XCTAssertEqual(counts.changesV2, 0)
    }

    func testFailureExecutionAlwaysUsesV3ReplayResetVersionForProductPath() {
        let bridge = LocalMetadataTransportBridge()
        let coordinator = LocalMetadataRefreshCoordinator(
            client: StubMetadataClient(),
            transportBridge: bridge,
            now: { self.now }
        )

        let execution = coordinator.failureExecution(
            context: makeContext(syncPrimed: true, transportVersion: nil, inventoryCount: 0),
            error: StubError.transportFailure,
            classifyLocalDaemonIssue: { _ in .localDaemonUnavailable(detail: "daemon unavailable") }
        )

        XCTAssertEqual(execution.replayResetVersions, [.v3])
        XCTAssertEqual(execution.plan.cacheAction, .clear)
        XCTAssertEqual(execution.plan.state.nextRefreshAt, now.addingTimeInterval(3.0))
        XCTAssertEqual(execution.postApplyLogMessages, ["sync metadata unavailable; cleared cached overlay: transportFailure"])
    }

    private func makeChangesV2() -> AgtmuxSyncV2Changes {
        AgtmuxSyncV2Changes(
            epoch: 1,
            changes: [],
            fromSeq: 1,
            toSeq: 2,
            nextCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 2)
        )
    }

    private func makeContext(
        syncPrimed: Bool,
        transportVersion: LocalMetadataTransportVersion?,
        inventoryCount: Int
    ) -> LocalMetadataRefreshContext {
        LocalMetadataRefreshContext(
            syncPrimed: syncPrimed,
            transportVersion: transportVersion,
            inventoryCount: inventoryCount,
            successInterval: 1.0,
            failureBackoff: 3.0,
            bootstrapNotReadyBackoff: 0.5,
            changeLimit: 256
        )
    }

    private func makeOverlayStore() -> LocalMetadataOverlayStore {
        LocalMetadataOverlayStore(
            inventory: [makeInventoryPane()],
            metadataByPaneKey: [:],
            presentationByPaneKey: [:]
        )
    }

    private func makeInventoryPane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "visible-session",
            windowId: "@1",
            activityState: .unknown,
            presence: .unmanaged,
            evidenceMode: .none,
            currentCmd: "zsh"
        )
    }

    private func makeExpectedV3Pane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "visible-session",
            windowId: "@1",
            activityState: .running,
            presence: .managed,
            provider: .codex,
            evidenceMode: .deterministic,
            updatedAt: now,
            metadataSessionKey: "opaque-session-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%1",
                generation: 1,
                birthTs: now
            )
        )
    }

    private func makeBootstrapV2() -> AgtmuxSyncV2Bootstrap {
        AgtmuxSyncV2Bootstrap(
            epoch: 1,
            snapshotSeq: 1,
            panes: [makeExpectedV3Pane()],
            sessions: [],
            generatedAt: now,
            replayCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 1)
        )
    }

    private func makeBootstrapV3() -> AgtmuxSyncV3Bootstrap {
        AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [makeV3Snapshot()],
            generatedAt: now,
            replayCursor: AgtmuxSyncV3Cursor(seq: 1)
        )
    }

    private func makeV3Snapshot() -> AgtmuxSyncV3PaneSnapshot {
        AgtmuxSyncV3PaneSnapshot(
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneID: "%1",
            paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                paneId: "%1",
                generation: 1,
                birthTs: now
            ),
            provider: .codex,
            presence: .managed,
            agent: AgtmuxSyncV3AgentState(lifecycle: .running),
            thread: AgtmuxSyncV3ThreadState(
                lifecycle: .active,
                blocking: .none,
                execution: .thinking,
                flags: AgtmuxSyncV3ThreadFlags(reviewMode: false, subagentActive: false),
                turn: AgtmuxSyncV3TurnState(
                    outcome: .none,
                    sequence: 1,
                    startedAt: now,
                    completedAt: nil
                )
            ),
            pendingRequests: [],
            attention: AgtmuxSyncV3AttentionSummary(
                activeKinds: [],
                highestPriority: .none,
                unresolvedCount: 0,
                generation: 1,
                latestAt: nil
            ),
            freshness: AgtmuxSyncV3FreshnessSummary(
                snapshot: .fresh,
                blocking: .fresh,
                execution: .fresh
            ),
            providerRaw: nil,
            updatedAt: now
        )
    }
}
