import Foundation
import Observation
import AgtmuxTermCore

struct LocalTmuxSocketOverride: Equatable, Hashable, Sendable {
    let socketPath: String

    init?(socketPath: String?) {
        guard let socketPath = socketPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              socketPath.isEmpty == false else {
            return nil
        }
        self.socketPath = socketPath
    }

    var tmuxArguments: [String] {
        ["-S", socketPath]
    }

    var shellEscapedArguments: String {
        tmuxArguments.map(LocalTmuxTarget.shellEscaped).joined(separator: " ")
    }

    var surfaceIdentity: String {
        socketPath
    }
}

enum MainTerminalMode: Equatable {
    case plainShell
    case tmux(
        sessionRef: SessionRef,
        requestedPaneRef: ActivePaneRef?,
        resolvedPaneRef: ActivePaneRef?
    )
}

enum MainTerminalDiagnostic: Equatable {
    case sessionMissing(SessionRef)
    case paneMissing(ActivePaneRef)
    case attachFailed(SessionRef, detail: String)
    case retargetFailed(ActivePaneRef, detail: String)
    case restoreFallbackUsed(requested: ActivePaneRef?, resolved: ActivePaneRef)
    case terminalSidebarDrift(requested: ActivePaneRef?, resolved: ActivePaneRef?)

    var code: String {
        switch self {
        case .sessionMissing:
            return "sessionMissing"
        case .paneMissing:
            return "paneMissing"
        case .attachFailed:
            return "attachFailed"
        case .retargetFailed:
            return "retargetFailed"
        case .restoreFallbackUsed:
            return "restoreFallbackUsed"
        case .terminalSidebarDrift:
            return "terminalSidebarDrift"
        }
    }

    var inlineSummary: String {
        switch self {
        case .sessionMissing:
            return "Session missing"
        case .paneMissing:
            return "Pane missing"
        case .attachFailed:
            return "Attach failed"
        case .retargetFailed:
            return "Retarget failed"
        case .restoreFallbackUsed:
            return "Restore fallback"
        case .terminalSidebarDrift:
            return "Terminal drift"
        }
    }

    var detailText: String {
        switch self {
        case .sessionMissing(let sessionRef):
            return "Session target unavailable: no panes are listed for \(sessionRef.sessionName)."
        case .paneMissing(let paneRef):
            return "Pane target unavailable: \(paneRef.sessionName) \(paneRef.windowID) \(paneRef.paneID)."
        case .attachFailed(_, let detail):
            return detail
        case .retargetFailed(_, let detail):
            return detail
        case .restoreFallbackUsed(let requested, let resolved):
            guard let requested else {
                return "Session target fell back to \(resolved.sessionName) \(resolved.windowID) \(resolved.paneID)."
            }
            return "Restore fallback used for \(requested.sessionName) \(requested.windowID) \(requested.paneID) -> \(resolved.sessionName) \(resolved.windowID) \(resolved.paneID)."
        case .terminalSidebarDrift(let requested, let resolved):
            let requestedLabel = requested.map(Self.paneLabel(for:)) ?? "none"
            let resolvedLabel = resolved.map(Self.paneLabel(for:)) ?? "none"
            return "Terminal/sidebar drift detected: requested=\(requestedLabel), resolved=\(resolvedLabel)."
        }
    }

    private static func paneLabel(for paneRef: ActivePaneRef) -> String {
        "\(paneRef.sessionName) \(paneRef.windowID) \(paneRef.paneID)"
    }
}

struct MainTerminalAttachPlan: Equatable {
    let command: String
    let surfaceKey: String
    let transport: TerminalTransport
    let displayTarget: String
}

enum TerminalTransport: String, Equatable {
    case local
    case ssh
    case mosh
}

enum MainTerminalAttachError: LocalizedError, Equatable {
    case missingRemoteHostKey(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteHostKey(let hostKey):
            return "Attach failed: missing configured remote host '\(hostKey)'"
        }
    }
}

enum MainTerminalAttachResolver {
    static func resolve(
        sessionRef: SessionRef,
        activePaneRef: ActivePaneRef? = nil,
        hostsConfig: HostsConfig,
        env: [String: String] = ProcessInfo.processInfo.environment,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) -> Result<MainTerminalAttachPlan, MainTerminalAttachError> {
        let baseCommand = telemetryWrappedCommand(
            directAttachCommand(
                sessionRef: sessionRef,
                activePaneRef: activePaneRef,
                env: env,
                localSocketOverride: localSocketOverride
            )
        )

        switch sessionRef.target {
        case .local:
            return .success(
                MainTerminalAttachPlan(
                    command: baseCommand,
                    surfaceKey: surfaceKey(for: sessionRef, localSocketOverride: localSocketOverride),
                    transport: .local,
                    displayTarget: "local"
                )
            )

        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                return .failure(.missingRemoteHostKey(hostKey))
            }

            let remoteCommand = LocalTmuxTarget.shellEscaped(baseCommand)
            let command: String
            let transport: TerminalTransport

            switch host.transport {
            case .ssh:
                command = "ssh -t \(host.sshTarget) \(remoteCommand)"
                transport = .ssh
            case .mosh:
                command = "mosh \(host.sshTarget) -- \(remoteCommand)"
                transport = .mosh
            }

            return .success(
                MainTerminalAttachPlan(
                    command: command,
                    surfaceKey: surfaceKey(for: sessionRef, localSocketOverride: localSocketOverride),
                    transport: transport,
                    displayTarget: host.id
                )
            )
        }
    }

    private static func directAttachCommand(
        sessionRef: SessionRef,
        activePaneRef: ActivePaneRef?,
        env: [String: String],
        localSocketOverride: LocalTmuxSocketOverride?
    ) -> String {
        let configSegment = LocalTmuxTarget.shellEscapedConfigArguments(from: env)
        let configArgs = configSegment.isEmpty ? "" : " " + configSegment
        let socketSegment = localSocketOverride?.shellEscapedArguments
            ?? LocalTmuxTarget.shellEscapedSocketArguments(from: env)
        let socketArgs = socketSegment.isEmpty ? "" : " " + socketSegment
        let escapedSessionName = LocalTmuxTarget.shellEscaped(sessionRef.sessionName)
        let tmuxPrefix = "env -u TMUX -u TMUX_PANE tmux\(configArgs)\(socketArgs)"
        var command = tmuxPrefix
        var scrollbackSeedCommand: String?
        if let activePaneRef,
           activePaneRef.target == sessionRef.target,
           activePaneRef.sessionName == sessionRef.sessionName {
            let normalizedWindowID = activePaneRef.windowID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPaneID = activePaneRef.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedWindowID.isEmpty, !normalizedPaneID.isEmpty else {
                command += " attach-session -t \(escapedSessionName)"
                return command
            }
            let escapedWindowID = LocalTmuxTarget.shellEscaped(normalizedWindowID)
            let escapedPaneID = LocalTmuxTarget.shellEscaped(normalizedPaneID)
            scrollbackSeedCommand = "\(tmuxPrefix) capture-pane -p -e -S -2000 -t \(escapedPaneID) 2>/dev/null || true"
            command += " select-window -t \(escapedWindowID) \\;"
            command += " select-pane -t \(escapedPaneID) \\;"
        }
        command += " attach-session -t \(escapedSessionName)"
        guard let scrollbackSeedCommand else {
            return command
        }
        let script = """
        \(scrollbackSeedCommand)
        exec \(command)
        """
        return "/bin/sh -lc \(LocalTmuxTarget.shellEscaped(script))"
    }

    private static func telemetryWrappedCommand(_ command: String) -> String {
        let telemetryScript = """
        tty_path=$(tty 2>/dev/null || true)
        if [ -n "$tty_path" ]; then
          printf '\\033]\(GhosttyCLIOSCBridge.command);{"version":1,"action":"bind_client","client_tty":"%s"}\\007' "$tty_path"
        fi
        exec \(command)
        """
        return "/bin/sh -lc \(LocalTmuxTarget.shellEscaped(telemetryScript))"
    }

    private static func surfaceKey(
        for sessionRef: SessionRef,
        localSocketOverride: LocalTmuxSocketOverride?
    ) -> String {
        switch sessionRef.target {
        case .local:
            if let localSocketOverride {
                return "main-terminal:local:\(localSocketOverride.surfaceIdentity):\(sessionRef.sessionName)"
            }
            return "main-terminal:local:\(sessionRef.sessionName)"
        case .remote(let hostKey):
            return "main-terminal:remote:\(hostKey):\(sessionRef.sessionName)"
        }
    }
}

struct MainTerminalStoreDependencies {
    var liveTarget: @Sendable (SessionRef, HostsConfig, LocalTmuxSocketOverride?) async throws -> TerminalLiveTarget
    var liveWindowTarget: @Sendable (SessionRef, String, HostsConfig, LocalTmuxSocketOverride?) async throws -> TerminalLiveTarget
    var renderedLiveTarget: @Sendable (String, TargetRef, HostsConfig, LocalTmuxSocketOverride?) async throws -> TerminalLiveTarget
    var renderedState: @MainActor (UUID) -> GhosttyRenderedTerminalSurfaceState?
    var applyNavigationIntent: @Sendable (ActivePaneRef, String, HostsConfig, LocalTmuxSocketOverride?) async throws -> Void
    var sleep: @Sendable (Duration) async throws -> Void

    static func live() -> Self {
        Self(
            liveTarget: { sessionRef, hostsConfig, localSocketOverride in
                try await MainTerminalNavigationResolver.liveTarget(
                    sessionRef: sessionRef,
                    hostsConfig: hostsConfig,
                    localSocketOverride: localSocketOverride
                )
            },
            liveWindowTarget: { sessionRef, windowID, hostsConfig, localSocketOverride in
                try await MainTerminalNavigationResolver.liveTarget(
                    sessionRef: sessionRef,
                    windowID: windowID,
                    hostsConfig: hostsConfig,
                    localSocketOverride: localSocketOverride
                )
            },
            renderedLiveTarget: { renderedClientTTY, target, hostsConfig, localSocketOverride in
                try await MainTerminalNavigationResolver.liveTarget(
                    renderedClientTTY: renderedClientTTY,
                    target: target,
                    hostsConfig: hostsConfig,
                    localSocketOverride: localSocketOverride
                )
            },
            renderedState: { surfaceID in
                GhosttyTerminalSurfaceRegistry.shared.renderedState(forSurfaceID: surfaceID)
            },
            applyNavigationIntent: { activePaneRef, renderedClientTTY, hostsConfig, localSocketOverride in
                try await MainTerminalNavigationResolver.applySessionNavigationIntent(
                    activePaneRef: activePaneRef,
                    hostsConfig: hostsConfig,
                    localSocketOverride: localSocketOverride
                )
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }
}

@Observable
@MainActor
final class MainTerminalStore {
    let viewportID: UUID
    let surfaceID: UUID

    private(set) var mode: MainTerminalMode
    private(set) var focusRequestNonce: UInt64
    private(set) var diagnostic: MainTerminalDiagnostic?
    private(set) var attachSurfaceGeneration: UInt64

    @ObservationIgnored private let dependencies: MainTerminalStoreDependencies
    @ObservationIgnored private var lastRestoreTargetBySession: [SessionRef: ActivePaneRef]
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var navigationGeneration: UInt64
    @ObservationIgnored private var localSocketOverride: LocalTmuxSocketOverride?

    init(
        viewportID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        mode: MainTerminalMode = .plainShell,
        focusRequestNonce: UInt64 = 0,
        diagnostic: MainTerminalDiagnostic? = nil,
        attachSurfaceGeneration: UInt64 = 0,
        lastRestoreTargetBySession: [SessionRef: ActivePaneRef] = [:],
        localSocketOverride: LocalTmuxSocketOverride? = nil,
        dependencies: MainTerminalStoreDependencies = .live()
    ) {
        self.viewportID = viewportID
        self.surfaceID = surfaceID
        self.mode = mode
        self.focusRequestNonce = focusRequestNonce
        self.diagnostic = diagnostic
        self.attachSurfaceGeneration = attachSurfaceGeneration
        self.lastRestoreTargetBySession = lastRestoreTargetBySession
        self.localSocketOverride = localSocketOverride
        self.dependencies = dependencies
        self.navigationGeneration = 0
    }

    deinit {
        navigationTask?.cancel()
    }

    var sessionRef: SessionRef? {
        guard case .tmux(let sessionRef, _, _) = mode else { return nil }
        return sessionRef
    }

    var requestedPaneRef: ActivePaneRef? {
        guard case .tmux(_, let requestedPaneRef, _) = mode else { return nil }
        return requestedPaneRef
    }

    var resolvedPaneRef: ActivePaneRef? {
        guard case .tmux(_, _, let resolvedPaneRef) = mode else { return nil }
        return resolvedPaneRef
    }

    var highlightedPaneRef: ActivePaneRef? {
        requestedPaneRef ?? resolvedPaneRef
    }

    var visiblePaneIdentity: String? {
        TerminalPaneIdentity.visiblePaneIdentity(for: highlightedPaneRef)
    }

    var currentLocalSocketOverride: LocalTmuxSocketOverride? {
        localSocketOverride
    }

    var diagnosticMessage: String? {
        diagnostic?.detailText
    }

    var diagnosticInlineText: String? {
        diagnostic?.inlineSummary
    }

    var attachResolution: Result<MainTerminalAttachPlan, MainTerminalAttachError>? {
        guard let sessionRef else { return nil }
        if let preservedAttachPlan = preservedAttachPlan(sessionRef: sessionRef) {
            return .success(preservedAttachPlan)
        }
        return MainTerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            activePaneRef: highlightedPaneRef,
            hostsConfig: currentHostsConfig,
            localSocketOverride: localSocketOverride
        )
    }

    var statusTitle: String {
        switch mode {
        case .plainShell:
            return "Plain Shell"
        case .tmux(let sessionRef, _, _):
            return sessionRef.sessionName
        }
    }

    var statusDetail: String {
        switch mode {
        case .plainShell:
            return "Local shell"
        case .tmux(let sessionRef, _, _):
            switch sessionRef.target {
            case .local:
                return "local"
            case .remote(let hostKey):
                return hostKey
            }
        }
    }

    @ObservationIgnored private var currentHostsConfig: HostsConfig = .empty

    func startPlainShell() {
        currentHostsConfig = .empty
        localSocketOverride = nil
        diagnostic = nil
        navigationGeneration &+= 1
        navigationTask?.cancel()
        navigationTask = nil
        attachSurfaceGeneration &+= 1
        mode = .plainShell
        focusRequestNonce &+= 1
    }

    func activate(session: SessionGroup, hostsConfig: HostsConfig) async {
        let sessionRef = Self.sessionRef(for: session, hostsConfig: hostsConfig)
        let sessionTarget = await resolveSessionTarget(
            session: session,
            sessionRef: sessionRef,
            hostsConfig: hostsConfig
        )
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: sessionTarget.paneRef,
            hostsConfig: hostsConfig,
            diagnostic: sessionTarget.diagnostic
        )
    }

    func activate(
        sessionRef: SessionRef,
        requestedPaneRef: ActivePaneRef?,
        hostsConfig: HostsConfig,
        diagnostic: MainTerminalDiagnostic? = nil,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) {
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: requestedPaneRef,
            hostsConfig: hostsConfig,
            diagnostic: diagnostic,
            localSocketOverride: localSocketOverride
        )
    }

    func activate(window: AgtmuxTermCore.WindowGroup, hostsConfig: HostsConfig) async {
        guard let fallbackPane = window.panes.first else {
            let sessionRef = SessionRef(
                target: Self.targetRef(for: window.source, hostsConfig: hostsConfig),
                sessionName: window.sessionName
            )
            diagnostic = .attachFailed(
                sessionRef,
                detail: "Window target unavailable: no panes are listed for \(window.windowId)."
            )
            return
        }
        let sessionRef = Self.sessionRef(for: fallbackPane, hostsConfig: hostsConfig)
        let fallbackPaneRef = Self.activePaneRef(for: fallbackPane, hostsConfig: hostsConfig)
        let target = await resolveWindowTarget(
            sessionRef: sessionRef,
            windowID: window.windowId,
            fallbackPaneRef: fallbackPaneRef,
            requestedPaneRefForDiagnostic: nil,
            hostsConfig: hostsConfig
        )
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: target.paneRef,
            hostsConfig: hostsConfig,
            diagnostic: target.diagnostic
        )
    }

    func activate(
        pane: AgtmuxPane,
        hostsConfig: HostsConfig,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) async {
        let sessionRef = Self.sessionRef(for: pane, hostsConfig: hostsConfig)
        let requestedPaneRef = Self.activePaneRef(for: pane, hostsConfig: hostsConfig)
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: requestedPaneRef,
            hostsConfig: hostsConfig,
            diagnostic: nil,
            localSocketOverride: localSocketOverride
        )
    }

    func selectedPaneInventoryID(
        panes: [AgtmuxPane],
        hostsConfig: HostsConfig
    ) -> String? {
        guard let paneRef = highlightedPaneRef else { return nil }
        return PaneSelectionResolver.resolvePaneInventoryID(
            source: Self.source(for: paneRef.target, hostsConfig: hostsConfig),
            activePaneRef: paneRef,
            panes: panes
        )
    }

    private func activateTmux(
        sessionRef: SessionRef,
        requestedPaneRef: ActivePaneRef?,
        hostsConfig: HostsConfig,
        diagnostic: MainTerminalDiagnostic? = nil,
        localSocketOverride: LocalTmuxSocketOverride? = nil
    ) {
        if shouldResetSurface(for: sessionRef, localSocketOverride: localSocketOverride) {
            attachSurfaceGeneration &+= 1
        }
        currentHostsConfig = hostsConfig
        self.localSocketOverride = localSocketOverride
        self.diagnostic = diagnostic
        mode = .tmux(
            sessionRef: sessionRef,
            requestedPaneRef: TerminalPaneIdentity.normalized(requestedPaneRef),
            resolvedPaneRef: nil
        )
        focusRequestNonce &+= 1
        restartNavigationTask()
    }

    private func resolveSessionTarget(
        session: SessionGroup,
        sessionRef: SessionRef,
        hostsConfig: HostsConfig
    ) async -> (paneRef: ActivePaneRef?, diagnostic: MainTerminalDiagnostic?) {
        if let liveTarget = try? await dependencies.liveTarget(
            sessionRef,
            hostsConfig,
            localSocketOverride
        ) {
            return (
                paneRef: Self.activePaneRef(
                    target: sessionRef.target,
                    sessionName: sessionRef.sessionName,
                    windowID: liveTarget.windowID,
                    paneID: liveTarget.paneID
                ),
                diagnostic: nil
            )
        }
        if let restoredPaneRef = lastRestoreTargetBySession[sessionRef] {
            return (
                paneRef: restoredPaneRef,
                diagnostic: .restoreFallbackUsed(requested: nil, resolved: restoredPaneRef)
            )
        }
        guard let fallbackPane = session.windows.first?.panes.first else {
            return (
                paneRef: nil,
                diagnostic: .sessionMissing(sessionRef)
            )
        }
        let fallbackPaneRef = Self.activePaneRef(for: fallbackPane, hostsConfig: hostsConfig)
        return (
            paneRef: fallbackPaneRef,
            diagnostic: .restoreFallbackUsed(requested: nil, resolved: fallbackPaneRef)
        )
    }

    private func resolveWindowTarget(
        sessionRef: SessionRef,
        windowID: String,
        fallbackPaneRef: ActivePaneRef,
        requestedPaneRefForDiagnostic: ActivePaneRef?,
        hostsConfig: HostsConfig
    ) async -> (paneRef: ActivePaneRef, diagnostic: MainTerminalDiagnostic?) {
        if let liveTarget = try? await dependencies.liveWindowTarget(
            sessionRef,
            windowID,
            hostsConfig,
            localSocketOverride
        ) {
            return (
                paneRef: Self.activePaneRef(
                    target: sessionRef.target,
                    sessionName: sessionRef.sessionName,
                    windowID: liveTarget.windowID,
                    paneID: liveTarget.paneID
                ),
                diagnostic: nil
            )
        }
        if let restoredPaneRef = lastRestoreTargetBySession[sessionRef],
           restoredPaneRef.windowID == windowID {
            return (
                paneRef: restoredPaneRef,
                diagnostic: fallbackDiagnostic(
                    requestedPaneRef: requestedPaneRefForDiagnostic,
                    resolvedPaneRef: restoredPaneRef
                )
            )
        }
        return (
            paneRef: fallbackPaneRef,
            diagnostic: fallbackDiagnostic(
                requestedPaneRef: requestedPaneRefForDiagnostic,
                resolvedPaneRef: fallbackPaneRef
            )
        )
    }

    private func restartNavigationTask() {
        navigationGeneration &+= 1
        let currentGeneration = navigationGeneration
        navigationTask?.cancel()
        guard case .tmux = mode else {
            navigationTask = nil
            return
        }

        navigationTask = Task { @MainActor [weak self] in
            await self?.runNavigationLoop(generation: currentGeneration)
        }
    }

    private func runNavigationLoop(generation: UInt64) async {
        while !Task.isCancelled {
            guard navigationGeneration == generation else { return }
            guard case .tmux(let sessionRef, _, _) = mode else { return }

            let liveTarget: TerminalLiveTarget
            do {
                liveTarget = try await dependencies.liveTarget(
                    sessionRef,
                    currentHostsConfig,
                    localSocketOverride
                )
            } catch let error as MainTerminalNavigationError {
                switch error {
                case .activePaneUnavailable:
                    do {
                        try await dependencies.sleep(.milliseconds(20))
                    } catch {
                        return
                    }
                    continue
                case .missingRemoteHostKey, .renderedClientUnavailable:
                    diagnostic = .attachFailed(sessionRef, detail: error.localizedDescription)
                    do {
                        try await dependencies.sleep(.milliseconds(50))
                    } catch {
                        return
                    }
                    continue
                }
            } catch {
                diagnostic = .attachFailed(sessionRef, detail: error.localizedDescription)
                do {
                    try await dependencies.sleep(.milliseconds(50))
                } catch {
                    return
                }
                continue
            }

            guard navigationGeneration == generation else { return }
            guard case .tmux(let currentSessionRef, let currentRequestedPaneRef, let currentResolvedPaneRef) = mode else {
                return
            }
            guard currentSessionRef == sessionRef else { return }

            let livePaneRef = Self.activePaneRef(
                target: sessionRef.target,
                sessionName: liveTarget.sessionName,
                windowID: liveTarget.windowID,
                paneID: liveTarget.paneID
            )

            if let currentRequestedPaneRef {
                if Self.samePane(lhs: currentRequestedPaneRef, rhs: livePaneRef) {
                    mode = .tmux(
                        sessionRef: currentSessionRef,
                        requestedPaneRef: nil,
                        resolvedPaneRef: livePaneRef
                    )
                    lastRestoreTargetBySession[sessionRef] = livePaneRef
                    clearTransientDiagnosticIfNeeded()
                    return
                }

                do {
                    try await dependencies.applyNavigationIntent(
                        currentRequestedPaneRef,
                        dependencies.renderedState(surfaceID)?.clientTTY ?? "",
                        currentHostsConfig,
                        localSocketOverride
                    )
                    try await dependencies.sleep(.milliseconds(20))
                } catch {
                    diagnostic = .retargetFailed(
                        currentRequestedPaneRef,
                        detail: error.localizedDescription
                    )
                    try? await dependencies.sleep(.milliseconds(50))
                }
                continue
            }

            if !Self.samePane(lhs: currentResolvedPaneRef, rhs: livePaneRef) {
                mode = .tmux(
                    sessionRef: currentSessionRef,
                    requestedPaneRef: nil,
                    resolvedPaneRef: livePaneRef
                )
                lastRestoreTargetBySession[sessionRef] = livePaneRef
            }
            clearTransientDiagnosticIfNeeded()
            return
        }
    }

    private func clearTransientDiagnosticIfNeeded() {
        switch diagnostic {
        case .attachFailed, .retargetFailed, .sessionMissing, .paneMissing:
            diagnostic = nil
        case .restoreFallbackUsed, .terminalSidebarDrift, .none:
            break
        }
    }

    private func shouldResetSurface(
        for nextSessionRef: SessionRef,
        localSocketOverride nextLocalSocketOverride: LocalTmuxSocketOverride?
    ) -> Bool {
        let renderedClientTTY = dependencies.renderedState(surfaceID)?.clientTTY?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .plainShell:
            return true
        case .tmux(let currentSessionRef, _, _):
            if currentSessionRef != nextSessionRef {
                return true
            }
            if localSocketOverride != nextLocalSocketOverride {
                return true
            }
            return renderedClientTTY?.isEmpty != false
        }
    }

    private func preservedAttachPlan(sessionRef: SessionRef) -> MainTerminalAttachPlan? {
        guard let renderedState = dependencies.renderedState(surfaceID) else {
            return nil
        }
        guard renderedState.context.sessionRef == sessionRef else {
            return nil
        }
        guard let clientTTY = renderedState.clientTTY?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              clientTTY.isEmpty == false else {
            return nil
        }
        guard case .success(let basePlan) = MainTerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            hostsConfig: currentHostsConfig,
            localSocketOverride: localSocketOverride
        ) else {
            return nil
        }
        guard renderedState.context.surfaceKey == basePlan.surfaceKey else {
            return nil
        }
        return MainTerminalAttachPlan(
            command: renderedState.attachCommand,
            surfaceKey: basePlan.surfaceKey,
            transport: basePlan.transport,
            displayTarget: basePlan.displayTarget
        )
    }

    private static func sessionRef(
        for session: SessionGroup,
        hostsConfig: HostsConfig
    ) -> SessionRef {
        SessionRef(
            target: targetRef(for: session.source, hostsConfig: hostsConfig),
            sessionName: session.sessionName,
            lastSeenRepoRoot: session.panes.compactMap(\.currentPath).first
        )
    }

    private static func sessionRef(
        for pane: AgtmuxPane,
        hostsConfig: HostsConfig
    ) -> SessionRef {
        SessionRef(
            target: targetRef(for: pane.source, hostsConfig: hostsConfig),
            sessionName: pane.sessionName,
            lastSeenRepoRoot: pane.currentPath
        )
    }

    private static func activePaneRef(
        for pane: AgtmuxPane,
        hostsConfig: HostsConfig
    ) -> ActivePaneRef {
        ActivePaneRef(
            target: targetRef(for: pane.source, hostsConfig: hostsConfig),
            sessionName: pane.sessionName,
            windowID: pane.windowId,
            paneID: pane.paneId,
            paneInstanceID: pane.paneInstanceID
        )
    }

    private static func activePaneRef(
        target: TargetRef,
        sessionName: String,
        windowID: String,
        paneID: String
    ) -> ActivePaneRef {
        ActivePaneRef(
            target: target,
            sessionName: sessionName,
            windowID: windowID,
            paneID: paneID
        )
    }

    private static func targetRef(
        for source: String,
        hostsConfig: HostsConfig
    ) -> TargetRef {
        if source == "local" {
            return .local
        }
        return .remote(hostKey: hostsConfig.remoteHostKey(for: source))
    }

    private static func source(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            return hostsConfig.host(id: hostKey)?.hostname ?? hostKey
        }
    }

    private static func samePane(
        lhs: ActivePaneRef?,
        rhs: ActivePaneRef?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.target == rhs.target,
              lhs.sessionName == rhs.sessionName,
              lhs.windowID == rhs.windowID,
              lhs.paneID == rhs.paneID else {
            return false
        }
        switch (lhs.paneInstanceID, rhs.paneInstanceID) {
        case let (.some(left), .some(right)):
            return left == right
        default:
            return true
        }
    }

    private func fallbackDiagnostic(
        requestedPaneRef: ActivePaneRef?,
        resolvedPaneRef: ActivePaneRef
    ) -> MainTerminalDiagnostic? {
        guard let requestedPaneRef else {
            return .restoreFallbackUsed(requested: nil, resolved: resolvedPaneRef)
        }
        guard !Self.samePane(lhs: requestedPaneRef, rhs: resolvedPaneRef) else {
            return nil
        }
        return .restoreFallbackUsed(requested: requestedPaneRef, resolved: resolvedPaneRef)
    }
}
