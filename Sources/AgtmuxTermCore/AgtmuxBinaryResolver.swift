import Foundation

/// Shared resolver for locating the agtmux executable.
///
/// Resolution order:
/// 1. `AGTMUX_BIN` environment variable (explicit override)
/// 2. Bundled binary in app resources (`Resources/Tools/agtmux`)
/// 3. PATH + common fallback directories
public enum AgtmuxBinaryResolver {
    public static let defaultSocketPath = "/tmp/agtmux-\(ProcessInfo.processInfo.userName)/agtmuxd.sock"

    public static func resolveBinaryURL() -> URL? {
        candidateBinaryURLs().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    public static func candidateBinaryURLs() -> [URL] {
        let env = ProcessInfo.processInfo.environment

        // Explicit user override takes precedence and disables fallback guessing.
        if let envPath = env["AGTMUX_BIN"], !envPath.isEmpty {
            return [URL(fileURLWithPath: envPath)]
        }

        var urls: [URL] = []
        if let bundled = bundledBinaryURL() {
            urls.append(bundled)
        }

        let home = NSHomeDirectory()
        let searchPaths: [String] = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/go/bin",
            "\(home)/.cargo/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]

        for dir in searchPaths {
            urls.append(URL(fileURLWithPath: dir).appendingPathComponent("agtmux"))
        }

        // Keep order stable while removing duplicate paths.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
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
