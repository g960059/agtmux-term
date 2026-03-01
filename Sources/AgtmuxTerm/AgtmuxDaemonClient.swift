import Foundation

// MARK: - DaemonError

/// Errors surfaced by AgtmuxDaemonClient.
///
/// Per CLAUDE.md "Fail loudly": all failures propagate to the caller —
/// nothing is silently swallowed here.
enum DaemonError: Error {
    /// agtmux binary not found in AGTMUX_BIN or PATH.
    case daemonUnavailable
    /// Binary ran but exited with a non-zero status.
    case processError(exitCode: Int32, stderr: String)
    /// Process exited 0 but JSON decoding failed.
    case parseError(String)
}

// MARK: - AgtmuxDaemonClient

/// Fetches pane snapshots by running `agtmux --socket-path <path> json` as a subprocess.
///
/// Phase 1 implementation: subprocess call.
/// Phase 3 migration: replace internals with direct UDS JSON-RPC;
/// the public interface (`fetchSnapshot()`) stays identical.
actor AgtmuxDaemonClient {
    private let socketPath: String

    init(socketPath: String = "/tmp/agtmux-\(ProcessInfo.processInfo.userName)/agtmuxd.sock") {
        self.socketPath = socketPath
    }

    // MARK: - Public API

    /// Run `agtmux --socket-path <socketPath> json` and decode the result.
    ///
    /// Uses `terminationHandler + withCheckedThrowingContinuation` to avoid
    /// blocking a thread with `waitUntilExit()`.
    func fetchSnapshot() async throws -> AgtmuxSnapshot {
        guard let agtmuxURL = Self.resolveBinaryURL() else {
            throw DaemonError.daemonUnavailable
        }

        let process = Process()
        process.executableURL = agtmuxURL
        process.arguments = ["--socket-path", socketPath, "json"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                // Read stderr regardless of exit code (surfaced in errors).
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                guard proc.terminationStatus == 0 else {
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: DaemonError.processError(
                            exitCode: proc.terminationStatus,
                            stderr: stderrStr))
                    return
                }

                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                do {
                    let snapshot = try AgtmuxSnapshot.decode(from: data, source: "local")
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(
                        throwing: DaemonError.parseError(error.localizedDescription))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: DaemonError.processError(
                        exitCode: -1, stderr: error.localizedDescription))
            }
        }
    }

    // MARK: - Binary Resolution

    /// Resolve the agtmux binary: AGTMUX_BIN env var → PATH search → common fallback dirs.
    ///
    /// macOS GUI apps inherit a restricted PATH that omits ~/go/bin, ~/.cargo/bin, etc.
    /// The fallback list covers the most common install locations so the app works
    /// without requiring the user to set AGTMUX_BIN explicitly.
    private static func resolveBinaryURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let envPath = env["AGTMUX_BIN"] {
            return URL(fileURLWithPath: envPath)
        }
        let home = NSHomeDirectory()
        let searchPaths: [String] = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/go/bin",
            "\(home)/.cargo/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]
        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("agtmux")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
