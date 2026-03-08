import Foundation
import XCTest
import Darwin
import AgtmuxTermCore
#if canImport(AgtmuxTerm)
@testable import AgtmuxTerm
#endif

private actor EnvironmentMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

final class AgtmuxDaemonXPCServiceBoundaryTests: XCTestCase {
    func testFetchUIBootstrapV2DecodesPayloadAcrossXPCServiceBoundary() async throws {
        let expected = AgtmuxXPCHealthTestSupport.makeBootstrap(
            replayCursor: AgtmuxSyncV2Cursor(epoch: 6, seq: 21)
        )

        let host = AnonymousXPCServiceHost(
            exportedObject: SyncV2ServiceBridge(
                daemonClient: AgtmuxDaemonClient()
            )
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            let actual = try await client.fetchUIBootstrapV2()
            XCTAssertEqual(actual, expected)
        }
    }

    func testFetchUIChangesV2FailsLoudlyBeforeBootstrapAndThenReturnsChangesAcrossXPCServiceBoundary() async throws {
        let bootstrap = AgtmuxXPCHealthTestSupport.makeBootstrap(
            replayCursor: AgtmuxSyncV2Cursor(epoch: 6, seq: 30)
        )
        let expected = AgtmuxXPCHealthTestSupport.makeChangesResponse(
            nextCursor: AgtmuxSyncV2Cursor(epoch: 6, seq: 31)
        )

        let host = AnonymousXPCServiceHost(
            exportedObject: SyncV2ServiceBridge(
                daemonClient: AgtmuxDaemonClient()
            )
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(bootstrap),
            "AGTMUX_UI_CHANGES_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            do {
                _ = try await client.fetchUIChangesV2(limit: 9)
                XCTFail("expected ui.changes.v2 to fail loudly before bootstrap")
            } catch let XPCClientError.remote(text) {
                XCTAssertFalse(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "bootstrap-required failure must surface across the service boundary"
                )
            } catch {
                XCTFail("unexpected error: \(error)")
            }

            let actualBootstrap = try await client.fetchUIBootstrapV2()
            XCTAssertEqual(actualBootstrap, bootstrap)

            let actualChanges = try await client.fetchUIChangesV2(limit: 9)
            XCTAssertEqual(actualChanges, expected)
        }
    }

    func testFetchUIHealthV1DecodesHealthPayloadAcrossXPCServiceBoundary() async throws {
        let expected = AgtmuxXPCHealthTestSupport.makeHealth(
            runtimeStatus: .ok,
            replayStatus: .degraded,
            replayLag: 2,
            overlayStatus: .degraded,
            focusStatus: .ok,
            focusMismatchCount: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inlineJSON = String(decoding: try encoder.encode(expected), as: UTF8.self)

        let host = AnonymousXPCServiceHost(
            exportedObject: HealthServiceBridge {
                AgtmuxDaemonClient()
            }
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_HEALTH_V1_JSON": inlineJSON
        ]) {
            let actual = try await client.fetchUIHealthV1()
            XCTAssertEqual(actual, expected)
        }
    }

    func testFetchUIHealthV1PreservesStructuredUnsupportedPayloadAcrossXPCServiceBoundary() async throws {
        let tempDirectory = try AgtmuxXPCHealthTestSupport.makeTemporaryDirectory(prefix: "agtmux-ui-health-v1-xpc")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        let responseLine = #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}"#
        let server = try OneShotUnixSocketServer(socketPath: socketURL.path, responseLine: responseLine)
        defer { server.cleanup() }

        let served = expectation(description: "ui.health.v1 service-boundary server responded")
        server.start(served)

        let host = AnonymousXPCServiceHost(
            exportedObject: HealthServiceBridge {
                AgtmuxDaemonClient(socketPath: socketURL.path)
            }
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        do {
            _ = try await client.fetchUIHealthV1()
            XCTFail("expected ui.health.v1 XPC fetch to fail")
        } catch let XPCClientError.remote(text) {
            let envelope = DaemonError.decodeUIErrorEnvelope(from: text)
            XCTAssertEqual(envelope?.code, DaemonUIErrorCode.uiHealthMethodNotFound.rawValue)
            XCTAssertEqual(envelope?.method, "ui.health.v1")
            XCTAssertEqual(envelope?.rpcCode, -32601)
            XCTAssertTrue(envelope?.message.contains("ui.health.v1 observability") == true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await fulfillment(of: [served], timeout: 1.0)
    }
}

#if !SWIFT_PACKAGE
final class AgtmuxDaemonServiceEndpointTests: XCTestCase {
    func testFetchUIBootstrapV2DecodesPayloadAcrossActualServiceEndpoint() async throws {
        let expected = AgtmuxXPCHealthTestSupport.makeBootstrap(
            replayCursor: AgtmuxSyncV2Cursor(epoch: 8, seq: 14)
        )

        let supervisor = StubServiceDaemonSupervisor()
        let endpoint = AgtmuxDaemonServiceEndpoint(
            supervisor: supervisor,
            daemonClient: AgtmuxDaemonClient()
        )
        let host = AnonymousXPCServiceHost(exportedObject: endpoint)
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            let actual = try await client.fetchUIBootstrapV2()
            XCTAssertEqual(actual, expected)
        }

        XCTAssertEqual(supervisor.startIfNeededCalls, 2)
    }

    func testFetchUIChangesV2FailsLoudlyBeforeBootstrapAndThenReturnsChangesAcrossActualServiceEndpoint() async throws {
        let bootstrap = AgtmuxXPCHealthTestSupport.makeBootstrap(
            replayCursor: AgtmuxSyncV2Cursor(epoch: 8, seq: 40)
        )
        let expected = AgtmuxXPCHealthTestSupport.makeChangesResponse(
            nextCursor: AgtmuxSyncV2Cursor(epoch: 8, seq: 41)
        )

        let supervisor = StubServiceDaemonSupervisor()
        let endpoint = AgtmuxDaemonServiceEndpoint(
            supervisor: supervisor,
            daemonClient: AgtmuxDaemonClient()
        )
        let host = AnonymousXPCServiceHost(exportedObject: endpoint)
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(bootstrap),
            "AGTMUX_UI_CHANGES_V2_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            do {
                _ = try await client.fetchUIChangesV2(limit: 5)
                XCTFail("expected ui.changes.v2 service-endpoint fetch to fail loudly before bootstrap")
            } catch let XPCClientError.remote(text) {
                XCTAssertFalse(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "bootstrap-required failure must surface across the actual service endpoint"
                )
            } catch {
                XCTFail("unexpected error: \(error)")
            }

            let actualBootstrap = try await client.fetchUIBootstrapV2()
            XCTAssertEqual(actualBootstrap, bootstrap)

            let actualChanges = try await client.fetchUIChangesV2(limit: 5)
            XCTAssertEqual(actualChanges, expected)
        }

        XCTAssertEqual(supervisor.startIfNeededCalls, 4)
    }

    func testFetchUIHealthV1DecodesHealthPayloadAcrossActualServiceEndpoint() async throws {
        let expected = AgtmuxXPCHealthTestSupport.makeHealth(
            runtimeStatus: .degraded,
            replayStatus: .ok,
            replayLag: 0,
            overlayStatus: .ok,
            focusStatus: .degraded,
            focusMismatchCount: 2
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inlineJSON = String(decoding: try encoder.encode(expected), as: UTF8.self)

        let supervisor = StubServiceDaemonSupervisor()
        let endpoint = AgtmuxDaemonServiceEndpoint(
            supervisor: supervisor,
            daemonClient: AgtmuxDaemonClient()
        )
        let host = AnonymousXPCServiceHost(exportedObject: endpoint)
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_HEALTH_V1_JSON": inlineJSON
        ]) {
            let actual = try await client.fetchUIHealthV1()
            XCTAssertEqual(actual, expected)
        }

        XCTAssertEqual(supervisor.startIfNeededCalls, 2)
    }

    func testFetchUIHealthV1PreservesStructuredUnsupportedPayloadAcrossActualServiceEndpoint() async throws {
        let tempDirectory = try AgtmuxXPCHealthTestSupport.makeTemporaryDirectory(prefix: "agtmux-ui-health-v1-endpoint")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        let responseLine = #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}"#
        let server = try OneShotUnixSocketServer(socketPath: socketURL.path, responseLine: responseLine)
        defer { server.cleanup() }

        let served = expectation(description: "ui.health.v1 endpoint server responded")
        server.start(served)

        let supervisor = StubServiceDaemonSupervisor()
        let endpoint = AgtmuxDaemonServiceEndpoint(
            supervisor: supervisor,
            daemonClient: AgtmuxDaemonClient(socketPath: socketURL.path)
        )
        let host = AnonymousXPCServiceHost(exportedObject: endpoint)
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        do {
            _ = try await client.fetchUIHealthV1()
            XCTFail("expected ui.health.v1 service-endpoint fetch to fail")
        } catch let XPCClientError.remote(text) {
            let envelope = DaemonError.decodeUIErrorEnvelope(from: text)
            XCTAssertEqual(envelope?.code, DaemonUIErrorCode.uiHealthMethodNotFound.rawValue)
            XCTAssertEqual(envelope?.method, "ui.health.v1")
            XCTAssertEqual(envelope?.rpcCode, -32601)
            XCTAssertTrue(envelope?.message.contains("ui.health.v1 observability") == true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await fulfillment(of: [served], timeout: 1.0)
        XCTAssertEqual(supervisor.startIfNeededCalls, 2)
    }
}
#endif

private enum AgtmuxXPCHealthTestSupport {
    private static let environmentGate = EnvironmentMutationGate()

    static func withEnvironment<T>(
        _ overrides: [String: String?],
        body: () async throws -> T
    ) async throws -> T {
        await environmentGate.acquire()
        let previous = overrides.keys.reduce(into: [String: String?]()) { result, key in
            result[key] = environmentValue(for: key)
        }

        do {
            try setEnvironment(overrides)
            let result = try await body()
            restoreEnvironment(previous)
            await environmentGate.release()
            return result
        } catch {
            restoreEnvironment(previous)
            await environmentGate.release()
            throw error
        }
    }

    private static func setEnvironment(_ overrides: [String: String?]) throws {
        for (key, value) in overrides {
            if let value {
                guard setenv(key, value, 1) == 0 else {
                    throw environmentMutationError("setenv", key: key)
                }
            } else {
                guard unsetenv(key) == 0 else {
                    throw environmentMutationError("unsetenv", key: key)
                }
            }
        }
    }

    private static func restoreEnvironment(_ values: [String: String?]) {
        for (key, value) in values {
            if let value {
                _ = setenv(key, value, 1)
            } else {
                _ = unsetenv(key)
            }
        }
    }

    private static func environmentValue(for key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }

    private static func environmentMutationError(_ operation: String, key: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(key)"]
        )
    }

    static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func makeBootstrap(
        replayCursor: AgtmuxSyncV2Cursor = .init(epoch: 5, seq: 11)
    ) -> AgtmuxSyncV2Bootstrap {
        let generatedAt = ISO8601DateFormatter().date(from: "2026-03-06T22:10:00Z")!
        return AgtmuxSyncV2Bootstrap(
            epoch: replayCursor.epoch,
            snapshotSeq: replayCursor.seq - 1,
            panes: [
                AgtmuxPane(
                    source: "local",
                    paneId: "%5",
                    sessionName: "dev",
                    windowId: "@3",
                    activityState: .running,
                    presence: .managed,
                    provider: .codex,
                    evidenceMode: .deterministic,
                    conversationTitle: "Boundary sync-v2",
                    currentCmd: "node",
                    updatedAt: generatedAt,
                    ageSecs: 0,
                    metadataSessionKey: "dev",
                    paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                        paneId: "%5",
                        generation: 1,
                        birthTs: Date(timeIntervalSince1970: 1_778_825_000)
                    )
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

    static func makeChangesResponse(
        nextCursor: AgtmuxSyncV2Cursor
    ) -> AgtmuxSyncV2ChangesResponse {
        .changes(
            AgtmuxSyncV2Changes(
                epoch: nextCursor.epoch,
                changes: [
                    AgtmuxSyncV2ChangeRef(
                        seq: nextCursor.seq - 1,
                        sessionKey: "dev",
                        paneId: "%5",
                        timestamp: Date(timeIntervalSince1970: 1_778_825_640),
                        pane: AgtmuxSyncV2PaneState(
                            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                                paneId: "%5",
                                generation: 1,
                                birthTs: Date(timeIntervalSince1970: 1_778_825_000)
                            ),
                            presence: .managed,
                            evidenceMode: .deterministic,
                            activityState: .running,
                            provider: .codex,
                            sessionKey: "dev",
                            updatedAt: Date(timeIntervalSince1970: 1_778_825_640)
                        ),
                        session: AgtmuxSyncV2SessionState(
                            sessionKey: "dev",
                            presence: .managed,
                            evidenceMode: .deterministic,
                            activityState: .running,
                            updatedAt: Date(timeIntervalSince1970: 1_778_825_640)
                        )
                    )
                ],
                fromSeq: nextCursor.seq - 1,
                toSeq: nextCursor.seq - 1,
                nextCursor: nextCursor
            )
        )
    }

    static func makeHealth(
        runtimeStatus: AgtmuxUIHealthStatus,
        replayStatus: AgtmuxUIHealthStatus,
        replayLag: UInt64?,
        overlayStatus: AgtmuxUIHealthStatus,
        focusStatus: AgtmuxUIHealthStatus,
        focusMismatchCount: UInt64?
    ) -> AgtmuxUIHealthV1 {
        let generatedAt = ISO8601DateFormatter().date(from: "2026-03-06T22:00:00Z")!
        return AgtmuxUIHealthV1(
            generatedAt: generatedAt,
            runtime: AgtmuxUIComponentHealth(
                status: runtimeStatus,
                detail: "runtime through service boundary",
                lastUpdatedAt: generatedAt.addingTimeInterval(-2)
            ),
            replay: AgtmuxUIReplayHealth(
                status: replayStatus,
                currentEpoch: 5,
                cursorSeq: 20,
                headSeq: 22,
                lag: replayLag,
                lastResyncReason: "replay_gap",
                lastResyncAt: generatedAt.addingTimeInterval(-4),
                detail: "replay through service boundary"
            ),
            overlay: AgtmuxUIComponentHealth(
                status: overlayStatus,
                detail: "overlay through service boundary",
                lastUpdatedAt: generatedAt.addingTimeInterval(-1)
            ),
            focus: AgtmuxUIFocusHealth(
                status: focusStatus,
                focusedPaneID: "%5",
                mismatchCount: focusMismatchCount,
                lastSyncAt: generatedAt.addingTimeInterval(-3),
                detail: "focus through service boundary"
            )
        )
    }
}

#if !SWIFT_PACKAGE
private final class StubServiceDaemonSupervisor: ServiceDaemonSupervising {
    private(set) var startIfNeededCalls = 0
    private(set) var stopIfOwnedCalls = 0
    var startIfNeededResult = true

    func startIfNeeded() -> Bool {
        startIfNeededCalls += 1
        return startIfNeededResult
    }

    func stopIfOwned() {
        stopIfOwnedCalls += 1
    }
}
#endif

private final class HealthServiceBridge: NSObject, AgtmuxDaemonServiceXPCProtocol {
    private let daemonClientProvider: () -> AgtmuxDaemonClient

    init(daemonClientProvider: @escaping () -> AgtmuxDaemonClient) {
        self.daemonClientProvider = daemonClientProvider
    }

    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
        reply(true, nil)
    }

    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchSnapshot call" as NSString)
    }

    func fetchUIBootstrapV2(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchUIBootstrapV2 call" as NSString)
    }

    func fetchUIChangesV2(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchUIChangesV2 call" as NSString)
    }

    func fetchUIHealthV1(_ reply: @escaping (NSData?, NSString?) -> Void) {
        let daemonClient = daemonClientProvider()
        Task {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let health = try await daemonClient.fetchUIHealthV1()
                reply(try encoder.encode(health) as NSData, nil)
            } catch let error as DaemonError {
                reply(nil, error.uiSurfaceText as NSString)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func resetUIChangesV2(_ reply: @escaping () -> Void) {
        reply()
    }

    func stopManagedDaemon(_ reply: @escaping () -> Void) {
        reply()
    }
}

private final class SyncV2ServiceBridge: NSObject, AgtmuxDaemonServiceXPCProtocol {
    private let syncV2Session: AgtmuxSyncV2Session

    init(daemonClient: AgtmuxDaemonClient) {
        self.syncV2Session = AgtmuxSyncV2Session(transport: daemonClient)
    }

    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
        reply(true, nil)
    }

    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchSnapshot call" as NSString)
    }

    func fetchUIBootstrapV2(_ reply: @escaping (NSData?, NSString?) -> Void) {
        Task {
            do {
                let bootstrap = try await syncV2Session.bootstrap()
                reply(try Self.encode(bootstrap) as NSData, nil)
            } catch let error as DaemonError {
                reply(nil, error.uiSurfaceText as NSString)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func fetchUIChangesV2(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        Task {
            do {
                let changes = try await syncV2Session.pollChanges(limit: limit.intValue)
                reply(try Self.encode(changes) as NSData, nil)
            } catch let error as DaemonError {
                reply(nil, error.uiSurfaceText as NSString)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func fetchUIHealthV1(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchUIHealthV1 call" as NSString)
    }

    func resetUIChangesV2(_ reply: @escaping () -> Void) {
        Task {
            await syncV2Session.reset()
            reply()
        }
    }

    func stopManagedDaemon(_ reply: @escaping () -> Void) {
        reply()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private final class AnonymousXPCServiceHost: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener.anonymous()
    private let exportedObject: any AgtmuxDaemonServiceXPCProtocol
    private let lock = NSLock()
    private var activeConnections: [ObjectIdentifier: NSXPCConnection] = [:]

    init(exportedObject: any AgtmuxDaemonServiceXPCProtocol) {
        self.exportedObject = exportedObject
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    func invalidate() {
        lock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        lock.unlock()

        connections.forEach { $0.invalidate() }
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AgtmuxDaemonServiceXPCProtocol.self)
        newConnection.exportedObject = exportedObject

        let identifier = ObjectIdentifier(newConnection)
        lock.lock()
        activeConnections[identifier] = newConnection
        lock.unlock()

        newConnection.invalidationHandler = { [weak self] in
            self?.removeConnection(identifier)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.removeConnection(identifier)
        }
        newConnection.resume()
        return true
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        lock.lock()
        activeConnections.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private final class OneShotUnixSocketServer {
    private let socketPath: String
    private let responseData: Data
    private let listeningFD: Int32

    init(socketPath: String, responseLine: String) throws {
        self.socketPath = socketPath
        self.responseData = Data((responseLine + "\n").utf8)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Self.socketError("socket", socketPath: socketPath)
        }

        _ = socketPath.withCString { unlink($0) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else {
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"]
            )
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            rawPointer.initialize(repeating: 0, count: maxLength)
            _ = pathBytes.withUnsafeBufferPointer { bytes in
                strncpy(rawPointer, bytes.baseAddress, maxLength - 1)
            }
        }

        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, addressLength)
            }
        }
        guard bindResult == 0 else {
            let error = Self.socketError("bind", socketPath: socketPath)
            close(fd)
            throw error
        }

        guard listen(fd, 1) == 0 else {
            let error = Self.socketError("listen", socketPath: socketPath)
            close(fd)
            _ = socketPath.withCString { unlink($0) }
            throw error
        }

        self.listeningFD = fd
    }

    func start(_ served: XCTestExpectation) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { served.fulfill() }

            let clientFD = Darwin.accept(self.listeningFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            Self.readRequestLine(fd: clientFD)
            _ = Self.writeAll(fd: clientFD, data: self.responseData)
        }
    }

    func cleanup() {
        close(listeningFD)
        _ = socketPath.withCString { unlink($0) }
    }

    private static func readRequestLine(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 {
                return
            }
            if buffer.prefix(count).contains(0x0A) {
                return
            }
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var written = 0
            while written < data.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    data.count - written
                )
                if result <= 0 {
                    return false
                }
                written += result
            }
            return true
        }
    }

    private static func socketError(_ function: String, socketPath: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(function) failed for \(socketPath)"]
        )
    }
}
