import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class AgtmuxDaemonXPCClientTests: XCTestCase {
    private final class ProxyStub: NSObject, AgtmuxDaemonServiceXPCProtocol {
        var startManagedDaemonResult: (Bool, String?) = (true, nil)
        var bootstrapReply: (Data?, String?) = (nil, nil)
        var changesReply: (Data?, String?) = (nil, nil)
        var healthReply: (Data?, String?) = (nil, nil)
        private(set) var startManagedDaemonCalls = 0
        private(set) var fetchUIBootstrapV2Calls = 0
        private(set) var fetchUIChangesV2Calls = 0
        private(set) var fetchUIHealthV1Calls = 0
        private(set) var lastFetchUIChangesV2Limit: Int?

        func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
            startManagedDaemonCalls += 1
            reply(startManagedDaemonResult.0, startManagedDaemonResult.1.map { $0 as NSString })
        }

        func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
            reply(nil, "unexpected fetchSnapshot call" as NSString)
        }

        func fetchUIBootstrapV2(_ reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIBootstrapV2Calls += 1
            reply(bootstrapReply.0.map { $0 as NSData }, bootstrapReply.1.map { $0 as NSString })
        }

        func fetchUIChangesV2(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIChangesV2Calls += 1
            lastFetchUIChangesV2Limit = limit.intValue
            reply(changesReply.0.map { $0 as NSData }, changesReply.1.map { $0 as NSString })
        }

        func fetchUIHealthV1(_ reply: @escaping (NSData?, NSString?) -> Void) {
            fetchUIHealthV1Calls += 1
            reply(healthReply.0.map { $0 as NSData }, healthReply.1.map { $0 as NSString })
        }

        func resetUIChangesV2(_ reply: @escaping () -> Void) {
            reply()
        }

        func stopManagedDaemon(_ reply: @escaping () -> Void) {
            reply()
        }
    }

    func testFetchUIBootstrapV2DecodesBootstrapPayloadFromInjectedXPCProxy() async throws {
        let expected = makeBootstrap()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let proxy = ProxyStub()
        proxy.bootstrapReply = (try encoder.encode(expected), nil)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        let actual = try await client.fetchUIBootstrapV2()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIBootstrapV2Calls, 1)
        XCTAssertEqual(proxy.fetchUIChangesV2Calls, 0)
    }

    func testFetchUIChangesV2DecodesPayloadAndForwardsLimitFromInjectedXPCProxy() async throws {
        let bootstrap = makeBootstrap(replayCursor: AgtmuxSyncV2Cursor(epoch: 7, seq: 40))
        let expected = makeChangesResponse(nextCursor: AgtmuxSyncV2Cursor(epoch: 7, seq: 41))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let proxy = ProxyStub()
        proxy.bootstrapReply = (try encoder.encode(bootstrap), nil)
        proxy.changesReply = (try encoder.encode(expected), nil)

        let client = AgtmuxDaemonXPCClient(
            serviceName: "test.agtmux.xpc",
            proxyProviderOverride: { _ in proxy }
        )

        _ = try await client.fetchUIBootstrapV2()
        let actual = try await client.fetchUIChangesV2(limit: 17)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(proxy.startManagedDaemonCalls, 1)
        XCTAssertEqual(proxy.fetchUIBootstrapV2Calls, 1)
        XCTAssertEqual(proxy.fetchUIChangesV2Calls, 1)
        XCTAssertEqual(proxy.lastFetchUIChangesV2Limit, 17)
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

    private func makeBootstrap(
        replayCursor: AgtmuxSyncV2Cursor = .init(epoch: 7, seq: 12)
    ) -> AgtmuxSyncV2Bootstrap {
        let generatedAt = ISO8601DateFormatter().date(from: "2026-03-06T21:00:00Z")!
        return AgtmuxSyncV2Bootstrap(
            epoch: replayCursor.epoch,
            snapshotSeq: replayCursor.seq - 1,
            panes: [
                AgtmuxPane(
                    source: "local",
                    paneId: "%41",
                    sessionName: "dev",
                    windowId: "@9",
                    activityState: .running,
                    presence: .managed,
                    provider: .claude,
                    evidenceMode: .deterministic,
                    conversationTitle: "Review sync-v2",
                    currentCmd: "node",
                    updatedAt: generatedAt,
                    ageSecs: 0
                )
            ],
            sessions: [
                AgtmuxSyncV2SessionState(
                    sessionKey: "dev",
                    presence: .managed,
                    evidenceMode: .deterministic,
                    activityState: .running,
                    updatedAt: generatedAt
                )
            ],
            generatedAt: generatedAt,
            replayCursor: replayCursor
        )
    }

    private func makeChangesResponse(
        nextCursor: AgtmuxSyncV2Cursor
    ) -> AgtmuxSyncV2ChangesResponse {
        .changes(
            AgtmuxSyncV2Changes(
                epoch: nextCursor.epoch,
                changes: [
                    AgtmuxSyncV2ChangeRef(
                        seq: nextCursor.seq - 1,
                        sessionKey: "dev",
                        paneId: "%41",
                        timestamp: Date(timeIntervalSince1970: 1_778_825_310),
                        pane: AgtmuxSyncV2PaneState(
                            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                                paneId: "%41",
                                generation: 2,
                                birthTs: Date(timeIntervalSince1970: 1_778_825_000)
                            ),
                            presence: .managed,
                            evidenceMode: .deterministic,
                            activityState: .running,
                            provider: .claude,
                            sessionKey: "dev",
                            updatedAt: Date(timeIntervalSince1970: 1_778_825_310)
                        ),
                        session: AgtmuxSyncV2SessionState(
                            sessionKey: "dev",
                            presence: .managed,
                            evidenceMode: .deterministic,
                            activityState: .running,
                            updatedAt: Date(timeIntervalSince1970: 1_778_825_310)
                        )
                    )
                ],
                fromSeq: nextCursor.seq - 1,
                toSeq: nextCursor.seq - 1,
                nextCursor: nextCursor
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
