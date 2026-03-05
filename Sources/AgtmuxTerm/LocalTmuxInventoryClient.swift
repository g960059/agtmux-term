import Foundation
import AgtmuxTermCore

/// Local tmux inventory client.
///
/// Unlike agtmux metadata (`agtmux json`), this client is authoritative for
/// local tmux object existence (session/window/pane).
actor LocalTmuxInventoryClient {
    /// Tab-separated tmux format string:
    /// pane_id, session_name, window_id, window_index, window_name,
    /// pane_current_path, pane_current_command, session_group
    private static let formatString =
        "#{pane_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_current_path}\t#{pane_current_command}\t#{session_group}"

    func fetchPanes() async throws -> [AgtmuxPane] {
        do {
            let output = try await TmuxCommandRunner.shared.run(
                ["list-panes", "-a", "-F", Self.formatString],
                source: "local"
            )
            return Self.parse(output: output, source: "local")
        } catch let TmuxCommandError.failed(_, _, stderr) {
            // "no server running" means local tmux has no sessions.
            // Treat as empty inventory, not a hard fetch failure.
            if Self.isNoServer(stderr) {
                return []
            }
            throw DaemonError.processError(exitCode: 1, stderr: stderr)
        } catch {
            throw error
        }
    }

    private static func isNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
    }

    private static func parse(output: String, source: String) -> [AgtmuxPane] {
        output
            .components(separatedBy: "\n")
            .compactMap { line -> AgtmuxPane? in
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 3 else { return nil }

                let paneId = fields[0]
                let sessionName = fields[1]
                let windowId = fields[2]
                let windowIndex = fields.count >= 4 ? Int(fields[3]) : nil
                let windowName = fields.count >= 5 && !fields[4].isEmpty ? fields[4] : nil
                let currentPath = fields.count >= 6 && !fields[5].isEmpty ? fields[5] : nil
                let currentCmd = fields.count >= 7 && !fields[6].isEmpty ? fields[6] : nil
                let sessionGroup = fields.count >= 8 && !fields[7].isEmpty ? fields[7] : nil

                guard !paneId.isEmpty, !sessionName.isEmpty, !windowId.isEmpty else { return nil }

                return AgtmuxPane(
                    source: source,
                    paneId: paneId,
                    sessionName: sessionName,
                    sessionGroup: sessionGroup,
                    windowId: windowId,
                    windowIndex: windowIndex,
                    windowName: windowName,
                    activityState: .unknown,
                    presence: .unmanaged,
                    evidenceMode: .none,
                    currentPath: currentPath,
                    currentCmd: currentCmd
                )
            }
    }
}
