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
    func testFetchUIBootstrapV3DecodesPayloadAcrossXPCServiceBoundary() async throws {
        let expected = AgtmuxXPCHealthTestSupport.makeBootstrapV3()

        let host = AnonymousXPCServiceHost(
            exportedObject: BootstrapV3ServiceBridge {
                AgtmuxDaemonClient()
            }
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V3_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            let actual = try await client.fetchUIBootstrapV3()
            XCTAssertEqual(actual, expected)
        }
    }

    func testFetchUIChangesV3FailsLoudlyBeforeBootstrapAndThenReturnsChangesAcrossXPCServiceBoundary() async throws {
        let bootstrap = AgtmuxXPCHealthTestSupport.makeBootstrapV3(replayCursor: .init(seq: 40))
        let expected = AgtmuxXPCHealthTestSupport.makeChangesResponseV3(nextCursor: .init(seq: 41))

        let host = AnonymousXPCServiceHost(
            exportedObject: BootstrapV3ServiceBridge {
                AgtmuxDaemonClient()
            }
        )
        defer { host.invalidate() }

        let client = AgtmuxDaemonXPCClient(listenerEndpointOverride: host.endpoint)
        defer { Task { await client.invalidate() } }

        try await AgtmuxXPCHealthTestSupport.withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_BOOTSTRAP_V3_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(bootstrap),
            "AGTMUX_UI_CHANGES_V3_JSON": try AgtmuxXPCHealthTestSupport.encodeJSON(expected)
        ]) {
            do {
                _ = try await client.fetchUIChangesV3(limit: 7)
                XCTFail("expected ui.changes.v3 to fail loudly before bootstrap")
            } catch let XPCClientError.remote(text) {
                XCTAssertFalse(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "bootstrap-required failure must surface across the service boundary"
                )
            } catch {
                XCTFail("unexpected error: \(error)")
            }

            let actualBootstrap = try await client.fetchUIBootstrapV3()
            XCTAssertEqual(actualBootstrap, bootstrap)

            let actualChanges = try await client.fetchUIChangesV3(limit: 7)
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
        let server: OneShotUnixSocketServer
        do {
            server = try OneShotUnixSocketServer(socketPath: socketURL.path, responseLine: responseLine)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) {
            throw XCTSkip("unix domain socket bind is unavailable in the current sandbox")
        }
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
        let shortPrefix = String(prefix.prefix(8))
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(shortPrefix)-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func makeBootstrapV3() -> AgtmuxSyncV3Bootstrap {
        makeBootstrapV3(replayCursor: nil)
    }

    static func makeBootstrapV3(replayCursor: AgtmuxSyncV3Cursor?) -> AgtmuxSyncV3Bootstrap {
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

    static func makeChangesResponseV3(
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
                        at: Date(timeIntervalSince1970: 1_778_825_640),
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

    func fetchUIBootstrapV3(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchUIBootstrapV3 call" as NSString)
    }

    func fetchUIChangesV3(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchUIChangesV3 call" as NSString)
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

    func waitForUIChangesV1(_ timeoutMs: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected waitForUIChangesV1 call" as NSString)
    }

    func resetUIChangesV3(_ reply: @escaping () -> Void) {
        reply()
    }

    func stopManagedDaemon(_ reply: @escaping () -> Void) {
        reply()
    }
}

private final class BootstrapV3ServiceBridge: NSObject, AgtmuxDaemonServiceXPCProtocol {
    private let syncV3Session: AgtmuxSyncV3Session

    init(daemonClientProvider: @escaping () -> AgtmuxDaemonClient) {
        self.syncV3Session = AgtmuxSyncV3Session(transport: daemonClientProvider())
    }

    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
        reply(true, nil)
    }

    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected fetchSnapshot call" as NSString)
    }

    func fetchUIBootstrapV3(_ reply: @escaping (NSData?, NSString?) -> Void) {
        Task {
            do {
                let bootstrap = try await syncV3Session.bootstrap()
                reply(try Self.encode(bootstrap) as NSData, nil)
            } catch let error as DaemonError {
                reply(nil, error.uiSurfaceText as NSString)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func fetchUIChangesV3(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        Task {
            do {
                let changes = try await syncV3Session.pollChanges(limit: limit.intValue)
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

    func waitForUIChangesV1(_ timeoutMs: NSNumber, reply: @escaping (NSData?, NSString?) -> Void) {
        reply(nil, "unexpected waitForUIChangesV1 call" as NSString)
    }

    func resetUIChangesV3(_ reply: @escaping () -> Void) {
        Task {
            await syncV3Session.reset()
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
