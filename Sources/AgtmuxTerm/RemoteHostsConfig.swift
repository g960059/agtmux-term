import Foundation

// MARK: - RemoteHost

/// A remote machine that hosts tmux sessions accessible via SSH or mosh.
struct RemoteHost: Codable, Identifiable {
    let id: String           // unique key, e.g. "vm1"
    let displayName: String?
    let hostname: String
    let user: String?        // nil → uses local SSH config / current user

    enum Transport: String, Codable { case ssh, mosh }
    let transport: Transport

    /// SSH-style target string, e.g. "alice@vm1.example.com" or "vm1.example.com".
    var sshTarget: String {
        user.map { "\($0)@\(hostname)" } ?? hostname
    }
}

// MARK: - HostsConfig

/// Loaded from `~/.config/agtmux-term/hosts.json`.
///
/// JSON format:
/// ```json
/// {
///   "hosts": [
///     { "id": "vm1", "hostname": "vm1.example.com", "user": "alice", "transport": "mosh" }
///   ]
/// }
/// ```
///
/// File missing or malformed → returns empty config (logged, not thrown).
struct HostsConfig: Codable {
    let hosts: [RemoteHost]

    static let empty = HostsConfig(hosts: [])

    static func load() -> HostsConfig {
        let configURL = hostsConfigURL()
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(HostsConfig.self, from: data)
        } catch {
            fputs("agtmux-term: failed to load hosts config at \(configURL.path): \(error)\n", stderr)
            return .empty
        }
    }

    /// Display name for a given source identifier (hostname or "local").
    func displayName(for source: String) -> String? {
        hosts.first { $0.hostname == source }?.displayName
    }

    /// Lookup host by its hostname (used as source identifier in AgtmuxPane).
    func host(for source: String) -> RemoteHost? {
        hosts.first { $0.hostname == source }
    }

    // MARK: - Private

    private static func hostsConfigURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("agtmux-term")
            .appendingPathComponent("hosts.json")
    }
}
