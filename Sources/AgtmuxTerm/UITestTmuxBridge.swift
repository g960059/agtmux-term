import Foundation
import AppKit
import AgtmuxTermCore

private func uiTestBridgeDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AGTMUX_UITEST_BRIDGE_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[ui-test-bridge] " + message() + "\n").utf8))
}

/// UITest-only tmux bridge.
///
/// Purpose:
/// - Move tmux command execution from sandboxed XCUITest runner to the app process.
/// - Provide a file-based command channel so UI tests can request tmux operations
///   without invoking `tmux` directly from the runner.
///
/// Enabled only when `AGTMUX_UITEST=1`.
@MainActor
final class UITestTmuxBridge {
    private struct BootstrapScenario: Decodable {
        let sessionName: String
        let windowName: String?
        let paneCount: Int?
        let shellCommand: String?
    }

    private struct BootstrapResult: Codable {
        let ok: Bool
        let sessionName: String?
        let windowID: String?
        let paneIDs: [String]
        let socketPath: String?
        let error: String?
    }

    private struct CommandRequest: Decodable {
        let id: String
        let args: [String]
        let refreshInventory: Bool?
    }

    private struct CommandResponse: Codable {
        let id: String
        let ok: Bool
        let stdout: String
        let error: String?
    }

    private struct ActiveTerminalTargetSnapshot: Codable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let sessionName: String
        let windowID: String
        let paneID: String
        let desiredWindowID: String
        let desiredPaneID: String
        let observedWindowID: String
        let observedPaneID: String
        let focusRequestNonce: UInt64
        let selectedPaneInventoryID: String
        let attachCommand: String
        let renderedAttachCommand: String
        let renderedClientTTY: String
        let renderedClientWindowID: String
        let renderedClientPaneID: String
        let renderedSurfaceGeneration: UInt64
        let controlModeKey: String
        let controlModeState: String
    }

    private struct ActiveDocumentTileSnapshot: Codable {
        let workbenchID: String
        let tileID: String
        let path: String
        let target: String
        let focused: Bool
    }

    struct RenderedTerminalTargetSnapshot: Codable, Equatable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let sessionName: String
        let renderedClientTTY: String
        let renderedClientWindowID: String
        let renderedClientPaneID: String
    }

    struct OpenTerminalForPaneSnapshot: Codable, Equatable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let disposition: String
        let usedSessionOnlyFallback: Bool
        let source: String
        let sessionName: String
        let paneID: String
    }

    private struct FocusStateSnapshot: Codable {
        let appIsActive: Bool
        let keyWindowNumber: Int?
        let keyWindowFirstResponderClass: String?
        let keyWindowFirstResponderDescription: String?
        let tileID: String
        let windowNumber: Int?
        let windowIsKey: Bool
        let windowIsMain: Bool
        let windowFirstResponderClass: String?
        let windowFirstResponderDescription: String?
        let terminalIsFirstResponder: Bool
        let terminalAccessibilityIdentifier: String?
        let terminalKeyDownCount: Int
        let terminalLastKeyCode: UInt16?
        let terminalLastCharacters: String?
        let terminalLastCharactersIgnoringModifiers: String?
        let terminalLastModifierFlagsRawValue: UInt?
        let terminalLastSendKeyResult: Bool?
        let terminalRecentInputEvents: [String]
    }

    private struct ScrollBenchTelemetrySnapshot: Codable {
        let scroll: GhosttyTerminalView.ScrollTelemetrySnapshot
        let island: GhosttyIslandUpdateTelemetry.Snapshot
        let publish: AppViewModel.PublishTelemetrySnapshot
    }

    struct TerminalViewportTextSampleSnapshot: Codable, Equatable {
        let sampleIndex: Int
        let elapsedMs: Double
        let snapshot: GhosttyTerminalView.ViewportTextSnapshot
    }

    struct TerminalViewportTextSamplingSnapshot: Codable, Equatable {
        let samples: [TerminalViewportTextSampleSnapshot]
    }

    private let viewModel: AppViewModel
    private let workbenchStore: WorkbenchStoreV2
    private let enableMetadataMode: @MainActor () async -> Void
    private let resolveDirectLocalPane: @Sendable (_ sessionName: String, _ paneID: String) async throws -> AgtmuxPane?
    private let applyNavigationIntent: @Sendable (_ activePaneRef: ActivePaneRef, _ renderedClientTTY: String, _ hostsConfig: HostsConfig) async throws -> Void
    private let resolveRenderedLiveTarget: @Sendable (_ renderedClientTTY: String, _ target: TargetRef, _ hostsConfig: HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget
    private let env: [String: String]
    private var commandLoopTask: Task<Void, Never>?
    private var createdSessions: Set<String> = []
    private let activeTerminalTargetCommand = "__agtmux_dump_active_terminal_target__"
    private let focusStateCommand = "__agtmux_dump_focus_state__"
    private let activeDocumentTileCommand = "__agtmux_dump_active_document_tile__"
    private let replaceFocusedTextCommand = "__agtmux_replace_focused_text__"
    private let sidebarStateCommand = "__agtmux_dump_sidebar_state__"
    private let enableMetadataCommand = "__agtmux_enable_metadata__"
    private let openTerminalForPaneCommand = "__agtmux_open_terminal_for_pane__"
    private let focusTerminalHostCommand = "__agtmux_focus_terminal_host__"
    private let focusRenderedPaneCommand = "__agtmux_focus_rendered_pane__"
    private let renderedTerminalTargetCommand = "__agtmux_dump_rendered_terminal_target__"
    private let setTerminalHostModeCommand = "__agtmux_set_terminal_host_mode__"
    private let sendTmuxNextPaneKeysCommand = "__agtmux_send_tmux_next_pane_keys__"
    private let resetScrollTelemetryCommand = "__agtmux_reset_scroll_telemetry__"
    private let dumpScrollTelemetryCommand = "__agtmux_dump_scroll_telemetry__"
    private let dumpTerminalViewportTextCommand = "__agtmux_dump_terminal_viewport_text__"
    private let sampleTerminalViewportTextCommand = "__agtmux_sample_terminal_viewport_text__"
    private let bridgeReadyCommand = "__agtmux_tmux_bridge_ready__"
    private var terminalViewRegistrationTimeoutMilliseconds: Int {
        guard let raw = env["AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS"],
              let value = Int(raw),
              value > 0 else {
            return 5_000
        }
        return value
    }

    private var terminalHostMode: TerminalHostMode {
        TerminalHostModeRuntime.shared.resolved(environment: env)
    }

    private var allowSessionOnlyOpenFallback: Bool {
        env["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK"] == "1"
    }

    init(
        viewModel: AppViewModel,
        workbenchStore: WorkbenchStoreV2 = workbenchStoreV2,
        enableMetadataMode: @escaping @MainActor () async -> Void = {},
        resolveDirectLocalPane: @escaping @Sendable (_ sessionName: String, _ paneID: String) async throws -> AgtmuxPane? = { sessionName, paneID in
            let output = try await TmuxCommandRunner.shared.run(
                ["list-panes", "-a", "-F", LocalTmuxInventoryClient.formatString],
                source: "local-default"
            )
            let panes = try LocalTmuxInventoryClient.parse(output: output, source: "local")
            return panes.first(where: { $0.sessionName == sessionName && $0.paneId == paneID })
        },
        applyNavigationIntent: @escaping @Sendable (_ activePaneRef: ActivePaneRef, _ renderedClientTTY: String, _ hostsConfig: HostsConfig) async throws -> Void = { activePaneRef, renderedClientTTY, hostsConfig in
            try await UITestTmuxBridge.applyRenderedPaneNavigation(
                activePaneRef: activePaneRef,
                renderedClientTTY: renderedClientTTY,
                hostsConfig: hostsConfig
            )
        },
        resolveRenderedLiveTarget: @escaping @Sendable (_ renderedClientTTY: String, _ target: TargetRef, _ hostsConfig: HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget = { renderedClientTTY, target, hostsConfig in
            try await WorkbenchV2TerminalNavigationResolver.liveTarget(
                renderedClientTTY: renderedClientTTY,
                target: target,
                hostsConfig: hostsConfig
            )
        },
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.viewModel = viewModel
        self.workbenchStore = workbenchStore
        self.enableMetadataMode = enableMetadataMode
        self.resolveDirectLocalPane = resolveDirectLocalPane
        self.applyNavigationIntent = applyNavigationIntent
        self.resolveRenderedLiveTarget = resolveRenderedLiveTarget
        self.env = env
    }

    func startIfNeeded() async {
        guard env["AGTMUX_UITEST"] == "1" else { return }
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(nil)

        startCommandLoopIfNeeded()

        if let scenarioJSON = env["AGTMUX_UITEST_TMUX_SCENARIO"],
           !scenarioJSON.isEmpty {
            await runBootstrapScenario(from: scenarioJSON)
            return
        }

        await viewModel.fetchAll()
    }

    func shutdown() async {
        commandLoopTask?.cancel()
        _ = await commandLoopTask?.value
        commandLoopTask = nil
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(nil)

        guard env["AGTMUX_UITEST"] == "1" else { return }
        guard env["AGTMUX_UITEST_TMUX_AUTO_CLEANUP"] == "1" else { return }

        for session in createdSessions {
            _ = try? await TmuxCommandRunner.shared.run(
                ["kill-session", "-t", session],
                source: "local"
            )
        }
        createdSessions.removeAll()

        if env["AGTMUX_UITEST_TMUX_KILL_SERVER"] == "1" {
            _ = try? await TmuxCommandRunner.shared.run(
                ["kill-server"],
                source: "local"
            )
        }
    }

    private func runBootstrapScenario(from json: String) async {
        guard let data = json.data(using: .utf8) else {
            writeBootstrapResult(
                BootstrapResult(ok: false, sessionName: nil, windowID: nil, paneIDs: [],
                                socketPath: nil,
                                error: "AGTMUX_UITEST_TMUX_SCENARIO is not valid UTF-8")
            )
            return
        }

        let decoder = JSONDecoder()
        let scenario: BootstrapScenario
        do {
            scenario = try decoder.decode(BootstrapScenario.self, from: data)
        } catch {
            writeBootstrapResult(
                BootstrapResult(ok: false, sessionName: nil, windowID: nil, paneIDs: [],
                                socketPath: nil,
                                error: "scenario decode failed: \(error.localizedDescription)")
            )
            return
        }

        do {
            let windowName = scenario.windowName ?? "main"
            let paneCount = max(1, scenario.paneCount ?? 1)
            let shellCommand = scenario.shellCommand ?? "/bin/sleep 600"
            uiTestBridgeDebugLog(
                "bootstrap start session=\(scenario.sessionName) window=\(windowName) paneCount=\(paneCount)"
            )

            // Ensure idempotency for repeated launches.
            _ = try? await TmuxCommandRunner.shared.run(
                ["kill-session", "-t", scenario.sessionName],
                source: "local"
            )

            _ = try await runBootstrapTmuxCommand(
                ["new-session", "-d", "-s", scenario.sessionName, "-n", windowName, shellCommand],
                step: "new-session"
            )
            createdSessions.insert(scenario.sessionName)

            if paneCount > 1 {
                for _ in 1..<paneCount {
                    _ = try await runBootstrapTmuxCommand(
                        ["split-window", "-t", "\(scenario.sessionName):\(windowName)", "-h", shellCommand],
                        step: "split-window"
                    )
                }
            }

            try await waitForBootstrapPaneInventory(
                sessionName: scenario.sessionName,
                expectedPaneCount: paneCount
            )

            let windowOutput = try await runBootstrapTmuxCommand(
                ["list-windows", "-t", scenario.sessionName, "-F", "#{window_id}"],
                step: "list-windows"
            )
            let windowID = windowOutput
                .components(separatedBy: "\n")
                .first(where: { !$0.isEmpty }) ?? "@0"

            let panesOutput = try await runBootstrapTmuxCommand(
                ["list-panes", "-t", scenario.sessionName, "-F", "#{pane_id}"],
                step: "list-panes"
            )
            let paneIDs = panesOutput
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            let resolvedTmuxSocketPath = try await resolveBootstrapTmuxSocketPath()
            AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(resolvedTmuxSocketPath)

            await viewModel.fetchAll()

            writeBootstrapResult(
                BootstrapResult(
                    ok: true,
                    sessionName: scenario.sessionName,
                    windowID: windowID,
                    paneIDs: paneIDs,
                    socketPath: resolvedTmuxSocketPath,
                    error: nil
                )
            )
        } catch {
            writeBootstrapResult(
                BootstrapResult(ok: false, sessionName: scenario.sessionName, windowID: nil, paneIDs: [],
                                socketPath: nil,
                                error: error.localizedDescription)
            )
        }
    }

    private func startCommandLoopIfNeeded() {
        guard commandLoopTask == nil else { return }
        guard let commandURL = commandURL, let responseURL = commandResponseURL else { return }

        commandLoopTask = Task { [weak self] in
            guard let self else { return }

            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            var lastCommandID: String?

            while !Task.isCancelled {
                guard let data = try? Data(contentsOf: commandURL), !data.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                guard let request = try? decoder.decode(CommandRequest.self, from: data) else {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                uiTestBridgeDebugLog("commandLoop request id=\(request.id) args=\(request.args)")
                if request.id == lastCommandID {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                lastCommandID = request.id

                var response = CommandResponse(
                    id: request.id,
                    ok: false,
                    stdout: "",
                    error: "unknown error"
                )

                if let internalResponse = await handleInternalCommand(request) {
                    response = internalResponse
                } else {
                    do {
                        let stdout = try await TmuxCommandRunner.shared.run(request.args, source: "local")
                        if request.refreshInventory ?? true {
                            await viewModel.fetchAll()
                        }
                        response = CommandResponse(id: request.id, ok: true, stdout: stdout, error: nil)

                        if let session = sessionNameFromNewSessionArgs(request.args) {
                            createdSessions.insert(session)
                        }
                        if let killedSession = sessionNameFromKillSessionArgs(request.args) {
                            createdSessions.remove(killedSession)
                        }
                    } catch {
                        response = CommandResponse(
                            id: request.id,
                            ok: false,
                            stdout: "",
                            error: error.localizedDescription
                        )
                    }
                }

                if let payload = try? encoder.encode(response) {
                    try? payload.write(to: responseURL, options: .atomic)
                    uiTestBridgeDebugLog("commandLoop response id=\(response.id) ok=\(response.ok) args=\(request.args)")
                }

                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private var bootstrapResultURL: URL? {
        guard let path = env["AGTMUX_UITEST_TMUX_RESULT_PATH"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var commandURL: URL? {
        guard let path = env["AGTMUX_UITEST_TMUX_COMMAND_PATH"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var commandResponseURL: URL? {
        guard let path = env["AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func handleInternalCommand(_ request: CommandRequest) async -> CommandResponse? {
        guard let firstArg = request.args.first else { return nil }

        do {
            let stdout: String
            switch firstArg {
            case enableMetadataCommand:
                await enableMetadataMode()
                await viewModel.fetchAll()
                stdout = "ok"
            case activeTerminalTargetCommand:
                let snapshot = try await activeTerminalTargetSnapshot()
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case activeDocumentTileCommand:
                let snapshot = try activeDocumentTileSnapshot()
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case replaceFocusedTextCommand:
                try replaceFocusedText(request.args)
                stdout = "ok"
            case focusStateCommand:
                let snapshot = try focusStateSnapshot(for: request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case openTerminalForPaneCommand:
                if request.refreshInventory ?? false {
                    await viewModel.fetchAll()
                }
                let snapshot = try await openTerminalForPane(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case focusTerminalHostCommand:
                try focusTerminalHost(request.args)
                stdout = "ok"
            case focusRenderedPaneCommand:
                try await focusRenderedPane(request.args)
                stdout = "ok"
            case renderedTerminalTargetCommand:
                let snapshot = try await renderedTerminalTargetSnapshot(for: request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case setTerminalHostModeCommand:
                let mode = try setTerminalHostMode(request.args)
                stdout = mode.rawValue
            case sendTmuxNextPaneKeysCommand:
                try sendTmuxNextPaneKeys(request.args)
                stdout = "ok"
            case resetScrollTelemetryCommand:
                try resetScrollTelemetry(request.args)
                stdout = "ok"
            case dumpScrollTelemetryCommand:
                let snapshot = try dumpScrollTelemetry(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case dumpTerminalViewportTextCommand:
                let snapshot = try dumpTerminalViewportText(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case sampleTerminalViewportTextCommand:
                let snapshot = try await sampleTerminalViewportText(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case bridgeReadyCommand:
                stdout = "ready"
            case sidebarStateCommand:
                let bootstrapProbeSummary: UITestBootstrapProbeSummary
                let bootstrapTargetSummary: UITestBootstrapTargetSummary?
                let requestedSessionName = request.args.dropFirst().first
                let requestedPaneID = request.args.dropFirst().dropFirst().first
                do {
                    let bootstrap = try await AgtmuxDaemonClient().fetchUIBootstrapV3()
                    bootstrapTargetSummary = UITestSidebarDiagnostics.bootstrapTargetSummary(
                        from: bootstrap,
                        requestedSessionName: requestedSessionName,
                        requestedPaneID: requestedPaneID
                    )
                    bootstrapProbeSummary = UITestSidebarDiagnostics.bootstrapProbeSummary(from: bootstrap)
                } catch {
                    bootstrapProbeSummary = UITestSidebarDiagnostics.bootstrapProbeSummary(error: error)
                    bootstrapTargetSummary = nil
                }
                let managedSocketPath = AgtmuxBinaryResolver.resolvedSocketPath(from: env)
                let launchRecord = AgtmuxManagedDaemonRuntime.launchRecord(socketPath: managedSocketPath)
                let bootstrapResolvedSocketPath = AgtmuxManagedDaemonRuntime.bootstrapResolvedTmuxSocketPath()
                let directResolvedSocketProbe = appDirectResolvedSocketProbe(
                    bootstrapResolvedSocketPath
                )
                let snapshot = UITestSidebarStateSnapshot(
                    statusFilter: viewModel.statusFilter.rawValue,
                    panePresentations: viewModel.panes.map(sidebarPanePresentationSnapshot(for:)),
                    filteredPanePresentations: viewModel.filteredPanes.map(sidebarPanePresentationSnapshot(for:)),
                    attentionCount: viewModel.attentionCount,
                    localDaemonIssueTitle: viewModel.localDaemonIssue?.bannerTitle,
                    localDaemonIssueDetail: viewModel.localDaemonIssue?.detail,
                    bootstrapProbeSummary: bootstrapProbeSummary,
                    bootstrapTargetSummary: bootstrapTargetSummary,
                    managedDaemonSocketPath: managedSocketPath,
                    tmuxSocketArguments: LocalTmuxTarget.socketArguments(from: env),
                    daemonCLIArguments: LocalTmuxTarget.daemonCLIArguments(from: env),
                    bootstrapResolvedTmuxSocketPath: bootstrapResolvedSocketPath,
                    appDirectResolvedSocketProbe: directResolvedSocketProbe.output,
                    appDirectResolvedSocketProbeError: directResolvedSocketProbe.error,
                    daemonProcessCommands: AgtmuxManagedDaemonRuntime.daemonProcessCommands(
                        socketPath: managedSocketPath
                    ),
                    daemonLaunchRecord: launchRecord.map {
                        UITestDaemonLaunchRecordSnapshot(
                            binaryPath: $0.binaryPath,
                            arguments: $0.arguments,
                            environment: $0.environment,
                            reusedExistingRuntime: $0.reusedExistingRuntime
                        )
                    },
                    managedDaemonStderrTail: managedDaemonStderrTail()
                )
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            default:
                return nil
            }
            return CommandResponse(id: request.id, ok: true, stdout: stdout, error: nil)
        } catch {
            return CommandResponse(
                id: request.id,
                ok: false,
                stdout: "",
                error: error.localizedDescription
            )
        }
    }

    private func sidebarPanePresentationSnapshot(for pane: AgtmuxPane) -> UITestSidebarPanePresentationSnapshot {
        let display = viewModel.paneDisplayState(for: pane)
        return UITestSidebarDiagnostics.panePresentationSnapshot(
            for: pane,
            display: display
        )
    }

    private func activeTerminalTargetSnapshot() async throws -> ActiveTerminalTargetSnapshot {
        guard let workbench = workbenchStore.activeWorkbench else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No active workbench"]
            )
        }

        let selection = workbenchStore.activePaneSelection(
            panes: viewModel.panes,
            hostsConfig: viewModel.hostsConfig
        )

        guard let selection else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Canonical active terminal target is unresolved"]
            )
        }

        guard let terminalTile = workbench.tiles.first(where: { $0.id == selection.tileID }) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Selected terminal tile is missing from active workbench"]
            )
        }
        guard case .terminal(let sessionRef) = terminalTile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Selected tile is not a terminal tile"]
            )
        }

        guard let activePaneContext = workbenchStore.activePaneContext,
              activePaneContext.workbenchID == selection.workbenchID else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Canonical active pane context is missing"]
            )
        }

        let attachPlan = try WorkbenchV2TerminalAttachResolver.resolve(
            sessionRef: sessionRef,
            activePaneRef: activePaneContext.activePaneRef,
            hostsConfig: viewModel.hostsConfig,
            env: env
        ).get()

        guard let selectedPaneInventoryID = selection.paneInventoryID else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Canonical active pane did not resolve to live inventory"]
            )
        }

        guard let renderedState = GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: terminalTile.id) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface state is missing"]
            )
        }
        guard let renderedClientTTY = renderedState.clientTTY else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface client tty is missing"]
            )
        }

        let renderedClientTarget = try await resolveRenderedLiveTarget(
            renderedClientTTY,
            sessionRef.target,
            viewModel.hostsConfig
        )
        let controlModeKey = WorkbenchFocusedNavigationControlModeKey.make(
            sessionRef: sessionRef,
            hostsConfig: viewModel.hostsConfig
        )
        let controlModeState: String
        if let controlModeKey,
           let mode = TmuxControlModeRegistry.shared.existingMode(
                for: controlModeKey.sessionName,
                source: controlModeKey.source
           ) {
            controlModeState = await mode.connectionState.debugLabel
        } else {
            controlModeState = "missing"
        }

        return ActiveTerminalTargetSnapshot(
            terminalHostMode: terminalHostMode.rawValue,
            workbenchID: selection.workbenchID.uuidString,
            tileID: terminalTile.id.uuidString,
            sessionName: sessionRef.sessionName,
            windowID: selection.windowID,
            paneID: selection.paneID,
            desiredWindowID: activePaneContext.activePaneRef.windowID,
            desiredPaneID: activePaneContext.activePaneRef.paneID,
            observedWindowID: workbenchStore.activePaneRuntimeContext?.observedPaneRef?.windowID ?? "",
            observedPaneID: workbenchStore.activePaneRuntimeContext?.observedPaneRef?.paneID ?? "",
            focusRequestNonce: activePaneContext.focusRequestNonce,
            selectedPaneInventoryID: selectedPaneInventoryID,
            attachCommand: attachPlan.command,
            renderedAttachCommand: renderedState.attachCommand,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: renderedClientTarget.windowID,
            renderedClientPaneID: renderedClientTarget.paneID,
            renderedSurfaceGeneration: renderedState.generation,
            controlModeKey: controlModeKey?.identity ?? "",
            controlModeState: controlModeState
        )
    }

    private func renderedTerminalTargetSnapshot(for args: [String]) async throws -> RenderedTerminalTargetSnapshot {
        let tileID = try tileID(from: args, command: renderedTerminalTargetCommand)
        guard let workbench = workbenchStore.workbenches.first(where: { workbench in
            workbench.tiles.contains(where: { $0.id == tileID })
        }), let terminalTile = workbench.tiles.first(where: { $0.id == tileID }) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "No terminal tile found for tileID \(tileID.uuidString)"]
            )
        }
        guard case .terminal(let sessionRef) = terminalTile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Tile \(tileID.uuidString) is not a terminal tile"]
            )
        }
        guard let renderedState = GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface state is missing"]
            )
        }
        guard let renderedClientTTY = renderedState.clientTTY else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 45,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface client tty is missing"]
            )
        }
        let liveTarget = try? await resolveRenderedLiveTarget(
            renderedClientTTY,
            sessionRef.target,
            viewModel.hostsConfig
        )
        return RenderedTerminalTargetSnapshot(
            terminalHostMode: terminalHostMode.rawValue,
            workbenchID: workbench.id.uuidString,
            tileID: tileID.uuidString,
            sessionName: sessionRef.sessionName,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: liveTarget?.windowID ?? "",
            renderedClientPaneID: liveTarget?.paneID ?? ""
        )
    }

    private func setTerminalHostMode(_ args: [String]) throws -> TerminalHostMode {
        guard args.count >= 2 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 46,
                userInfo: [NSLocalizedDescriptionKey: "\(setTerminalHostModeCommand) requires <legacy|next|default>"]
            )
        }

        let rawValue = args[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawValue {
        case "default", "clear", "reset":
            TerminalHostModeRuntime.shared.setOverride(nil)
        default:
            guard let mode = TerminalHostMode.parse(rawValue) else {
                throw NSError(
                    domain: "UITestTmuxBridge",
                    code: 47,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported terminal host mode: \(args[1])"]
                )
            }
            TerminalHostModeRuntime.shared.setOverride(mode)
        }
        return terminalHostMode
    }

    private func activeDocumentTileSnapshot() throws -> ActiveDocumentTileSnapshot {
        guard let workbench = workbenchStore.activeWorkbench else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "No active workbench"]
            )
        }

        guard let focusedTileID = workbench.focusedTileID,
              let tile = workbench.tiles.first(where: { $0.id == focusedTileID }) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: "No focused tile in active workbench"]
            )
        }
        guard case .document(let ref) = tile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "Focused tile is not a document tile"]
            )
        }

        return ActiveDocumentTileSnapshot(
            workbenchID: workbench.id.uuidString,
            tileID: tile.id.uuidString,
            path: ref.path,
            target: ref.target.label,
            focused: workbench.focusedTileID == tile.id
        )
    }

    private func replaceFocusedText(_ args: [String]) throws {
        guard args.count >= 2 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "\(replaceFocusedTextCommand) requires <value>"]
            )
        }
        guard let keyWindow = NSApp.keyWindow else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 34,
                userInfo: [NSLocalizedDescriptionKey: "No key window for focused text replacement"]
            )
        }
        guard let textView = keyWindow.firstResponder as? NSTextView else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 35,
                userInfo: [NSLocalizedDescriptionKey: "Focused responder is not an NSTextView field editor"]
            )
        }

        let replacement = args[1]
        let currentLength = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: 0, length: currentLength))
        textView.insertText(replacement, replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: replacement.utf16.count, length: 0))
    }

    func openTerminalForPaneForTesting(
        source: String,
        sessionName: String,
        paneID: String
    ) async throws -> OpenTerminalForPaneSnapshot {
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting start source=\(source) session=\(sessionName) pane=\(paneID)"
        )
        let pane: AgtmuxPane
        let usedSessionOnlyFallback: Bool
        if let inventoryPane = viewModel.panes.first(where: {
            $0.source == source && $0.sessionName == sessionName && $0.paneId == paneID
        }) {
            pane = inventoryPane
            usedSessionOnlyFallback = false
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting inventory-hit panes=\(viewModel.panes.count)"
            )
        } else if source == "local",
                  let localPane = viewModel.panes.first(where: {
                      $0.source == "local" && $0.paneId == paneID
                  }) {
            pane = localPane
            usedSessionOnlyFallback = false
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting inventory-paneid-fallback requestedSession=\(sessionName) resolvedSession=\(localPane.sessionName)"
            )
        } else if source == "local",
                  let directPane = try await resolveDirectLocalPane(sessionName, paneID) {
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting default-socket-fallback session=\(sessionName) pane=\(paneID)"
            )
            pane = directPane
            usedSessionOnlyFallback = false
            prepareDirectLocalPaneForRendering(directPane)
        } else if source == "local" && allowSessionOnlyOpenFallback {
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting session-only-fallback session=\(sessionName) pane=\(paneID)"
            )
            prepareDirectLocalSessionForRendering(sessionName)
            let result = workbenchStore.openTerminal(
                sessionRef: SessionRef(target: .local, sessionName: sessionName)
            )
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting session-only-opened tile=\(result.tileID.uuidString)"
            )
            try await waitForTerminalViewRegistration(
                tileID: result.tileID,
                timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
            )
            let disposition: String
            let workbenchID: UUID
            switch result {
            case .opened(let resolvedWorkbenchID, _):
                disposition = "opened"
                workbenchID = resolvedWorkbenchID
            case .revealedExisting(let resolvedWorkbenchID, _):
                disposition = "revealedExisting"
                workbenchID = resolvedWorkbenchID
            }
            return OpenTerminalForPaneSnapshot(
                terminalHostMode: terminalHostMode.rawValue,
                workbenchID: workbenchID.uuidString,
                tileID: result.tileID.uuidString,
                disposition: disposition,
                usedSessionOnlyFallback: true,
                source: source,
                sessionName: sessionName,
                paneID: paneID
            )
        } else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Pane not found for source=\(source) session=\(sessionName) pane=\(paneID)"
                ]
            )
        }
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting pane-found window=\(pane.windowId) path=\(String(describing: pane.currentPath)) sessionOnlyFallback=\(usedSessionOnlyFallback)"
        )
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting store-state workbenches=\(workbenchStore.workbenches.count) activeIndex=\(workbenchStore.activeWorkbenchIndex)"
        )

        let result = workbenchStore.openTerminal(
            for: pane,
            hostsConfig: viewModel.hostsConfig
        )
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting store-opened tile=\(result.tileID.uuidString)"
        )
        try await waitForTerminalViewRegistration(
            tileID: result.tileID,
            timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
        )
        let disposition: String
        let workbenchID: UUID
        switch result {
        case .opened(let resolvedWorkbenchID, _):
            disposition = "opened"
            workbenchID = resolvedWorkbenchID
        case .revealedExisting(let resolvedWorkbenchID, _):
            disposition = "revealedExisting"
            workbenchID = resolvedWorkbenchID
        }

        return OpenTerminalForPaneSnapshot(
            terminalHostMode: terminalHostMode.rawValue,
            workbenchID: workbenchID.uuidString,
            tileID: result.tileID.uuidString,
            disposition: disposition,
            usedSessionOnlyFallback: usedSessionOnlyFallback,
            source: source,
            sessionName: sessionName,
            paneID: paneID
        )
    }

    private func prepareDirectLocalPaneForRendering(_ pane: AgtmuxPane) {
        if let existingIndex = viewModel.panes.firstIndex(where: { $0.id == pane.id }) {
            if viewModel.panes[existingIndex] != pane {
                var panes = viewModel.panes
                panes[existingIndex] = pane
                viewModel.panes = panes
            }
        } else {
            var panes = viewModel.panes
            panes.append(pane)
            viewModel.panes = panes
        }
        prepareDirectLocalSessionForRendering(pane.sessionName)
    }

    private func prepareDirectLocalSessionForRendering(_ sessionName: String) {
        let sessionKey = "local:\(sessionName)"
        if !viewModel.runtimeStore.hasCompletedInitialFetch {
            viewModel.runtimeStore.hasCompletedInitialFetch = true
        }
        if viewModel.runtimeStore.offlineHosts.contains("local") {
            viewModel.runtimeStore.offlineHosts.remove("local")
        }
        if !viewModel.runtimeStore.livePaneSessionKeys.contains(sessionKey) {
            viewModel.runtimeStore.livePaneSessionKeys.insert(sessionKey)
        }
    }

    private func openTerminalForPane(_ args: [String]) async throws -> OpenTerminalForPaneSnapshot {
        guard args.count >= 4 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(openTerminalForPaneCommand) requires <source> <sessionName> <paneID>"
                ]
            )
        }

        let source = args[1]
        let sessionName = args[2]
        let paneID = args[3]
        return try await openTerminalForPaneForTesting(
            source: source,
            sessionName: sessionName,
            paneID: paneID
        )
    }

    private func focusStateSnapshot(for args: [String]) throws -> FocusStateSnapshot {
        guard args.count >= 2 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(focusStateCommand) requires <tileID>"
                ]
            )
        }

        guard let tileID = UUID(uuidString: args[1]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tile id: \(args[1])"]
            )
        }

        let resolvedLeafID = resolvedTerminalLeafID(for: tileID)
        guard let terminalView = SurfacePool.shared.managedView(forLeafID: resolvedLeafID) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "No managed terminal view for tile \(tileID.uuidString)"]
            )
        }

        let terminalWindow = terminalView.window
        let terminalFirstResponder = terminalWindow?.firstResponder
        let keyWindow = NSApp.keyWindow
        let keyWindowFirstResponder = keyWindow?.firstResponder

        return FocusStateSnapshot(
            appIsActive: NSApp.isActive,
            keyWindowNumber: keyWindow?.windowNumber,
            keyWindowFirstResponderClass: keyWindowFirstResponder.map {
                String(describing: type(of: $0))
            },
            keyWindowFirstResponderDescription: keyWindowFirstResponder.map(String.init(describing:)),
            tileID: tileID.uuidString,
            windowNumber: terminalWindow?.windowNumber,
            windowIsKey: terminalWindow?.isKeyWindow ?? false,
            windowIsMain: terminalWindow?.isMainWindow ?? false,
            windowFirstResponderClass: terminalFirstResponder.map {
                String(describing: type(of: $0))
            },
            windowFirstResponderDescription: terminalFirstResponder.map(String.init(describing:)),
            terminalIsFirstResponder: terminalFirstResponder === terminalView,
            terminalAccessibilityIdentifier: terminalView.accessibilityIdentifier(),
            terminalKeyDownCount: terminalView.debugKeyDownCount,
            terminalLastKeyCode: terminalView.debugLastKeyCode,
            terminalLastCharacters: terminalView.debugLastCharacters,
            terminalLastCharactersIgnoringModifiers: terminalView.debugLastCharactersIgnoringModifiers,
            terminalLastModifierFlagsRawValue: terminalView.debugLastModifierFlagsRawValue,
            terminalLastSendKeyResult: terminalView.debugLastSendKeyResult,
            terminalRecentInputEvents: terminalView.debugRecentInputEvents
        )
    }

    private func focusTerminalHost(_ args: [String]) throws {
        let terminalView = try terminalView(for: args, command: focusTerminalHostCommand)
        guard let window = terminalView.window else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 15,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Terminal view window missing for tileID \(args[1])"
                ]
            )
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
    }

    private func focusRenderedPane(_ args: [String]) async throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 48,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(focusRenderedPaneCommand) requires <tileID> <paneID>"
                ]
            )
        }

        let tileID = try tileID(from: args, command: focusRenderedPaneCommand)
        let paneID = args[2]
        uiTestBridgeDebugLog("focusRenderedPane start tileID=\(tileID.uuidString) pane=\(paneID)")
        let sessionRef = try sessionRef(forTileID: tileID)
        uiTestBridgeDebugLog("focusRenderedPane sessionRef session=\(sessionRef.sessionName) target=\(sessionRef.target)")
        guard let renderedClientTTY = GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID)?.clientTTY else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 49,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Rendered Ghostty surface client tty is missing for tileID \(tileID.uuidString)"
                ]
            )
        }
        uiTestBridgeDebugLog("focusRenderedPane renderedClientTTY=\(renderedClientTTY)")

        uiTestBridgeDebugLog("focusRenderedPane applyNavigationIntent start pane=\(paneID)")
        try await applyNavigationIntent(
            ActivePaneRef(
                target: sessionRef.target,
                sessionName: sessionRef.sessionName,
                windowID: "",
                paneID: paneID
            ),
            renderedClientTTY,
            viewModel.hostsConfig
        )
        uiTestBridgeDebugLog("focusRenderedPane applyNavigationIntent done pane=\(paneID)")
    }

    private static func applyRenderedPaneNavigation(
        activePaneRef: ActivePaneRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig
    ) async throws {
        let source = try tmuxSource(for: activePaneRef.target, hostsConfig: hostsConfig)
        let clientName = try await resolveClientName(
            renderedClientTTY: renderedClientTTY,
            source: source
        )
        uiTestBridgeDebugLog(
            "applyRenderedPaneNavigation clientName=\(clientName) tty=\(renderedClientTTY) pane=\(activePaneRef.paneID)"
        )
        _ = try await TmuxCommandRunner.shared.run(
            ["switch-client", "-c", clientName, "-t", activePaneRef.paneID],
            source: source
        )
    }

    private static func resolveClientName(
        renderedClientTTY: String,
        source: String
    ) async throws -> String {
        let output = try await TmuxCommandRunner.shared.run(
            ["list-clients", "-F", "#{client_name}|#{client_tty}"],
            source: source
        )

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            guard fields[1] == renderedClientTTY else { continue }
            guard !fields[0].isEmpty else { continue }
            return fields[0]
        }

        throw NSError(
            domain: "UITestTmuxBridge",
            code: 52,
            userInfo: [NSLocalizedDescriptionKey: "No tmux client name found for rendered tty \(renderedClientTTY)"]
        )
    }

    private static func tmuxSource(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) throws -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                throw WorkbenchV2TerminalNavigationError.missingRemoteHostKey(hostKey)
            }
            return host.sshTarget
        }
    }

    private func sendTmuxNextPaneKeys(_ args: [String]) throws {
        uiTestBridgeDebugLog("sendTmuxNextPaneKeys start args=\(args)")
        let terminalView = try terminalView(for: args, command: sendTmuxNextPaneKeysCommand)
        guard let window = terminalView.window else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 15,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Terminal view window missing for tileID \(args[1])"
                ]
            )
        }

        let tileID = args[1]
        let windowNumber = window.windowNumber
        uiTestBridgeDebugLog("sendTmuxNextPaneKeys schedule tileID=\(tileID) windowNumber=\(windowNumber)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak terminalView] in
            guard let terminalView else { return }
            uiTestBridgeDebugLog("sendTmuxNextPaneKeys fire tileID=\(tileID) windowNumber=\(windowNumber)")
            let sent = terminalView.sendTmuxNextPaneKeysForTesting(windowNumber: windowNumber)
            if !sent {
                FileHandle.standardError.write(
                    Data(("UITestTmuxBridge failed to inject tmux next-pane keys for tileID \(tileID)\n").utf8)
                )
            }
            uiTestBridgeDebugLog("sendTmuxNextPaneKeys done tileID=\(tileID) sent=\(sent)")
        }
        uiTestBridgeDebugLog("sendTmuxNextPaneKeys return tileID=\(tileID)")
    }

    private func resetScrollTelemetry(_ args: [String]) throws {
        let terminalView = try terminalView(for: args, command: resetScrollTelemetryCommand)
        let tileID = try tileID(from: args, command: resetScrollTelemetryCommand)
        terminalView.resetScrollTelemetryForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        GhosttyIslandUpdateTelemetry.shared.reset(tileID: tileID)
        viewModel.resetPublishTelemetryForTesting()
    }

    private func dumpScrollTelemetry(_ args: [String]) throws -> ScrollBenchTelemetrySnapshot {
        let terminalView = try terminalView(for: args, command: dumpScrollTelemetryCommand)
        let tileID = try tileID(from: args, command: dumpScrollTelemetryCommand)
        return ScrollBenchTelemetrySnapshot(
            scroll: terminalView.scrollTelemetrySnapshotForTesting(),
            island: GhosttyIslandUpdateTelemetry.shared.snapshot(tileID: tileID),
            publish: viewModel.publishTelemetrySnapshotForTesting()
        )
    }

    func terminalViewportTextSnapshotForTesting(tileID: UUID) throws -> GhosttyTerminalView.ViewportTextSnapshot {
        let resolvedLeafID = resolvedTerminalLeafID(for: tileID)
        guard let terminalView = SurfacePool.shared.view(leafID: resolvedLeafID) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No terminal view registered for tileID \(tileID.uuidString)"
                ]
            )
        }
        return terminalView.viewportTextSnapshotForTesting()
    }

    func renderedTerminalTargetSnapshotForTesting(tileID: UUID) async throws -> RenderedTerminalTargetSnapshot {
        try await renderedTerminalTargetSnapshot(for: [renderedTerminalTargetCommand, tileID.uuidString])
    }

    func focusRenderedPaneForTesting(tileID: UUID, paneID: String) async throws {
        try await focusRenderedPane([focusRenderedPaneCommand, tileID.uuidString, paneID])
    }

    func sampleTerminalViewportTextForTesting(
        tileID: UUID,
        sampleCount: Int,
        intervalMilliseconds: Int
    ) async throws -> TerminalViewportTextSamplingSnapshot {
        guard sampleCount > 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 36,
                userInfo: [NSLocalizedDescriptionKey: "sampleCount must be greater than zero"]
            )
        }
        guard intervalMilliseconds >= 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 37,
                userInfo: [NSLocalizedDescriptionKey: "intervalMilliseconds must be non-negative"]
            )
        }

        var samples: [TerminalViewportTextSampleSnapshot] = []
        let startUptime = ProcessInfo.processInfo.systemUptime
        for sampleIndex in 0..<sampleCount {
            let snapshot = try terminalViewportTextSnapshotForTesting(tileID: tileID)
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000.0
            samples.append(
                TerminalViewportTextSampleSnapshot(
                    sampleIndex: sampleIndex,
                    elapsedMs: elapsedMs,
                    snapshot: snapshot
                )
            )
            if sampleIndex < sampleCount - 1, intervalMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }

        return TerminalViewportTextSamplingSnapshot(samples: samples)
    }

    private func dumpTerminalViewportText(_ args: [String]) throws -> GhosttyTerminalView.ViewportTextSnapshot {
        let tileID = try tileID(from: args, command: dumpTerminalViewportTextCommand)
        return try terminalViewportTextSnapshotForTesting(tileID: tileID)
    }

    private func sampleTerminalViewportText(_ args: [String]) async throws -> TerminalViewportTextSamplingSnapshot {
        guard args.count >= 4 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 38,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(sampleTerminalViewportTextCommand) requires <tileID> <sampleCount> <intervalMs>"
                ]
            )
        }

        let tileID = try tileID(from: args, command: sampleTerminalViewportTextCommand)
        guard let sampleCount = Int(args[2]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 39,
                userInfo: [NSLocalizedDescriptionKey: "Invalid sampleCount: \(args[2])"]
            )
        }
        guard let intervalMs = Int(args[3]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey: "Invalid intervalMs: \(args[3])"]
            )
        }

        return try await sampleTerminalViewportTextForTesting(
            tileID: tileID,
            sampleCount: sampleCount,
            intervalMilliseconds: intervalMs
        )
    }

    func waitForTerminalViewRegistrationForTesting(
        tileID: UUID,
        timeoutMilliseconds: Int = 5_000
    ) async throws {
        try await waitForTerminalViewRegistration(
            tileID: tileID,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    private func terminalView(for args: [String], command: String) throws -> GhosttyTerminalView {
        uiTestBridgeDebugLog("terminalView lookup command=\(command) args=\(args)")
        let tileID = try tileID(from: args, command: command)
        let resolvedLeafID = resolvedTerminalLeafID(for: tileID)
        guard let terminalView = SurfacePool.shared.view(leafID: resolvedLeafID) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 14,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No terminal view registered for tileID \(tileID.uuidString)"
                ]
            )
        }

        uiTestBridgeDebugLog("terminalView resolved command=\(command) tileID=\(tileID.uuidString)")
        return terminalView
    }

    private func sessionRef(forTileID tileID: UUID) throws -> SessionRef {
        guard let workbench = workbenchStore.workbenches.first(where: { workbench in
            workbench.tiles.contains(where: { $0.id == tileID })
        }), let terminalTile = workbench.tiles.first(where: { $0.id == tileID }) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 50,
                userInfo: [NSLocalizedDescriptionKey: "No terminal tile found for tileID \(tileID.uuidString)"]
            )
        }

        guard case .terminal(let sessionRef) = terminalTile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 51,
                userInfo: [NSLocalizedDescriptionKey: "Tile \(tileID.uuidString) is not a terminal tile"]
            )
        }

        return sessionRef
    }

    private func resolvedTerminalLeafID(for tileID: UUID) -> UUID {
        TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID) ?? tileID
    }

    private func waitForTerminalViewRegistration(
        tileID: UUID,
        timeoutMilliseconds: Int = 5_000
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            let resolvedLeafID = resolvedTerminalLeafID(for: tileID)
            if SurfacePool.shared.view(leafID: resolvedLeafID) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        throw NSError(
            domain: "UITestTmuxBridge",
            code: 41,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for terminal view registration for tileID \(tileID.uuidString)"
            ]
        )
    }

    private func tileID(from args: [String], command: String) throws -> UUID {
        guard args.count >= 2 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(command) requires <tileID>"
                ]
            )
        }

        guard let tileID = UUID(uuidString: args[1]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid tileID for \(command): \(args[1])"
                ]
            )
        }
        return tileID
    }

    private func writeBootstrapResult(_ result: BootstrapResult) {
        guard let url = bootstrapResultURL else { return }
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func sessionNameFromNewSessionArgs(_ args: [String]) -> String? {
        guard args.first == "new-session" else { return nil }
        guard let idx = args.firstIndex(of: "-s"), args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }

    private func sessionNameFromKillSessionArgs(_ args: [String]) -> String? {
        guard args.first == "kill-session" else { return nil }
        guard let idx = args.firstIndex(of: "-t"), args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }

    private func runBootstrapTmuxCommand(
        _ args: [String],
        step: String
    ) async throws -> String {
        do {
            let output = try await TmuxCommandRunner.shared.run(args, source: "local")
            uiTestBridgeDebugLog("bootstrap \(step) ok args=\(args)")
            return output
        } catch let error as TmuxCommandError {
            let message = bootstrapTmuxErrorDescription(step: step, error: error, fallbackArgs: args)
            uiTestBridgeDebugLog("bootstrap \(step) failed: \(message)")
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        } catch {
            let message = "bootstrap \(step) failed: \(error.localizedDescription)"
            uiTestBridgeDebugLog(message)
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func bootstrapTmuxErrorDescription(
        step: String,
        error: TmuxCommandError,
        fallbackArgs: [String]
    ) -> String {
        let socketArgs = LocalTmuxTarget.socketArguments(from: env).joined(separator: " ")
        let configArgs = LocalTmuxTarget.configArguments(from: env).joined(separator: " ")

        switch error {
        case .failed(let args, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = (args.isEmpty ? fallbackArgs : args).joined(separator: " ")
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "bootstrap \(step) failed (\(command), exit \(code), socketArgs=[\(socketArgs)], configArgs=[\(configArgs)])\(suffix)"
        case .timeout(let args):
            let command = (args.isEmpty ? fallbackArgs : args).joined(separator: " ")
            return "bootstrap \(step) timed out (\(command), socketArgs=[\(socketArgs)], configArgs=[\(configArgs)])"
        case .tmuxNotFound(let source):
            return "bootstrap \(step) could not find tmux for source \(source)"
        case .permissionDenied(let source, let detail):
            return "bootstrap \(step) permission denied for source \(source): \(detail)"
        case .sshFailed(let host, let code, let stderr):
            return "bootstrap \(step) unexpected ssh failure host=\(host) exit=\(code): \(stderr)"
        }
    }

    private func resolveBootstrapTmuxSocketPath() async throws -> String {
        let output = try await runBootstrapTmuxCommand(
            ["display-message", "-p", "#{socket_path}"],
            step: "display-message"
        )
        let socketPath = output
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let socketPath, !socketPath.isEmpty else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve bootstrap tmux socket path"]
            )
        }
        return socketPath
    }

    private func waitForBootstrapPaneInventory(
        sessionName: String,
        expectedPaneCount: Int,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var lastFailure = "bootstrap pane inventory did not become ready"

        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                let output = try await TmuxCommandRunner.shared.run(
                    ["list-panes", "-t", sessionName, "-F", "#{pane_id}"],
                    source: "local"
                )
                let paneIDs = output
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                if paneIDs.count >= expectedPaneCount {
                    return
                }
                lastFailure = "bootstrap pane inventory incomplete for \(sessionName): expected \(expectedPaneCount), got \(paneIDs.count)"
            } catch let error as TmuxCommandError {
                lastFailure = bootstrapTmuxErrorDescription(
                    step: "wait-for-pane-inventory",
                    error: error,
                    fallbackArgs: ["list-panes", "-t", sessionName, "-F", "#{pane_id}"]
                )
            } catch {
                lastFailure = "bootstrap wait-for-pane-inventory failed: \(error.localizedDescription)"
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        throw NSError(
            domain: "UITestTmuxBridge",
            code: 16,
            userInfo: [NSLocalizedDescriptionKey: lastFailure]
        )
    }

    private func managedDaemonStderrTail(maxLength: Int = 2048) -> String? {
        guard let path = env["AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            !data.isEmpty,
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxLength {
            return trimmed
        }
        return String(trimmed.suffix(maxLength))
    }

    private func appDirectResolvedSocketProbe(_ socketPath: String?) -> (output: String?, error: String?) {
        guard let socketPath, !socketPath.isEmpty else {
            return (nil, "bootstrap tmux socket unresolved")
        }

        let tmuxPath = ManagedDaemonLaunchEnvironment.normalized(from: env)["TMUX_BIN"]
            ?? "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else {
            return (nil, "tmux executable unavailable at \(tmuxPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        var arguments: [String] = []
        if let configPath = env["AGTMUX_UITEST_TMUX_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configPath.isEmpty {
            arguments.append(contentsOf: ["-f", configPath])
        }
        arguments.append(contentsOf: [
            "-S", socketPath,
            "list-panes",
            "-a",
            "-F", "#{session_name}|#{window_id}|#{pane_id}|#{pane_current_command}",
        ])
        process.arguments = arguments
        process.environment = ManagedDaemonLaunchEnvironment.normalized(from: env)
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (nil, error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return (nil, "timed out")
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return (stdout?.isEmpty == true ? nil : stdout, nil)
        }
        return (stdout?.isEmpty == true ? nil : stdout, stderr?.isEmpty == true ? "exit \(process.terminationStatus)" : stderr)
    }
}
