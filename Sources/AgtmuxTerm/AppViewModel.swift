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

enum LocalDaemonIssue: Equatable {
    case localDaemonUnavailable(detail: String)
    case incompatibleSyncV2(detail: String)

    var bannerTitle: String {
        switch self {
        case .localDaemonUnavailable:
            return "Local daemon unavailable"
        case .incompatibleSyncV2:
            return "Local daemon incompatible"
        }
    }

    var bannerMessage: String {
        switch self {
        case .localDaemonUnavailable:
            return "No local agtmux daemon runtime is configured. Pane rows below are from local tmux inventory only. Use the bundled app runtime or set AGTMUX_BIN."
        case .incompatibleSyncV2:
            return "This agtmux daemon is too old for sync-v2 metadata. Pane rows below are from local tmux inventory only. Restart with a newer daemon."
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .localDaemonUnavailable:
            return "Local agtmux daemon runtime is unavailable. Use the bundled app runtime or set AGTMUX_BIN."
        case .incompatibleSyncV2:
            return "This agtmux daemon is too old for sync-v2 metadata. Restart with a newer daemon."
        }
    }

    var detail: String {
        switch self {
        case let .localDaemonUnavailable(detail):
            return detail
        case let .incompatibleSyncV2(detail):
            return detail
        }
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
    @Published private(set) var localDaemonIssue: LocalDaemonIssue?
    @Published private(set) var localDaemonHealth: AgtmuxUIHealthV1?

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

    private let localClient: any LocalMetadataClient
    private let localHealthClient: (any LocalHealthClient)?
    private let localInventoryClient: any LocalPaneInventoryClient
    private var remoteClients: [RemoteTmuxClient] = []
    let hostsConfig: HostsConfig
    private var lastSuccessfulPanesBySource: [String: [AgtmuxPane]] = [:]
    private var lastSuccessfulLocalSessionAliasMap: [String: String] = [:]
    private var cachedLocalMetadataByPaneKey: [String: AgtmuxPane] = [:]
    private var localMetadataRefreshTask: Task<Void, Never>?
    private var localHealthRefreshTask: Task<Void, Never>?
    private var localMetadataSyncPrimed = false
    private var nextLocalMetadataRefreshAt: Date = .distantPast
    private var nextLocalHealthRefreshAt: Date = .distantPast
    private let localMetadataSuccessInterval: TimeInterval = 1.0
    private let localMetadataFailureBackoff: TimeInterval = 3.0
    private let localMetadataChangeLimit = 256
    private let localHealthSuccessInterval: TimeInterval = 1.0
    private let localHealthFailureBackoff: TimeInterval = 3.0
    private let localHealthUnsupportedBackoff: TimeInterval = 60.0

    private enum LocalHealthRefreshDisposition {
        case unsupportedMethod
        case transientFailure
    }

    private func logLocalFetch(_ message: String) {
        guard let data = "AgtmuxTerm local-fetch: \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private func classifyLocalDaemonIssue(from error: any Error) -> LocalDaemonIssue? {
        if let daemonError = error as? DaemonError {
            switch daemonError {
            case .daemonUnavailable:
                return makeLocalDaemonUnavailableIssue()
            case let .processError(_, stderr):
                return classifyLocalDaemonIssue(fromDescription: stderr)
            case let .parseError(message):
                return classifyLocalDaemonIssue(fromDescription: message)
            }
        }

        if let xpcError = error as? XPCClientError {
            switch xpcError {
            case .unavailable, .proxyUnavailable, .timeout(_):
                return nil
            case let .remote(message), let .decode(message):
                return classifyLocalDaemonIssue(fromDescription: message)
            }
        }

        return classifyLocalDaemonIssue(fromDescription: String(describing: error))
    }

    private func classifyLocalDaemonIssue(fromDescription description: String) -> LocalDaemonIssue? {
        let normalized = description.lowercased()
        if normalized.contains("agtmux daemon unavailable") {
            return makeLocalDaemonUnavailableIssue(detail: description)
        }

        let referencesSyncV2Method =
            normalized.contains("ui.bootstrap.v2") ||
            normalized.contains("ui.changes.v2")
        let indicatesMissingMethod =
            normalized.contains("-32601") ||
            normalized.contains("method not found")

        guard referencesSyncV2Method, indicatesMissingMethod else { return nil }
        return .incompatibleSyncV2(detail: description)
    }

    private func makeLocalDaemonUnavailableIssue(detail: String? = nil) -> LocalDaemonIssue {
        let env = ProcessInfo.processInfo.environment
        let explicitBinary = env["AGTMUX_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackDetail: String
        if explicitBinary.isEmpty {
            fallbackDetail = """
            Local agtmux daemon runtime is unavailable: no bundled daemon was found and AGTMUX_BIN is not set. The managed socket is \(AgtmuxBinaryResolver.defaultSocketPath).
            """
        } else {
            fallbackDetail = """
            Local agtmux daemon runtime is unavailable: AGTMUX_BIN is set to \(explicitBinary), but no executable daemon runtime could be resolved for the managed socket \(AgtmuxBinaryResolver.defaultSocketPath).
            """
        }

        let resolvedDetail = detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedDetail, !resolvedDetail.isEmpty,
           resolvedDetail.lowercased() != "agtmux daemon unavailable" {
            return .localDaemonUnavailable(detail: resolvedDetail)
        }
        return .localDaemonUnavailable(detail: fallbackDetail)
    }

    private func localHealthErrorDescription(from error: any Error) -> String {
        if let healthError = error as? LocalHealthClientError {
            switch healthError {
            case let .unsupportedMethod(method):
                return "\(method) unsupported"
            }
        }

        if let daemonError = error as? DaemonError {
            switch daemonError {
            case .daemonUnavailable:
                return daemonError.localizedDescription
            case let .processError(_, stderr):
                return stderr
            case let .parseError(message):
                return message
            }
        }

        if let xpcError = error as? XPCClientError {
            switch xpcError {
            case .unavailable:
                return "xpc unavailable"
            case .proxyUnavailable:
                return "xpc proxy unavailable"
            case let .remote(message), let .decode(message), let .timeout(message):
                return message
            }
        }

        return String(describing: error)
    }

    private func localHealthUIErrorEnvelope(from error: any Error) -> DaemonUIErrorEnvelope? {
        if let daemonError = error as? DaemonError {
            switch daemonError {
            case .daemonUnavailable:
                return nil
            case let .processError(_, stderr):
                return DaemonError.decodeUIErrorEnvelope(from: stderr)
            case let .parseError(message):
                return DaemonError.decodeUIErrorEnvelope(from: message)
            }
        }

        if let xpcError = error as? XPCClientError {
            switch xpcError {
            case .unavailable, .proxyUnavailable:
                return nil
            case let .remote(message), let .decode(message), let .timeout(message):
                return DaemonError.decodeUIErrorEnvelope(from: message)
            }
        }

        return DaemonError.decodeUIErrorEnvelope(from: String(describing: error))
    }

    private func classifyLocalHealthRefreshFailure(from error: any Error) -> LocalHealthRefreshDisposition {
        if let healthError = error as? LocalHealthClientError {
            switch healthError {
            case .unsupportedMethod:
                return .unsupportedMethod
            }
        }

        if let envelope = localHealthUIErrorEnvelope(from: error) {
            if envelope.code == DaemonUIErrorCode.uiHealthMethodNotFound.rawValue {
                return .unsupportedMethod
            }
            return .transientFailure
        }

        let normalized = localHealthErrorDescription(from: error).lowercased()
        let referencesHealthMethod = normalized.contains("ui.health.v1")
        let indicatesMissingMethod =
            normalized.contains("-32601") ||
            normalized.contains("method not found") ||
            normalized.contains("unsupported")

        if referencesHealthMethod && indicatesMissingMethod {
            return .unsupportedMethod
        }
        return .transientFailure
    }

    // MARK: - Init

    init(localClient: any LocalMetadataClient = AgtmuxDaemonClient(),
         localInventoryClient: any LocalPaneInventoryClient = LocalTmuxInventoryClient(),
         hostsConfig: HostsConfig? = nil) {
        self.localClient = localClient
        self.localHealthClient = localClient as? any LocalHealthClient
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
        localHealthRefreshTask?.cancel()
        localHealthRefreshTask = nil
        localMetadataSyncPrimed = false
        nextLocalHealthRefreshAt = .distantPast
        Task { await localClient.resetUIChangesV2() }
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

    /// Merge local tmux inventory with daemon metadata overlay.
    ///
    /// Inventory (tmux list-panes) is authoritative for pane existence.
    /// Daemon metadata enriches rows (managed status/activity/provider/etc.)
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

    private func overlayLocalMetadata(_ paneState: AgtmuxSyncV2PaneState, onto basePane: AgtmuxPane) -> AgtmuxPane {
        AgtmuxPane(
            source: basePane.source,
            paneId: basePane.paneId,
            sessionName: basePane.sessionName,
            sessionGroup: basePane.sessionGroup,
            windowId: basePane.windowId,
            windowIndex: basePane.windowIndex,
            windowName: basePane.windowName,
            activityState: paneState.activityState,
            presence: paneState.presence,
            provider: paneState.provider,
            evidenceMode: paneState.evidenceMode,
            conversationTitle: basePane.conversationTitle,
            currentPath: basePane.currentPath,
            gitBranch: basePane.gitBranch,
            currentCmd: basePane.currentCmd,
            updatedAt: paneState.updatedAt,
            ageSecs: basePane.ageSecs
        )
    }

    private func metadataBasePane(for paneId: String) -> AgtmuxPane? {
        let key = paneMetadataKey(source: "local", paneId: paneId)
        if let cached = cachedLocalMetadataByPaneKey[key] {
            return cached
        }

        return lastSuccessfulPanesBySource["local"]?.first { pane in
            pane.source == "local" && pane.paneId == paneId
        }
    }

    private func applyLocalMetadataChanges(_ payload: AgtmuxSyncV2Changes) -> [String: AgtmuxPane] {
        var metadataByPaneKey = cachedLocalMetadataByPaneKey

        for change in payload.changes {
            guard let paneState = change.pane else { continue }
            let key = paneMetadataKey(source: "local", paneId: paneState.paneId)
            guard let basePane = metadataBasePane(for: paneState.paneId) else {
                logLocalFetch("sync-v2 pane change dropped for unknown pane_id \(paneState.paneId)")
                continue
            }
            metadataByPaneKey[key] = overlayLocalMetadata(paneState, onto: basePane)
        }

        return metadataByPaneKey
    }

    private func publishLocalMetadataCache(_ metadataByPaneKey: [String: AgtmuxPane]) async {
        cachedLocalMetadataByPaneKey = metadataByPaneKey
        nextLocalMetadataRefreshAt = Date().addingTimeInterval(localMetadataSuccessInterval)

        if let localPanes = lastSuccessfulPanesBySource["local"] {
            lastSuccessfulPanesBySource["local"] = mergeLocalInventory(
                inventory: localPanes,
                metadataByPaneKey: metadataByPaneKey
            )
            await publishFromSnapshotCache()
        }
    }

    private func scheduleLocalHealthRefreshIfNeeded() {
        guard let localHealthClient else { return }
        guard localHealthRefreshTask == nil else { return }
        let now = Date()
        guard now >= nextLocalHealthRefreshAt else { return }

        localHealthRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.localHealthRefreshTask = nil }

            do {
                let health = try await localHealthClient.fetchUIHealthV1()
                try Task.checkCancellation()
                self.localDaemonHealth = health
                self.nextLocalHealthRefreshAt = Date().addingTimeInterval(self.localHealthSuccessInterval)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                switch self.classifyLocalHealthRefreshFailure(from: error) {
                case .unsupportedMethod:
                    self.localDaemonHealth = nil
                    self.nextLocalHealthRefreshAt = Date().addingTimeInterval(self.localHealthUnsupportedBackoff)
                case .transientFailure:
                    self.nextLocalHealthRefreshAt = Date().addingTimeInterval(self.localHealthFailureBackoff)
                }
            }
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
                if !self.localMetadataSyncPrimed {
                    let bootstrap = try await self.localClient.fetchUIBootstrapV2()
                    try Task.checkCancellation()
                    let metadataByPaneKey = self.localMetadataMap(from: bootstrap.panes)
                    self.localMetadataSyncPrimed = true
                    self.localDaemonIssue = nil
                    await self.publishLocalMetadataCache(metadataByPaneKey)
                    return
                }

                let response = try await self.localClient.fetchUIChangesV2(limit: self.localMetadataChangeLimit)
                try Task.checkCancellation()
                switch response {
                case let .changes(payload):
                    let metadataByPaneKey = self.applyLocalMetadataChanges(payload)
                    self.localDaemonIssue = nil
                    await self.publishLocalMetadataCache(metadataByPaneKey)
                case let .resyncRequired(payload):
                    self.logLocalFetch(
                        "sync-v2 resync required; reason=\(payload.reason) epoch=\(payload.currentEpoch) snapshot_seq=\(payload.latestSnapshotSeq)"
                    )
                    await self.localClient.resetUIChangesV2()
                    let bootstrap = try await self.localClient.fetchUIBootstrapV2()
                    try Task.checkCancellation()
                    let metadataByPaneKey = self.localMetadataMap(from: bootstrap.panes)
                    self.localMetadataSyncPrimed = true
                    self.localDaemonIssue = nil
                    await self.publishLocalMetadataCache(metadataByPaneKey)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                await self.localClient.resetUIChangesV2()
                if Task.isCancelled {
                    return
                }
                self.localMetadataSyncPrimed = false
                self.nextLocalMetadataRefreshAt = Date().addingTimeInterval(self.localMetadataFailureBackoff)
                self.localDaemonIssue = self.classifyLocalDaemonIssue(from: error)
                self.logLocalFetch("sync-v2 metadata unavailable; keeping cached overlay: \(error)")
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

        scheduleLocalHealthRefreshIfNeeded()
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
        if newOffline.contains("local") {
            localMetadataRefreshTask?.cancel()
            localMetadataRefreshTask = nil
            localMetadataSyncPrimed = false
            localDaemonIssue = nil
            await localClient.resetUIChangesV2()
        }
        await publishFromSnapshotCache(offlineHosts: newOffline)
    }
}
