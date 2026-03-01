import Foundation

// MARK: - AppViewModel

/// Central state holder for the agtmux-term UI.
///
/// Polls the local agtmux daemon and any configured remote hosts every 1 second.
/// Remote hosts are discovered via SSH + `tmux list-panes` — no agtmux required on remote.
/// All @Published properties are mutated on the main actor.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var panes: [AgtmuxPane] = []
    @Published var selectedPane: AgtmuxPane?
    /// Set of source identifiers that are currently unreachable ("local" or hostname).
    @Published var offlineHosts: Set<String> = []
    @Published var statusFilter: StatusFilter = .all

    /// True if any source is offline.
    var isOffline: Bool { !offlineHosts.isEmpty }

    /// Panes grouped by source, with "local" first, then remotes alphabetically.
    var panesBySource: [(source: String, panes: [AgtmuxPane])] {
        let grouped = Dictionary(grouping: panes, by: \.source)
        let sources = grouped.keys.sorted { a, b in
            if a == "local" { return true }
            if b == "local" { return false }
            return a < b
        }
        return sources.map { source in (source: source, panes: grouped[source] ?? []) }
    }

    // MARK: - Filtered panes

    var filteredPanes: [AgtmuxPane] {
        switch statusFilter {
        case .all:
            return panes
        case .managed:
            return panes.filter { $0.presence != nil }
        case .attention:
            return panes.filter { $0.needsAttention }
        case .pinned:
            return panes.filter { $0.isPinned }
        }
    }

    // MARK: - Selection

    func selectPane(_ pane: AgtmuxPane) {
        selectedPane = pane
    }

    // MARK: - Clients

    private let localClient = AgtmuxDaemonClient()
    private var remoteClients: [RemoteTmuxClient] = []
    let hostsConfig: HostsConfig

    // MARK: - Init

    init() {
        let config = HostsConfig.load()
        self.hostsConfig = config
        self.remoteClients = config.hosts.map { RemoteTmuxClient(host: $0) }
    }

    // MARK: - Polling

    private var pollingTask: Task<Void, Never>?

    /// Start the 1-second polling loop.
    ///
    /// Guarded against double-start: calling startPolling() while already running is a no-op.
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                await fetchAll()

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    /// Cancel the polling loop and reset so startPolling() can be called again.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    /// Fetch from all sources concurrently, merge results, update state.
    private func fetchAll() async {
        // Gather panes from all sources concurrently.
        var allPanes: [AgtmuxPane] = []
        var newOffline: Set<String> = []

        await withTaskGroup(of: (source: String, panes: [AgtmuxPane]?, offline: Bool).self) { group in
            // Local
            group.addTask {
                do {
                    let snapshot = try await self.localClient.fetchSnapshot()
                    return ("local", snapshot.panes, false)
                } catch {
                    return ("local", nil, true)
                }
            }
            // Remote hosts
            for client in self.remoteClients {
                group.addTask {
                    let source = client.host.hostname
                    do {
                        let panes = try await client.fetchPanes()
                        return (source, panes, false)
                    } catch {
                        return (source, nil, true)
                    }
                }
            }

            for await result in group {
                if result.offline {
                    newOffline.insert(result.source)
                } else if let panes = result.panes {
                    allPanes.append(contentsOf: panes)
                }
            }
        }

        panes = allPanes
        offlineHosts = newOffline
    }
}
