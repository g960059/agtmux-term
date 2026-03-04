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
        let visible = panes
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
    private var lastSuccessfulPanesBySource: [String: [AgtmuxPane]] = [:]
    private var lastSuccessfulLocalSessionAliasMap: [String: String] = [:]

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

    /// Normalize panes so UI identity and grouping are stable:
    /// - collapse session-group aliases to a canonical session name
    /// - hide internal linked sessions
    /// - dedupe repeated rows that point to the same pane in the same canonical session
    private func normalizePanes(_ allPanes: [AgtmuxPane]) async -> [AgtmuxPane] {
        let bySource = Dictionary(grouping: allPanes, by: \.source)
        var normalized: [AgtmuxPane] = []

        for source in sortedSources(bySource.keys) {
            let sourcePanes = bySource[source] ?? []
            let aliasMap = source == "local" ? await localSessionAliasMap() : [:]

            let transformed = sourcePanes.compactMap { pane -> AgtmuxPane? in
                // Internal linked sessions are implementation details.
                if pane.sessionName.hasPrefix("agtmux-linked-") { return nil }

                let canonicalSession: String
                if let group = pane.sessionGroup, !group.isEmpty {
                    canonicalSession = group
                } else if let alias = aliasMap[pane.sessionName], !alias.isEmpty {
                    canonicalSession = alias
                } else {
                    canonicalSession = pane.sessionName
                }

                if canonicalSession == pane.sessionName { return pane }
                return pane.withSessionName(canonicalSession)
            }

            normalized.append(contentsOf: dedupePanes(transformed))
        }

        return normalized
    }

    /// Map local tmux session_name -> canonical session-group name.
    ///
    /// This mapping must stay stable across polls; canonical target is always
    /// `session_group` when available. On transient command failure, return the
    /// previous successful map to avoid flicker.
    private func localSessionAliasMap() async -> [String: String] {
        let format = "#{session_name}\t#{session_group}"
        guard let output = try? await TmuxCommandRunner.shared.run(
            ["list-sessions", "-F", format],
            source: "local"
        ) else {
            return lastSuccessfulLocalSessionAliasMap
        }
        var aliases: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let rawName = fields.first else { continue }
            let name = String(rawName)
            guard !name.isEmpty else { continue }
            let group = fields.count >= 2 ? String(fields[1]) : ""
            aliases[name] = group.isEmpty ? name : group
        }

        if aliases.isEmpty {
            return lastSuccessfulLocalSessionAliasMap
        }
        lastSuccessfulLocalSessionAliasMap = aliases
        return aliases
    }

    private func dedupePanes(_ panes: [AgtmuxPane]) -> [AgtmuxPane] {
        var deduped: [String: AgtmuxPane] = [:]

        for pane in panes {
            let key = "\(pane.source):\(pane.sessionName):\(pane.windowId):\(pane.paneId)"
            if let existing = deduped[key] {
                deduped[key] = preferredPane(existing, pane)
            } else {
                deduped[key] = pane
            }
        }
        return Array(deduped.values)
    }

    private func preferredPane(_ lhs: AgtmuxPane, _ rhs: AgtmuxPane) -> AgtmuxPane {
        func score(_ pane: AgtmuxPane) -> (Int, Int, Int, Date) {
            (
                pane.isManaged ? 1 : 0,
                pane.conversationTitle?.isEmpty == false ? 1 : 0,
                pane.provider != nil ? 1 : 0,
                pane.updatedAt ?? .distantPast
            )
        }
        return score(rhs) > score(lhs) ? rhs : lhs
    }

    /// Fetch from all sources concurrently, merge results, update state.
    /// Internal access so TmuxManager can trigger an immediate refresh.
    func fetchAll() async {
        var successfulBySource: [String: [AgtmuxPane]] = [:]
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
                    successfulBySource[result.source] = panes
                }
            }
        }

        // Update cache only for successful sources. Failed sources keep the previous
        // successful snapshot to avoid sidebar flicker/empty flashes.
        for (source, panes) in successfulBySource {
            lastSuccessfulPanesBySource[source] = panes
        }

        let knownSources = Set(["local"] + remoteClients.map(\.host.hostname))
        lastSuccessfulPanesBySource = lastSuccessfulPanesBySource.filter { knownSources.contains($0.key) }

        let merged = sortedSources(lastSuccessfulPanesBySource.keys)
            .flatMap { lastSuccessfulPanesBySource[$0] ?? [] }
        let normalized = await normalizePanes(merged)
        panes = normalized
        if let currentSelectedPane = selectedPane {
            selectedPane = normalized.first {
                $0.source == currentSelectedPane.source
                    && $0.paneId == currentSelectedPane.paneId
                    && $0.windowId == currentSelectedPane.windowId
            }
        }
        offlineHosts = newOffline
    }
}
