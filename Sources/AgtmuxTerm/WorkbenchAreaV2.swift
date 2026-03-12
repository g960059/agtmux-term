import SwiftUI
import AgtmuxTermCore

struct WorkbenchAreaV2: View {
    @Environment(WorkbenchStoreV2.self) private var store
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Group {
            if let workbench = store.activeWorkbench {
                WorkbenchNodeViewV2(
                    workbenchID: workbench.id,
                    node: workbench.root,
                    focusedTileID: workbench.focusedTileID,
                    hostsConfig: viewModel.hostsConfig
                )
            } else {
                WorkbenchEmptyStateV2()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceArea)
    }
}

private struct WorkbenchNodeViewV2: View {
    let workbenchID: UUID
    let node: WorkbenchNode
    let focusedTileID: UUID?
    let hostsConfig: HostsConfig

    var body: some View {
        switch node {
        case .empty:
            WorkbenchEmptyStateV2()
        case .tile(let tile):
            WorkbenchTileViewV2(
                workbenchID: workbenchID,
                tile: tile,
                isFocused: focusedTileID == tile.id,
                hostsConfig: hostsConfig
            )
        case .split(let split):
            GeometryReader { geometry in
                splitBody(split, size: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func splitBody(_ split: WorkbenchSplit, size: CGSize) -> some View {
        switch split.axis {
        case .horizontal:
            HStack(spacing: 8) {
                WorkbenchNodeViewV2(
                    workbenchID: workbenchID,
                    node: split.first,
                    focusedTileID: focusedTileID,
                    hostsConfig: hostsConfig
                )
                    .frame(width: max(1, size.width * split.ratio - 4))
                WorkbenchNodeViewV2(
                    workbenchID: workbenchID,
                    node: split.second,
                    focusedTileID: focusedTileID,
                    hostsConfig: hostsConfig
                )
                    .frame(width: max(1, size.width * (1 - split.ratio) - 4))
            }
        case .vertical:
            VStack(spacing: 8) {
                WorkbenchNodeViewV2(
                    workbenchID: workbenchID,
                    node: split.first,
                    focusedTileID: focusedTileID,
                    hostsConfig: hostsConfig
                )
                    .frame(height: max(1, size.height * split.ratio - 4))
                WorkbenchNodeViewV2(
                    workbenchID: workbenchID,
                    node: split.second,
                    focusedTileID: focusedTileID,
                    hostsConfig: hostsConfig
                )
                    .frame(height: max(1, size.height * (1 - split.ratio) - 4))
            }
        }
    }
}

private struct WorkbenchEmptyStateV2: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 40))
                .foregroundStyle(Color.white.opacity(0.56))
            Text("Open a tmux session or companion surface")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceEmpty)
    }
}

// MARK: - TerminalTileInventorySnapshot

/// A minimal snapshot of AppViewModel state relevant to a single terminal tile.
/// Passed as a `let` to `WorkbenchTerminalTileViewV2` so the tile only re-renders
/// when its own inventory state changes, not on unrelated pane-list updates.
struct TerminalTileInventorySnapshot: Equatable {
    let isOffline: Bool
    let hasCompletedInitialFetch: Bool
    let paneIsLive: Bool
    let localDaemonIssue: LocalDaemonIssue?
}

private struct WorkbenchTileViewV2: View {
    let workbenchID: UUID
    let tile: WorkbenchTile
    let isFocused: Bool
    let hostsConfig: HostsConfig

    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        switch tile.kind {
        case .terminal(let sessionRef):
            WorkbenchTerminalTileViewV2(
                workbenchID: workbenchID,
                tile: tile,
                sessionRef: sessionRef,
                isFocused: isFocused,
                hostsConfig: hostsConfig,
                inventorySnapshot: makeInventorySnapshot(for: sessionRef)
            )
        case .browser(let url, let sourceContext):
            WorkbenchBrowserTileViewV2(
                tile: tile,
                url: url,
                sourceContext: sourceContext,
                isFocused: isFocused
            )
        case .document(let ref):
            WorkbenchDocumentTileViewV2(
                tile: tile,
                ref: ref,
                isFocused: isFocused,
                hostsConfig: hostsConfig
            )
        }
    }

    private func makeInventorySnapshot(for sessionRef: SessionRef) -> TerminalTileInventorySnapshot {
        let source: String
        let isOffline: Bool
        switch sessionRef.target {
        case .local:
            source = "local"
            isOffline = viewModel.offlineHosts.contains("local")
        case .remote(let hostKey):
            let hostname = hostsConfig.host(id: hostKey)?.hostname ?? hostKey
            source = hostname
            isOffline = viewModel.offlineHosts.contains(hostname)
        }
        let paneIsLive = viewModel.livePaneSessionKeys.contains("\(source):\(sessionRef.sessionName)")
        return TerminalTileInventorySnapshot(
            isOffline: isOffline,
            hasCompletedInitialFetch: viewModel.hasCompletedInitialFetch,
            paneIsLive: paneIsLive,
            localDaemonIssue: viewModel.localDaemonIssue
        )
    }
}

private struct WorkbenchTerminalTileViewV2: View {
    let workbenchID: UUID
    let tile: WorkbenchTile
    let sessionRef: SessionRef
    let isFocused: Bool
    let hostsConfig: HostsConfig
    let inventorySnapshot: TerminalTileInventorySnapshot

    @Environment(WorkbenchStoreV2.self) private var store
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isPresentingRebindSheet = false
    @State private var navigationSyncErrorMessage: String?
    @State private var frozenAttachPlan: WorkbenchV2TerminalAttachPlan?

    private var rendersGhosttySurface: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] == "1" {
            return true
        }
        return env["AGTMUX_UITEST"] != "1"
    }

    private var terminalState: WorkbenchV2TerminalTileState {
        // Derive state from the pre-computed snapshot (computed by WorkbenchTileViewV2)
        // to avoid subscribing to the full AppViewModel pane list.
        if !inventorySnapshot.hasCompletedInitialFetch {
            if case .remote(let hostKey) = sessionRef.target,
               hostsConfig.host(id: hostKey) == nil {
                return .broken(.hostMissing(hostKey))
            }
            return .bootstrapping
        }

        switch sessionRef.target {
        case .local:
            if inventorySnapshot.isOffline {
                return .broken(.tmuxUnavailable)
            }
            if inventorySnapshot.paneIsLive {
                return .ready
            }
            if let localDaemonIssue = inventorySnapshot.localDaemonIssue {
                switch localDaemonIssue {
                case .localDaemonUnavailable(let detail):
                    return .broken(.daemonUnavailable(detail))
                case .incompatibleMetadataProtocol(let detail):
                    return .broken(.daemonIncompatible(detail))
                }
            }
            return .broken(.sessionMissing(sessionRef.sessionName))
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                return .broken(.hostMissing(hostKey))
            }
            if inventorySnapshot.isOffline {
                return .broken(.hostOffline(host.id))
            }
            if !inventorySnapshot.paneIsLive {
                return .broken(.sessionMissing(sessionRef.sessionName))
            }
            return .ready
        }
    }

    private var liveAttachResolution: Result<WorkbenchV2TerminalAttachPlan, WorkbenchV2TerminalAttachError> {
        WorkbenchV2TerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            activePaneRef: activePaneRef,
            hostsConfig: hostsConfig
        )
    }

    private var attachResolution: Result<WorkbenchV2TerminalAttachPlan, WorkbenchV2TerminalAttachError> {
        if let frozenAttachPlan {
            return .success(frozenAttachPlan)
        }
        return liveAttachResolution
    }

    private var activePaneRuntimeContext: (
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        focusRequestNonce: UInt64
    )? {
        guard let context = store.activePaneRuntimeContext else { return nil }
        guard context.workbenchID == workbenchID else { return nil }
        guard context.tileID == tile.id else { return nil }
        return (
            desiredPaneRef: context.desiredPaneRef?.matches(sessionRef: sessionRef) == true
                ? context.desiredPaneRef
                : nil,
            observedPaneRef: context.observedPaneRef?.matches(sessionRef: sessionRef) == true
                ? context.observedPaneRef
                : nil,
            focusRequestNonce: context.focusRequestNonce
        )
    }

    private var desiredPaneRef: ActivePaneRef? {
        activePaneRuntimeContext?.desiredPaneRef
    }

    private var observedPaneRef: ActivePaneRef? {
        activePaneRuntimeContext?.observedPaneRef
    }

    private var activePaneRef: ActivePaneRef? {
        desiredPaneRef ?? observedPaneRef
    }

    private var focusRestoreNonce: UInt64 {
        activePaneRuntimeContext?.focusRequestNonce ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            tileBackground

            terminalBody

            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString)
                .accessibilityLabel(sessionRef.sessionName)
                .accessibilityValue(accessibilityValue)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusTile(id: tile.id)
        }
        .sheet(isPresented: $isPresentingRebindSheet) {
            WorkbenchTerminalRebindSheetV2(
                tileID: tile.id,
                initialRef: sessionRef,
                hostsConfig: hostsConfig
            )
        }
        .onChange(of: sessionRef) { oldValue, newValue in
            if shouldPreserveFrozenAttachPlan(
                oldValue: oldValue,
                newValue: newValue
            ) {
                return
            }
            frozenAttachPlan = nil
        }
        .task(id: attachPlanFreezeIdentity) {
            freezeAttachPlanIfNeeded()
        }
        .task(id: navigationSyncTaskIdentity) {
            await runNavigationSyncLoop()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var terminalBody: some View {
        switch terminalState {
        case .bootstrapping:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

        case .broken:
            LinearGradient(
                colors: [
                    Color.red.opacity(0.22),
                    Color.black.opacity(0.38)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

        case .ready:
            switch attachResolution {
            case .success(let plan):
                if !rendersGhosttySurface {
                    Color.clear
                } else {
                    GhosttyIslandRepresentable(
                        surfaceID: tile.id,
                        poolKey: plan.surfaceKey,
                        attachCommand: plan.command,
                        surfaceContext: GhosttyTerminalSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tile.id,
                            surfaceKey: plan.surfaceKey,
                            sessionRef: sessionRef
                        ),
                        isFocused: isFocused,
                        focusRestoreNonce: focusRestoreNonce
                    )
                    .id("ghostty-island:\(tile.id.uuidString):\(plan.command)")
                }

            case .failure:
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.22),
                        Color.black.opacity(0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func restoreIssueBody(_ issue: WorkbenchV2TerminalRestoreIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(issue.message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                issueActionButton("Retry", icon: "arrow.clockwise") {
                    retryAttach()
                }
                issueActionButton("Rebind", icon: "link") {
                    isPresentingRebindSheet = true
                }
                issueActionButton("Remove Tile", icon: "trash") {
                    store.removeTile(id: tile.id)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func issueActionButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.90))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.24), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func retryAttach() {
        Task {
            await viewModel.fetchAll()
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .font(.system(size: 11, weight: .bold))

            Text(statusText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(2)
        }
        .foregroundStyle(Color.white.opacity(0.84))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(statusBackground, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString + ".status")
        .accessibilityLabel(accessibilityValue)
        .accessibilityValue(accessibilityValue)
    }

    private func navigationHintBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.18), in: Capsule(style: .continuous))
            .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString + ".target")
    }

    private var targetBadgeText: String {
        switch terminalState {
        case .bootstrapping:
            return "sync"
        case .broken:
            return "error"
        case .ready:
            break
        }
        switch attachResolution {
        case .success(let plan):
            switch plan.transport {
            case .local:
                return "local"
            case .ssh:
                return "ssh"
            case .mosh:
                return "mosh"
            }
        case .failure:
            return "error"
        }
    }

    private var detailText: String {
        var segments = [detailTargetText]
        if let repoRoot = sessionRef.lastSeenRepoRoot,
           !repoRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(repoRoot)
        }
        return segments.joined(separator: " • ")
    }

    private var detailTargetText: String {
        switch terminalState {
        case .bootstrapping, .broken:
            return sessionRef.target.label
        case .ready:
            break
        }
        switch attachResolution {
        case .success(let plan):
            switch plan.transport {
            case .local:
                return "local"
            case .ssh, .mosh:
                return "\(plan.displayTarget)"
            }
        case .failure(let error):
            return error.errorDescription ?? sessionRef.target.label
        }
    }

    private var statusText: String {
        switch terminalState {
        case .bootstrapping:
            return "Restoring session inventory…"
        case .broken(let restoreIssue):
            return "\(restoreIssue.title): \(restoreIssue.message)"
        case .ready:
            break
        }
        if let navigationSyncErrorMessage {
            return navigationSyncErrorMessage
        }
        switch attachResolution {
        case .success(let plan):
            switch plan.transport {
            case .local:
                return "Direct attach: local session \(sessionRef.sessionName)"
            case .ssh:
                return "Direct attach over ssh: session \(sessionRef.sessionName)"
            case .mosh:
                return "Direct attach over mosh: session \(sessionRef.sessionName)"
            }
        case .failure(let error):
            return error.errorDescription ?? "Attach failed"
        }
    }

    private var accessibilityValue: String {
        if let navigationHintText {
            return "\(statusText) • \(navigationHintText)"
        }
        return statusText
    }

    private var navigationHintText: String? {
        switch (activePaneRef?.windowID, activePaneRef?.paneID) {
        case let (.some(windowID), .some(paneID)):
            return "target \(windowID)/\(paneID)"
        case let (.some(windowID), nil):
            return "target \(windowID)"
        case let (nil, .some(paneID)):
            return "target \(paneID)"
        case (nil, nil):
            return nil
        }
    }

    private var statusIconName: String {
        switch terminalState {
        case .bootstrapping:
            return "arrow.triangle.2.circlepath"
        case .broken:
            return "exclamationmark.triangle.fill"
        case .ready:
            break
        }
        if navigationSyncErrorMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        switch attachResolution {
        case .success:
            return "play.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusBackground: Color {
        switch terminalState {
        case .bootstrapping:
            return Color.black.opacity(0.28)
        case .broken:
            return Color.red.opacity(0.28)
        case .ready:
            break
        }
        if navigationSyncErrorMessage != nil {
            return Color.red.opacity(0.28)
        }
        switch attachResolution {
        case .success:
            return Color.black.opacity(0.28)
        case .failure:
            return Color.red.opacity(0.28)
        }
    }

    private var shouldRunNavigationSync: Bool {
        guard isFocused else { return false }
        guard terminalState == .ready else { return false }
        guard case .success = attachResolution else { return false }
        return true
    }

    private var navigationSyncTaskIdentity: String {
        let focused = isFocused ? "1" : "0"
        let ready = terminalState == .ready ? "1" : "0"
        let windowID = activePaneRef?.windowID ?? ""
        let paneID = activePaneRef?.paneID ?? ""
        return "\(tile.id.uuidString)|\(focused)|\(ready)|\(sessionRef.target.label)|\(sessionRef.sessionName)|\(windowID)|\(paneID)"
    }

    @MainActor
    private func runNavigationSyncLoop() async {
        guard shouldRunNavigationSync else {
            navigationSyncErrorMessage = nil
            return
        }

        // TmuxControlMode が利用可能なら event-driven パスへ
        if let controlMode = resolveControlMode(for: sessionRef) {
            await runNavigationSyncLoopControlMode(controlMode: controlMode)
            // Release the focus lease: stop the tmux -C process when this tile's
            // navigation task exits (cancelled on blur or snapshot stale).
            if case .local = sessionRef.target {
                await TmuxControlModeRegistry.shared.stopMonitoring(
                    sessionName: sessionRef.sessionName,
                    source: "local"
                )
            }
            return
        }

        // fallback: polling loop (1500ms — reduced from 400ms to cut subprocess spawn rate)
        do {
            while !Task.isCancelled {
                guard let renderedState = GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tile.id),
                      let renderedClientTTY = renderedState.clientTTY else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                guard navigationTaskSnapshotIsCurrent else { return }
                let liveTarget: WorkbenchV2TerminalLiveTarget
                do {
                    liveTarget = try await WorkbenchV2TerminalNavigationResolver.liveTarget(
                        renderedClientTTY: renderedClientTTY,
                        target: sessionRef.target,
                        hostsConfig: hostsConfig
                    )
                } catch let error as WorkbenchV2TerminalNavigationError {
                    switch error {
                    case .renderedClientUnavailable:
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    case .missingRemoteHostKey, .activePaneUnavailable:
                        throw error
                    }
                }
                guard navigationTaskSnapshotIsCurrent else { return }
                if liveTarget.sessionName != sessionRef.sessionName {
                    let didChange = try store.syncTerminalObservation(
                        tileID: tile.id,
                        observedSessionName: liveTarget.sessionName,
                        preferredWindowID: liveTarget.windowID,
                        preferredPaneID: liveTarget.paneID,
                        paneInstanceID: livePaneInstanceID(for: liveTarget)
                    )
                    navigationSyncErrorMessage = nil
                    try await Task.sleep(for: .milliseconds(didChange ? 100 : 1500))
                    continue
                }
                if WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
                    desiredPaneRef: desiredPaneRef,
                    observedPaneRef: liveObservedPaneRef(from: liveTarget),
                    liveTarget: liveTarget
                ) {
                    if let desiredPaneRef {
                        try await WorkbenchV2TerminalNavigationResolver.applyNavigationIntent(
                            activePaneRef: desiredPaneRef,
                            renderedClientTTY: renderedClientTTY,
                            hostsConfig: hostsConfig
                        )
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                }
                navigationSyncErrorMessage = nil
                store.syncTerminalNavigation(
                    tileID: tile.id,
                    preferredWindowID: liveTarget.windowID,
                    preferredPaneID: liveTarget.paneID,
                    paneInstanceID: livePaneInstanceID(for: liveTarget)
                )
                try await Task.sleep(for: .milliseconds(1500))
            }
        } catch is CancellationError {
            return
        } catch let error as WorkbenchV2TerminalNavigationError {
            navigationSyncErrorMessage = error.localizedDescription
        } catch {
            navigationSyncErrorMessage = error.localizedDescription
        }
    }

    /// Returns a TmuxControlMode for this session if one is available.
    ///
    /// For local sessions: gets-or-creates the control mode and starts monitoring.
    /// For remote sessions: only returns an existing (already-started) mode to avoid
    /// creating unnecessary SSH connections.
    @MainActor
    private func resolveControlMode(for ref: SessionRef) -> TmuxControlMode? {
        switch ref.target {
        case .local:
            // Get-or-create and start monitoring for local sessions
            TmuxControlModeRegistry.shared.startMonitoring(
                sessionName: ref.sessionName,
                source: "local"
            )
            return TmuxControlModeRegistry.shared.mode(for: ref.sessionName, source: "local")
        case .remote:
            // For remote sessions, only use a control mode if already registered
            return TmuxControlModeRegistry.shared.existingMode(
                for: ref.sessionName,
                source: selectionSource
            )
        }
    }

    @MainActor
    private func runNavigationSyncLoopControlMode(controlMode: TmuxControlMode) async {
        for await event in controlMode.events {
            guard !Task.isCancelled else { return }
            // Skip terminal output events — navigation only cares about layout/session events
            if case .output = event { continue }
            guard navigationTaskSnapshotIsCurrent else { return }

            switch event {
            case .windowPaneChanged(let windowId, let paneId):
                // Active pane changed within the current session
                navigationSyncErrorMessage = nil
                store.syncTerminalNavigation(
                    tileID: tile.id,
                    preferredWindowID: windowId,
                    preferredPaneID: paneId,
                    paneInstanceID: nil
                )
                // If a desired pane is set and differs, apply intent via control mode
                if let desired = desiredPaneRef, desired.paneID != paneId {
                    try? await controlMode.send(command: "select-pane -t \(desired.paneID)")
                }

            case .sessionChanged(_, let sessionName):
                // The client switched to a different session
                navigationSyncErrorMessage = nil
                _ = try? store.syncTerminalObservation(
                    tileID: tile.id,
                    observedSessionName: sessionName,
                    preferredWindowID: nil,
                    preferredPaneID: nil,
                    paneInstanceID: nil
                )

            case .sessionWindowChanged(_, let windowId):
                // Active window changed within the current session
                navigationSyncErrorMessage = nil
                store.syncTerminalNavigation(
                    tileID: tile.id,
                    preferredWindowID: windowId,
                    preferredPaneID: nil,
                    paneInstanceID: nil
                )
                // If a desired pane is set, apply intent via control mode
                if let desired = desiredPaneRef {
                    try? await controlMode.send(command: "select-pane -t \(desired.paneID)")
                }

            default:
                break
            }
        }
    }

    private var navigationTaskSnapshotIsCurrent: Bool {
        guard let context = store.focusedTerminalTileContext else { return false }
        guard context.workbenchID == workbenchID else { return false }
        guard context.tileID == tile.id else { return false }
        guard context.sessionRef.target == sessionRef.target else { return false }
        guard context.sessionRef.sessionName == sessionRef.sessionName else { return false }
        return activePaneRuntimeContext?.desiredPaneRef == desiredPaneRef
            && activePaneRuntimeContext?.observedPaneRef == observedPaneRef
    }

    private var attachPlanFreezeIdentity: String {
        let desiredWindowID = desiredPaneRef?.windowID ?? ""
        let desiredPaneID = desiredPaneRef?.paneID ?? ""
        let observedWindowID = observedPaneRef?.windowID ?? ""
        let observedPaneID = observedPaneRef?.paneID ?? ""
        let readiness = terminalState == .ready ? "ready" : "not-ready"
        return [
            sessionRef.target.label,
            sessionRef.sessionName,
            desiredWindowID,
            desiredPaneID,
            observedWindowID,
            observedPaneID,
            readiness
        ].joined(separator: "|")
    }

    @MainActor
    private func freezeAttachPlanIfNeeded() {
        guard frozenAttachPlan == nil else { return }
        guard terminalState == .ready else { return }
        guard case .success(let plan) = liveAttachResolution else { return }
        frozenAttachPlan = plan
    }

    @MainActor
    private func shouldPreserveFrozenAttachPlan(
        oldValue: SessionRef,
        newValue: SessionRef
    ) -> Bool {
        guard oldValue.target == newValue.target else { return false }
        guard oldValue.sessionName != newValue.sessionName else { return false }
        guard frozenAttachPlan != nil else { return false }
        guard terminalState == .ready else { return false }
        return GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tile.id)?.clientTTY != nil
    }

    private var selectionSource: String {
        switch sessionRef.target {
        case .local:
            return "local"
        case .remote(let hostKey):
            return hostsConfig.host(id: hostKey)?.hostname ?? hostKey
        }
    }

    private func livePaneInstanceID(
        for liveTarget: WorkbenchV2TerminalLiveTarget
    ) -> AgtmuxSyncV2PaneInstanceID? {
        let matches = viewModel.panes.filter { pane in
            pane.source == selectionSource
                && pane.sessionName == liveTarget.sessionName
                && pane.windowId == liveTarget.windowID
                && pane.paneId == liveTarget.paneID
        }
        guard matches.count == 1 else { return nil }
        return matches[0].paneInstanceID
    }

    private func liveObservedPaneRef(
        from liveTarget: WorkbenchV2TerminalLiveTarget
    ) -> ActivePaneRef? {
        ActivePaneRef(
            target: sessionRef.target,
            sessionName: liveTarget.sessionName,
            windowID: liveTarget.windowID,
            paneID: liveTarget.paneID,
            paneInstanceID: livePaneInstanceID(for: liveTarget)
        )
    }

    private var tileBackground: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.black.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

private struct WorkbenchTilePlaceholderViewV2: View {
    let tile: WorkbenchTile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))

                Text(tile.kind.displayTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if tile.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }

            Text(detailText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.68))
                .lineLimit(3)

            Spacer(minLength: 0)

            Text(statusLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tileBackground)
        .overlay(tileBorder)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString)
        .accessibilityLabel(tile.kind.displayTitle)
        .accessibilityValue(statusLabel)
    }

    private var iconName: String {
        switch tile.kind {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .document:
            return "doc.text"
        }
    }

    private var detailText: String {
        tile.kind.detailText
    }

    private var statusLabel: String {
        switch tile.kind {
        case .browser:
            return "Placeholder browser tile"
        case .document:
            return "Placeholder document tile"
        case .terminal:
            return "Terminal tile"
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
}
