import Foundation
import AgtmuxTermCore

// MARK: - SessionGroup

/// A group of windows sharing the same tmux session, within a single source.
struct SessionGroup: Identifiable {
    var id: String { "\(source):\(sessionName)" }
    let source: String
    let sessionName: String
    let windows: [WindowGroup]

    /// All panes across all windows in this session (backward-compatible read access).
    var panes: [AgtmuxPane] { windows.flatMap(\.panes) }

    /// Representative git branch: the first non-nil gitBranch among managed panes, else any pane.
    var representativeBranch: String? {
        let allPanes = panes
        return allPanes.first(where: { $0.isManaged && $0.gitBranch != nil })?.gitBranch
            ?? allPanes.first(where: { $0.gitBranch != nil })?.gitBranch
    }
}

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

    // MARK: - Grouping

    /// Panes grouped by source, with "local" first, then remotes alphabetically.
    var panesBySource: [(source: String, panes: [AgtmuxPane])] {
        let grouped = Dictionary(grouping: panes, by: \.source)
        return sortedSources(grouped.keys).map { source in
            (source: source, panes: grouped[source] ?? [])
        }
    }

    /// Panes grouped by source → session → window. Used by the sidebar 4-level layout.
    ///
    /// Within each source, sessions are sorted alphabetically.
    /// Within each session, windows are sorted by windowIndex (if available), else by windowId.
    /// Within each window, panes are sorted by paneId.
    var panesBySession: [(source: String, sessions: [SessionGroup])] {
        let bySource = Dictionary(grouping: filteredPanes, by: \.source)
        return sortedSources(bySource.keys).map { source in
            let sourcePanes = bySource[source] ?? []
            let bySession = Dictionary(grouping: sourcePanes, by: \.sessionName)
            let sessions = bySession.keys.sorted().map { sessionName -> SessionGroup in
                let sessionPanes = bySession[sessionName] ?? []
                let byWindow = Dictionary(grouping: sessionPanes, by: \.windowId)
                let windows = byWindow.keys
                    .sorted { a, b in
                        let ia = (byWindow[a] ?? []).first?.windowIndex
                        let ib = (byWindow[b] ?? []).first?.windowIndex
                        if let ia, let ib { return ia < ib }
                        return a < b
                    }
                    .map { wid -> WindowGroup in
                        let wPanes = (byWindow[wid] ?? []).sorted { $0.paneId < $1.paneId }
                        let first = wPanes.first
                        return WindowGroup(source: source,
                                           sessionName: sessionName,
                                           windowId: wid,
                                           windowIndex: first?.windowIndex,
                                           windowName: first?.windowName,
                                           panes: wPanes)
                    }
                return SessionGroup(source: source, sessionName: sessionName, windows: windows)
            }
            return (source: source, sessions: sessions)
        }
    }

    /// Count of panes currently needing attention (across all sources, unfiltered).
    var attentionCount: Int { panes.filter { $0.needsAttention }.count }

    // MARK: - Filtered panes

    var filteredPanes: [AgtmuxPane] {
        // Exclude internal linked sessions created by LinkedSessionManager (agtmux-linked-*).
        // These share pane IDs with parent sessions; showing them causes multiple
        // sidebar rows to highlight simultaneously for the same selected pane.
        // NOTE: "agtmux-{UUID}" sessions (without "linked-") are real user sessions
        // created by the agtmux CLI where Claude Code runs — they must remain visible
        // for status dots to appear (T-056).
        let visible = panes.filter { !$0.sessionName.hasPrefix("agtmux-linked-") }
        switch statusFilter {
        case .all:       return visible
        case .managed:   return visible.filter { $0.isManaged }
        case .attention: return visible.filter { $0.needsAttention }
        case .pinned:    return visible.filter { $0.isPinned }
        }
    }

    // MARK: - Selection

    func selectPane(_ pane: AgtmuxPane) {
        selectedPane = pane
    }

    // MARK: - Clients

    private let localClient: any LocalSnapshotClient
    private var remoteClients: [RemoteTmuxClient] = []
    let hostsConfig: HostsConfig

    // MARK: - Init

    init(localClient: (any LocalSnapshotClient)? = nil) {
        self.localClient = localClient ?? AgtmuxDaemonClient()
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

    /// Source ordering: "local" first, then alphabetically.
    private func sortedSources(_ keys: some Collection<String>) -> [String] {
        keys.sorted { a, b in
            if a == "local" { return true }
            if b == "local" { return false }
            return a < b
        }
    }

    /// Fetch from all sources concurrently, merge results, update state.
    /// Internal access so TmuxManager can trigger an immediate refresh.
    func fetchAll() async {
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
