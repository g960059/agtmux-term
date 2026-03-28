import Foundation

/// Resolves which local tmux server/socket to target.
///
/// Precedence:
/// 1) `AGTMUX_TMUX_SOCKET_NAME` -> `tmux -L <name>`
/// 2) `AGTMUX_TMUX_SOCKET_PATH` / `AGTMUX_TMUX_SOCKET` -> `tmux -S <path>`
/// 3) default tmux socket selection (no args)
///
/// Note:
/// Inherited `TMUX` is intentionally ignored to avoid pinning local commands to a
/// stale or sandbox-inaccessible socket from the launch environment.
public enum LocalTmuxTarget {
    public static let socketNameDefaultsKey = "UITestTmuxSocketName"
    public static let socketPathDefaultsKey = "UITestTmuxSocketPath"
    public static let configPathDefaultsKey = "UITestTmuxConfigPath"
    public static let stableAttachEnabledRelativePath = "agtmux-term/gate-l-attach/enabled"

    public static func configArguments(
        from env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        markerURL: URL? = nil
    ) -> [String] {
        guard let path = explicitConfigPath(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ),
            !path.isEmpty else {
            return []
        }
        return ["-f", path]
    }

    public static func socketArguments(
        from env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        markerURL: URL? = nil
    ) -> [String] {
        if let explicitName = explicitSocketName(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ),
           !explicitName.isEmpty {
            return ["-L", explicitName]
        }

        if let explicitPath = explicitSocketPath(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ),
           !explicitPath.isEmpty {
            return ["-S", explicitPath]
        }

        return []
    }

    public static func daemonCLIArguments(
        from env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        markerURL: URL? = nil,
        socketPathResolver: (([String: String]) -> String?)? = nil
    ) -> [String] {
        if let socketPathResolver {
            guard let socketPath = socketPathResolver(env) else { return [] }
            return ["--tmux-socket", socketPath]
        }
        guard let socketPath = resolvedSocketPathForDaemon(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ) else {
            return []
        }
        return ["--tmux-socket", socketPath]
    }

    public static func defaultsBackedUITestTargetingActive(
        from env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        markerURL: URL? = nil
    ) -> Bool {
        if env["AGTMUX_UITEST"] == "1" {
            return true
        }
        return fileManager.fileExists(
            atPath: stableAttachEnabledURL(fileManager: fileManager, markerURL: markerURL).path
        )
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

    public static func shellEscapedConfigArguments(from env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        configArguments(from: env).map(shellEscaped).joined(separator: " ")
    }

    package static func resolvedTmuxBinaryPath(
        from env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        resolveTmuxURL(from: env)?.path
    }

    private static func explicitSocketPath(
        from env: [String: String],
        userDefaults: UserDefaults,
        fileManager: FileManager,
        markerURL: URL?
    ) -> String? {
        for key in ["AGTMUX_TMUX_SOCKET_PATH", "AGTMUX_TMUX_SOCKET"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        guard defaultsBackedUITestTargetingActive(
            from: env,
            fileManager: fileManager,
            markerURL: markerURL
        ) else {
            return nil
        }
        if let value = userDefaults.string(forKey: socketPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func explicitConfigPath(
        from env: [String: String],
        userDefaults: UserDefaults,
        fileManager: FileManager,
        markerURL: URL?
    ) -> String? {
        if let value = env["AGTMUX_UITEST_TMUX_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        guard defaultsBackedUITestTargetingActive(
            from: env,
            fileManager: fileManager,
            markerURL: markerURL
        ) else {
            return nil
        }
        if let value = userDefaults.string(forKey: configPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func explicitSocketName(
        from env: [String: String],
        userDefaults: UserDefaults,
        fileManager: FileManager,
        markerURL: URL?
    ) -> String? {
        if let value = env["AGTMUX_TMUX_SOCKET_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        guard defaultsBackedUITestTargetingActive(
            from: env,
            fileManager: fileManager,
            markerURL: markerURL
        ) else {
            return nil
        }
        if let value = userDefaults.string(forKey: socketNameDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func resolvedSocketPathForDaemon(
        from env: [String: String],
        userDefaults: UserDefaults,
        fileManager: FileManager,
        markerURL: URL?
    ) -> String? {
        if let explicitPath = explicitSocketPath(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ) {
            return explicitPath
        }

        if let runtimeResolvedPath = AgtmuxManagedDaemonRuntime.bootstrapResolvedTmuxSocketPath() {
            return runtimeResolvedPath
        }

        guard let explicitName = explicitSocketName(
            from: env,
            userDefaults: userDefaults,
            fileManager: fileManager,
            markerURL: markerURL
        ),
              !explicitName.isEmpty else {
            return nil
        }

        return querySocketPath(
            tmuxArguments: ["-L", explicitName, "display-message", "-p", "#{socket_path}"],
            env: env
        )
    }

    private static func querySocketPath(tmuxArguments: [String], env: [String: String]) -> String? {
        guard let tmuxURL = resolveTmuxURL(from: env) else { return nil }

        let process = Process()
        process.executableURL = tmuxURL
        process.arguments = tmuxArguments
        var processEnv = env
        processEnv["TMUX"] = nil
        processEnv["TMUX_PANE"] = nil
        process.environment = processEnv

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard let firstLine = output.split(separator: "\n").first else {
            return nil
        }

        let socketPath = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        return socketPath.isEmpty ? nil : socketPath
    }

    private static func resolveTmuxURL(from env: [String: String]) -> URL? {
        var candidates: [String] = []

        if let explicit = env["TMUX_BIN"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        if let path = env["PATH"], !path.isEmpty {
            for dir in path.split(separator: ":") {
                candidates.append(String(dir) + "/tmux")
            }
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux",
        ])

        var seen: Set<String> = []
        for candidate in candidates where !candidate.isEmpty {
            if !seen.insert(candidate).inserted { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func stableAttachEnabledURL(fileManager: FileManager, markerURL: URL?) -> URL {
        if let markerURL {
            return markerURL
        }
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesURL.appendingPathComponent(stableAttachEnabledRelativePath, isDirectory: false)
    }
}
