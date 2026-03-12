import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class AgtmuxDaemonXPCClientTests: XCTestCase {
    private final class ProxyStub: NSObject, AgtmuxDaemonServiceXPCProtocol {
        var startManagedDaemonResult: (Bool, String?) = (true, nil)
        var bootstrapV3Reply: (Data?, String?) = (nil, nil)
        var changesV3Reply: (Data?, String?) = (nil, nil)
        var healthReply: (Data?, String?) = (nil, nil)
        private(set) var startManagedDaemonCalls = 0
        private(set) var fetchUIBootstrapV3Calls = 0
        private(set) var fetchUIChangesV3Calls = 0
        private(set) var fetchUIHealthV1Calls = 0
        private(set) var resetUIChangesV3Calls = 0
        private(set) var lastFetchUIChangesV3Limit: Int?

        func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
            startManagedDaemonCalls += 1
            reply(startManagedDaemonResult.0, startManagedDaemonResult.1.map { $0 as NSString })
        }

        func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
            reply(nil, "unexpected fetchSnapshot call" as NSString)
        }

        func fetchUIBootstrapV3(_ reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIBootstrapV3Calls += 1
            reply(bootstrapV3Reply.0.map { $0 as NSData }, bootstrapV3Reply.1.map { $0 as NSString })
        }

        func fetchUIChangesV3(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIChangesV3Calls += 1
            lastFetchUIChangesV3Limit = limit.intValue
            reply(changesV3Reply.0.map { $0 as NSData }, changesV3Reply.1.map { $0 as NSString })
        }

        func fetchUIHealthV1(_ reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIHealthV1Calls += 1
            reply(healthReply.0.map { $0 as NSData }, healthReply.1.map { $0 as NSString })
        }

        func waitForUIChangesV1(_ timeoutMs: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
            reply(nil, "unsupported" as NSString)
        }

        func resetUIChangesV3(_ reply: @escaping () -> Void) {
            resetUIChangesV3Calls += 1
            reply()
        }

        func stopManagedDaemon(_ reply: @escaping () -> Void) {
            reply()
        }
    }

    func testFetchUIBootstrapV3DecodesBootstrapPayloadFromInjectedXPCProxy() async throws {
        let expected = makeBootstrapV3()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let proxy = ProxyStub()
        proxy.bootstrapV3Reply = (try encoder.encode(expected), nil)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        let actual = try await client.fetchUIBootstrapV3()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIBootstrapV3Calls, 1)
    }

    func testFetchUIChangesV3DecodesPayloadAndForwardsLimitFromInjectedXPCProxy() async throws {
        let bootstrap = makeBootstrapV3(replayCursor: .init(seq: 40))
        let expected = makeChangesResponseV3(nextCursor: .init(seq: 41))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let proxy = ProxyStub()
        proxy.bootstrapV3Reply = (try encoder.encode(bootstrap), nil)
        proxy.changesV3Reply = (try encoder.encode(expected), nil)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        _ = try await client.fetchUIBootstrapV3()
        let actual = try await client.fetchUIChangesV3(limit: 19)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIBootstrapV3Calls, 1)
        XCTAssertEqual(proxy.fetchUIChangesV3Calls, 1)
        XCTAssertEqual(proxy.lastFetchUIChangesV3Limit, 19)
    }

    func testFetchUIHealthV1DecodesHealthPayloadFromInjectedXPCProxy() async throws {
        let expected = makeHealth(
            runtimeStatus: .degraded,
            replayStatus: .degraded,
            replayLag: 12,
            overlayStatus: .ok,
            focusStatus: .unavailable,
            focusMismatchCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let proxy = ProxyStub()
        proxy.healthReply = (try encoder.encode(expected), nil)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        let actual = try await client.fetchUIHealthV1()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIHealthV1Calls, 1)
    }

    func testFetchUIHealthV1PreservesStructuredUnsupportedPayloadFromInjectedXPCProxy() async throws {
        let structuredError = DaemonError.makeUIHealthMethodNotFoundError(
            method: "ui.health.v1",
            rpcCode: -32601,
            message: "ui.health.v1 observability is not available on this daemon"
        )
        let structuredText: String
        switch structuredError {
        case let .processError(_, stderr):
            structuredText = stderr
        default:
            return XCTFail("expected processError-backed structured ui.health.v1 error")
        }

        let proxy = ProxyStub()
        proxy.healthReply = (nil, structuredText)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        do {
            _ = try await client.fetchUIHealthV1()
            XCTFail("expected ui.health.v1 XPC fetch to fail")
        } catch let XPCClientError.remote(text) {
            XCTAssertEqual(text, structuredText)
            let envelope = DaemonError.decodeUIErrorEnvelope(from: text)
            XCTAssertEqual(envelope?.code, DaemonUIErrorCode.uiHealthMethodNotFound.rawValue)
            XCTAssertEqual(envelope?.method, "ui.health.v1")
            XCTAssertEqual(envelope?.rpcCode, -32601)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIHealthV1Calls, 1)
    }

    private func makeBootstrapV3(replayCursor: AgtmuxSyncV3Cursor? = nil) -> AgtmuxSyncV3Bootstrap {
        let generatedAt = ISO8601DateFormatter().date(from: "2026-03-09T20:11:04Z")!
        return AgtmuxSyncV3Bootstrap(
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
                        birthTs: ISO8601DateFormatter().date(from: "2026-03-09T20:09:54Z")
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
                            sequence: 42,
                            startedAt: ISO8601DateFormatter().date(from: "2026-03-09T20:10:00Z"),
                            completedAt: nil
                        )
                    ),
                    pendingRequests: [],
                    attention: AgtmuxSyncV3AttentionSummary(
                        activeKinds: [],
                        highestPriority: .none,
                        unresolvedCount: 0,
                        generation: 0,
                        latestAt: nil
                    ),
                    freshness: AgtmuxSyncV3FreshnessSummary(
                        snapshot: .fresh,
                        blocking: .fresh,
                        execution: .fresh
                    ),
                    providerRaw: AgtmuxSyncV3ProviderRaw(
                        valuesByProvider: [
                            "codex": .init(
                                .object([
                                    "thread_status_type": .init(.string("active"))
                                ])
                            )
                        ]
                    ),
                    updatedAt: generatedAt
                )
            ],
            generatedAt: generatedAt,
            replayCursor: replayCursor
        )
    }

    private func makeChangesResponseV3(
        nextCursor: AgtmuxSyncV3Cursor
    ) -> AgtmuxSyncV3ChangesResponse {
        let pane = makeBootstrapV3().panes[0]
        return .changes(
            AgtmuxSyncV3Changes(
                fromSeq: nextCursor.seq,
                toSeq: nextCursor.seq,
                nextCursor: nextCursor,
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: nextCursor.seq,
                        at: Date(timeIntervalSince1970: 1_778_825_310),
                        kind: .upsert,
                        paneID: pane.paneID,
                        sessionName: pane.sessionName,
                        windowID: pane.windowID,
                        sessionKey: pane.sessionKey,
                        paneInstanceID: pane.paneInstanceID,
                        fieldGroups: [.thread, .pendingRequests, .attention],
                        pane: pane
                    )
                ]
            )
        )
    }

    private func makeHealth(
        runtimeStatus: AgtmuxUIHealthStatus,
        replayStatus: AgtmuxUIHealthStatus,
        replayLag: UInt64?,
        overlayStatus: AgtmuxUIHealthStatus,
        focusStatus: AgtmuxUIHealthStatus,
        focusMismatchCount: UInt64?
    ) -> AgtmuxUIHealthV1 {
        let generatedAt = ISO8601DateFormatter().date(from: "2026-03-06T20:00:00Z")!
        return AgtmuxUIHealthV1(
            generatedAt: generatedAt,
            runtime: AgtmuxUIComponentHealth(
                status: runtimeStatus,
                detail: "runtime detail",
                lastUpdatedAt: generatedAt.addingTimeInterval(-2)
            ),
            replay: AgtmuxUIReplayHealth(
                status: replayStatus,
                currentEpoch: 4,
                cursorSeq: 32,
                headSeq: 44,
                lag: replayLag,
                lastResyncReason: "trimmed_cursor",
                lastResyncAt: generatedAt.addingTimeInterval(-4),
                detail: "replay detail"
            ),
            overlay: AgtmuxUIComponentHealth(
                status: overlayStatus,
                detail: "overlay detail",
                lastUpdatedAt: generatedAt.addingTimeInterval(-1)
            ),
            focus: AgtmuxUIFocusHealth(
                status: focusStatus,
                focusedPaneID: "%42",
                mismatchCount: focusMismatchCount,
                lastSyncAt: generatedAt.addingTimeInterval(-3),
                detail: "focus detail"
            )
        )
    }
}
