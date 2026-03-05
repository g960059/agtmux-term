import Foundation

/// Resolves which local tmux server/socket to target.
///
/// Precedence:
/// 1) `AGTMUX_TMUX_SOCKET_NAME` -> `tmux -L <name>`
/// 2) `AGTMUX_TMUX_SOCKET` -> `tmux -S <path>`
/// 3) default tmux socket selection (no args)
///
/// Note:
/// Inherited `TMUX` is intentionally ignored to avoid pinning local commands to a
/// stale or sandbox-inaccessible socket from the launch environment.
public enum LocalTmuxTarget {
    public static func socketArguments(from env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let explicitName = env["AGTMUX_TMUX_SOCKET_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitName.isEmpty {
            return ["-L", explicitName]
        }

        if let explicitPath = env["AGTMUX_TMUX_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty {
            return ["-S", explicitPath]
        }

        return []
    }

    public static func shellEscaped(_ value: String) -> String {
        if value.range(of: #"[^A-Za-z0-9_./:-]"#, options: .regularExpression) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellEscapedSocketArguments(from env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        socketArguments(from: env).map(shellEscaped).joined(separator: " ")
    }
}
