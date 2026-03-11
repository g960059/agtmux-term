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
    @Published private(set) var hasCompletedInitialFetch = false
    @Published private(set) var localDaemonIssue: LocalDaemonIssue?
    @Published private(set) var localDaemonHealth: AgtmuxUIHealthV1?
    @Published private(set) var hookSetupStatus: HookSetupStatus = .unknown

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
    var attentionCount: Int { panes.filter { paneNeedsAttention($0) }.count }

    // MARK: - Filtered panes

    var filteredPanes: [AgtmuxPane] {
        let visible = panes
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

    func paneDisplaySubtitle(for pane: AgtmuxPane) -> String? {
        guard pane.presence == .managed else { return nil }
        return pane.sessionSubtitle
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

    func hasSamePaneIdentity(_ lhs: AgtmuxPane, _ rhs: AgtmuxPane) -> Bool {
        paneIdentityKey(for: lhs) == paneIdentityKey(for: rhs)
    }

    func panePresentation(for pane: AgtmuxPane) -> PanePresentationState? {
        guard pane.source == "local" else { return nil }
        return cachedLocalPresentationByPaneKey[LocalMetadataOverlayStore.paneMetadataKey(for: pane)]
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
        paneDisplayState(for: pane).needsAttention
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
        sessionOrderBySource[source] = ordered
    }

    // MARK: - Clients

    private let localClient: any ProductLocalMetadataClient
    private let localHealthClient: (any LocalHealthClient)?
    private let localInventoryClient: any LocalPaneInventoryClient
    private var remotePaneSources: [RemotePaneInventorySource] = []
    let hostsConfig: HostsConfig
    private var lastSuccessfulRemotePanesBySource: [String: [AgtmuxPane]] = [:]
    private var lastSuccessfulLocalInventory: [AgtmuxPane] = []
    private var cachedLocalMetadataByPaneKey: [String: AgtmuxPane] = [:]
    private var cachedLocalPresentationByPaneKey: [String: PanePresentationState] = [:]
    private var localMetadataRefreshTask: Task<Void, Never>?
    private var localHealthRefreshTask: Task<Void, Never>?
    private var localMetadataSyncPrimed = false
    private var localMetadataTransportVersion: LocalMetadataTransportVersion?
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

    private enum LocalHealthRefreshDisposition {
        case unsupportedMethod
        case transientFailure
    }

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
         hostsConfig: HostsConfig? = nil,
         remotePaneSources: [RemotePaneInventorySource]? = nil,
         binaryURLResolver: @escaping () -> URL? = AgtmuxBinaryResolver.resolveBinaryURL) {
        self.localClient = localClient
        self.localHealthClient = localClient as? any LocalHealthClient
        self.localInventoryClient = localInventoryClient
        self.binaryURLResolver = binaryURLResolver
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
        Task {
            await performStartupHookCheck()
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
        localMetadataTransportVersion = nil
        nextLocalHealthRefreshAt = .distantPast
        Task {
            await localClient.resetUIChangesV3()
        }
    }

    func enableUITestMetadataMode() {
        uiTestMetadataModeEnabled = true
        localMetadataRefreshTask?.cancel()
        localMetadataRefreshTask = nil
        localHealthRefreshTask?.cancel()
        localHealthRefreshTask = nil
        localMetadataSyncPrimed = false
        localMetadataTransportVersion = nil
        nextLocalMetadataRefreshAt = .distantPast
        nextLocalHealthRefreshAt = .distantPast
    }

    func performStartupHookCheck() async {
        guard let binaryURL = binaryURLResolver() else {
            hookSetupStatus = .unavailable
            return
        }

        hookSetupStatus = .checking
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--check"])
        switch exitCode {
        case 0:
            hookSetupStatus = .registered
        case 1:
            hookSetupStatus = .missing
        default:
            hookSetupStatus = .unavailable
        }
    }

    func registerHooks() async {
        guard let binaryURL = binaryURLResolver() else {
            hookSetupStatus = .unavailable
            return
        }

        hookSetupStatus = .checking
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks"])
        guard exitCode >= 0 else {
            hookSetupStatus = .unavailable
            return
        }
        await performStartupHookCheck()
    }

    func unregisterHooks() async {
        guard let binaryURL = binaryURLResolver() else {
            hookSetupStatus = .unavailable
            return
        }

        hookSetupStatus = .checking
        let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--unregister"])
        guard exitCode >= 0 else {
            hookSetupStatus = .unavailable
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

    /// Normalize panes so UI identity and grouping stay stable while preserving
    /// exact real-session visibility in the sidebar.
    ///
    /// Deduplication is limited to exact duplicate rows that point at the same
    /// source/session/window/pane. Session-group aliases and linked-looking
    /// session names are preserved as-is so the normal path reflects tmux truth.
    private func normalizePanes(_ allPanes: [AgtmuxPane]) -> [AgtmuxPane] {
        let bySource = Dictionary(grouping: allPanes, by: \.source)
        var normalized: [AgtmuxPane] = []

        for source in sortedSources(bySource.keys) {
            normalized.append(contentsOf: dedupePanes(bySource[source] ?? []))
        }

        return normalized
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
            changeLimit: localMetadataChangeLimit
        )
    }

    private func makeLocalMetadataRefreshCoordinator() -> LocalMetadataRefreshCoordinator {
        LocalMetadataRefreshCoordinator(
            client: localClient,
            transportBridge: localMetadataTransportBridge
        )
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
        localMetadataSyncPrimed = plan.state.syncPrimed
        localMetadataTransportVersion = plan.state.transportVersion
        localDaemonIssue = plan.state.daemonIssue
        nextLocalMetadataRefreshAt = plan.state.nextRefreshAt

        switch plan.cacheAction {
        case .replace(let cache):
            cachedLocalMetadataByPaneKey = cache.metadataByPaneKey
            cachedLocalPresentationByPaneKey = cache.presentationByPaneKey
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
                let execution = try await self.makeLocalMetadataRefreshCoordinator().runStep(
                    context: self.makeLocalMetadataRefreshContext(),
                    overlayStore: self.makeLocalMetadataOverlayStore()
                )
                try Task.checkCancellation()
                await self.applyLocalMetadataRefreshExecution(execution)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                let execution = self.makeLocalMetadataRefreshCoordinator().failureExecution(
                    context: self.makeLocalMetadataRefreshContext(),
                    error: error,
                    classifyLocalDaemonIssue: self.classifyLocalDaemonIssue(from:)
                )
                await self.applyLocalMetadataRefreshExecution(execution)
            }
        }
    }

    private func fetchLocalPanes() async throws -> [AgtmuxPane] {
        let env = ProcessInfo.processInfo.environment

        // Fixture mode for deterministic UI tests. Keep the current AGTMUX_JSON-only behavior.
        if env["AGTMUX_JSON"] != nil {
            let snapshot = try await localClient.fetchSnapshot()
            lastSuccessfulLocalInventory = snapshot.panes
            return snapshot.panes
        }

        // Live UI tests exercise tmux inventory lifecycle/selection behavior.
        // Running `agtmux json` here can block app responsiveness under XCUITest
        // (metadata collection may require host capabilities not available to tests).
        if env["AGTMUX_UITEST"] == "1",
           env["AGTMUX_UITEST_INVENTORY_ONLY"] == "1",
           !uiTestMetadataModeEnabled {
            let inventory = try await localInventoryClient.fetchPanes()
            lastSuccessfulLocalInventory = inventory
            return inventory
        }

        scheduleLocalHealthRefreshIfNeeded()
        let inventory = try await localInventoryClient.fetchPanes()
        lastSuccessfulLocalInventory = inventory
        scheduleLocalMetadataRefreshIfNeeded()
        return inventory
    }

    private func knownSources() -> Set<String> {
        Set(["local"] + remotePaneSources.map(\.source))
    }

    private func trimSnapshotCacheToKnownSources() {
        let known = knownSources()
        lastSuccessfulRemotePanesBySource = lastSuccessfulRemotePanesBySource.filter { known.contains($0.key) }
    }

    private func visibleLocalPanes() -> [AgtmuxPane] {
        mergeLocalInventory(
            inventory: lastSuccessfulLocalInventory,
            metadataByPaneKey: cachedLocalMetadataByPaneKey
        )
    }

    private func retainSelection(in normalized: [AgtmuxPane]) {
        guard let currentSelectedPane = selectedPane else { return }
        selectedPane = normalized.first { hasSamePaneIdentity($0, currentSelectedPane) }
    }

    private func publishFromSnapshotCache(offlineHosts newOffline: Set<String>? = nil) async {
        trimSnapshotCacheToKnownSources()
        var panesBySource = lastSuccessfulRemotePanesBySource
        if !lastSuccessfulLocalInventory.isEmpty || panesBySource["local"] != nil {
            panesBySource["local"] = visibleLocalPanes()
        }
        let merged = sortedSources(panesBySource.keys)
            .flatMap { panesBySource[$0] ?? [] }
        let normalized = normalizePanes(merged)
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
            localMetadataRefreshTask?.cancel()
            localMetadataRefreshTask = nil
            localMetadataSyncPrimed = false
            localMetadataTransportVersion = nil
            localDaemonIssue = nil
            await localClient.resetUIChangesV3()
        }
        await publishFromSnapshotCache(offlineHosts: newOffline)
        hasCompletedInitialFetch = true
    }
}
