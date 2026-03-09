import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalMetadataTransportBridgeTests: XCTestCase {
    private enum StubError: Error, Equatable {
        case exhausted
        case sentinel
    }

    private actor StubMetadataClient: LocalMetadataClient {
        private var bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>]
        private(set) var bootstrapV3Calls = 0
        private(set) var bootstrapV2Calls = 0

        init(bootstrapV3Results: [Result<AgtmuxSyncV3Bootstrap, Error>] = []) {
            self.bootstrapV3Results = bootstrapV3Results
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.exhausted
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapV3Calls += 1
            guard !bootstrapV3Results.isEmpty else {
                throw StubError.exhausted
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
            throw StubError.exhausted
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

    func testFetchRequiredBootstrapV3ReturnsV3SnapshotUnchanged() async throws {
        let client = StubMetadataClient(bootstrapV3Results: [.success(makeBootstrapV3())])
        let bridge = LocalMetadataTransportBridge()

        let bootstrap = try await bridge.fetchRequiredBootstrapV3(using: client)

        XCTAssertEqual(bootstrap.panes.first?.provider, .codex)
        XCTAssertEqual(bootstrap.panes.first?.sessionKey, "codex:%12")
        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrapV3, 1)
        XCTAssertEqual(counts.bootstrapV2, 0)
    }

    func testFetchRequiredBootstrapV3PropagatesUnsupportedMethodWithoutFallback() async {
        let client = StubMetadataClient(
            bootstrapV3Results: [.failure(LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3"))]
        )
        let bridge = LocalMetadataTransportBridge()

        do {
            _ = try await bridge.fetchRequiredBootstrapV3(using: client)
            XCTFail("expected unsupported method to propagate")
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
    }
}
