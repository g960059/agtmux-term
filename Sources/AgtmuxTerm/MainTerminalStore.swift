import Foundation
import Observation
import AgtmuxTermCore

enum MainTerminalMode: Equatable {
    case plainShell
    case tmux(
        sessionRef: SessionRef,
        requestedPaneRef: ActivePaneRef?,
        resolvedPaneRef: ActivePaneRef?
    )
}

struct MainTerminalAttachPlan: Equatable {
    let command: String
    let surfaceKey: String
    let transport: WorkbenchV2TerminalTransport
    let displayTarget: String
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
        hostsConfig: HostsConfig,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<MainTerminalAttachPlan, MainTerminalAttachError> {
        let baseCommand = telemetryWrappedCommand(
            directAttachCommand(
                sessionRef: sessionRef,
                env: env
            )
        )

        switch sessionRef.target {
        case .local:
            return .success(
                MainTerminalAttachPlan(
                    command: baseCommand,
                    surfaceKey: surfaceKey(for: sessionRef),
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
            let transport: WorkbenchV2TerminalTransport

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
                    surfaceKey: surfaceKey(for: sessionRef),
                    transport: transport,
                    displayTarget: host.id
                )
            )
        }
    }

    private static func directAttachCommand(
        sessionRef: SessionRef,
        env: [String: String]
    ) -> String {
        let configSegment = LocalTmuxTarget.shellEscapedConfigArguments(from: env)
        let configArgs = configSegment.isEmpty ? "" : " " + configSegment
        let socketSegment = LocalTmuxTarget.shellEscapedSocketArguments(from: env)
        let socketArgs = socketSegment.isEmpty ? "" : " " + socketSegment
        let escapedSessionName = LocalTmuxTarget.shellEscaped(sessionRef.sessionName)
        return "env -u TMUX -u TMUX_PANE tmux\(configArgs)\(socketArgs) attach-session -t \(escapedSessionName)"
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

    private static func surfaceKey(for sessionRef: SessionRef) -> String {
        switch sessionRef.target {
        case .local:
            return "main-terminal:local:\(sessionRef.sessionName)"
        case .remote(let hostKey):
            return "main-terminal:remote:\(hostKey):\(sessionRef.sessionName)"
        }
    }
}

struct MainTerminalStoreDependencies {
    var liveTarget: @Sendable (SessionRef, HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget
    var renderedLiveTarget: @Sendable (String, TargetRef, HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget
    var renderedState: @MainActor (UUID) -> GhosttyRenderedTerminalSurfaceState?
    var applyNavigationIntent: @Sendable (ActivePaneRef, String, HostsConfig) async throws -> Void
    var sleep: @Sendable (Duration) async throws -> Void

    static func live() -> Self {
        Self(
            liveTarget: { sessionRef, hostsConfig in
                try await WorkbenchV2TerminalNavigationResolver.liveTarget(
                    sessionRef: sessionRef,
                    hostsConfig: hostsConfig
                )
            },
            renderedLiveTarget: { renderedClientTTY, target, hostsConfig in
                try await WorkbenchV2TerminalNavigationResolver.liveTarget(
                    renderedClientTTY: renderedClientTTY,
                    target: target,
                    hostsConfig: hostsConfig
                )
            },
            renderedState: { tileID in
                GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID)
            },
            applyNavigationIntent: { activePaneRef, renderedClientTTY, hostsConfig in
                try await WorkbenchV2TerminalNavigationResolver.applyNavigationIntent(
                    activePaneRef: activePaneRef,
                    renderedClientTTY: renderedClientTTY,
                    hostsConfig: hostsConfig
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
    private(set) var diagnosticMessage: String?

    @ObservationIgnored private let dependencies: MainTerminalStoreDependencies
    @ObservationIgnored private var lastRestoreTargetBySession: [SessionRef: ActivePaneRef]
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var navigationGeneration: UInt64

    init(
        viewportID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        mode: MainTerminalMode = .plainShell,
        focusRequestNonce: UInt64 = 0,
        diagnosticMessage: String? = nil,
        lastRestoreTargetBySession: [SessionRef: ActivePaneRef] = [:],
        dependencies: MainTerminalStoreDependencies = .live()
    ) {
        self.viewportID = viewportID
        self.surfaceID = surfaceID
        self.mode = mode
        self.focusRequestNonce = focusRequestNonce
        self.diagnosticMessage = diagnosticMessage
        self.lastRestoreTargetBySession = lastRestoreTargetBySession
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
        WorkbenchTerminalPaneIdentity.visiblePaneIdentity(for: highlightedPaneRef)
    }

    var attachResolution: Result<MainTerminalAttachPlan, MainTerminalAttachError>? {
        guard let sessionRef else { return nil }
        return MainTerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            hostsConfig: currentHostsConfig
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
            return sessionRef.target.label
        }
    }

    @ObservationIgnored private var currentHostsConfig: HostsConfig = .empty

    func startPlainShell() {
        currentHostsConfig = .empty
        diagnosticMessage = nil
        navigationGeneration &+= 1
        navigationTask?.cancel()
        navigationTask = nil
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
            diagnosticMessage: sessionTarget.diagnosticMessage
        )
    }

    func activate(window: AgtmuxTermCore.WindowGroup, hostsConfig: HostsConfig) async {
        guard let fallbackPane = window.panes.first else {
            diagnosticMessage = "Window target unavailable: no panes are listed for \(window.windowId)."
            return
        }
        let sessionRef = Self.sessionRef(for: fallbackPane, hostsConfig: hostsConfig)
        let requestedPaneRef: ActivePaneRef
        if let liveTarget = try? await dependencies.liveTarget(sessionRef, hostsConfig),
           liveTarget.windowID == window.windowId {
            requestedPaneRef = Self.activePaneRef(
                target: sessionRef.target,
                sessionName: sessionRef.sessionName,
                windowID: liveTarget.windowID,
                paneID: liveTarget.paneID
            )
        } else if let restoredPaneRef = lastRestoreTargetBySession[sessionRef],
                  restoredPaneRef.windowID == window.windowId {
            requestedPaneRef = restoredPaneRef
        } else {
            requestedPaneRef = Self.activePaneRef(for: fallbackPane, hostsConfig: hostsConfig)
        }
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: requestedPaneRef,
            hostsConfig: hostsConfig
        )
    }

    func activate(pane: AgtmuxPane, hostsConfig: HostsConfig) {
        let sessionRef = Self.sessionRef(for: pane, hostsConfig: hostsConfig)
        let requestedPaneRef = Self.activePaneRef(for: pane, hostsConfig: hostsConfig)
        activateTmux(
            sessionRef: sessionRef,
            requestedPaneRef: requestedPaneRef,
            hostsConfig: hostsConfig
        )
    }

    func selectedPaneInventoryID(
        panes: [AgtmuxPane],
        hostsConfig: HostsConfig
    ) -> String? {
        guard let paneRef = highlightedPaneRef else { return nil }
        return WorkbenchV2ActivePaneSelectionResolver.resolvePaneInventoryID(
            source: Self.source(for: paneRef.target, hostsConfig: hostsConfig),
            activePaneRef: paneRef,
            panes: panes
        )
    }

    private func activateTmux(
        sessionRef: SessionRef,
        requestedPaneRef: ActivePaneRef?,
        hostsConfig: HostsConfig,
        diagnosticMessage: String? = nil
    ) {
        currentHostsConfig = hostsConfig
        self.diagnosticMessage = diagnosticMessage
        mode = .tmux(
            sessionRef: sessionRef,
            requestedPaneRef: WorkbenchTerminalPaneIdentity.normalized(requestedPaneRef),
            resolvedPaneRef: nil
        )
        focusRequestNonce &+= 1
        restartNavigationTask()
    }

    private func resolveSessionTarget(
        session: SessionGroup,
        sessionRef: SessionRef,
        hostsConfig: HostsConfig
    ) async -> (paneRef: ActivePaneRef?, diagnosticMessage: String?) {
        if let liveTarget = try? await dependencies.liveTarget(sessionRef, hostsConfig) {
            return (
                paneRef: Self.activePaneRef(
                    target: sessionRef.target,
                    sessionName: sessionRef.sessionName,
                    windowID: liveTarget.windowID,
                    paneID: liveTarget.paneID
                ),
                diagnosticMessage: nil
            )
        }
        if let restoredPaneRef = lastRestoreTargetBySession[sessionRef] {
            return (
                paneRef: restoredPaneRef,
                diagnosticMessage: "Session target fell back to the last restored pane."
            )
        }
        guard let fallbackPane = session.windows.first?.panes.first else {
            return (
                paneRef: nil,
                diagnosticMessage: "Session target unavailable: no panes are listed for \(session.sessionName)."
            )
        }
        return (
            paneRef: Self.activePaneRef(for: fallbackPane, hostsConfig: hostsConfig),
            diagnosticMessage: "Session target fell back to the first listed pane."
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
            guard let renderedClientTTY = dependencies.renderedState(surfaceID)?.clientTTY else {
                do {
                    try await dependencies.sleep(.milliseconds(100))
                } catch {
                    return
                }
                continue
            }

            let liveTarget: WorkbenchV2TerminalLiveTarget
            do {
                liveTarget = try await dependencies.renderedLiveTarget(
                    renderedClientTTY,
                    sessionRef.target,
                    currentHostsConfig
                )
            } catch let error as WorkbenchV2TerminalNavigationError {
                switch error {
                case .renderedClientUnavailable:
                    do {
                        try await dependencies.sleep(.milliseconds(100))
                    } catch {
                        return
                    }
                    continue
                case .missingRemoteHostKey, .activePaneUnavailable:
                    diagnosticMessage = error.localizedDescription
                    do {
                        try await dependencies.sleep(.milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }
            } catch {
                diagnosticMessage = error.localizedDescription
                do {
                    try await dependencies.sleep(.milliseconds(250))
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

            if liveTarget.sessionName == sessionRef.sessionName {
                lastRestoreTargetBySession[sessionRef] = livePaneRef
            }

            if let currentRequestedPaneRef,
               Self.samePane(lhs: currentRequestedPaneRef, rhs: livePaneRef) {
                mode = .tmux(
                    sessionRef: currentSessionRef,
                    requestedPaneRef: nil,
                    resolvedPaneRef: livePaneRef
                )
                diagnosticMessage = nil
                do {
                    try await dependencies.sleep(.milliseconds(1500))
                } catch {
                    return
                }
                continue
            }

            if currentRequestedPaneRef == nil {
                if !Self.samePane(lhs: currentResolvedPaneRef, rhs: livePaneRef) {
                    mode = .tmux(
                        sessionRef: currentSessionRef,
                        requestedPaneRef: nil,
                        resolvedPaneRef: livePaneRef
                    )
                }
                diagnosticMessage = nil
                do {
                    try await dependencies.sleep(.milliseconds(1500))
                } catch {
                    return
                }
                continue
            }

            guard let currentRequestedPaneRef,
                  liveTarget.sessionName == sessionRef.sessionName else {
                do {
                    try await dependencies.sleep(.milliseconds(100))
                } catch {
                    return
                }
                continue
            }

            do {
                try await dependencies.applyNavigationIntent(
                    currentRequestedPaneRef,
                    renderedClientTTY,
                    currentHostsConfig
                )
                diagnosticMessage = nil
                try await dependencies.sleep(.milliseconds(100))
            } catch {
                diagnosticMessage = error.localizedDescription
                try? await dependencies.sleep(.milliseconds(250))
            }
        }
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
}
