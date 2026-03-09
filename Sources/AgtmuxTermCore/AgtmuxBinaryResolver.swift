import Foundation

/// Shared resolver for locating the agtmux executable.
///
/// Resolution order:
/// 1. `AGTMUX_BIN` environment variable (explicit override)
/// 2. Bundled binary in app resources (`Resources/Tools/agtmux`)
public enum AgtmuxBinaryResolver {
    public static let managedSocketPathEnvKey = "AGTMUX_DAEMON_SOCKET_PATH"
    private static let runtimeDirectoryName = "AGTMUXDesktop"
    public static let defaultSocketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
        .appendingPathComponent("agtmuxd.sock", isDirectory: false)
    public static let defaultSocketPath = defaultSocketURL.path

    public static func resolvedSocketPath(from env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = env[managedSocketPathEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return defaultSocketPath
    }

    public static func resolvedSocketURL(from env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: resolvedSocketPath(from: env))
    }

    public static func resolveBinaryURL() -> URL? {
        candidateBinaryURLs().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    public static func candidateBinaryURLs() -> [URL] {
        let env = ProcessInfo.processInfo.environment

        // Explicit user override takes precedence and disables fallback guessing.
        if let envPath = env["AGTMUX_BIN"], !envPath.isEmpty {
            return [URL(fileURLWithPath: envPath)]
        }

        if let bundled = bundledBinaryURL() {
            return [bundled]
        }
        return []
    }

    public static func bundledBinaryURL() -> URL? {
        let bundle = Bundle.main

        if let url = bundle.url(forResource: "agtmux", withExtension: nil as String?, subdirectory: "Tools") {
            return url
        }
        if let url = bundle.url(forResource: "agtmux", withExtension: nil as String?) {
            return url
        }
        if let appBundleURL = containingAppBundleURL(for: bundle.bundleURL) {
            let bundledTools = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("Tools")
                .appendingPathComponent("agtmux")
            if FileManager.default.fileExists(atPath: bundledTools.path) {
                return bundledTools
            }

            let bundledFlat = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("agtmux")
            if FileManager.default.fileExists(atPath: bundledFlat.path) {
                return bundledFlat
            }
        }
        return nil
    }

    public static func ensureSocketParentDirectoryExists(for socketPath: String) throws {
        let directoryURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func containingAppBundleURL(for bundleURL: URL) -> URL? {
        guard bundleURL.pathExtension == "xpc" else { return nil }
        let xpcServicesURL = bundleURL.deletingLastPathComponent()
        let contentsURL = xpcServicesURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else { return nil }

        let appBundleURL = contentsURL.deletingLastPathComponent()
        guard appBundleURL.pathExtension == "app" else { return nil }
        return appBundleURL
    }
}
