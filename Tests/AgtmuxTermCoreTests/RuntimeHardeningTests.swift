import Foundation
import XCTest
import Darwin
@testable import AgtmuxTermCore

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

final class RuntimeHardeningTests: XCTestCase {
    private static let environmentGate = EnvironmentMutationGate()

    func testCandidateBinaryURLsPrefersAGTMUX_BINOverride() async throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-bin-env")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let explicitBinary = try makeExecutable(named: "agtmux-explicit", in: tempDirectory)
        _ = try makeExecutable(named: "agtmux", in: tempDirectory)

        let candidates = try await withEnvironment([
            "AGTMUX_BIN": explicitBinary.path,
            "PATH": tempDirectory.path
        ]) {
            AgtmuxBinaryResolver.candidateBinaryURLs()
        }

        XCTAssertEqual(candidates, [explicitBinary])
    }

    func testCandidateBinaryURLsFallsBackOnlyToBundledBinary() async throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-bin-path")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pathBinary = try makeExecutable(named: "agtmux", in: tempDirectory)
        let expected = AgtmuxBinaryResolver.bundledBinaryURL().map { [$0] } ?? []

        let candidates = try await withEnvironment([
            "AGTMUX_BIN": nil,
            "PATH": tempDirectory.path
        ]) {
            AgtmuxBinaryResolver.candidateBinaryURLs()
        }

        XCTAssertEqual(candidates, expected)
        XCTAssertLessThanOrEqual(candidates.count, 1)
        XCTAssertFalse(candidates.contains(pathBinary), "PATH lookup must not participate in binary resolution")
        XCTAssertFalse(candidates.map(\.path).contains("/usr/local/bin/agtmux"))
        XCTAssertFalse(candidates.map(\.path).contains("/opt/homebrew/bin/agtmux"))
    }

    func testDefaultSocketPathUsesAppOwnedApplicationSupportDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AGTMUXDesktop", isDirectory: true)
            .appendingPathComponent("agtmuxd.sock", isDirectory: false)

        XCTAssertEqual(AgtmuxBinaryResolver.defaultSocketPath, expected.path)
        XCTAssertEqual(AgtmuxBinaryResolver.defaultSocketURL, expected)
        XCTAssertFalse(AgtmuxBinaryResolver.defaultSocketPath.contains("/tmp/agtmux-"))
    }

    func testResolvedSocketPathPrefersExplicitManagedSocketOverride() async throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-daemon-socket-override")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("override.sock", isDirectory: false)

        let resolved = try await withEnvironment([
            AgtmuxBinaryResolver.managedSocketPathEnvKey: socketURL.path
        ]) {
            AgtmuxBinaryResolver.resolvedSocketPath()
        }

        XCTAssertEqual(resolved, socketURL.path)
    }

    func testDaemonClientDefaultInitUsesResolvedManagedSocketOverride() async throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-daemon-client-override")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("client.sock", isDirectory: false)

        let socketPath = try await withEnvironment([
            AgtmuxBinaryResolver.managedSocketPathEnvKey: socketURL.path
        ]) {
            await AgtmuxDaemonClient().socketPath
        }

        XCTAssertEqual(socketPath, socketURL.path)
    }

    func testDaemonClientFetchUIBootstrapV3DecodesDaemonOwnedFixtureFromInlineOverride() async throws {
        let fixtureURL = AgtmuxSyncV3FixtureLoader.fixtureURL(named: "codex-running")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let expected = try AgtmuxSyncV3FixtureLoader.bootstrap(named: "codex-running")
        let client = AgtmuxDaemonClient(socketPath: "/tmp/agtmux-sync-v3-test.sock")

        let actual = try await withEnvironment([
            "AGTMUX_UI_BOOTSTRAP_V3_JSON": String(decoding: fixtureData, as: UTF8.self)
        ]) {
            try await client.fetchUIBootstrapV3()
        }

        XCTAssertEqual(actual, expected)
    }

    func testDaemonClientFetchUIChangesV3DecodesInlineOverride() async throws {
        let fixtureBootstrap = try AgtmuxSyncV3FixtureLoader.bootstrap(named: "codex-waiting-approval")
        let pane = try XCTUnwrap(fixtureBootstrap.panes.first)
        let bootstrap = AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: fixtureBootstrap.panes,
            generatedAt: fixtureBootstrap.generatedAt,
            replayCursor: AgtmuxSyncV3Cursor(seq: 40)
        )
        let expected: AgtmuxSyncV3ChangesResponse = .changes(
            AgtmuxSyncV3Changes(
                fromSeq: 41,
                toSeq: 41,
                nextCursor: AgtmuxSyncV3Cursor(seq: 41),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: 41,
                        at: pane.updatedAt,
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let client = AgtmuxDaemonClient(socketPath: "/tmp/agtmux-sync-v3-test.sock")

        let actual = try await withEnvironment([
            "AGTMUX_UI_BOOTSTRAP_V3_JSON": String(decoding: try encoder.encode(bootstrap), as: UTF8.self),
            "AGTMUX_UI_CHANGES_V3_JSON": String(decoding: try encoder.encode(expected), as: UTF8.self)
        ]) {
            _ = try await client.fetchUIBootstrapV3()
            return try await client.fetchUIChangesV3(limit: 33)
        }

        XCTAssertEqual(actual, expected)
    }

    func testManagedDaemonFreshnessRequiresRestartWhenBinaryIsNewerThanDefaultSocket() throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-daemon-freshness")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let binary = try makeExecutable(named: "agtmux", in: tempDirectory)
        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        try "".write(to: socketURL, atomically: true, encoding: .utf8)

        let socketDate = Date(timeIntervalSince1970: 100)
        let binaryDate = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: socketDate], ofItemAtPath: socketURL.path)
        try FileManager.default.setAttributes([.modificationDate: binaryDate], ofItemAtPath: binary.path)

        XCTAssertTrue(
            AgtmuxManagedDaemonRuntime.shouldRestartReachableDaemon(
                socketPath: socketURL.path,
                candidateBinaryURL: binary,
                appOwnedSocketPath: socketURL.path
            )
        )
    }

    func testManagedDaemonFreshnessUsesProcessStartTimeWhenSocketFileLooksFresh() throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-daemon-process-freshness")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let binary = try makeExecutable(named: "agtmux", in: tempDirectory)
        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        try "".write(to: socketURL, atomically: true, encoding: .utf8)

        let binaryDate = Date(timeIntervalSince1970: 1_773_100_000)
        let socketDate = Date(timeIntervalSince1970: 1_773_200_000)
        try FileManager.default.setAttributes([.modificationDate: socketDate], ofItemAtPath: socketURL.path)
        try FileManager.default.setAttributes([.modificationDate: binaryDate], ofItemAtPath: binary.path)

        let psOutput = """
          101 Thu Jan  1 00:01:40 1970 /tmp/agtmux --socket-path \(socketURL.path) daemon
        """

        XCTAssertTrue(
            AgtmuxManagedDaemonRuntime.shouldRestartReachableDaemon(
                socketPath: socketURL.path,
                candidateBinaryURL: binary,
                appOwnedSocketPath: socketURL.path,
                psOutput: psOutput
            )
        )
    }

    func testManagedDaemonFreshnessDoesNotRestartForCustomSocketPaths() throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-daemon-custom-socket")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let binary = try makeExecutable(named: "agtmux", in: tempDirectory)
        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        try "".write(to: socketURL, atomically: true, encoding: .utf8)

        let socketDate = Date(timeIntervalSince1970: 100)
        let binaryDate = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: socketDate], ofItemAtPath: socketURL.path)
        try FileManager.default.setAttributes([.modificationDate: binaryDate], ofItemAtPath: binary.path)

        XCTAssertFalse(
            AgtmuxManagedDaemonRuntime.shouldRestartReachableDaemon(
                socketPath: socketURL.path,
                candidateBinaryURL: binary,
                appOwnedSocketPath: "/tmp/not-the-app-owned.sock"
            )
        )
    }

    func testManagedDaemonProcessMatcherOnlyReturnsExactSocketDaemonProcesses() {
        let socketPath = "/Users/test/Library/Application Support/AGTMUXDesktop/agtmuxd.sock"
        let psOutput = """
          101 /Users/test/bin/agtmux --socket-path \(socketPath) daemon
          102 /Users/test/bin/agtmux --socket-path /tmp/other.sock daemon
          103 /Users/test/bin/agtmux json
          104 /Users/test/bin/agtmux --socket-path \(socketPath) watch
        """

        XCTAssertEqual(
            AgtmuxManagedDaemonRuntime.daemonProcessIDs(socketPath: socketPath, psOutput: psOutput),
            [101]
        )
    }

    func testManagedDaemonProcessRuntimeParserReadsStartTimeForExactSocketDaemon() throws {
        let socketPath = "/Users/test/Library/Application Support/AGTMUXDesktop/agtmuxd.sock"
        let psOutput = """
          101 Sun Mar  8 12:47:30 2026 /Users/test/bin/agtmux --socket-path \(socketPath) daemon
          102 Sun Mar  8 13:00:00 2026 /Users/test/bin/agtmux --socket-path /tmp/other.sock daemon
        """

        let processes = AgtmuxManagedDaemonRuntime.daemonProcesses(
            socketPath: socketPath,
            psOutput: psOutput
        )

        XCTAssertEqual(processes.map(\.pid), [101])
        let startedAt = try XCTUnwrap(processes.first?.startedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let expectedStart = try XCTUnwrap(formatter.date(from: "Sun Mar 8 12:47:30 2026"))
        XCTAssertEqual(
            startedAt.timeIntervalSince1970,
            expectedStart.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testFetchUIHealthV1UsesInlineOverrideJSON() async throws {
        let inlineJSON = """
        {
          "generated_at": "2026-03-06T19:00:00Z",
          "runtime": {
            "status": "ok",
            "detail": "inline runtime",
            "last_updated_at": "2026-03-06T18:59:59Z"
          },
          "replay": {
            "status": "ok",
            "current_epoch": 9,
            "cursor_seq": 20,
            "head_seq": 20,
            "lag": 0,
            "detail": "caught up"
          },
          "overlay": {
            "status": "degraded",
            "detail": "overlay stale",
            "last_updated_at": "2026-03-06T18:59:40Z"
          },
          "focus": {
            "status": "unavailable",
            "focused_pane_id": "%7",
            "mismatch_count": 3,
            "last_sync_at": "2026-03-06T18:59:30Z",
            "detail": "focus feed missing"
          }
        }
        """

        try await withEnvironment([
            "AGTMUX_BIN": nil,
            "AGTMUX_UI_HEALTH_V1_JSON": inlineJSON
        ]) {
            let client = AgtmuxDaemonClient()
            let health = try await client.fetchUIHealthV1()
            XCTAssertEqual(health.runtime.status, .ok)
            XCTAssertEqual(health.runtime.detail, "inline runtime")
            XCTAssertEqual(health.replay.currentEpoch, 9)
            XCTAssertEqual(health.replay.lag, 0)
            XCTAssertEqual(health.overlay.status, .degraded)
            XCTAssertEqual(health.focus.status, .unavailable)
            XCTAssertEqual(health.focus.focusedPaneID, "%7")
            XCTAssertEqual(health.focus.mismatchCount, 3)
        }
    }

    func testFetchUIHealthV1MethodNotFoundSurfacesStructuredUIError() async throws {
        let tempDirectory = try makeTemporaryDirectory(prefix: "agtmux-ui-health-v1")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("agtmuxd.sock", isDirectory: false)
        let responseLine = #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}"#
        let server = try OneShotUnixSocketServer(socketPath: socketURL.path, responseLine: responseLine)
        defer { server.cleanup() }

        let served = expectation(description: "ui.health.v1 server responded")
        server.start(served)

        let client = AgtmuxDaemonClient(socketPath: socketURL.path)

        do {
            _ = try await client.fetchUIHealthV1()
            XCTFail("expected ui.health.v1 method-not-found error")
        } catch let error as DaemonError {
            guard case let .processError(exitCode, stderr) = error else {
                return XCTFail("expected processError, got \(error)")
            }

            XCTAssertEqual(exitCode, -32601)
            XCTAssertEqual(error.uiSurfaceText, stderr)
            XCTAssertTrue(stderr.hasPrefix(DaemonError.uiErrorPrefix))

            let payloadText = String(stderr.dropFirst(DaemonError.uiErrorPrefix.count))
            let envelope = try JSONDecoder().decode(
                DaemonUIErrorEnvelope.self,
                from: Data(payloadText.utf8)
            )

            XCTAssertEqual(envelope.code, DaemonUIErrorCode.uiHealthMethodNotFound.rawValue)
            XCTAssertEqual(envelope.method, "ui.health.v1")
            XCTAssertEqual(envelope.rpcCode, -32601)
            XCTAssertTrue(envelope.message.contains("ui.health.v1 observability"))
            XCTAssertFalse(envelope.message.contains("sync-v2"))
            XCTAssertEqual(error.localizedDescription, envelope.message)
        } catch {
            XCTFail("expected DaemonError, got \(error)")
        }

        await fulfillment(of: [served], timeout: 1.0)
    }

    func testManagedDaemonLaunchEnvironmentNormalizesUserPathAndClearsInheritedTmux() {
        let normalized = ManagedDaemonLaunchEnvironment.normalized(
            from: [
                "PATH": "/custom/bin:/bin",
                "TMUX": "/tmp/stale.sock,123,1",
                "TMUX_PANE": "%1",
                "USER": "virtualmachine",
                "HOME": "/Users/virtualmachine"
            ],
            tmuxBinResolver: { _ in "/opt/homebrew/bin/tmux" }
        )

        XCTAssertNil(normalized["TMUX"])
        XCTAssertNil(normalized["TMUX_PANE"])
        XCTAssertEqual(normalized["USER"], "virtualmachine")
        XCTAssertEqual(normalized["LOGNAME"], "virtualmachine")
        XCTAssertEqual(normalized["HOME"], "/Users/virtualmachine")
        XCTAssertEqual(normalized["XDG_CONFIG_HOME"], "/Users/virtualmachine/.config")
        XCTAssertEqual(normalized["CODEX_HOME"], "/Users/virtualmachine/.codex")
        XCTAssertEqual(normalized["TMUX_BIN"], "/opt/homebrew/bin/tmux")
        XCTAssertEqual(
            normalized["PATH"],
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin"
        )
    }

    func testManagedDaemonLaunchEnvironmentPreservesExplicitCodexHomeAndCanOmitTmuxBin() {
        let normalized = ManagedDaemonLaunchEnvironment.normalized(
            from: [
                "PATH": "/usr/bin",
                "USER": "virtualmachine",
                "HOME": "/Users/virtualmachine",
                "CODEX_HOME": "/tmp/custom-codex-home"
            ],
            tmuxBinResolver: { _ in nil }
        )

        XCTAssertEqual(normalized["CODEX_HOME"], "/tmp/custom-codex-home")
        XCTAssertNil(normalized["TMUX_BIN"])
        XCTAssertEqual(
            normalized["PATH"],
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
    }

    private func withEnvironment<T>(
        _ overrides: [String: String?],
        body: () async throws -> T
    ) async throws -> T {
        await Self.environmentGate.acquire()
        let previous = overrides.keys.reduce(into: [String: String?]()) { result, key in
            result[key] = Self.environmentValue(for: key)
        }

        do {
            try setEnvironment(overrides)
            let result = try await body()
            restoreEnvironment(previous)
            await Self.environmentGate.release()
            return result
        } catch {
            restoreEnvironment(previous)
            await Self.environmentGate.release()
            throw error
        }
    }

    private func setEnvironment(_ overrides: [String: String?]) throws {
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

    private func restoreEnvironment(_ values: [String: String?]) {
        for (key, value) in values {
            if let value {
                _ = setenv(key, value, 1)
            } else {
                _ = unsetenv(key)
            }
        }
    }

    private static func environmentValue(for key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }

    private func environmentMutationError(_ function: String, key: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(function) failed for \(key)"]
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
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
        DispatchQueue.global(qos: .userInitiated).async { [listeningFD = self.listeningFD, responseData = self.responseData] in
            defer { served.fulfill() }

            let clientFD = Darwin.accept(listeningFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            Self.readRequestLine(fd: clientFD)
            _ = Self.writeAll(fd: clientFD, data: responseData)
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
