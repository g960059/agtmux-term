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
    @Published private(set) var pinnedPaneKeys: Set<String> = []
    @Published private(set) var paneDisplayTitleOverrides: [String: String] = [:]
    @Published private(set) var sessionOrderBySource: [String: [String]] = [:]

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
    /// Within each source, sessions follow user-managed order (DnD) when present,
    /// then append unknown sessions alphabetically.
    /// Within each session, windows are sorted by windowIndex (if available), else by windowId.
    /// Within each window, panes are sorted by paneId.
    var panesBySession: [(source: String, sessions: [SessionGroup])] {
        let bySource = Dictionary(grouping: filteredPanes, by: \.source)
        return sortedSources(bySource.keys).map { source in
            let sourcePanes = bySource[source] ?? []
            let bySession = Dictionary(grouping: sourcePanes, by: \.sessionName)
            let orderedNames = orderedSessionNames(
                source: source,
                currentNames: Set(bySession.keys)
            )
            let sessions = orderedNames.map { sessionName -> SessionGroup in
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
        case .pinned:    return visible.filter { isPanePinned($0) }
        }
    }

    // MARK: - Pinning

    func isPanePinned(_ pane: AgtmuxPane) -> Bool {
        pinnedPaneKeys.contains(paneIdentityKey(for: pane))
    }

    func areAllPanesPinned(in window: WindowGroup) -> Bool {
        guard !window.panes.isEmpty else { return false }
        return window.panes.allSatisfy { isPanePinned($0) }
    }

    func areAllPanesPinned(in session: SessionGroup) -> Bool {
        let panes = session.panes
        guard !panes.isEmpty else { return false }
        return panes.allSatisfy { isPanePinned($0) }
    }

    func setPanePinned(_ pane: AgtmuxPane, pinned: Bool) {
        let key = paneIdentityKey(for: pane)
        if pinned {
            pinnedPaneKeys.insert(key)
        } else {
            pinnedPaneKeys.remove(key)
        }
    }

    func setWindowPinned(_ window: WindowGroup, pinned: Bool) {
        for pane in window.panes {
            setPanePinned(pane, pinned: pinned)
        }
    }

    func setSessionPinned(_ session: SessionGroup, pinned: Bool) {
        for pane in session.panes {
            setPanePinned(pane, pinned: pinned)
        }
    }

    func paneDisplayTitle(for pane: AgtmuxPane) -> String {
        let key = paneIdentityKey(for: pane)
        if let overridden = paneDisplayTitleOverrides[key],
           !overridden.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return overridden
        }
        return pane.primaryLabel
    }

    func setPaneDisplayTitleOverride(_ title: String?, for pane: AgtmuxPane) {
        let key = paneIdentityKey(for: pane)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            paneDisplayTitleOverrides.removeValue(forKey: key)
        } else {
            paneDisplayTitleOverrides[key] = trimmed
        }
    }

    private func paneIdentityKey(for pane: AgtmuxPane) -> String {
        "\(pane.source):\(pane.sessionName):\(pane.windowId):\(pane.paneId)"
    }

    // MARK: - Selection

    func selectPane(_ pane: AgtmuxPane) {
        selectedPane = pane
    }

    // MARK: - Session order (DnD)

    func moveSession(source: String, draggedSessionName: String, targetSessionName: String) {
        guard draggedSessionName != targetSessionName else { return }

        let currentNames = Set(
            panes
                .filter { $0.source == source }
                .map(\.sessionName)
        )
        var ordered = orderedSessionNames(source: source, currentNames: currentNames)
        guard
            let from = ordered.firstIndex(of: draggedSessionName),
            let to = ordered.firstIndex(of: targetSessionName),
            from != to
        else { return }

        let moving = ordered.remove(at: from)
        ordered.insert(moving, at: to)
        sessionOrderBySource[source] = ordered
    }

    // MARK: - Clients

    private let localClient: any LocalSnapshotClient
    private let localInventoryClient: any LocalPaneInventoryClient
    private var remoteClients: [RemoteTmuxClient] = []
    let hostsConfig: HostsConfig
    private var lastSuccessfulPanesBySource: [String: [AgtmuxPane]] = [:]
    private var lastSuccessfulLocalSessionAliasMap: [String: String] = [:]
    private var cachedLocalMetadataByPaneKey: [String: AgtmuxPane] = [:]
    private var localMetadataRefreshTask: Task<Void, Never>?
    private var nextLocalMetadataRefreshAt: Date = .distantPast
    private let localMetadataSuccessInterval: TimeInterval = 1.0
    private let localMetadataFailureBackoff: TimeInterval = 3.0

    private func logLocalFetch(_ message: String) {
        guard let data = "AgtmuxTerm local-fetch: \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    // MARK: - Init

    init(localClient: any LocalSnapshotClient = AgtmuxDaemonClient(),
         localInventoryClient: any LocalPaneInventoryClient = LocalTmuxInventoryClient(),
         hostsConfig: HostsConfig? = nil) {
        self.localClient = localClient
        self.localInventoryClient = localInventoryClient
        let config = hostsConfig ?? HostsConfig.load()
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
        localMetadataRefreshTask?.cancel()
        localMetadataRefreshTask = nil
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

    private func orderedSessionNames(source: String, currentNames: Set<String>) -> [String] {
        let existing = sessionOrderBySource[source] ?? []
        let kept = existing.filter { currentNames.contains($0) }
        let unknown = currentNames.subtracting(kept).sorted()
        return kept + unknown
    }

    private func reconcileSessionOrder(with panes: [AgtmuxPane]) {
        let bySource = Dictionary(grouping: panes, by: \.source)
        var updated: [String: [String]] = [:]

        for source in sortedSources(bySource.keys) {
            let names = Set((bySource[source] ?? []).map(\.sessionName))
            updated[source] = orderedSessionNames(source: source, currentNames: names)
        }
        sessionOrderBySource = updated
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

    private func paneMetadataKey(source: String, paneId: String) -> String {
        "\(source):\(paneId)"
    }

    private func localMetadataMap(from metadata: [AgtmuxPane]) -> [String: AgtmuxPane] {
        let grouped = Dictionary(grouping: metadata.filter { $0.source == "local" }) {
            paneMetadataKey(source: $0.source, paneId: $0.paneId)
        }
        return grouped.mapValues { panes in
            panes.reduce(panes[0]) { preferredPane($0, $1) }
        }
    }

    /// Merge local tmux inventory with daemon metadata.
    ///
    /// Inventory (tmux list-panes) is authoritative for pane existence.
    /// Metadata (agtmux json) enriches rows (managed status/activity/provider/etc.)
    /// but does not create new rows if the pane is absent from inventory.
    private func mergeLocalInventory(
        inventory: [AgtmuxPane],
        metadataByPaneKey: [String: AgtmuxPane]
    ) -> [AgtmuxPane] {
        return inventory.map { inventoryPane in
            let key = paneMetadataKey(source: inventoryPane.source, paneId: inventoryPane.paneId)
            guard let metadataPane = metadataByPaneKey[key] else { return inventoryPane }
            return AgtmuxPane(
                source: inventoryPane.source,
                paneId: inventoryPane.paneId,
                sessionName: inventoryPane.sessionName,
                sessionGroup: inventoryPane.sessionGroup ?? metadataPane.sessionGroup,
                windowId: inventoryPane.windowId,
                windowIndex: inventoryPane.windowIndex ?? metadataPane.windowIndex,
                windowName: inventoryPane.windowName ?? metadataPane.windowName,
                activityState: metadataPane.activityState,
                presence: metadataPane.presence,
                provider: metadataPane.provider,
                evidenceMode: metadataPane.evidenceMode,
                conversationTitle: metadataPane.conversationTitle,
                currentPath: metadataPane.currentPath ?? inventoryPane.currentPath,
                gitBranch: metadataPane.gitBranch,
                currentCmd: metadataPane.currentCmd ?? inventoryPane.currentCmd,
                updatedAt: metadataPane.updatedAt,
                ageSecs: metadataPane.ageSecs
            )
        }
    }

    private func scheduleLocalMetadataRefreshIfNeeded() {
        guard localMetadataRefreshTask == nil else { return }
        let now = Date()
        guard now >= nextLocalMetadataRefreshAt else { return }

        localMetadataRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localMetadataRefreshTask = nil }

            do {
                let snapshot = try await self.localClient.fetchSnapshot()
                let metadataByPaneKey = self.localMetadataMap(from: snapshot.panes)
                self.cachedLocalMetadataByPaneKey = metadataByPaneKey
                self.nextLocalMetadataRefreshAt = Date().addingTimeInterval(self.localMetadataSuccessInterval)

                if let localPanes = self.lastSuccessfulPanesBySource["local"] {
                    self.lastSuccessfulPanesBySource["local"] = self.mergeLocalInventory(
                        inventory: localPanes,
                        metadataByPaneKey: metadataByPaneKey
                    )
                    await self.publishFromSnapshotCache()
                }
            } catch {
                self.nextLocalMetadataRefreshAt = Date().addingTimeInterval(self.localMetadataFailureBackoff)
                self.logLocalFetch("metadata unavailable; keeping cached overlay: \(error)")
            }
        }
    }

    private func fetchLocalPanes() async throws -> [AgtmuxPane] {
        let env = ProcessInfo.processInfo.environment

        // Fixture mode for deterministic UI tests. Keep the current AGTMUX_JSON-only behavior.
        if env["AGTMUX_JSON"] != nil {
            let snapshot = try await localClient.fetchSnapshot()
            return snapshot.panes
        }

        // Live UI tests exercise tmux inventory lifecycle/selection behavior.
        // Running `agtmux json` here can block app responsiveness under XCUITest
        // (metadata collection may require host capabilities not available to tests).
        if env["AGTMUX_UITEST"] == "1", env["AGTMUX_UITEST_INVENTORY_ONLY"] == "1" {
            return try await localInventoryClient.fetchPanes()
        }

        let inventory = try await localInventoryClient.fetchPanes()
        scheduleLocalMetadataRefreshIfNeeded()
        return mergeLocalInventory(inventory: inventory, metadataByPaneKey: cachedLocalMetadataByPaneKey)
    }

    private func knownSources() -> Set<String> {
        Set(["local"] + remoteClients.map(\.host.hostname))
    }

    private func trimSnapshotCacheToKnownSources() {
        let known = knownSources()
        lastSuccessfulPanesBySource = lastSuccessfulPanesBySource.filter { known.contains($0.key) }
    }

    private func retainSelection(in normalized: [AgtmuxPane]) {
        guard let currentSelectedPane = selectedPane else { return }
        selectedPane = normalized.first {
            $0.source == currentSelectedPane.source
                && $0.paneId == currentSelectedPane.paneId
                && $0.windowId == currentSelectedPane.windowId
        }
    }

    private func publishFromSnapshotCache(offlineHosts newOffline: Set<String>? = nil) async {
        trimSnapshotCacheToKnownSources()
        let merged = sortedSources(lastSuccessfulPanesBySource.keys)
            .flatMap { lastSuccessfulPanesBySource[$0] ?? [] }
        let normalized = await normalizePanes(merged)
        reconcileSessionOrder(with: normalized)
        panes = normalized
        let livePaneKeys = Set(normalized.map(paneIdentityKey(for:)))
        pinnedPaneKeys = pinnedPaneKeys.intersection(livePaneKeys)
        paneDisplayTitleOverrides = paneDisplayTitleOverrides.filter { livePaneKeys.contains($0.key) }
        retainSelection(in: normalized)
        if let newOffline {
            offlineHosts = newOffline
        }
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
                    let panes = try await self.fetchLocalPanes()
                    return ("local", panes, false)
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
        await publishFromSnapshotCache(offlineHosts: newOffline)
    }
}
