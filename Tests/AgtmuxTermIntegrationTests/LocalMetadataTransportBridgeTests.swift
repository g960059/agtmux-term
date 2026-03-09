import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalMetadataTransportBridgeTests: XCTestCase {
    private enum StubError: Error {
        case exhausted
    }

    private actor StubMetadataClient: LocalMetadataClient {
        private var bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>]
        private var bootstrapV2Results: [Result<AgtmuxSyncV2Bootstrap, Error>]
        private(set) var bootstrapV3Calls = 0
        private(set) var bootstrapV2Calls = 0

        init(
            bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>] = [],
            bootstrapV2Results: [Result<AgtmuxSyncV2Bootstrap, Error>] = []
        ) {
            self.bootstrapV3Results = bootstrapV3Results
            self.bootstrapV2Results = bootstrapV2Results
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
            case .success(let bootstrap):
                return bootstrap
            case .failure(let error):
                throw error
            }
        }

        func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap {
            bootstrapV2Calls += 1
            guard !bootstrapV2Results.isEmpty else {
                throw StubError.exhausted
            }
            switch bootstrapV2Results.removeFirst() {
            case .success(let bootstrap):
                return bootstrap
            case .failure(let error):
                throw error
            }
        }

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            throw StubError.exhausted
        }

        func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse {
            throw StubError.exhausted
        }

        func resetUIChangesV2() async {}
        func resetUIChangesV3() async {}

        func callCounts() -> (bootstrapV3: Int, bootstrapV2: Int) {
            (bootstrapV3Calls, bootstrapV2Calls)
        }
    }

    private func makeBootstrapV3() -> AgtmuxSyncV3Bootstrap {
        AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [
                AgtmuxSyncV3PaneSnapshot(
                    sessionName: "workbench",
                    windowID: "@5",
                    sessionKey: "codex:%12",
                    paneID: "%12",
                    paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                        paneId: "%12",
                        generation: 7,
                        birthTs: Date(timeIntervalSince1970: 1_778_822_994)
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
                            startedAt: Date(timeIntervalSince1970: 1_778_822_994),
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
                    updatedAt: Date(timeIntervalSince1970: 1_778_823_000)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_778_823_001),
            replayCursor: AgtmuxSyncV3Cursor(seq: 1)
        )
    }

    private func makeBootstrapV2() -> AgtmuxSyncV2Bootstrap {
        AgtmuxSyncV2Bootstrap(
            epoch: 1,
            snapshotSeq: 1,
            panes: [
                AgtmuxPane(
                    source: "local",
                    paneId: "%12",
                    sessionName: "workbench",
                    windowId: "@5",
                    activityState: .running,
                    presence: .managed,
                    provider: .codex,
                    currentCmd: "zsh",
                    metadataSessionKey: "opaque-v2",
                    paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                        paneId: "%12",
                        generation: 7,
                        birthTs: Date(timeIntervalSince1970: 1_778_822_994)
                    )
                )
            ],
            sessions: [],
            generatedAt: Date(timeIntervalSince1970: 1_778_930_000),
            replayCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 1)
        )
    }

    func testFetchBootstrapPrefersV3WhenAvailable() async throws {
        let client = StubMetadataClient(
            bootstrapV3Results: [.success(makeBootstrapV3())]
        )
        let bridge = LocalMetadataTransportBridge()

        let bootstrap = try await bridge.fetchBootstrap(using: client)

        switch bootstrap {
        case .v3(let payload):
            XCTAssertEqual(payload.panes.first?.provider, .codex)
        case .v2:
            XCTFail("expected v3 bootstrap when available")
        }
        XCTAssertTrue(bridge.prefersSyncV3)
        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 1)
        XCTAssertEqual(counts.bootstrapV2, 0)
    }

    func testFetchBootstrapFallsBackToV2AndSticksAfterUnsupportedV3() async throws {
        let client = StubMetadataClient(
            bootstrapV3Results: [
                .failure(LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3"))
            ],
            bootstrapV2Results: [
                .success(makeBootstrapV2()),
                .success(makeBootstrapV2())
            ]
        )
        let bridge = LocalMetadataTransportBridge()

        let first = try await bridge.fetchBootstrap(using: client)
        switch first {
        case .v2(let payload):
            XCTAssertEqual(payload.panes.first?.metadataSessionKey, "opaque-v2")
        case .v3:
            XCTFail("expected v2 fallback after unsupported v3")
        }
        XCTAssertFalse(bridge.prefersSyncV3)

        let second = try await bridge.fetchBootstrap(using: client)
        switch second {
        case .v2:
            break
        case .v3:
            XCTFail("expected sticky v2 preference after unsupported v3")
        }
        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 1)
        XCTAssertEqual(counts.bootstrapV2, 2)
    }

    func testMarkV3UnsupportedIgnoresNonMethodNotFoundErrors() {
        let bridge = LocalMetadataTransportBridge()

        let shouldFallback = bridge.markV3UnsupportedIfNeeded(
            DaemonError.parseError("RPC ui.bootstrap.v3 parse failed: bad payload")
        )

        XCTAssertFalse(shouldFallback)
        XCTAssertTrue(bridge.prefersSyncV3)
    }
}
