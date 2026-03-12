import Foundation
import Darwin

// MARK: - DaemonError

/// Errors surfaced by AgtmuxDaemonClient.
package enum DaemonError: Error {
    /// agtmux binary not found in AGTMUX_BIN or bundled app resources.
    case daemonUnavailable
    /// Binary ran but exited with a non-zero status.
    case processError(exitCode: Int32, stderr: String)
    /// Process exited 0 but JSON decoding failed.
    case parseError(String)
}

// MARK: - AgtmuxDaemonClient

/// Local daemon client for snapshot, sync-v3 metadata, and health APIs.
package actor AgtmuxDaemonClient {
    package let socketPath: String
    private var syncV3Session: AgtmuxSyncV3Session?

    package init(socketPath: String = AgtmuxBinaryResolver.resolvedSocketPath()) {
        self.socketPath = socketPath
    }

    package var usesManagedDefaultSocket: Bool {
        socketPath == AgtmuxBinaryResolver.defaultSocketPath
    }

    /// Run `agtmux --socket-path <socketPath> json` and decode the result.
    package func fetchSnapshot() async throws -> AgtmuxSnapshot {
        // Test override: allow inline JSON without spawning a subprocess.
        if let inlineJSON = ProcessInfo.processInfo.environment["AGTMUX_JSON"] {
            guard let data = inlineJSON.data(using: .utf8) else {
                throw DaemonError.parseError("AGTMUX_JSON is not valid UTF-8")
            }
            do {
                return try AgtmuxSnapshot.decode(from: data, source: "local")
            } catch {
                throw DaemonError.parseError("AGTMUX_JSON parse failed: \(error.localizedDescription)")
            }
        }

        let candidates = AgtmuxBinaryResolver.candidateBinaryURLs()
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard !candidates.isEmpty else { throw DaemonError.daemonUnavailable }

        var lastError: Error?
        for agtmuxURL in candidates {
            do {
                return try runJSON(binaryURL: agtmuxURL)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DaemonError.daemonUnavailable
    }

    package func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_BOOTSTRAP_V3_JSON"])
        let session = syncV3SessionInstance()
        return try await session.bootstrap()
    }

    package func fetchUIChangesV3(limit: Int = 256) async throws -> AgtmuxSyncV3ChangesResponse {
        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_CHANGES_V3_JSON"])
        let session = syncV3SessionInstance()
        return try await session.pollChanges(limit: limit)
    }

    package func waitForUIChangesV1(timeoutMs: UInt64 = 3000) async throws -> AgtmuxSyncV3ChangesResponse {
        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_CHANGES_V3_JSON"])
        let session = syncV3SessionInstance()
        return try await session.waitForChangesV1(timeoutMs: timeoutMs)
    }

    package func resetUIChangesV3() async {
        syncV3Session = nil
    }

    private func runJSON(binaryURL agtmuxURL: URL) throws -> AgtmuxSnapshot {
        let result = try Self.runProcess(
            executableURL: agtmuxURL,
            arguments: ["--socket-path", socketPath, "json"],
            timeout: 5.0
        )

        guard result.exitCode == 0 else {
            throw DaemonError.processError(exitCode: result.exitCode, stderr: result.stderr)
        }

        do {
            return try AgtmuxSnapshot.decode(from: result.stdout, source: "local")
        } catch {
            throw DaemonError.parseError(error.localizedDescription)
        }
    }

    private func syncV3SessionInstance() -> AgtmuxSyncV3Session {
        if let syncV3Session {
            return syncV3Session
        }

        let created = AgtmuxSyncV3Session(transport: self)
        syncV3Session = created
        return created
    }

    func ensureManagedRuntimeConfigured(forInlineOverrideKeys keys: [String]) throws {
        guard usesManagedDefaultSocket else { return }

        let env = ProcessInfo.processInfo.environment
        if keys.contains(where: { env[$0] != nil }) {
            return
        }

        let candidates = AgtmuxBinaryResolver.candidateBinaryURLs()
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard !candidates.isEmpty else {
            throw DaemonError.daemonUnavailable
        }
    }

    // MARK: - Process Helper

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: String
    }

    private static func runProcess(executableURL: URL,
                                   arguments: [String],
                                   timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        var stdoutData = Data()
        var stderrData = Data()

        let stdoutRead = DispatchSemaphore(value: 0)
        let stderrRead = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutRead.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrRead.signal()
        }

        do {
            try process.run()
        } catch {
            throw DaemonError.processError(exitCode: -1, stderr: error.localizedDescription)
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = stdoutRead.wait(timeout: .now() + 0.5)
            _ = stderrRead.wait(timeout: .now() + 0.5)
            throw DaemonError.processError(exitCode: -2, stderr: "timed out")
        }

        _ = stdoutRead.wait(timeout: .now() + 1.0)
        _ = stderrRead.wait(timeout: .now() + 1.0)

        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderr)
    }
}

package enum DaemonUIErrorCode: String, Sendable {
    case syncV3MethodNotFound = "sync_v3_method_not_found"
    case uiHealthMethodNotFound = "ui_health_v1_method_not_found"
}

package struct DaemonUIErrorEnvelope: Codable, Sendable {
    package let code: String
    package let message: String
    package let method: String?
    package let rpcCode: Int?

    package init(code: String, message: String, method: String?, rpcCode: Int?) {
        self.code = code
        self.message = message
        self.method = method
        self.rpcCode = rpcCode
    }
}

extension DaemonError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .daemonUnavailable:
            return "agtmux daemon unavailable"
        case let .processError(exitCode, stderr):
            if let payload = Self.decodeUIErrorEnvelope(from: stderr) {
                return payload.message
            }
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "agtmux process failed with exit code \(exitCode)"
            }
            return "agtmux process failed with exit code \(exitCode): \(detail)"
        case let .parseError(message):
            return message
        }
    }

    public var description: String {
        errorDescription ?? "agtmux daemon error"
    }
}

package extension DaemonError {
    static let uiErrorPrefix = "AGTMUX_UI_ERROR="

    var uiSurfaceText: String {
        switch self {
        case let .processError(_, stderr) where stderr.hasPrefix(Self.uiErrorPrefix):
            return stderr
        default:
            return errorDescription ?? "agtmux daemon error"
        }
    }

    static func makeSyncV3MethodNotFoundError(method: String, rpcCode: Int?, message: String) -> DaemonError {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeText = rpcCode.map(String.init) ?? "unknown"
        let humanMessage = "agtmux daemon does not expose sync-v3 RPC method \(method) (code \(codeText)): \(trimmed)"
        return makeStructuredMethodNotFoundError(
            code: .syncV3MethodNotFound,
            method: method,
            rpcCode: rpcCode,
            message: humanMessage
        )
    }

    static func makeUIHealthMethodNotFoundError(method: String, rpcCode: Int?, message: String) -> DaemonError {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeText = rpcCode.map(String.init) ?? "unknown"
        let humanMessage = "agtmux daemon does not expose ui.health.v1 observability: missing RPC method \(method) (code \(codeText)): \(trimmed)"
        return makeStructuredMethodNotFoundError(
            code: .uiHealthMethodNotFound,
            method: method,
            rpcCode: rpcCode,
            message: humanMessage
        )
    }

    private static func makeStructuredMethodNotFoundError(
        code: DaemonUIErrorCode,
        method: String,
        rpcCode: Int?,
        message: String
    ) -> DaemonError {
        let payload = DaemonUIErrorEnvelope(
            code: code.rawValue,
            message: message,
            method: method,
            rpcCode: rpcCode
        )
        guard
            let data = try? JSONEncoder().encode(payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return .processError(exitCode: Int32(rpcCode ?? -32601), stderr: message)
        }
        return .processError(exitCode: Int32(rpcCode ?? -32601), stderr: "\(Self.uiErrorPrefix)\(json)")
    }

    var isSyncV3MethodNotFound: Bool {
        guard case let .processError(_, stderr) = self,
              let envelope = Self.decodeUIErrorEnvelope(from: stderr) else { return false }
        return envelope.code == DaemonUIErrorCode.syncV3MethodNotFound.rawValue
    }

    static func decodeUIErrorEnvelope(from text: String) -> DaemonUIErrorEnvelope? {
        guard text.hasPrefix(Self.uiErrorPrefix) else { return nil }
        let payloadText = String(text.dropFirst(Self.uiErrorPrefix.count))
        guard let data = payloadText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DaemonUIErrorEnvelope.self, from: data)
    }
}
