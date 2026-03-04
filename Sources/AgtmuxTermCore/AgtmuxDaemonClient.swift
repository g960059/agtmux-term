import Foundation
import Darwin

// MARK: - DaemonError

/// Errors surfaced by AgtmuxDaemonClient.
package enum DaemonError: Error {
    /// agtmux binary not found in AGTMUX_BIN or PATH.
    case daemonUnavailable
    /// Binary ran but exited with a non-zero status.
    case processError(exitCode: Int32, stderr: String)
    /// Process exited 0 but JSON decoding failed.
    case parseError(String)
}

// MARK: - AgtmuxDaemonClient

/// Fetches pane snapshots by running `agtmux --socket-path <path> json` as a subprocess.
package actor AgtmuxDaemonClient {
    private let socketPath: String

    package init(socketPath: String = AgtmuxBinaryResolver.defaultSocketPath) {
        self.socketPath = socketPath
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
