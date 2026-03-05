import Foundation
import AgtmuxTermCore

protocol LocalPaneInventoryClient: Sendable {
    func fetchPanes() async throws -> [AgtmuxPane]
}

/// Local tmux inventory client.
///
/// Unlike agtmux metadata (`agtmux json`), this client is authoritative for
/// local tmux object existence (session/window/pane).
actor LocalTmuxInventoryClient: LocalPaneInventoryClient {
    /// tmux format string using a stable printable separator token:
    /// pane_id, session_name, window_id, window_index, window_name,
    /// pane_current_path, pane_current_command, session_group
    ///
    /// Some environments sanitize control-character delimiters (e.g. `\t`) to `_`
    /// in `list-panes -F` output. A long alphanumeric token avoids that mutation.
    private static let fieldSeparator = "AGTMUXFIELDSEP9F6F2D4D"
    private static let formatString =
        [
            "#{pane_id}",
            "#{session_name}",
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{pane_current_path}",
            "#{pane_current_command}",
            "#{session_group}"
        ].joined(separator: fieldSeparator)

    func fetchPanes() async throws -> [AgtmuxPane] {
        do {
            let output = try await TmuxCommandRunner.shared.run(
                ["list-panes", "-a", "-F", Self.formatString],
                source: "local"
            )
            let panes = try Self.parse(output: output, source: "local")
            return panes
        } catch let TmuxCommandError.failed(_, _, stderr) {
            // "no server running" means local tmux has no sessions.
            // Treat as empty inventory, not a hard fetch failure.
            if Self.isNoServer(stderr) {
                return []
            }
            throw DaemonError.processError(exitCode: 1, stderr: stderr)
        }
    }

    private static func isNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
    }

    static func parse(output: String, source: String) throws -> [AgtmuxPane] {
        var panes: [AgtmuxPane] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            let fields = line.components(separatedBy: fieldSeparator)
            guard fields.count == 8 else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: expected 8 fields " +
                    "separator=\(fieldSeparator) line='\(line)'"
                )
            }

            let paneId = fields[0]
            let sessionName = fields[1]
            let windowId = fields[2]
            let rawWindowIndex = fields[3]
            let windowName = fields[4].isEmpty ? nil : fields[4]
            let currentPath = fields[5].isEmpty ? nil : fields[5]
            let currentCmd = fields[6].isEmpty ? nil : fields[6]
            let sessionGroup = fields[7].isEmpty ? nil : fields[7]

            guard !paneId.isEmpty, !sessionName.isEmpty, !windowId.isEmpty else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: required field empty line='\(line)'"
                )
            }

            let windowIndex: Int?
            if rawWindowIndex.isEmpty {
                windowIndex = nil
            } else if let parsedIndex = Int(rawWindowIndex) {
                windowIndex = parsedIndex
            } else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: invalid window_index '\(rawWindowIndex)' line='\(line)'"
                )
            }

            panes.append(
                AgtmuxPane(
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
            )
        }

        return panes
    }
}
