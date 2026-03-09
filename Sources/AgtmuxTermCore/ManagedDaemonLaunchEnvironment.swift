import Foundation

package enum ManagedDaemonLaunchEnvironment {
    private static let preferredPathSegments = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    package static func normalized(
        from env: [String: String],
        tmuxBinResolver: ([String: String]) -> String? = { env in
            LocalTmuxTarget.resolvedTmuxBinaryPath(from: env)
        }
    ) -> [String: String] {
        var normalized = env
        normalized["TMUX"] = nil
        normalized["TMUX_PANE"] = nil

        let username = normalized["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? NSUserName()
        let homeDirectory = normalized["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? NSHomeDirectoryForUser(username)
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        normalized["USER"] = username
        normalized["LOGNAME"] = username
        normalized["HOME"] = homeDirectory

        if normalized["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            normalized["XDG_CONFIG_HOME"] = homeDirectory + "/.config"
        }
        if normalized["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            normalized["CODEX_HOME"] = homeDirectory + "/.codex"
        }

        let existingPathSegments = (normalized["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedPathSegments: [String] = []
        for segment in preferredPathSegments + existingPathSegments where !segment.isEmpty {
            if !mergedPathSegments.contains(segment) {
                mergedPathSegments.append(segment)
            }
        }
        normalized["PATH"] = mergedPathSegments.joined(separator: ":")

        if let tmuxBin = tmuxBinResolver(normalized)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tmuxBin.isEmpty {
            normalized["TMUX_BIN"] = tmuxBin
        } else {
            normalized["TMUX_BIN"] = nil
        }

        return normalized
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
