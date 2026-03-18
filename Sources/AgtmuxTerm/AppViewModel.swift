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
    case incompatibleMetadataProtocol(detail: String)

    var bannerTitle: String {
        switch self {
        case .localDaemonUnavailable:
            return "Local daemon unavailable"
        case .incompatibleMetadataProtocol:
            return "Local metadata incompatible"
        }
    }

    var bannerMessage: String {
        switch self {
        case .localDaemonUnavailable:
            return "No local agtmux daemon runtime is configured. Pane rows below are from local tmux inventory only. Use the bundled app runtime or set AGTMUX_BIN."
        case .incompatibleMetadataProtocol:
            return "This agtmux daemon is incompatible with the current sync-v3 metadata protocol. Pane rows below are from local tmux inventory only. Restart with a newer daemon."
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .localDaemonUnavailable:
            return "Local agtmux daemon runtime is unavailable. Use the bundled app runtime or set AGTMUX_BIN."
        case .incompatibleMetadataProtocol:
            return "This agtmux daemon is incompatible with the current sync-v3 metadata protocol. Restart with a newer daemon."
        }
    }

    var detail: String {
        switch self {
        case let .localDaemonUnavailable(detail):
            return detail
        case let .incompatibleMetadataProtocol(detail):
            return detail
        }
    }
}

public enum HookSetupStatus: Equatable, Sendable {
    case unknown
    case checking
    case registered
    case missing
    case unavailable
}

struct RemotePaneInventorySource {
    let source: String
    let fetchPanes: @Sendable () async throws -> [AgtmuxPane]
}

// MARK: - AppViewModel

/// Central state holder for the agtmux-term UI.
///
/// Performs explicit local inventory refreshes and runs a 1-second remote broad poll.
/// Local steady-state metadata/health are owned by `LocalProjectionCoordinator`.
/// Remote hosts are discovered via SSH + `tmux list-panes` — no agtmux required on remote.
///
/// T-PERF-P12 (Phase C): @Published storage has been replaced with computed forwarders
/// that delegate to the sub-stores. The stores are the source of truth; AppViewModel's
/// objectWillChange fires only for selectedPane and autoLaunchSessionName.
///
/// Sub-stores:
///   - sidebarStore (SidebarInventoryStore): panes, filters, pinned, panesBySession
///   - runtimeStore (TerminalRuntimeStore): hostsConfig, offlineHosts, hasCompletedInitialFetch, livePaneSessionKeys
///   - healthStore (HealthAndHooksStore): hookSetupStatus, localDaemonHealth, localDaemonIssue
@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Sub-stores (T-PERF-P12: stores are the source of truth for migrated properties)
    let sidebarStore = SidebarInventoryStore()
    let runtimeStore = TerminalRuntimeStore()
    let healthStore = HealthAndHooksStore()

    // MARK: - Computed forwarders → SidebarInventoryStore

    var panes: [AgtmuxPane] {
        get { sidebarStore.panes }
        set { sidebarStore.panes = newValue }
    }

    var statusFilter: StatusFilter {
        get { sidebarStore.statusFilter }
        set {
            sidebarStore.statusFilter = newValue
            triggerPanesBySessionRecompute()
        }
    }

    var showAgentsOnly: Bool {
        get { sidebarStore.showAgentsOnly }
        set {
            sidebarStore.showAgentsOnly = newValue
            triggerPanesBySessionRecompute()
        }
    }

    var showPinnedOnly: Bool {
        get { sidebarStore.showPinnedOnly }
        set {
            sidebarStore.showPinnedOnly = newValue
            triggerPanesBySessionRecompute()
        }
    }

    private(set) var pinnedPaneKeys: Set<String> {
        get { sidebarStore.pinnedPaneKeys }
        set { sidebarStore.pinnedPaneKeys = newValue }
    }

    private(set) var paneDisplayTitleOverrides: [String: String] {
        get { sidebarStore.paneDisplayTitleOverrides }
        set { sidebarStore.paneDisplayTitleOverrides = newValue }
    }

    private(set) var sessionOrderBySource: [String: [String]] {
        get { sidebarStore.sessionOrderBySource }
        set { sidebarStore.sessionOrderBySource = newValue }
    }

    private(set) var panesBySession: [(source: String, sessions: [SessionGroup])] {
        get { sidebarStore.panesBySession }
        set { sidebarStore.panesBySession = newValue }
    }

    // MARK: - Computed forwarders → TerminalRuntimeStore

    /// Set of source identifiers that are currently unreachable ("local" or hostname).
    var offlineHosts: Set<String> {
        get { runtimeStore.offlineHosts }
        set { runtimeStore.offlineHosts = newValue }
    }

    private(set) var hasCompletedInitialFetch: Bool {
        get { runtimeStore.hasCompletedInitialFetch }
        set { runtimeStore.hasCompletedInitialFetch = newValue }
    }

    private(set) var livePaneSessionKeys: Set<String> {
        get { runtimeStore.livePaneSessionKeys }
        set { runtimeStore.livePaneSessionKeys = newValue }
    }

    // MARK: - Computed forwarders → HealthAndHooksStore

    private(set) var localDaemonIssue: LocalDaemonIssue? {
        get { healthStore.localDaemonIssue }
        set { healthStore.localDaemonIssue = newValue }
    }

    private(set) var localDaemonHealth: AgtmuxUIHealthV1? {
        get { healthStore.localDaemonHealth }
        set { healthStore.localDaemonHealth = newValue }
    }

    private(set) var hookSetupStatus: HookSetupStatus {
        get { healthStore.hookSetupStatus }
        set { healthStore.hookSetupStatus = newValue }
    }

    // MARK: - Remaining @Published properties (no store mirror)
    @Published var selectedPane: AgtmuxPane?
    @Published var autoLaunchSessionName: String {
        didSet { UserDefaults.standard.set(autoLaunchSessionName, forKey: "autoLaunchSessionName") }
    }

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

    /// Compute panes grouped by source → session → window.
    ///
    /// `static` so it can be called off the main actor.
    /// Within each source, sessions follow user-managed order (DnD) when present,
    /// then append unknown sessions alphabetically.
    /// Within each session, windows are sorted by windowIndex (if available), else by windowId.
    /// Within each window, panes are sorted by paneId.
    private nonisolated static func computePanesBySession(
        filteredPanes: [AgtmuxPane],
        sessionOrderBySource: [String: [String]],
        sortedSources: ([String]) -> [String]
    ) -> [(source: String, sessions: [SessionGroup])] {
        let bySource = Dictionary(grouping: filteredPanes, by: \.source)
        return sortedSources(Array(bySource.keys)).map { source in
            let sourcePanes = bySource[source] ?? []
            let bySession = Dictionary(grouping: sourcePanes, by: \.sessionName)
            let currentNames = Set(bySession.keys)
            let existing = sessionOrderBySource[source] ?? []
            let kept = existing.filter { currentNames.contains($0) }
            let unknown = currentNames.subtracting(kept).sorted()
            let orderedNames = kept + unknown
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

    struct PublishSnapshotAssemblyInput: Sendable {
        let generation: UInt64
        let sideInputGeneration: UInt64
        let localInventory: [AgtmuxPane]
        let localMetadataByPaneKey: [String: AgtmuxPane]
        let localPresentationByPaneKey: [String: PanePresentationState]
        let remotePanesBySource: [String: [AgtmuxPane]]
        let pinnedPaneKeys: Set<String>
        let paneDisplayTitleOverrides: [String: String]
        let sessionOrderBySource: [String: [String]]
    }

    struct PublishSnapshotAssembly: Sendable {
        let generation: UInt64
        let sideInputGeneration: UInt64
        let panes: [AgtmuxPane]
        let reconciledSessionOrderBySource: [String: [String]]
        let livePaneKeys: Set<String>
        let livePaneSessionKeys: Set<String>
        let prunedPinnedPaneKeys: Set<String>
        let prunedPaneDisplayTitleOverrides: [String: String]
        let attentionCount: Int
        let paneIdentityIndex: [String: AgtmuxSyncV2PaneInstanceID]
    }

    typealias PublishSnapshotAssembler = @Sendable (PublishSnapshotAssemblyInput) async -> PublishSnapshotAssembly

    /// Schedule an off-main recomputation of `panesBySession` from the current
    /// `filteredPanes` and `sessionOrderBySource`.
    private func triggerPanesBySessionRecompute() {
        panesBySessionGeneration &+= 1
        let generation = panesBySessionGeneration
        let snapshot = filteredPanes
        let orderSnapshot = sessionOrderBySource
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let computed = Self.computePanesBySession(
                filteredPanes: snapshot,
                sessionOrderBySource: orderSnapshot,
                sortedSources: { keys in
                    keys.sorted { a, b in
                        if a == "local" { return true }
                        if b == "local" { return false }
                        return a < b
                    }
                }
            )
            await MainActor.run {
                guard self.panesBySessionGeneration == generation else { return }
                self.syncPanesBySession(computed)
            }
        }
    }

    /// Count of panes currently needing attention (across all sources, unfiltered).
    var attentionCount: Int { panes.filter { paneNeedsAttention($0) }.count }

    // MARK: - Filtered panes

    var filteredPanes: [AgtmuxPane] {
        var visible = panes
        if showAgentsOnly { visible = visible.filter { paneIsManaged($0) } }
        if showPinnedOnly { visible = visible.filter { isPanePinned($0) } }
        switch statusFilter {
        case .all:       return visible
        case .managed:   return visible.filter { paneIsManaged($0) }
        case .attention: return visible.filter { paneNeedsAttention($0) }
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
        var updated = pinnedPaneKeys
        if pinned {
            updated.insert(key)
        } else {
            updated.remove(key)
        }
        guard updated != pinnedPaneKeys else { return }
        publishSideInputGeneration &+= 1
        syncPinnedPaneKeys(updated)
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

    func paneDisplaySubtitle(for pane: AgtmuxPane) -> String? {
        guard pane.presence == .managed else { return nil }
        return pane.sessionSubtitle
    }

    func setPaneDisplayTitleOverride(_ title: String?, for pane: AgtmuxPane) {
        let key = paneIdentityKey(for: pane)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var updated = paneDisplayTitleOverrides
        if trimmed.isEmpty {
            updated.removeValue(forKey: key)
        } else {
            updated[key] = trimmed
        }
        guard updated != paneDisplayTitleOverrides else { return }
        publishSideInputGeneration &+= 1
        syncPaneDisplayTitleOverrides(updated)
    }

    private func paneIdentityKey(for pane: AgtmuxPane) -> String {
        Self.paneIdentityKey(for: pane)
    }

    func hasSamePaneIdentity(_ lhs: AgtmuxPane, _ rhs: AgtmuxPane) -> Bool {
        paneIdentityKey(for: lhs) == paneIdentityKey(for: rhs)
    }

    func panePresentation(for pane: AgtmuxPane) -> PanePresentationState? {
        Self.panePresentation(
            for: pane,
            presentationByPaneKey: cachedLocalPresentationByPaneKey
        )
    }

    func paneDisplayState(for pane: AgtmuxPane) -> PaneDisplayState {
        PaneDisplayState(pane: pane, presentation: panePresentation(for: pane))
    }

    func panePrimaryState(for pane: AgtmuxPane) -> PanePresentationPrimaryState {
        paneDisplayState(for: pane).primaryState
    }

    func paneIsManaged(_ pane: AgtmuxPane) -> Bool {
        paneDisplayState(for: pane).isManaged
    }

    func paneNeedsAttention(_ pane: AgtmuxPane) -> Bool {
        Self.paneNeedsAttention(
            pane,
            presentationByPaneKey: cachedLocalPresentationByPaneKey
        )
    }

    func paneProviderForSidebar(_ pane: AgtmuxPane) -> Provider? {
        paneDisplayState(for: pane).provider
    }

    func paneFreshnessText(for pane: AgtmuxPane) -> String? {
        paneDisplayState(for: pane).freshnessText
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
        publishSideInputGeneration &+= 1
        syncSessionOrderBySource(sessionOrderBySource.merging([source: ordered]) { _, new in new })
        triggerPanesBySessionRecompute()
    }

    // MARK: - Clients

    private let localClient: any ProductLocalMetadataClient
    private let localHealthClient: (any LocalHealthClient)?
    private let localInventoryClient: any LocalPaneInventoryClient
    private let localInventoryAuthority: any LocalPaneInventoryAuthorityProtocol
    private var remotePaneSources: [RemotePaneInventorySource] = []
    var hostsConfig: HostsConfig {
        get { runtimeStore.hostsConfig }
        set { runtimeStore.hostsConfig = newValue }
    }
    private var lastSuccessfulRemotePanesBySource: [String: [AgtmuxPane]] = [:]
    private var lastSuccessfulLocalInventory: [AgtmuxPane] = []
    private var hasFetchedLocalInventory = false
    private var cachedLocalMetadataByPaneKey: [String: AgtmuxPane] = [:]
    private var cachedLocalPresentationByPaneKey: [String: PanePresentationState] = [:]
    private var hasAttemptedAutoLaunch = false
    private var panesBySessionGeneration = 0
    private var publishGeneration: UInt64 = 0
    private var publishSideInputGeneration: UInt64 = 0
    private var localMetadataSyncPrimed = false
    private var localMetadataTransportVersion: LocalMetadataTransportVersion?
    private var localMetadataUseLongPoll: Bool? = nil  // nil=unknown, optimistically try on first call
    private var localMetadataTransportBridge = LocalMetadataTransportBridge()
    private var uiTestMetadataModeEnabled = false
    private var nextLocalMetadataRefreshAt: Date = .distantPast
    private var nextLocalHealthRefreshAt: Date = .distantPast
    private let localMetadataSuccessInterval: TimeInterval = 1.0
    private let localMetadataFailureBackoff: TimeInterval = 3.0
    private let localMetadataBootstrapNotReadyBackoff: TimeInterval = 0.5
    private let localMetadataChangeLimit = 256
    private let localHealthSuccessInterval: TimeInterval = 1.0
    private let localHealthFailureBackoff: TimeInterval = 3.0
    private let localHealthUnsupportedBackoff: TimeInterval = 60.0
    private let binaryURLResolver: () -> URL?
    private let publishSnapshotAssembler: PublishSnapshotAssembler
    private let pollingInterval: TimeInterval
    private let localInventoryPollingInterval: TimeInterval
    private lazy var localProjectionCoordinator = LocalProjectionCoordinator(
        localClient: localClient,
        localHealthClient: localHealthClient,
        localInventoryClient: localInventoryClient,
        transportBridge: localMetadataTransportBridge
    )

    private func logLocalFetch(_ message: String) {
        guard let data = "AgtmuxTerm local-fetch: \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private func classifyLocalDaemonIssue(from error: any Error) -> LocalDaemonIssue? {
        if let overlayError = error as? LocalMetadataOverlayError {
            return .incompatibleMetadataProtocol(
                detail: normalizedMetadataProtocolDetail(
                    overlayError.errorDescription ?? String(describing: overlayError)
                )
            )
        }

        if let metadataError = error as? LocalMetadataClientError {
            switch metadataError {
            case let .unsupportedMethod(method):
                return .incompatibleMetadataProtocol(
                    detail: "agtmux daemon does not expose required sync metadata RPC method \(method)"
                )
            }
        }

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

        let referencesMetadataProtocol =
            normalized.contains("ui.bootstrap.v2") ||
            normalized.contains("ui.changes.v2") ||
            normalized.contains("agtmux_ui_bootstrap_v2_json") ||
            normalized.contains("agtmux_ui_changes_v2_json") ||
            normalized.contains("ui.bootstrap.v3") ||
            normalized.contains("ui.changes.v3") ||
            normalized.contains("agtmux_ui_bootstrap_v3_json") ||
            normalized.contains("agtmux_ui_changes_v3_json") ||
            normalized.contains("sync-v2 bootstrap") ||
            normalized.contains("sync-v2 pane") ||
            normalized.contains("sync-v3 bootstrap") ||
            normalized.contains("sync-v3 pane")
        let indicatesIncompatibleMethod =
            normalized.contains("-32601") ||
            normalized.contains("method not found")
        let indicatesMissingExactIdentity =
            normalized.contains("missing required exact identity field") ||
            normalized.contains("legacy identity field") ||
            normalized.contains("session_id") ||
            normalized.contains("session_key") ||
            normalized.contains("pane_instance_id") ||
            normalized.contains("session_name") ||
            normalized.contains("window_id") ||
            normalized.contains("ambiguous exact pane location") ||
            normalized.contains("ambiguous exact pane") ||
            normalized.contains("mismatched pane instance") ||
            normalized.contains("unknown exact pane")

        guard referencesMetadataProtocol, indicatesIncompatibleMethod || indicatesMissingExactIdentity else {
            return nil
        }
        return .incompatibleMetadataProtocol(detail: normalizedMetadataProtocolDetail(description))
    }

    private func normalizedMetadataProtocolDetail(_ description: String) -> String {
        var detail = description

        let replacements: [(String, String)] = [
            ("RPC ui.bootstrap.v2 parse failed:", "Local metadata protocol parse failed (ui.bootstrap.v2):"),
            ("RPC ui.changes.v2 parse failed:", "Local metadata protocol parse failed (ui.changes.v2):"),
            ("RPC ui.bootstrap.v3 parse failed:", "Local metadata protocol parse failed (ui.bootstrap.v3):"),
            ("RPC ui.changes.v3 parse failed:", "Local metadata protocol parse failed (ui.changes.v3):"),
            ("AGTMUX_UI_BOOTSTRAP_V2_JSON parse failed:", "Local metadata protocol parse failed (AGTMUX_UI_BOOTSTRAP_V2_JSON):"),
            ("AGTMUX_UI_CHANGES_V2_JSON parse failed:", "Local metadata protocol parse failed (AGTMUX_UI_CHANGES_V2_JSON):"),
            ("AGTMUX_UI_BOOTSTRAP_V3_JSON parse failed:", "Local metadata protocol parse failed (AGTMUX_UI_BOOTSTRAP_V3_JSON):"),
            ("AGTMUX_UI_CHANGES_V3_JSON parse failed:", "Local metadata protocol parse failed (AGTMUX_UI_CHANGES_V3_JSON):"),
            ("sync-v2 bootstrap", "metadata bootstrap"),
            ("sync-v2 pane", "metadata pane"),
            ("sync-v3 bootstrap", "metadata bootstrap"),
            ("sync-v3 pane", "metadata pane"),
        ]

        for (needle, replacement) in replacements {
            detail = detail.replacingOccurrences(of: needle, with: replacement)
        }

        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeLocalDaemonUnavailableIssue(detail: String? = nil) -> LocalDaemonIssue {
        let env = ProcessInfo.processInfo.environment
        let managedSocketPath = AgtmuxBinaryResolver.resolvedSocketPath(from: env)
        let explicitBinary = env["AGTMUX_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackDetail: String
        if explicitBinary.isEmpty {
            fallbackDetail = """
            Local agtmux daemon runtime is unavailable: no bundled daemon was found and AGTMUX_BIN is not set. The managed socket is \(managedSocketPath).
            """
        } else {
            fallbackDetail = """
            Local agtmux daemon runtime is unavailable: AGTMUX_BIN is set to \(explicitBinary), but no executable daemon runtime could be resolved for the managed socket \(managedSocketPath).
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

    // MARK: - Store sync helpers (T-PERF-P12)

    private func syncPanes(
        _ newPanes: [AgtmuxPane],
        attentionCount: Int,
        paneIdentityIndex: [String: AgtmuxSyncV2PaneInstanceID]
    ) {
        sidebarStore.panes = newPanes
        sidebarStore.attentionCount = attentionCount
        runtimeStore.paneIdentityIndex = paneIdentityIndex
    }

    private func syncPanesBySession(_ v: [(source: String, sessions: [SessionGroup])]) {
        sidebarStore.panesBySession = v
    }

    private func syncSessionOrderBySource(_ v: [String: [String]]) {
        sidebarStore.sessionOrderBySource = v
    }

    private func syncPinnedPaneKeys(_ v: Set<String>) {
        sidebarStore.pinnedPaneKeys = v
    }

    private func syncPaneDisplayTitleOverrides(_ v: [String: String]) {
        sidebarStore.paneDisplayTitleOverrides = v
    }

    private func syncStatusFilter(_ v: StatusFilter) {
        sidebarStore.statusFilter = v
    }

    private func syncOfflineHosts(_ v: Set<String>) {
        runtimeStore.offlineHosts = v
    }

    private func syncLivePaneSessionKeys(_ v: Set<String>) {
        runtimeStore.livePaneSessionKeys = v
    }

    private func syncHasCompletedInitialFetch(_ v: Bool) {
        runtimeStore.hasCompletedInitialFetch = v
    }

    private func syncLocalDaemonIssue(_ v: LocalDaemonIssue?) {
        healthStore.localDaemonIssue = v
    }

    private func syncLocalDaemonHealth(_ v: AgtmuxUIHealthV1?) {
        healthStore.localDaemonHealth = v
    }

    private func syncHookSetupStatus(_ v: HookSetupStatus) {
        healthStore.hookSetupStatus = v
    }

    private func syncHostsConfig(_ v: HostsConfig) {
        runtimeStore.hostsConfig = v
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

    init(localClient: any ProductLocalMetadataClient = AgtmuxDaemonClient(),
         localInventoryClient: any LocalPaneInventoryClient = LocalTmuxInventoryClient(),
         localInventoryAuthority: (any LocalPaneInventoryAuthorityProtocol)? = nil,
         hostsConfig: HostsConfig? = nil,
         remotePaneSources: [RemotePaneInventorySource]? = nil,
         binaryURLResolver: @escaping () -> URL? = AgtmuxBinaryResolver.resolveBinaryURL,
         publishSnapshotAssembler: PublishSnapshotAssembler? = nil,
         pollingInterval: TimeInterval = 1.0,
         localInventoryPollingInterval: TimeInterval? = nil) {
        let resolvedLocalInventoryPollingInterval = localInventoryPollingInterval ?? pollingInterval
        self.localClient = localClient
        self.localHealthClient = localClient as? any LocalHealthClient
        self.localInventoryClient = localInventoryClient
        self.binaryURLResolver = binaryURLResolver
        self.publishSnapshotAssembler = publishSnapshotAssembler ?? { input in
            await AppViewModel.defaultPublishSnapshotAssembler(input)
        }
        self.pollingInterval = pollingInterval
        self.localInventoryPollingInterval = resolvedLocalInventoryPollingInterval
        self.localInventoryAuthority = localInventoryAuthority
            ?? LocalPaneInventoryAuthority(
                dependencies: .live(
                    localInventoryClient: localInventoryClient,
                    fallbackPollInterval: resolvedLocalInventoryPollingInterval
                )
            )
        self.autoLaunchSessionName = UserDefaults.standard.string(forKey: "autoLaunchSessionName") ?? "main"
        let config = hostsConfig ?? HostsConfig.load()
        self.hostsConfig = config
        if let remotePaneSources {
            self.remotePaneSources = remotePaneSources
        } else {
            self.remotePaneSources = config.hosts.map { host in
                let client = RemoteTmuxClient(host: host)
                return RemotePaneInventorySource(
                    source: host.hostname,
                    fetchPanes: { try await client.fetchPanes() }
                )
            }
        }
        runtimeStore.onRefreshInventory = { [weak self] in await self?.fetchAll() }
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Host Management

    func addHost(_ host: RemoteHost) {
        var hosts = hostsConfig.hosts
        hosts.removeAll { $0.id == host.id }
        hosts.append(host)
        syncHostsConfig(HostsConfig(hosts: hosts))
        refreshRemotePaneSources()
        HostsConfig.save(hostsConfig)
    }

    func removeHost(id: String) {
        var hosts = hostsConfig.hosts
        hosts.removeAll { $0.id == id }
        syncHostsConfig(HostsConfig(hosts: hosts))
        refreshRemotePaneSources()
        HostsConfig.save(hostsConfig)
    }

    // MARK: - Polling

    private var pollingTask: Task<Void, Never>?
    private var isPolling = false

    var isRemotePollingActiveForTesting: Bool {
        pollingTask != nil
    }

    /// Start the remote broad poll and the local steady-state projection owner.
    ///
    /// Guarded against double-start: calling startPolling() while already running is a no-op.
    func startPolling() {
        isPolling = true
        localProjectionCoordinator.startSteadyState(
            runtime: makeLocalProjectionRuntime(),
            classifyLocalDaemonIssue: { [weak self] error in
                self?.classifyLocalDaemonIssue(from: error)
            },
            classifyHealthFailure: { [weak self] error in
                self?.classifyLocalHealthRefreshFailure(from: error) ?? .transientFailure
            }
        )
        startLocalInventoryAuthorityIfNeeded()
        startRemotePollingIfNeeded()
        Task { [weak self] in
            await self?.performStartupHookCheck()
        }
    }

    /// Cancel the polling loop and reset so startPolling() can be called again.
    func stopPolling() {
        isPolling = false
        stopRemotePolling()
        localInventoryAuthority.stop()
        localProjectionCoordinator.stop()
        localMetadataSyncPrimed = false
        localMetadataTransportVersion = nil
        localMetadataUseLongPoll = nil
        nextLocalMetadataRefreshAt = .distantPast
        nextLocalHealthRefreshAt = .distantPast
        Task {
            await localClient.resetUIChangesV3()
        }
    }

    private func makeRemotePaneSources(from hosts: [RemoteHost]) -> [RemotePaneInventorySource] {
        hosts.map { host in
            let client = RemoteTmuxClient(host: host)
            return RemotePaneInventorySource(
                source: host.hostname,
                fetchPanes: { try await client.fetchPanes() }
            )
        }
    }

    private func refreshRemotePaneSources() {
        remotePaneSources = makeRemotePaneSources(from: hostsConfig.hosts)
        trimSnapshotCacheToKnownSources()
        let prunedOfflineHosts = offlineHosts.intersection(knownSources())
        if prunedOfflineHosts != offlineHosts {
            syncOfflineHosts(prunedOfflineHosts)
        }
        reconcileRemotePollingState()
        Task { [weak self] in
            await self?.publishFromSnapshotCache(offlineHosts: prunedOfflineHosts)
        }
    }

    private func reconcileRemotePollingState() {
        guard isPolling else {
            stopRemotePolling()
            return
        }

        guard remotePaneSources.isEmpty == false else {
            stopRemotePolling()
            return
        }

        startRemotePollingIfNeeded()
    }

    private func startRemotePollingIfNeeded() {
        guard isPolling else { return }
        guard remotePaneSources.isEmpty == false else { return }
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchRemotePanes()

                do {
                    let nanoseconds = UInt64((self.pollingInterval * 1_000_000_000).rounded(.up))
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    private func stopRemotePolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func enableUITestMetadataMode() {
        uiTestMetadataModeEnabled = true
        localInventoryAuthority.stop()
        localProjectionCoordinator.stop()
        localMetadataSyncPrimed = false
        localMetadataTransportVersion = nil
        localMetadataUseLongPoll = nil
        nextLocalMetadataRefreshAt = .distantPast
        nextLocalHealthRefreshAt = .distantPast
    }

    func performStartupHookCheck() async {
        guard let binaryURL = binaryURLResolver() else {
            syncHookSetupStatus(.unavailable)
            return
        }

        syncHookSetupStatus(.checking)
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--check"])
        switch exitCode {
        case 0:
            syncHookSetupStatus(.registered)
        case 1:
            syncHookSetupStatus(.missing)
        default:
            syncHookSetupStatus(.unavailable)
        }
    }

    func registerHooks() async {
        guard let binaryURL = binaryURLResolver() else {
            syncHookSetupStatus(.unavailable)
            return
        }

        syncHookSetupStatus(.checking)
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks"])
        guard exitCode >= 0 else {
            syncHookSetupStatus(.unavailable)
            return
        }
        await performStartupHookCheck()
    }

    func unregisterHooks() async {
        guard let binaryURL = binaryURLResolver() else {
            syncHookSetupStatus(.unavailable)
            return
        }

        syncHookSetupStatus(.checking)
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--unregister"])
        guard exitCode >= 0 else {
            syncHookSetupStatus(.unavailable)
            return
        }
        await performStartupHookCheck()
    }

    private nonisolated func runAgtmuxCommand(_ binaryURL: URL, args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    // MARK: - Private

    /// Source ordering: "local" first, then alphabetically.
    private nonisolated static func sortedSources(_ keys: [String]) -> [String] {
        keys.sorted { a, b in
            if a == "local" { return true }
            if b == "local" { return false }
            return a < b
        }
    }

    private func sortedSources(_ keys: some Collection<String>) -> [String] {
        Self.sortedSources(Array(keys))
    }

    private nonisolated static func orderedSessionNames(
        source: String,
        currentNames: Set<String>,
        sessionOrderBySource: [String: [String]]
    ) -> [String] {
        let existing = sessionOrderBySource[source] ?? []
        let kept = existing.filter { currentNames.contains($0) }
        let unknown = currentNames.subtracting(kept).sorted()
        return kept + unknown
    }

    private func orderedSessionNames(source: String, currentNames: Set<String>) -> [String] {
        Self.orderedSessionNames(
            source: source,
            currentNames: currentNames,
            sessionOrderBySource: sessionOrderBySource
        )
    }

    private nonisolated static func reconciledSessionOrder(
        currentSessionOrderBySource: [String: [String]],
        panes: [AgtmuxPane]
    ) -> [String: [String]] {
        let bySource = Dictionary(grouping: panes, by: \.source)
        var updated: [String: [String]] = [:]

        for source in sortedSources(Array(bySource.keys)) {
            let names = Set((bySource[source] ?? []).map(\.sessionName))
            updated[source] = orderedSessionNames(
                source: source,
                currentNames: names,
                sessionOrderBySource: currentSessionOrderBySource
            )
        }

        return updated
    }

    /// Normalize panes so UI identity and grouping stay stable while preserving
    /// exact real-session visibility in the sidebar.
    ///
    /// Deduplication is limited to exact duplicate rows that point at the same
    /// source/session/window/pane. Session-group aliases and linked-looking
    /// session names are preserved as-is so the normal path reflects tmux truth.
    private nonisolated static func normalizePanes(_ allPanes: [AgtmuxPane]) -> [AgtmuxPane] {
        let bySource = Dictionary(grouping: allPanes, by: \.source)
        var normalized: [AgtmuxPane] = []

        for source in sortedSources(Array(bySource.keys)) {
            normalized.append(contentsOf: dedupePanes(bySource[source] ?? []))
        }

        return normalized
    }

    private nonisolated static func dedupePanes(_ panes: [AgtmuxPane]) -> [AgtmuxPane] {
        var deduped: [String: AgtmuxPane] = [:]

        for pane in panes {
            let key = paneIdentityKey(for: pane)
            if let existing = deduped[key] {
                deduped[key] = preferredPane(existing, pane)
            } else {
                deduped[key] = pane
            }
        }
        return Array(deduped.values)
    }

    private nonisolated static func preferredPane(_ lhs: AgtmuxPane, _ rhs: AgtmuxPane) -> AgtmuxPane {
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

    private func makeLocalMetadataOverlayStore() -> LocalMetadataOverlayStore {
        LocalMetadataOverlayStore(
            inventory: lastSuccessfulLocalInventory,
            metadataByPaneKey: cachedLocalMetadataByPaneKey,
            presentationByPaneKey: cachedLocalPresentationByPaneKey,
            log: logLocalFetch
        )
    }

    private func makeLocalMetadataRefreshContext() -> LocalMetadataRefreshContext {
        LocalMetadataRefreshContext(
            syncPrimed: localMetadataSyncPrimed,
            transportVersion: localMetadataTransportVersion,
            inventoryCount: lastSuccessfulLocalInventory.count,
            successInterval: localMetadataSuccessInterval,
            failureBackoff: localMetadataFailureBackoff,
            bootstrapNotReadyBackoff: localMetadataBootstrapNotReadyBackoff,
            changeLimit: localMetadataChangeLimit,
            useLongPoll: localMetadataUseLongPoll ?? true,
            longPollTimeoutMs: 3000
        )
    }

    private func makeLocalProjectionState() -> LocalProjectionState {
        LocalProjectionState(
            uiTestMetadataModeEnabled: uiTestMetadataModeEnabled,
            localInventoryKnown: hasFetchedLocalInventory,
            localInventoryAvailable: !offlineHosts.contains("local"),
            nextMetadataRefreshAt: nextLocalMetadataRefreshAt,
            nextHealthRefreshAt: nextLocalHealthRefreshAt,
            metadataRefreshContext: makeLocalMetadataRefreshContext(),
            overlayStore: makeLocalMetadataOverlayStore(),
            healthSuccessInterval: localHealthSuccessInterval,
            healthFailureBackoff: localHealthFailureBackoff,
            healthUnsupportedBackoff: localHealthUnsupportedBackoff
        )
    }

    private func makeLocalProjectionRuntime() -> LocalProjectionSteadyStateRuntime {
        LocalProjectionSteadyStateRuntime(
            captureState: { [weak self] in
                self?.makeLocalProjectionState()
            },
            applyInventory: { [weak self] inventory in
                self?.cacheLocalInventory(inventory)
            },
            applyMetadataExecution: { [weak self] execution in
                await self?.applyLocalMetadataRefreshExecution(execution)
            },
            applyHealthExecution: { [weak self] execution in
                self?.applyLocalHealthRefreshExecution(execution)
            }
        )
    }

    /// Merge local tmux inventory with daemon metadata overlay.
    ///
    /// Inventory (tmux list-panes) is authoritative for pane existence.
    /// Daemon metadata enriches rows (managed status/activity/provider/etc.)
    /// but does not create new rows if the pane is absent from inventory.
    private nonisolated static func mergeLocalInventory(
        inventory: [AgtmuxPane],
        metadataByPaneKey: [String: AgtmuxPane]
    ) -> [AgtmuxPane] {
        inventory.map { inventoryPane in
            let key = LocalMetadataOverlayStore.paneMetadataKey(for: inventoryPane)
            guard let metadataPane = metadataByPaneKey[key] else { return inventoryPane }
            // session_key is opaque daemon identity and must not be compared to the visible
            // session_name. Correlation is already guaranteed by the paneMetadataKey lookup
            // above (source:sessionName:windowId:paneId). Comparing metadataSessionKey to
            // sessionName here would incorrectly drop valid overlays whenever session_key
            // differs from session_name (e.g. numeric IDs or UUIDs).
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
                sessionSubtitle: metadataPane.sessionSubtitle,
                currentPath: metadataPane.currentPath ?? inventoryPane.currentPath,
                gitBranch: metadataPane.gitBranch,
                currentCmd: metadataPane.currentCmd ?? inventoryPane.currentCmd,
                updatedAt: metadataPane.updatedAt,
                ageSecs: metadataPane.ageSecs,
                metadataSessionKey: metadataPane.metadataSessionKey,
                paneInstanceID: metadataPane.paneInstanceID
            )
        }
    }

    private func applyLocalMetadataRefreshPlan(_ plan: LocalMetadataRefreshPlan) async {
        if plan.disableLongPoll {
            localMetadataUseLongPoll = false
        }
        localMetadataSyncPrimed = plan.state.syncPrimed
        localMetadataTransportVersion = plan.state.transportVersion
        if localDaemonIssue != plan.state.daemonIssue { syncLocalDaemonIssue(plan.state.daemonIssue) }
        nextLocalMetadataRefreshAt = plan.state.nextRefreshAt

        switch plan.cacheAction {
        case .replace(let cache):
            cachedLocalMetadataByPaneKey = cache.metadataByPaneKey
            cachedLocalPresentationByPaneKey = cache.presentationByPaneKey
        case .preserve:
            break
        case .clear:
            cachedLocalMetadataByPaneKey = [:]
            cachedLocalPresentationByPaneKey = [:]
        }

        if let logMessage = plan.logMessage {
            logLocalFetch(logMessage)
        }

        guard plan.shouldPublishSnapshotCache else { return }
        await publishFromSnapshotCache()
    }

    private func applyLocalMetadataRefreshExecution(_ execution: LocalMetadataRefreshExecution) async {
        for message in execution.preApplyLogMessages {
            logLocalFetch(message)
        }

        for version in execution.replayResetVersions {
            _ = version
            await localClient.resetUIChangesV3()
        }

        await applyLocalMetadataRefreshPlan(execution.plan)

        for message in execution.postApplyLogMessages {
            logLocalFetch(message)
        }
    }

    private func applyLocalHealthRefreshExecution(_ execution: LocalHealthRefreshExecution) {
        switch execution.cacheAction {
        case .preserve:
            break
        case .set(let health):
            if localDaemonHealth != health {
                syncLocalDaemonHealth(health)
            }
        }
        nextLocalHealthRefreshAt = execution.nextRefreshAt
    }

    private func startLocalInventoryAuthorityIfNeeded() {
        localInventoryAuthority.start(
            seedInventory: lastSuccessfulLocalInventory,
            applyInventory: { [weak self] inventory in
                await self?.applyLocalInventorySuccess(inventory)
            },
            handleFailure: { [weak self] in
                await self?.applyLocalInventoryFailure()
            }
        )
    }

    private func cacheLocalInventory(_ inventory: [AgtmuxPane]) {
        lastSuccessfulLocalInventory = inventory
        hasFetchedLocalInventory = true
        localInventoryAuthority.updateSeedInventory(inventory)
    }

    private func applyLocalInventorySuccess(_ inventory: [AgtmuxPane]) async {
        cacheLocalInventory(inventory)

        var newOffline = offlineHosts
        newOffline.remove("local")
        await publishFromSnapshotCache(offlineHosts: newOffline)

        if pollingTask != nil {
            localProjectionCoordinator.startSteadyState(
                runtime: makeLocalProjectionRuntime(),
                classifyLocalDaemonIssue: { [weak self] error in
                    self?.classifyLocalDaemonIssue(from: error)
                },
                classifyHealthFailure: { [weak self] error in
                    self?.classifyLocalHealthRefreshFailure(from: error) ?? .transientFailure
                }
            )
        }
        if !hasCompletedInitialFetch { syncHasCompletedInitialFetch(true) }
        maybeAutoLaunchSession()
    }

    private func applyLocalInventoryFailure() async {
        let wasOffline = offlineHosts.contains("local")
        if !wasOffline {
            localProjectionCoordinator.stopMetadataSteadyState()
            localMetadataSyncPrimed = false
            localMetadataTransportVersion = nil
            localMetadataUseLongPoll = nil
            nextLocalMetadataRefreshAt = .distantPast
            syncLocalDaemonIssue(nil)
            await localClient.resetUIChangesV3()
        }

        var newOffline = offlineHosts
        newOffline.insert("local")
        await publishFromSnapshotCache(offlineHosts: newOffline)
    }

    private func fetchLocalPanes() async throws -> [AgtmuxPane] {
        let inventory = try await localProjectionCoordinator.refreshOnce(
            state: makeLocalProjectionState(),
            runtime: makeLocalProjectionRuntime(),
            classifyLocalDaemonIssue: { [weak self] error in
                self?.classifyLocalDaemonIssue(from: error)
            },
            classifyHealthFailure: { [weak self] error in
                self?.classifyLocalHealthRefreshFailure(from: error) ?? .transientFailure
            }
        )
        cacheLocalInventory(inventory)
        return inventory
    }

    private func knownSources() -> Set<String> {
        Set(["local"] + remotePaneSources.map(\.source))
    }

    private func trimSnapshotCacheToKnownSources() {
        let known = knownSources()
        lastSuccessfulRemotePanesBySource = lastSuccessfulRemotePanesBySource.filter { known.contains($0.key) }
    }

    private nonisolated static func paneIdentityKey(for pane: AgtmuxPane) -> String {
        "\(pane.source):\(pane.sessionName):\(pane.windowId):\(pane.paneId)"
    }

    private nonisolated static func panePresentation(
        for pane: AgtmuxPane,
        presentationByPaneKey: [String: PanePresentationState]
    ) -> PanePresentationState? {
        guard pane.source == "local" else { return nil }
        return presentationByPaneKey[LocalMetadataOverlayStore.paneMetadataKey(for: pane)]
    }

    private nonisolated static func paneNeedsAttention(
        _ pane: AgtmuxPane,
        presentationByPaneKey: [String: PanePresentationState]
    ) -> Bool {
        let presentation = panePresentation(
            for: pane,
            presentationByPaneKey: presentationByPaneKey
        )
        return PaneDisplayState(pane: pane, presentation: presentation).needsAttention
    }

    private nonisolated static func buildPaneIdentityIndex(
        from panes: [AgtmuxPane]
    ) -> [String: AgtmuxSyncV2PaneInstanceID] {
        var index: [String: AgtmuxSyncV2PaneInstanceID] = [:]
        for pane in panes {
            guard let instanceID = pane.paneInstanceID else { continue }
            index[paneIdentityKey(for: pane)] = instanceID
        }
        return index
    }

    nonisolated static func defaultPublishSnapshotAssembler(
        _ input: PublishSnapshotAssemblyInput
    ) async -> PublishSnapshotAssembly {
        await Task.detached(priority: .userInitiated) {
            assemblePublishSnapshot(input)
        }.value
    }

    nonisolated static func assemblePublishSnapshot(
        _ input: PublishSnapshotAssemblyInput
    ) -> PublishSnapshotAssembly {
        var panesBySource = input.remotePanesBySource
        if !input.localInventory.isEmpty || panesBySource["local"] != nil {
            panesBySource["local"] = mergeLocalInventory(
                inventory: input.localInventory,
                metadataByPaneKey: input.localMetadataByPaneKey
            )
        }

        let merged = sortedSources(Array(panesBySource.keys))
            .flatMap { panesBySource[$0] ?? [] }
        let normalized = normalizePanes(merged)
        let livePaneKeys = Set(normalized.map(paneIdentityKey(for:)))
        let livePaneSessionKeys = Set(normalized.map { "\($0.source):\($0.sessionName)" })
        let prunedPinnedPaneKeys = input.pinnedPaneKeys.intersection(livePaneKeys)
        let prunedPaneDisplayTitleOverrides = input.paneDisplayTitleOverrides.filter {
            livePaneKeys.contains($0.key)
        }
        let attentionCount = normalized.reduce(into: 0) { count, pane in
            if paneNeedsAttention(
                pane,
                presentationByPaneKey: input.localPresentationByPaneKey
            ) {
                count += 1
            }
        }
        let paneIdentityIndex = buildPaneIdentityIndex(from: normalized)
        let reconciledSessionOrderBySource = reconciledSessionOrder(
            currentSessionOrderBySource: input.sessionOrderBySource,
            panes: normalized
        )

        return PublishSnapshotAssembly(
            generation: input.generation,
            sideInputGeneration: input.sideInputGeneration,
            panes: normalized,
            reconciledSessionOrderBySource: reconciledSessionOrderBySource,
            livePaneKeys: livePaneKeys,
            livePaneSessionKeys: livePaneSessionKeys,
            prunedPinnedPaneKeys: prunedPinnedPaneKeys,
            prunedPaneDisplayTitleOverrides: prunedPaneDisplayTitleOverrides,
            attentionCount: attentionCount,
            paneIdentityIndex: paneIdentityIndex
        )
    }

    private func retainSelection(in normalized: [AgtmuxPane]) {
        guard let currentSelectedPane = selectedPane else { return }
        selectedPane = normalized.first { hasSamePaneIdentity($0, currentSelectedPane) }
    }

    private func commitPublishSnapshot(
        _ snapshot: PublishSnapshotAssembly,
        offlineHosts newOffline: Set<String>?
    ) {
        guard publishGeneration == snapshot.generation else { return }

        let panesChanged = snapshot.panes != panes
        let sideInputsAreCurrent = snapshot.sideInputGeneration == publishSideInputGeneration
        let nextSessionOrderBySource: [String: [String]]
        let nextPinnedPaneKeys: Set<String>
        let nextPaneDisplayTitleOverrides: [String: String]

        if sideInputsAreCurrent {
            nextSessionOrderBySource = snapshot.reconciledSessionOrderBySource
            nextPinnedPaneKeys = snapshot.prunedPinnedPaneKeys
            nextPaneDisplayTitleOverrides = snapshot.prunedPaneDisplayTitleOverrides
        } else {
            nextSessionOrderBySource = Self.reconciledSessionOrder(
                currentSessionOrderBySource: sessionOrderBySource,
                panes: snapshot.panes
            )
            nextPinnedPaneKeys = pinnedPaneKeys.intersection(snapshot.livePaneKeys)
            nextPaneDisplayTitleOverrides = paneDisplayTitleOverrides.filter {
                snapshot.livePaneKeys.contains($0.key)
            }
        }

        if panesChanged {
            if nextSessionOrderBySource != sessionOrderBySource {
                syncSessionOrderBySource(nextSessionOrderBySource)
            }
            syncPanes(
                snapshot.panes,
                attentionCount: snapshot.attentionCount,
                paneIdentityIndex: snapshot.paneIdentityIndex
            )
            triggerPanesBySessionRecompute()
        }
        if snapshot.livePaneSessionKeys != livePaneSessionKeys {
            syncLivePaneSessionKeys(snapshot.livePaneSessionKeys)
        }
        if nextPinnedPaneKeys != pinnedPaneKeys {
            syncPinnedPaneKeys(nextPinnedPaneKeys)
        }
        if nextPaneDisplayTitleOverrides != paneDisplayTitleOverrides {
            syncPaneDisplayTitleOverrides(nextPaneDisplayTitleOverrides)
        }
        retainSelection(in: snapshot.panes)
        if let newOffline, newOffline != offlineHosts {
            syncOfflineHosts(newOffline)
        }
    }

    func makePublishSnapshotAssemblyInputForTesting(
        localInventory: [AgtmuxPane]? = nil,
        localMetadataByPaneKey: [String: AgtmuxPane]? = nil,
        localPresentationByPaneKey: [String: PanePresentationState]? = nil,
        remotePanesBySource: [String: [AgtmuxPane]]? = nil
    ) -> PublishSnapshotAssemblyInput {
        trimSnapshotCacheToKnownSources()
        publishGeneration &+= 1
        return PublishSnapshotAssemblyInput(
            generation: publishGeneration,
            sideInputGeneration: publishSideInputGeneration,
            localInventory: localInventory ?? lastSuccessfulLocalInventory,
            localMetadataByPaneKey: localMetadataByPaneKey ?? cachedLocalMetadataByPaneKey,
            localPresentationByPaneKey: localPresentationByPaneKey ?? cachedLocalPresentationByPaneKey,
            remotePanesBySource: remotePanesBySource ?? lastSuccessfulRemotePanesBySource,
            pinnedPaneKeys: pinnedPaneKeys,
            paneDisplayTitleOverrides: paneDisplayTitleOverrides,
            sessionOrderBySource: sessionOrderBySource
        )
    }

    func commitPublishSnapshotForTesting(
        _ snapshot: PublishSnapshotAssembly,
        offlineHosts: Set<String>? = nil
    ) {
        commitPublishSnapshot(snapshot, offlineHosts: offlineHosts)
    }

    private func publishFromSnapshotCache(offlineHosts newOffline: Set<String>? = nil) async {
        let pubID = AgtmuxSignpost.publish.makeSignpostID()
        let pubState = AgtmuxSignpost.publish.beginInterval("publish", id: pubID)
        defer { AgtmuxSignpost.publish.endInterval("publish", pubState) }
        trimSnapshotCacheToKnownSources()

        publishGeneration &+= 1
        let generation = publishGeneration
        let input = PublishSnapshotAssemblyInput(
            generation: generation,
            sideInputGeneration: publishSideInputGeneration,
            localInventory: lastSuccessfulLocalInventory,
            localMetadataByPaneKey: cachedLocalMetadataByPaneKey,
            localPresentationByPaneKey: cachedLocalPresentationByPaneKey,
            remotePanesBySource: lastSuccessfulRemotePanesBySource,
            pinnedPaneKeys: pinnedPaneKeys,
            paneDisplayTitleOverrides: paneDisplayTitleOverrides,
            sessionOrderBySource: sessionOrderBySource
        )

        let assembleID = AgtmuxSignpost.publishAssemble.makeSignpostID()
        let assembleState = AgtmuxSignpost.publishAssemble.beginInterval(
            "assembleSnapshot",
            id: assembleID
        )
        defer { AgtmuxSignpost.publishAssemble.endInterval("assembleSnapshot", assembleState) }
        let snapshot = await publishSnapshotAssembler(input)
        commitPublishSnapshot(snapshot, offlineHosts: newOffline)
    }

    private func fetchRemotePanes() async {
        var successfulRemoteBySource: [String: [AgtmuxPane]] = [:]
        var newOffline = offlineHosts.filter { $0 == "local" }

        await withTaskGroup(of: (source: String, panes: [AgtmuxPane]?, offline: Bool).self) { group in
            for source in self.remotePaneSources {
                group.addTask {
                    do {
                        let panes = try await source.fetchPanes()
                        return (source.source, panes, false)
                    } catch {
                        return (source.source, nil, true)
                    }
                }
            }

            for await result in group {
                if result.offline {
                    newOffline.insert(result.source)
                } else if let panes = result.panes {
                    successfulRemoteBySource[result.source] = panes
                }
            }
        }

        for (source, panes) in successfulRemoteBySource {
            lastSuccessfulRemotePanesBySource[source] = panes
        }

        await publishFromSnapshotCache(offlineHosts: newOffline)
        if !hasCompletedInitialFetch { syncHasCompletedInitialFetch(true) }
        maybeAutoLaunchSession()
    }

    /// Perform the bounded startup refresh before the steady-state pollers begin.
    func performInitialSync() async {
        await fetchAll()
    }

    /// Fetch from all sources concurrently, merge results, update state.
    /// Internal access so TmuxManager can trigger an immediate refresh.
    func fetchAll() async {
        let fetchID = AgtmuxSignpost.fetchAll.makeSignpostID()
        let fetchState = AgtmuxSignpost.fetchAll.beginInterval("fetchAll", id: fetchID)
        defer { AgtmuxSignpost.fetchAll.endInterval("fetchAll", fetchState) }
        var successfulRemoteBySource: [String: [AgtmuxPane]] = [:]
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
            for source in self.remotePaneSources {
                group.addTask {
                    do {
                        let panes = try await source.fetchPanes()
                        return (source.source, panes, false)
                    } catch {
                        return (source.source, nil, true)
                    }
                }
            }

            for await result in group {
                if result.offline {
                    newOffline.insert(result.source)
                } else if let panes = result.panes {
                    if result.source != "local" {
                        successfulRemoteBySource[result.source] = panes
                    }
                }
            }
        }

        // Update cache only for successful sources. Failed sources keep the previous
        // successful snapshot to avoid sidebar flicker/empty flashes.
        for (source, panes) in successfulRemoteBySource {
            lastSuccessfulRemotePanesBySource[source] = panes
        }
        if newOffline.contains("local") {
            localProjectionCoordinator.stopMetadataSteadyState()
            localMetadataSyncPrimed = false
            localMetadataTransportVersion = nil
            localMetadataUseLongPoll = nil
            nextLocalMetadataRefreshAt = .distantPast
            syncLocalDaemonIssue(nil)
            await localClient.resetUIChangesV3()
        }
        await publishFromSnapshotCache(offlineHosts: newOffline)
        if pollingTask != nil {
            if newOffline.contains("local") {
                localInventoryAuthority.stop()
            } else {
                startLocalInventoryAuthorityIfNeeded()
                localInventoryAuthority.updateSeedInventory(lastSuccessfulLocalInventory)
            }
            localProjectionCoordinator.startSteadyState(
                runtime: makeLocalProjectionRuntime(),
                classifyLocalDaemonIssue: { [weak self] error in
                    self?.classifyLocalDaemonIssue(from: error)
                },
                classifyHealthFailure: { [weak self] error in
                    self?.classifyLocalHealthRefreshFailure(from: error) ?? .transientFailure
                }
            )
        }
        if !hasCompletedInitialFetch { syncHasCompletedInitialFetch(true) }
        maybeAutoLaunchSession()
    }

    private func maybeAutoLaunchSession() {
        guard !hasAttemptedAutoLaunch else { return }
        guard !autoLaunchSessionName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let hasLocalPanes = panes.contains { $0.source == "local" }
        guard !hasLocalPanes else { return }
        hasAttemptedAutoLaunch = true
        let name = autoLaunchSessionName
        Task {
            _ = try? await TmuxCommandRunner.shared.run(
                ["new-session", "-d", "-s", name],
                source: "local"
            )
        }
    }
}
