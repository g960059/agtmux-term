import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class PreferredLocalMetadataClientTests: XCTestCase {
    private enum StubError: Error {
        case unused
    }

    private actor StubClient: LocalMetadataHealthClient {
        private let bootstrapResult: Result<AgtmuxSyncV3Bootstrap, Error>
        private(set) var bootstrapCallCount = 0
        private(set) var resetCallCount = 0

        init(bootstrapResult: Result<AgtmuxSyncV3Bootstrap, Error>) {
            self.bootstrapResult = bootstrapResult
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.unused
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapCallCount += 1
            return try bootstrapResult.get()
        }

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            .changes(
                AgtmuxSyncV3Changes(
                    fromSeq: 1,
                    toSeq: 1,
                    nextCursor: AgtmuxSyncV3Cursor(seq: 1),
                    changes: []
                )
            )
        }

        func waitForUIChangesV1(timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
            throw LocalMetadataClientError.unsupportedMethod("ui.wait_for_changes.v1")
        }

        func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
            throw LocalHealthClientError.unsupportedMethod("ui.health.v1")
        }

        func resetUIChangesV3() async {
            resetCallCount += 1
        }
    }

    func testFallsBackToSocketClientWhenXPCProxyUnavailable() async throws {
        let primary = StubClient(
            bootstrapResult: .failure(XPCClientError.proxyUnavailable)
        )
        let fallback = StubClient(
            bootstrapResult: .success(makeBootstrap(provider: .codex))
        )
        let startProbe = Counter()

        let client = PreferredLocalMetadataClient(
            primary: primary,
            fallback: fallback,
            startFallbackRuntimeIfNeeded: {
                await startProbe.increment()
            }
        )

        let bootstrap = try await client.fetchUIBootstrapV3()
        let primaryBootstrapCalls1 = await primary.bootstrapCallCount
        let fallbackBootstrapCalls1 = await fallback.bootstrapCallCount
        let startCount1 = await startProbe.value
        XCTAssertEqual(bootstrap.panes.first?.provider, .codex)
        XCTAssertEqual(primaryBootstrapCalls1, 1)
        XCTAssertEqual(fallbackBootstrapCalls1, 1)
        XCTAssertEqual(startCount1, 1)

        _ = try await client.fetchUIBootstrapV3()
        let primaryBootstrapCalls2 = await primary.bootstrapCallCount
        let fallbackBootstrapCalls2 = await fallback.bootstrapCallCount
        let startCount2 = await startProbe.value
        XCTAssertEqual(primaryBootstrapCalls2, 1)
        XCTAssertEqual(fallbackBootstrapCalls2, 2)
        XCTAssertEqual(startCount2, 2)
    }

    func testDoesNotFallbackForMetadataDecodeError() async {
        let primary = StubClient(
            bootstrapResult: .failure(
                XPCClientError.decode(
                    "Local metadata protocol parse failed (ui.bootstrap.v3): missing required exact identity field 'session_key'"
                )
            )
        )
        let fallback = StubClient(
            bootstrapResult: .success(makeBootstrap(provider: .claude))
        )
        let startProbe = Counter()

        let client = PreferredLocalMetadataClient(
            primary: primary,
            fallback: fallback,
            startFallbackRuntimeIfNeeded: {
                await startProbe.increment()
            }
        )

        do {
            _ = try await client.fetchUIBootstrapV3()
            XCTFail("expected metadata decode error")
        } catch let error as XPCClientError {
            guard case .decode = error else {
                return XCTFail("unexpected XPC error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let primaryBootstrapCalls = await primary.bootstrapCallCount
        let fallbackBootstrapCalls = await fallback.bootstrapCallCount
        let startCount = await startProbe.value
        XCTAssertEqual(primaryBootstrapCalls, 1)
        XCTAssertEqual(fallbackBootstrapCalls, 0)
        XCTAssertEqual(startCount, 0)
    }

    func testResetForwardsToBothClients() async {
        let primary = StubClient(
            bootstrapResult: .success(makeBootstrap(provider: .codex))
        )
        let fallback = StubClient(
            bootstrapResult: .success(makeBootstrap(provider: .codex))
        )
        let client = PreferredLocalMetadataClient(primary: primary, fallback: fallback)

        await client.resetUIChangesV3()

        let primaryResets = await primary.resetCallCount
        let fallbackResets = await fallback.resetCallCount
        XCTAssertEqual(primaryResets, 1)
        XCTAssertEqual(fallbackResets, 1)
    }

    private func makeBootstrap(provider: Provider) -> AgtmuxSyncV3Bootstrap {
        AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [
                AgtmuxSyncV3PaneSnapshot(
                    sessionName: "vm agtmux-term",
                    windowID: "@2",
                    sessionKey: "shell:%298",
                    paneID: "%298",
                    paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                        paneId: "%298",
                        generation: 1,
                        birthTs: Date(timeIntervalSince1970: 1_778_909_000)
                    ),
                    provider: provider,
                    bindingEpochID: "epoch-1",
                    runtimeRef: AgtmuxRuntimeRefV3(provider: provider, nativeID: "native-1"),
                    conversationTitle: nil,
                    sessionSubtitle: nil,
                    presence: .managed,
                    agent: AgtmuxSyncV3AgentState(lifecycle: .running),
                    thread: AgtmuxSyncV3ThreadState(
                        lifecycle: .active,
                        blocking: .waitingUserInput,
                        execution: .toolRunning,
                        flags: AgtmuxSyncV3ThreadFlags(reviewMode: false, subagentActive: false),
                        turn: AgtmuxSyncV3TurnState(
                            outcome: .none,
                            sequence: 1,
                            startedAt: Date(timeIntervalSince1970: 1_778_909_005),
                            completedAt: nil
                        )
                    ),
                    pendingRequests: [],
                    attention: AgtmuxSyncV3AttentionSummary(
                        activeKinds: [.question],
                        highestPriority: .question,
                        unresolvedCount: 1,
                        generation: 1,
                        latestAt: Date(timeIntervalSince1970: 1_778_909_006)
                    ),
                    freshness: AgtmuxSyncV3FreshnessSummary(
                        snapshot: .fresh,
                        blocking: .fresh,
                        execution: .fresh
                    ),
                    providerRaw: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_778_909_010)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_778_909_011),
            replayCursor: AgtmuxSyncV3Cursor(seq: 1)
        )
    }
}

private actor Counter {
    private var storage = 0

    func increment() {
        storage += 1
    }

    var value: Int {
        storage
    }
}
