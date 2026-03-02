import Foundation

// MARK: - RemoteTmuxClient

/// Fetches pane snapshots from a remote host via SSH without requiring agtmux.
///
/// Runs: `ssh -o BatchMode=yes -o ConnectTimeout=5 [user@]host tmux list-panes -a -F "..."`
///
/// Requirements on the remote host: only `tmux` and SSH access.
/// Agent state (`activityState`, `conversationTitle`) will always be `.unknown` / nil.
actor RemoteTmuxClient {
    let host: RemoteHost

    init(host: RemoteHost) {
        self.host = host
    }

    // MARK: - Public API

    /// Fetch the pane list from the remote host via SSH.
    ///
    /// Throws `DaemonError` on SSH failures (auth, timeout, tmux not running).
    func fetchPanes() async throws -> [AgtmuxPane] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Capture source before entering the nonisolated terminationHandler closure.
        let source = host.hostname
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            host.sshTarget,
            "tmux", "list-panes", "-a",
            "-F", Self.formatString,
        ]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
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
                let output = String(data: data, encoding: .utf8) ?? ""
                let panes = Self.parse(output: output, source: source)
                continuation.resume(returning: panes)
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

    // MARK: - Private

    /// Tab-separated tmux format string.
    /// Fields: pane_id, session_name, window_id, pane_current_path
    private static let formatString = "#{pane_id}\t#{session_name}\t#{window_id}\t#{pane_current_path}"

    private static func parse(output: String, source: String) -> [AgtmuxPane] {
        output
            .components(separatedBy: "\n")
            .compactMap { line -> AgtmuxPane? in
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 3 else { return nil }
                let paneId      = fields[0]
                let sessionName = fields[1]
                let windowId    = fields[2]
                let currentPath  = fields.count >= 4 ? fields[3] : nil
                guard !paneId.isEmpty, !sessionName.isEmpty, !windowId.isEmpty else { return nil }
                return AgtmuxPane(source: source,
                                  paneId: paneId,
                                  sessionName: sessionName,
                                  windowId: windowId,
                                  activityState: .unknown,
                                  currentPath: currentPath)
            }
    }
}
