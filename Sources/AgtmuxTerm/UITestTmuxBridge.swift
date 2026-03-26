import Foundation
import AppKit
import AgtmuxTermCore

private func uiTestBridgeDebugLog(_ message: @autoclosure () -> String) {
    let line = "[ui-test-bridge] " + message() + "\n"
    if let debugPath = UserDefaults.standard.string(forKey: "UITestBridgeDebugLogPath"),
       !debugPath.isEmpty {
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: debugPath) == false {
            FileManager.default.createFile(atPath: debugPath, contents: data)
            return
        }
        if let handle = FileHandle(forWritingAtPath: debugPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
    }
    guard ProcessInfo.processInfo.environment["AGTMUX_UITEST_BRIDGE_DEBUG"] == "1"
        || UserDefaults.standard.bool(forKey: "UITestBridgeDebugEnabled")
    else {
        return
    }
    FileHandle.standardError.write(Data(line.utf8))
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
    static let bridgeEnabledDefaultsKey = "UITestBridgeEnabled"
    static let commandPathDefaultsKey = "UITestTmuxCommandPath"
    static let commandResultPathDefaultsKey = "UITestTmuxCommandResultPath"
    static let bootstrapResultPathDefaultsKey = "UITestTmuxResultPath"
    static let registrationTimeoutDefaultsKey = "UITestTerminalViewRegistrationTimeoutMS"
    static let sessionOnlyFallbackDefaultsKey = "UITestAllowSessionOnlyOpenFallback"
    nonisolated static let stableAttachEnabledRelativePath = "agtmux-term/gate-l-attach/enabled"
    nonisolated static let stableAttachCommandRelativePath = "agtmux-term/gate-l-attach/tmux-command.json"
    nonisolated static let stableAttachCommandResultRelativePath = "agtmux-term/gate-l-attach/tmux-command-result.json"
    nonisolated static let stableAttachBootstrapResultRelativePath = "agtmux-term/gate-l-attach/tmux-bootstrap-result.json"

    nonisolated static func stableAttachURL(relativePath: String) -> URL {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    nonisolated static var stableAttachEnabledURL: URL {
        stableAttachURL(relativePath: stableAttachEnabledRelativePath)
    }

    nonisolated static func bridgeRequested(
        environment: [String: String],
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        let bridgeEnabledKey = "UITestBridgeEnabled"
        let commandPathKey = "UITestTmuxCommandPath"
        let commandResultPathKey = "UITestTmuxCommandResultPath"
        if environment["AGTMUX_UITEST"] == "1" {
            return true
        }
        if userDefaults.bool(forKey: bridgeEnabledKey) {
            return true
        }
        let commandPath = userDefaults.string(forKey: commandPathKey)
        let commandResultPath = userDefaults.string(forKey: commandResultPathKey)
        if FileManager.default.fileExists(atPath: stableAttachEnabledURL.path) {
            return true
        }
        return (commandPath?.isEmpty == false) && (commandResultPath?.isEmpty == false)
    }

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
        let responsePath: String?
    }

    private struct CommandResponse: Codable {
        let id: String
        let ok: Bool
        let stdout: String
        let error: String?
    }

    struct ActiveTerminalTargetSnapshot: Codable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let mainTerminalMode: String
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
        let diagnosticCode: String
        let diagnosticMessage: String
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
        let terminalSurfaceMetrics: GhosttyTerminalView.SurfaceMetricsSnapshot
    }

    private struct TerminalRegistrationStateSnapshot: Codable {
        let tileID: String
        let terminalHostMode: String
        let mainTerminalSurfaceID: String
        let tileMatchesMainTerminalSurface: Bool
        let mainTerminalMode: String
        let mainTerminalSessionName: String?
        let mainTerminalFocusRequestNonce: UInt64
        let renderedStatePresent: Bool
        let renderedSurfaceGeneration: UInt64
        let registrySurfaceHandlePresent: Bool
        let resolvedSurfaceHandlePresent: Bool
        let activeLeafID: String?
        let resolvedLeafID: String?
        let viewForTileLeafPresent: Bool
        let viewForResolvedLeafPresent: Bool
        let viewForRegistrySurfaceHandlePresent: Bool
        let viewForResolvedSurfaceHandlePresent: Bool
        let resolvedTerminalViewPresent: Bool
        let surfacePool: SurfacePool.TelemetrySnapshot
    }

    private struct ScrollBenchTelemetrySnapshot: Codable {
        let scroll: GhosttyTerminalView.ScrollTelemetrySnapshot
        let app: GhosttyApp.SurfaceDrawTelemetrySnapshot
        let island: GhosttyIslandUpdateTelemetry.Snapshot
        let surfacePool: SurfacePool.TelemetrySnapshot
        let nextHost: NextHostPaneControllerTelemetry.Snapshot
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

    struct TerminalScrollBurstMeasurementSnapshot: Codable, Equatable {
        let sender: GhosttyTerminalView.InternalScrollInjectionSnapshot
        let sampling: TerminalViewportTextSamplingSnapshot
    }

    struct FocusExistingTerminalTileSnapshot: Codable, Equatable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let sessionName: String
    }

    private let viewModel: AppViewModel
    private let mainTerminalStore: MainTerminalStore
    private let workbenchStore: WorkbenchStoreV2
    private let enableMetadataMode: @MainActor () async -> Void
    private let resolveDirectLocalPane: @Sendable (_ sessionName: String, _ paneID: String) async throws -> AgtmuxPane?
    private let applyNavigationIntent: @Sendable (_ activePaneRef: ActivePaneRef, _ renderedClientTTY: String, _ hostsConfig: HostsConfig) async throws -> Void
    private let resolveRenderedLiveTarget: @Sendable (_ renderedClientTTY: String, _ target: TargetRef, _ hostsConfig: HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget
    private let env: [String: String]
    private let userDefaults: UserDefaults
    private var bridgeActivationMonitorTask: Task<Void, Never>?
    private var activeCommandLoopPaths: (command: String, response: String)?
    private var commandLoopTask: Task<Void, Never>?
    private var lastProcessedCommandID: String?
    private var processedCommandCount: Int = 0
    private var createdSessions: Set<String> = []
    private let activeTerminalTargetCommand = "__agtmux_dump_active_terminal_target__"
    private let focusStateCommand = "__agtmux_dump_focus_state__"
    private let terminalRegistrationStateCommand = "__agtmux_dump_terminal_registration_state__"
    private let activeDocumentTileCommand = "__agtmux_dump_active_document_tile__"
    private let replaceFocusedTextCommand = "__agtmux_replace_focused_text__"
    private let sidebarStateCommand = "__agtmux_dump_sidebar_state__"
    private let enableMetadataCommand = "__agtmux_enable_metadata__"
    private let openTerminalForPaneCommand = "__agtmux_open_terminal_for_pane__"
    private let focusTerminalHostCommand = "__agtmux_focus_terminal_host__"
    private let focusExistingTerminalTileCommand = "__agtmux_focus_existing_terminal_tile__"
    private let focusRenderedPaneCommand = "__agtmux_focus_rendered_pane__"
    private let renderedTerminalTargetCommand = "__agtmux_dump_rendered_terminal_target__"
    private let setTerminalHostModeCommand = "__agtmux_set_terminal_host_mode__"
    private let sendTmuxNextPaneKeysCommand = "__agtmux_send_tmux_next_pane_keys__"
    private let resetScrollTelemetryCommand = "__agtmux_reset_scroll_telemetry__"
    private let dumpScrollTelemetryCommand = "__agtmux_dump_scroll_telemetry__"
    private let dumpTerminalViewportTextCommand = "__agtmux_dump_terminal_viewport_text__"
    private let sampleTerminalViewportTextCommand = "__agtmux_sample_terminal_viewport_text__"
    private let measureTerminalScrollBurstCommand = "__agtmux_measure_terminal_scroll_burst__"
    private let bridgeReadyCommand = "__agtmux_tmux_bridge_ready__"
    private var terminalViewRegistrationTimeoutMilliseconds: Int {
        guard let raw = env["AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS"],
              let value = Int(raw),
              value > 0 else {
            let defaultsValue = userDefaults.integer(forKey: Self.registrationTimeoutDefaultsKey)
            return defaultsValue > 0 ? defaultsValue : 5_000
        }
        return value
    }

    private var renderedLiveTargetTimeoutMilliseconds: Int {
        if let raw = env["AGTMUX_UITEST_RENDERED_LIVE_TARGET_TIMEOUT_MS"],
           let value = Int(raw),
           value > 0 {
            return value
        }
        return 750
    }

    private var bridgeProcessDelayMilliseconds: Int {
        guard let raw = env["AGTMUX_UITEST_BRIDGE_PROCESS_DELAY_MS"],
              let value = Int(raw),
              value > 0 else {
            return 0
        }
        return value
    }

    private var terminalHostMode: TerminalHostMode {
        TerminalHostModeRuntime.shared.resolved(environment: env)
    }

    private var allowSessionOnlyOpenFallback: Bool {
        if let raw = env["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK"] {
            return raw == "1"
        }
        return userDefaults.bool(forKey: Self.sessionOnlyFallbackDefaultsKey)
    }

    private var bridgeEnabled: Bool {
        if env["AGTMUX_UITEST"] == "1" {
            return true
        }
        if userDefaults.bool(forKey: Self.bridgeEnabledDefaultsKey) {
            return true
        }
        let commandPath = userDefaults.string(forKey: Self.commandPathDefaultsKey)
        let commandResultPath = userDefaults.string(forKey: Self.commandResultPathDefaultsKey)
        return (commandPath?.isEmpty == false) && (commandResultPath?.isEmpty == false)
    }

    init(
        viewModel: AppViewModel,
        mainTerminalStore: MainTerminalStore? = nil,
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
        env: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) {
        self.viewModel = viewModel
        self.mainTerminalStore = mainTerminalStore ?? MainTerminalStore()
        self.workbenchStore = workbenchStore
        self.enableMetadataMode = enableMetadataMode
        self.resolveDirectLocalPane = resolveDirectLocalPane
        self.applyNavigationIntent = applyNavigationIntent
        self.resolveRenderedLiveTarget = resolveRenderedLiveTarget
        self.env = env
        self.userDefaults = userDefaults
    }

    @MainActor
    func startIfNeeded() async {
        startBridgeActivationMonitorIfNeeded()
        uiTestBridgeDebugLog(
            "startIfNeeded bridgeEnabled=\(bridgeEnabled) commandURL=\(commandURL?.path ?? "<nil>") commandResponseURL=\(commandResponseURL?.path ?? "<nil>") envUITest=\(env["AGTMUX_UITEST"] ?? "<nil>")"
        )
        guard bridgeEnabled else { return }
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(nil)

        startCommandLoopIfNeeded()

        if let scenarioJSON = env["AGTMUX_UITEST_TMUX_SCENARIO"],
           !scenarioJSON.isEmpty {
            await runBootstrapScenario(from: scenarioJSON)
            return
        }

        await viewModel.fetchAll()
    }

    @MainActor
    func shutdown() async {
        bridgeActivationMonitorTask?.cancel()
        _ = await bridgeActivationMonitorTask?.value
        bridgeActivationMonitorTask = nil
        commandLoopTask?.cancel()
        _ = await commandLoopTask?.value
        commandLoopTask = nil
        activeCommandLoopPaths = nil
        lastProcessedCommandID = nil
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

    @MainActor
    private func startBridgeActivationMonitorIfNeeded() {
        guard bridgeActivationMonitorTask == nil else { return }

        bridgeActivationMonitorTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await MainActor.run {
                    guard self.bridgeEnabled else { return }
                    uiTestBridgeDebugLog("bridgeActivationMonitor reconciling command loop after runtime config update")
                    self.startCommandLoopIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
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

    @MainActor
    private func startCommandLoopIfNeeded() {
        guard let commandURL = commandURL, let responseURL = commandResponseURL else {
            uiTestBridgeDebugLog("startCommandLoopIfNeeded missing command paths")
            return
        }
        let requestedPaths = (command: commandURL.path, response: responseURL.path)
        if activeCommandLoopPaths?.command != requestedPaths.command
            || activeCommandLoopPaths?.response != requestedPaths.response {
            uiTestBridgeDebugLog(
                "startCommandLoopIfNeeded commandURL=\(commandURL.path) responseURL=\(responseURL.path)"
            )
            activeCommandLoopPaths = requestedPaths
            lastProcessedCommandID = nil
        }

        guard commandLoopTask == nil else { return }

        commandLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commandLoopTask = nil }
            _ = await self.processCommandFileIfNeeded(
                commandURL: commandURL,
                responseURL: responseURL
            )
        }
    }

    @MainActor
    private func claimCommandFileIfPresent(at commandURL: URL) -> URL? {
        let claimedURL = commandURL
            .deletingPathExtension()
            .appendingPathExtension("processing.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: commandURL, to: claimedURL)
            return claimedURL
        } catch {
            return nil
        }
    }

    @MainActor
    private func processCommandFileIfNeeded(
        commandURL: URL,
        responseURL: URL
    ) async -> Bool {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        guard let claimedCommandURL = claimCommandFileIfPresent(at: commandURL) else {
            return false
        }
        defer {
            try? FileManager.default.removeItem(at: claimedCommandURL)
        }

        guard let data = try? Data(contentsOf: claimedCommandURL), !data.isEmpty else {
            return false
        }
        guard let request = try? decoder.decode(CommandRequest.self, from: data) else {
            return false
        }
        let requestResponseURL: URL
        if let responsePath = request.responsePath, !responsePath.isEmpty {
            requestResponseURL = URL(fileURLWithPath: responsePath)
        } else {
            requestResponseURL = responseURL
        }
        guard request.id != lastProcessedCommandID else {
            return true
        }
        lastProcessedCommandID = request.id
        processedCommandCount += 1
        uiTestBridgeDebugLog("commandLoop request id=\(request.id) args=\(request.args)")

        if bridgeProcessDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(bridgeProcessDelayMilliseconds))
        }

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

                recordCommandLoopSessionSideEffects(for: request.args)
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
            try? payload.write(to: requestResponseURL, options: .atomic)
            uiTestBridgeDebugLog("commandLoop response id=\(response.id) ok=\(response.ok) args=\(request.args)")
        }

        return true
    }

    private func recordCommandLoopSessionSideEffects(for args: [String]) {
        if let session = sessionNameFromNewSessionArgs(args) {
            createdSessions.insert(session)
        }
        if let killedSession = sessionNameFromKillSessionArgs(args) {
            createdSessions.remove(killedSession)
        }
    }

    private var bootstrapResultURL: URL? {
        let path = env["AGTMUX_UITEST_TMUX_RESULT_PATH"]
            ?? userDefaults.string(forKey: Self.bootstrapResultPathDefaultsKey)
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard env["AGTMUX_UITEST"] == "1"
            || userDefaults.bool(forKey: Self.bridgeEnabledDefaultsKey)
            || FileManager.default.fileExists(atPath: Self.stableAttachEnabledURL.path) else {
            return nil
        }
        return Self.stableAttachURL(relativePath: Self.stableAttachBootstrapResultRelativePath)
    }

    private var commandURL: URL? {
        let path = env["AGTMUX_UITEST_TMUX_COMMAND_PATH"]
            ?? userDefaults.string(forKey: Self.commandPathDefaultsKey)
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard env["AGTMUX_UITEST"] == "1"
            || userDefaults.bool(forKey: Self.bridgeEnabledDefaultsKey)
            || FileManager.default.fileExists(atPath: Self.stableAttachEnabledURL.path) else {
            return nil
        }
        return Self.stableAttachURL(relativePath: Self.stableAttachCommandRelativePath)
    }

    private var commandResponseURL: URL? {
        let path = env["AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH"]
            ?? userDefaults.string(forKey: Self.commandResultPathDefaultsKey)
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard env["AGTMUX_UITEST"] == "1"
            || userDefaults.bool(forKey: Self.bridgeEnabledDefaultsKey)
            || FileManager.default.fileExists(atPath: Self.stableAttachEnabledURL.path) else {
            return nil
        }
        return Self.stableAttachURL(relativePath: Self.stableAttachCommandResultRelativePath)
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
            case terminalRegistrationStateCommand:
                let snapshot = terminalRegistrationStateSnapshot(for: request.args)
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
                try await focusTerminalHost(request.args)
                stdout = "ok"
            case focusExistingTerminalTileCommand:
                let snapshot = try focusExistingTerminalTile(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case focusRenderedPaneCommand:
                try await focusRenderedPane(request.args)
                stdout = "ok"
            case renderedTerminalTargetCommand:
                let snapshot = try await renderedTerminalTargetSnapshot(for: request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case setTerminalHostModeCommand:
                let mode = try await setTerminalHostMode(request.args)
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
                let snapshot = try await dumpTerminalViewportText(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case sampleTerminalViewportTextCommand:
                let snapshot = try await sampleTerminalViewportText(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case measureTerminalScrollBurstCommand:
                let snapshot = try await measureTerminalScrollBurst(request.args)
                let data = try JSONEncoder().encode(snapshot)
                stdout = String(decoding: data, as: UTF8.self)
            case bridgeReadyCommand:
                stdout = "ready"
            case sidebarStateCommand:
                if request.refreshInventory ?? false {
                    await viewModel.fetchAll()
                }
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
        if let snapshot = await mainTerminalTargetSnapshotOrNil() {
            return snapshot
        }

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
        if let selection,
           let terminalTile = workbench.tiles.first(where: { $0.id == selection.tileID }),
           case .terminal(let sessionRef) = terminalTile.kind,
           let activePaneContext = workbenchStore.activePaneContext,
           activePaneContext.workbenchID == selection.workbenchID,
           let selectedPaneInventoryID = selection.paneInventoryID {
            let renderedState = resolvedRenderedState(for: terminalTile.id)
            if let renderedState,
               let renderedClientTTY = renderedState.clientTTY,
               let renderedClientTarget = await resolveRenderedLiveTargetOrNil(
                    renderedClientTTY: renderedClientTTY,
                    target: sessionRef.target,
                    hostsConfig: viewModel.hostsConfig
               ) {
                return try await makeActiveTerminalTargetSnapshot(
                    workbenchID: selection.workbenchID,
                    tileID: terminalTile.id,
                    sessionRef: sessionRef,
                    resolvedWindowID: selection.windowID,
                    resolvedPaneID: selection.paneID,
                    desiredPaneRef: activePaneContext.activePaneRef,
                    observedPaneRef: workbenchStore.activePaneRuntimeContext?.observedPaneRef,
                    focusRequestNonce: activePaneContext.focusRequestNonce,
                    selectedPaneInventoryID: selectedPaneInventoryID,
                    renderedState: renderedState,
                    renderedClientTTY: renderedClientTTY,
                    renderedClientTarget: renderedClientTarget
                )
            }
            if resolvedTerminalView(for: terminalTile.id) != nil {
                return try await makeBootstrapActiveTerminalTargetSnapshot(
                    workbenchID: selection.workbenchID,
                    tileID: terminalTile.id,
                    sessionRef: sessionRef,
                    resolvedWindowID: selection.windowID,
                    resolvedPaneID: selection.paneID,
                    desiredPaneRef: activePaneContext.activePaneRef,
                    observedPaneRef: workbenchStore.activePaneRuntimeContext?.observedPaneRef,
                    focusRequestNonce: activePaneContext.focusRequestNonce,
                    selectedPaneInventoryID: selectedPaneInventoryID,
                    renderedState: renderedState
                )
            }
        }

        return try await fallbackActiveTerminalTargetSnapshot(workbench: workbench)
    }

    private func mainTerminalTargetSnapshotOrNil() async -> ActiveTerminalTargetSnapshot? {
        guard case .tmux(let sessionRef, let requestedPaneRef, let resolvedPaneRef) = mainTerminalStore.mode else {
            return nil
        }

        let tileID = mainTerminalStore.surfaceID
        let renderedState = resolvedRenderedState(for: tileID)
        let selectedPaneInventoryID = mainTerminalStore.selectedPaneInventoryID(
            panes: viewModel.panes,
            hostsConfig: viewModel.hostsConfig
        ) ?? ""
        let renderedClientTTY = renderedState?.clientTTY ?? ""
        let renderedClientTarget: WorkbenchV2TerminalLiveTarget?
        if renderedClientTTY.isEmpty == false {
            renderedClientTarget = await resolveRenderedLiveTargetOrNil(
                renderedClientTTY: renderedClientTTY,
                target: sessionRef.target,
                hostsConfig: viewModel.hostsConfig
            )
        } else {
            renderedClientTarget = nil
        }

        let observedPaneRef = renderedClientTarget.map {
            ActivePaneRef(
                target: sessionRef.target,
                sessionName: $0.sessionName,
                windowID: $0.windowID,
                paneID: $0.paneID
            )
        }
        let effectivePaneRef = resolvedPaneRef ?? observedPaneRef ?? requestedPaneRef
        let desiredPaneRef = requestedPaneRef ?? effectivePaneRef
        let attachCommand = (try? mainTerminalStore.attachResolution?.get().command)
            ?? renderedState?.attachCommand
            ?? ""
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
            terminalHostMode: (renderedState?.context.terminalHostMode ?? terminalHostMode).rawValue,
            workbenchID: mainTerminalStore.viewportID.uuidString,
            tileID: tileID.uuidString,
            mainTerminalMode: "tmux",
            sessionName: sessionRef.sessionName,
            windowID: effectivePaneRef?.windowID ?? "",
            paneID: effectivePaneRef?.paneID ?? "",
            desiredWindowID: desiredPaneRef?.windowID ?? "",
            desiredPaneID: desiredPaneRef?.paneID ?? "",
            observedWindowID: observedPaneRef?.windowID ?? effectivePaneRef?.windowID ?? "",
            observedPaneID: observedPaneRef?.paneID ?? effectivePaneRef?.paneID ?? "",
            focusRequestNonce: mainTerminalStore.focusRequestNonce,
            selectedPaneInventoryID: selectedPaneInventoryID,
            attachCommand: attachCommand,
            renderedAttachCommand: renderedState?.attachCommand ?? attachCommand,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: renderedClientTarget?.windowID ?? "",
            renderedClientPaneID: renderedClientTarget?.paneID ?? "",
            renderedSurfaceGeneration: renderedState?.generation ?? 0,
            controlModeKey: controlModeKey?.identity ?? "",
            controlModeState: controlModeState,
            diagnosticCode: mainTerminalStore.diagnostic?.code ?? "",
            diagnosticMessage: mainTerminalStore.diagnostic?.detailText ?? ""
        )
    }

    private func fallbackActiveTerminalTargetSnapshot(
        workbench: Workbench
    ) async throws -> ActiveTerminalTargetSnapshot {
        guard let focusedTileID = workbench.focusedTileID,
              let terminalTile = workbench.tiles.first(where: { $0.id == focusedTileID }) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Canonical active terminal target is unresolved"]
            )
        }
        guard case .terminal(let sessionRef) = terminalTile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Selected tile is not a terminal tile"]
            )
        }

        let renderedState = resolvedRenderedState(for: terminalTile.id)
        if let renderedState,
           let renderedClientTTY = renderedState.clientTTY,
           let renderedClientTarget = await resolveRenderedLiveTargetOrNil(
                renderedClientTTY: renderedClientTTY,
                target: sessionRef.target,
                hostsConfig: viewModel.hostsConfig
           ) {
            let runtimeContext = workbenchStore.activePaneRuntimeContext
            let desiredPaneRef = (runtimeContext?.tileID == terminalTile.id)
                ? runtimeContext?.desiredPaneRef
                : workbench.activePaneRef
            let observedPaneRef = (runtimeContext?.tileID == terminalTile.id)
                ? runtimeContext?.observedPaneRef
                : nil
            let focusRequestNonce = (runtimeContext?.tileID == terminalTile.id)
                ? (runtimeContext?.focusRequestNonce ?? 0)
                : 0
            let resolvedPaneRef = observedPaneRef
                ?? desiredPaneRef
                ?? ActivePaneRef(
                    target: sessionRef.target,
                    sessionName: sessionRef.sessionName,
                    windowID: renderedClientTarget.windowID,
                    paneID: renderedClientTarget.paneID
                )
            let source = WorkbenchV2ActivePaneSelectionResolver.resolvePaneInventoryID(
                source: sourceLabel(for: sessionRef.target, hostsConfig: viewModel.hostsConfig),
                activePaneRef: resolvedPaneRef,
                panes: viewModel.panes
            ) ?? ""

            return try await makeActiveTerminalTargetSnapshot(
                workbenchID: workbench.id,
                tileID: terminalTile.id,
                sessionRef: sessionRef,
                resolvedWindowID: renderedClientTarget.windowID,
                resolvedPaneID: renderedClientTarget.paneID,
                desiredPaneRef: desiredPaneRef,
                observedPaneRef: observedPaneRef,
                focusRequestNonce: focusRequestNonce,
                selectedPaneInventoryID: source,
                renderedState: renderedState,
                renderedClientTTY: renderedClientTTY,
                renderedClientTarget: renderedClientTarget
            )
        }

        let runtimeContext = workbenchStore.activePaneRuntimeContext
        let desiredPaneRef = (runtimeContext?.tileID == terminalTile.id)
            ? runtimeContext?.desiredPaneRef
            : workbench.activePaneRef
        let observedPaneRef = (runtimeContext?.tileID == terminalTile.id)
            ? runtimeContext?.observedPaneRef
            : nil
        let focusRequestNonce = (runtimeContext?.tileID == terminalTile.id)
            ? (runtimeContext?.focusRequestNonce ?? 0)
            : 0
        let resolvedWindowID = observedPaneRef?.windowID ?? desiredPaneRef?.windowID ?? ""
        let resolvedPaneID = observedPaneRef?.paneID ?? desiredPaneRef?.paneID ?? ""
        let resolvedPaneRef = observedPaneRef
            ?? desiredPaneRef
            ?? (resolvedWindowID.isEmpty == false && resolvedPaneID.isEmpty == false
                ? ActivePaneRef(
                    target: sessionRef.target,
                    sessionName: sessionRef.sessionName,
                    windowID: resolvedWindowID,
                    paneID: resolvedPaneID
                )
                : nil)
        let source: String
        if let resolvedPaneRef {
            source = WorkbenchV2ActivePaneSelectionResolver.resolvePaneInventoryID(
                source: sourceLabel(for: sessionRef.target, hostsConfig: viewModel.hostsConfig),
                activePaneRef: resolvedPaneRef,
                panes: viewModel.panes
            ) ?? ""
        } else {
            source = ""
        }

        guard resolvedTerminalView(for: terminalTile.id) != nil else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface state is missing"]
            )
        }

        return try await makeBootstrapActiveTerminalTargetSnapshot(
            workbenchID: workbench.id,
            tileID: terminalTile.id,
            sessionRef: sessionRef,
            resolvedWindowID: resolvedWindowID,
            resolvedPaneID: resolvedPaneID,
            desiredPaneRef: desiredPaneRef,
            observedPaneRef: observedPaneRef,
            focusRequestNonce: focusRequestNonce,
            selectedPaneInventoryID: source,
            renderedState: renderedState
        )
    }

    private func makeActiveTerminalTargetSnapshot(
        workbenchID: UUID,
        tileID: UUID,
        sessionRef: SessionRef,
        resolvedWindowID: String,
        resolvedPaneID: String,
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        focusRequestNonce: UInt64,
        selectedPaneInventoryID: String,
        renderedState: GhosttyRenderedTerminalSurfaceState,
        renderedClientTTY: String,
        renderedClientTarget: WorkbenchV2TerminalLiveTarget,
        mainTerminalMode: String = "tmux",
        diagnostic: MainTerminalDiagnostic? = nil
    ) async throws -> ActiveTerminalTargetSnapshot {
        let attachCommand = (
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                activePaneRef: desiredPaneRef,
                hostsConfig: viewModel.hostsConfig,
                env: env
            ).get().command
        ) ?? renderedState.attachCommand
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
            terminalHostMode: renderedState.context.terminalHostMode.rawValue,
            workbenchID: workbenchID.uuidString,
            tileID: tileID.uuidString,
            mainTerminalMode: mainTerminalMode,
            sessionName: sessionRef.sessionName,
            windowID: resolvedWindowID,
            paneID: resolvedPaneID,
            desiredWindowID: desiredPaneRef?.windowID ?? "",
            desiredPaneID: desiredPaneRef?.paneID ?? "",
            observedWindowID: observedPaneRef?.windowID ?? renderedClientTarget.windowID,
            observedPaneID: observedPaneRef?.paneID ?? renderedClientTarget.paneID,
            focusRequestNonce: focusRequestNonce,
            selectedPaneInventoryID: selectedPaneInventoryID,
            attachCommand: attachCommand,
            renderedAttachCommand: renderedState.attachCommand,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: renderedClientTarget.windowID,
            renderedClientPaneID: renderedClientTarget.paneID,
            renderedSurfaceGeneration: renderedState.generation,
            controlModeKey: controlModeKey?.identity ?? "",
            controlModeState: controlModeState,
            diagnosticCode: diagnostic?.code ?? "",
            diagnosticMessage: diagnostic?.detailText ?? ""
        )
    }

    private func makeBootstrapActiveTerminalTargetSnapshot(
        workbenchID: UUID,
        tileID: UUID,
        sessionRef: SessionRef,
        resolvedWindowID: String,
        resolvedPaneID: String,
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        focusRequestNonce: UInt64,
        selectedPaneInventoryID: String,
        renderedState: GhosttyRenderedTerminalSurfaceState?,
        mainTerminalMode: String = "tmux",
        diagnostic: MainTerminalDiagnostic? = nil
    ) async throws -> ActiveTerminalTargetSnapshot {
        let attachCommand = (
            try? WorkbenchV2TerminalAttachResolver.resolve(
                sessionRef: sessionRef,
                activePaneRef: desiredPaneRef,
                hostsConfig: viewModel.hostsConfig,
                env: env
            ).get().command
        ) ?? renderedState?.attachCommand ?? ""
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
            terminalHostMode: (renderedState?.context.terminalHostMode ?? terminalHostMode).rawValue,
            workbenchID: workbenchID.uuidString,
            tileID: tileID.uuidString,
            mainTerminalMode: mainTerminalMode,
            sessionName: sessionRef.sessionName,
            windowID: resolvedWindowID,
            paneID: resolvedPaneID,
            desiredWindowID: desiredPaneRef?.windowID ?? "",
            desiredPaneID: desiredPaneRef?.paneID ?? "",
            observedWindowID: observedPaneRef?.windowID ?? resolvedWindowID,
            observedPaneID: observedPaneRef?.paneID ?? resolvedPaneID,
            focusRequestNonce: focusRequestNonce,
            selectedPaneInventoryID: selectedPaneInventoryID,
            attachCommand: attachCommand,
            renderedAttachCommand: renderedState?.attachCommand ?? attachCommand,
            renderedClientTTY: renderedState?.clientTTY ?? "",
            renderedClientWindowID: "",
            renderedClientPaneID: "",
            renderedSurfaceGeneration: renderedState?.generation ?? 0,
            controlModeKey: controlModeKey?.identity ?? "",
            controlModeState: controlModeState,
            diagnosticCode: diagnostic?.code ?? "",
            diagnosticMessage: diagnostic?.detailText ?? ""
        )
    }

    private func renderedTerminalTargetSnapshot(for args: [String]) async throws -> RenderedTerminalTargetSnapshot {
        let tileID = try tileID(from: args, command: renderedTerminalTargetCommand)
        uiTestBridgeDebugLog("renderedTerminalTargetSnapshot start tile=\(tileID.uuidString)")
        let sessionRef = try sessionRef(forTileID: tileID)
        let renderedState = resolvedRenderedState(for: tileID)
        guard renderedState != nil || resolvedTerminalView(for: tileID) != nil else {
            uiTestBridgeDebugLog("renderedTerminalTargetSnapshot missing surface tile=\(tileID.uuidString)")
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "Rendered Ghostty surface state is missing"]
            )
        }
        let renderedClientTTY = renderedState?.clientTTY ?? ""
        let liveTarget: WorkbenchV2TerminalLiveTarget?
        if renderedClientTTY.isEmpty == false {
            uiTestBridgeDebugLog(
                "renderedTerminalTargetSnapshot resolving live target tile=\(tileID.uuidString) tty=\(renderedClientTTY)"
            )
            liveTarget = await resolveRenderedLiveTargetOrNil(
                renderedClientTTY: renderedClientTTY,
                target: sessionRef.target,
                hostsConfig: viewModel.hostsConfig
            )
            uiTestBridgeDebugLog(
                "renderedTerminalTargetSnapshot resolved live target tile=\(tileID.uuidString) tty=\(renderedClientTTY) window=\(liveTarget?.windowID ?? "<nil>") pane=\(liveTarget?.paneID ?? "<nil>")"
            )
        } else {
            uiTestBridgeDebugLog("renderedTerminalTargetSnapshot bootstrap-only tile=\(tileID.uuidString)")
            liveTarget = nil
        }
        uiTestBridgeDebugLog(
            "renderedTerminalTargetSnapshot returning tile=\(tileID.uuidString) tty=\(renderedClientTTY) window=\(liveTarget?.windowID ?? "") pane=\(liveTarget?.paneID ?? "")"
        )
        return RenderedTerminalTargetSnapshot(
            terminalHostMode: (renderedState?.context.terminalHostMode ?? terminalHostMode).rawValue,
            workbenchID: workbenchOrViewportID(forTileID: tileID).uuidString,
            tileID: tileID.uuidString,
            sessionName: sessionRef.sessionName,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: liveTarget?.windowID ?? "",
            renderedClientPaneID: liveTarget?.paneID ?? ""
        )
    }

    private func setTerminalHostMode(_ args: [String]) async throws -> TerminalHostMode {
        guard args.count >= 2 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 46,
                userInfo: [NSLocalizedDescriptionKey: "\(setTerminalHostModeCommand) requires <legacy|next|default>"]
            )
        }

        let priorMode = terminalHostMode
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
        if terminalHostMode != priorMode {
            // Runtime override is the source of truth for same-app live diagnostics.
            // The caller already waits for tile host-mode convergence, so this command
            // should not block on a full inventory refresh or fixed sleep.
            await Task.yield()
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

    @MainActor
    private func focusExistingTerminalTile(_ args: [String]) throws -> FocusExistingTerminalTileSnapshot {
        let requestedSessionName = args.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSession = requestedSessionName?.isEmpty == false ? requestedSessionName : nil

        func matchingTile(
            in workbench: Workbench
        ) -> WorkbenchTile? {
            workbench.tiles.first { tile in
                guard case .terminal(let sessionRef) = tile.kind else { return false }
                guard let requestedSession else { return true }
                return sessionRef.sessionName == requestedSession
            }
        }

        let activeIndex = workbenchStore.activeWorkbenchIndex
        let candidate: (index: Int, workbench: Workbench, tile: WorkbenchTile)? = {
            if workbenchStore.workbenches.indices.contains(activeIndex) {
                let workbench = workbenchStore.workbenches[activeIndex]
                if let tile = matchingTile(in: workbench) {
                    return (activeIndex, workbench, tile)
                }
            }
            for (index, workbench) in workbenchStore.workbenches.enumerated() where index != activeIndex {
                if let tile = matchingTile(in: workbench) {
                    return (index, workbench, tile)
                }
            }
            return nil
        }()

        guard let candidate else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 48,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No existing terminal tile found\(requestedSession.map { " for session \($0)" } ?? "")"
                ]
            )
        }
        guard case .terminal(let sessionRef) = candidate.tile.kind else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 49,
                userInfo: [NSLocalizedDescriptionKey: "Matched tile is not terminal"]
            )
        }

        if workbenchStore.activeWorkbenchIndex != candidate.index {
            workbenchStore.activeWorkbenchIndex = candidate.index
        }
        workbenchStore.focusTile(id: candidate.tile.id)

        return FocusExistingTerminalTileSnapshot(
            terminalHostMode: terminalHostMode.rawValue,
            workbenchID: candidate.workbench.id.uuidString,
            tileID: candidate.tile.id.uuidString,
            sessionName: sessionRef.sessionName
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
        paneID: String,
        waitForRegistration: Bool = true
    ) async throws -> OpenTerminalForPaneSnapshot {
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting start source=\(source) session=\(sessionName) pane=\(paneID)"
        )
        let pane: AgtmuxPane
        let usedSessionOnlyFallback: Bool
        let hostsConfig = viewModel.hostsConfig
        let currentSessionRef = mainTerminalStore.sessionRef
        let hasExistingLocalTerminalTarget = source == "local"
            && currentSessionRef?.target == .local
            && currentSessionRef?.sessionName == sessionName
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
        } else if source == "local" && allowSessionOnlyOpenFallback && !hasExistingLocalTerminalTarget {
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting session-only-fallback session=\(sessionName) pane=\(paneID)"
            )
            prepareDirectLocalSessionForRendering(sessionName)
            let sessionRef = SessionRef(target: .local, sessionName: sessionName)
            let disposition = currentSessionRef == sessionRef ? "revealedExisting" : "opened"
            mainTerminalStore.activate(
                sessionRef: sessionRef,
                requestedPaneRef: nil,
                hostsConfig: hostsConfig
            )
            if waitForRegistration {
                try await waitForTerminalViewRegistration(
                    tileID: mainTerminalStore.surfaceID,
                    timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
                )
            }
            return OpenTerminalForPaneSnapshot(
                terminalHostMode: terminalHostMode.rawValue,
                workbenchID: mainTerminalStore.viewportID.uuidString,
                tileID: mainTerminalStore.surfaceID.uuidString,
                disposition: disposition,
                usedSessionOnlyFallback: true,
                source: source,
                sessionName: sessionName,
                paneID: paneID
            )
        } else if source == "local" && allowSessionOnlyOpenFallback {
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting session-only-fallback session=\(sessionName) pane=\(paneID)"
            )
            prepareDirectLocalSessionForRendering(sessionName)
            let sessionRef = SessionRef(target: .local, sessionName: sessionName)
            let disposition = currentSessionRef == sessionRef ? "revealedExisting" : "opened"
            mainTerminalStore.activate(
                sessionRef: sessionRef,
                requestedPaneRef: nil,
                hostsConfig: hostsConfig
            )
            if waitForRegistration {
                try await waitForTerminalViewRegistration(
                    tileID: mainTerminalStore.surfaceID,
                    timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
                )
            }
            return OpenTerminalForPaneSnapshot(
                terminalHostMode: terminalHostMode.rawValue,
                workbenchID: mainTerminalStore.viewportID.uuidString,
                tileID: mainTerminalStore.surfaceID.uuidString,
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
            "openTerminalForPaneForTesting main-terminal currentSession=\(String(describing: currentSessionRef?.sessionName)) currentPane=\(String(describing: mainTerminalStore.highlightedPaneRef?.paneID))"
        )
        let sessionRef = sessionRef(forPane: pane, hostsConfig: hostsConfig)
        let disposition = currentSessionRef == sessionRef ? "revealedExisting" : "opened"
        await mainTerminalStore.activate(pane: pane, hostsConfig: hostsConfig)
        uiTestBridgeDebugLog(
            "openTerminalForPaneForTesting main-terminal-activated tile=\(mainTerminalStore.surfaceID.uuidString)"
        )
        if waitForRegistration {
            try await waitForTerminalViewRegistration(
                tileID: mainTerminalStore.surfaceID,
                timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
            )
        }
        let requestedWindowID = pane.windowId
        let resolvedWindowID = mainTerminalStore.resolvedPaneRef?.windowID
        let desiredWindowID = mainTerminalStore.requestedPaneRef?.windowID
        if resolvedWindowID != requestedWindowID,
           desiredWindowID != requestedWindowID {
            uiTestBridgeDebugLog(
                "openTerminalForPaneForTesting main-terminal window mismatch requestedWindow=\(requestedWindowID) actualRequestedWindow=\(String(describing: desiredWindowID)) actualResolvedWindow=\(String(describing: resolvedWindowID))"
            )
        }

        return OpenTerminalForPaneSnapshot(
            terminalHostMode: terminalHostMode.rawValue,
            workbenchID: mainTerminalStore.viewportID.uuidString,
            tileID: mainTerminalStore.surfaceID.uuidString,
            disposition: disposition,
            usedSessionOnlyFallback: usedSessionOnlyFallback,
            source: source,
            sessionName: sessionName,
            paneID: paneID
        )
    }

    private func sessionRef(
        forPane pane: AgtmuxPane,
        hostsConfig: HostsConfig
    ) -> SessionRef {
        SessionRef(
            target: targetRef(for: pane.source, hostsConfig: hostsConfig),
            sessionName: pane.sessionName,
            lastSeenRepoRoot: pane.currentPath
        )
    }

    private func activePaneRef(
        forPane pane: AgtmuxPane,
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

    private func targetRef(
        for source: String,
        hostsConfig: HostsConfig
    ) -> TargetRef {
        if source == "local" {
            return .local
        }
        return .remote(hostKey: hostsConfig.remoteHostKey(for: source))
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

        guard let terminalView = resolvedTerminalView(for: tileID) else {
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
            terminalRecentInputEvents: terminalView.debugRecentInputEvents,
            terminalSurfaceMetrics: terminalView.surfaceMetricsSnapshotForTesting()
        )
    }

    private func terminalRegistrationStateSnapshot(
        for args: [String]
    ) -> TerminalRegistrationStateSnapshot {
        let tileID = (try? tileID(from: args, command: terminalRegistrationStateCommand)) ?? UUID()
        let renderedState = resolvedRenderedState(for: tileID)
        let registrySurfaceHandle = GhosttyTerminalSurfaceRegistry.shared.surfaceHandle(forTileID: tileID)
        let resolvedSurfaceHandle = resolvedRenderedSurfaceHandle(for: tileID)
        let activeLeafID = TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID)
        let resolvedLeafID = resolvedTerminalLeafID(for: tileID)

        let mainTerminalMode: String
        let mainTerminalSessionName: String?
        switch mainTerminalStore.mode {
        case .plainShell:
            mainTerminalMode = "plainShell"
            mainTerminalSessionName = nil
        case .tmux(let sessionRef, _, _):
            mainTerminalMode = "tmux"
            mainTerminalSessionName = sessionRef.sessionName
        }

        return TerminalRegistrationStateSnapshot(
            tileID: tileID.uuidString,
            terminalHostMode: (renderedState?.context.terminalHostMode ?? terminalHostMode).rawValue,
            mainTerminalSurfaceID: mainTerminalStore.surfaceID.uuidString,
            tileMatchesMainTerminalSurface: tileID == mainTerminalStore.surfaceID,
            mainTerminalMode: mainTerminalMode,
            mainTerminalSessionName: mainTerminalSessionName,
            mainTerminalFocusRequestNonce: mainTerminalStore.focusRequestNonce,
            renderedStatePresent: renderedState != nil,
            renderedSurfaceGeneration: renderedState?.generation ?? 0,
            registrySurfaceHandlePresent: registrySurfaceHandle != nil,
            resolvedSurfaceHandlePresent: resolvedSurfaceHandle != nil,
            activeLeafID: activeLeafID?.uuidString,
            resolvedLeafID: resolvedLeafID?.uuidString,
            viewForTileLeafPresent: SurfacePool.shared.view(leafID: tileID) != nil,
            viewForResolvedLeafPresent: resolvedLeafID.flatMap { SurfacePool.shared.view(leafID: $0) } != nil,
            viewForRegistrySurfaceHandlePresent: registrySurfaceHandle.flatMap {
                SurfacePool.shared.view(forSurfaceHandle: $0)
            } != nil,
            viewForResolvedSurfaceHandlePresent: resolvedSurfaceHandle.flatMap {
                SurfacePool.shared.view(forSurfaceHandle: $0)
            } != nil,
            resolvedTerminalViewPresent: resolvedTerminalView(for: tileID) != nil,
            surfacePool: SurfacePool.shared.telemetrySnapshotForTesting()
        )
    }

    private func focusTerminalHost(_ args: [String]) async throws {
        let tileID = try tileID(from: args, command: focusTerminalHostCommand)
        try await waitForTerminalViewRegistration(
            tileID: tileID,
            timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
        )
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
        guard let renderedClientTTY = resolvedRenderedState(for: tileID)?.clientTTY else {
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
        let clientName = try await WorkbenchV2TerminalNavigationResolver.resolveRenderedClientName(
            renderedClientTTY: renderedClientTTY,
            target: activePaneRef.target,
            hostsConfig: hostsConfig
        )
        uiTestBridgeDebugLog(
            "applyRenderedPaneNavigation clientName=\(clientName) tty=\(renderedClientTTY) pane=\(activePaneRef.paneID)"
        )
        _ = try await TmuxCommandRunner.shared.run(
            WorkbenchV2TerminalNavigationResolver.navigationCommand(
                for: activePaneRef,
                tmuxClientName: clientName
            ),
            source: source
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

    private func sourceLabel(
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
        SurfacePool.shared.resetTelemetryForTesting()
        NextHostPaneControllerTelemetry.shared.reset(tileID: tileID)
        viewModel.resetPublishTelemetryForTesting()
    }

    private func dumpScrollTelemetry(_ args: [String]) throws -> ScrollBenchTelemetrySnapshot {
        let terminalView = try terminalView(for: args, command: dumpScrollTelemetryCommand)
        let tileID = try tileID(from: args, command: dumpScrollTelemetryCommand)
        return ScrollBenchTelemetrySnapshot(
            scroll: terminalView.scrollTelemetrySnapshotForTesting(),
            app: GhosttyApp.surfaceDrawTelemetrySnapshotForTesting(),
            island: GhosttyIslandUpdateTelemetry.shared.snapshot(tileID: tileID),
            surfacePool: SurfacePool.shared.telemetrySnapshotForTesting(),
            nextHost: NextHostPaneControllerTelemetry.shared.snapshot(tileID: tileID),
            publish: viewModel.publishTelemetrySnapshotForTesting()
        )
    }

    func terminalViewportTextSnapshotForTesting(tileID: UUID) throws -> GhosttyTerminalView.ViewportTextSnapshot {
        guard let terminalView = resolvedTerminalView(for: tileID) else {
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

    func activeTerminalTargetSnapshotForTesting() async throws -> ActiveTerminalTargetSnapshot {
        try await activeTerminalTargetSnapshot()
    }

    func focusRenderedPaneForTesting(tileID: UUID, paneID: String) async throws {
        try await focusRenderedPane([focusRenderedPaneCommand, tileID.uuidString, paneID])
    }

    func focusTerminalHostForTesting(tileID: UUID) async throws {
        try await focusTerminalHost([focusTerminalHostCommand, tileID.uuidString])
    }

    func terminalRegistrationStateSnapshotForTesting(tileID: UUID) -> Data {
        let snapshot = terminalRegistrationStateSnapshot(for: [terminalRegistrationStateCommand, tileID.uuidString])
        return (try? JSONEncoder().encode(snapshot)) ?? Data()
    }

    @MainActor
    func startCommandLoopIfNeededForTesting() {
        startCommandLoopIfNeeded()
    }

    @MainActor
    func processedCommandCountForTesting() -> Int {
        processedCommandCount
    }

    @MainActor
    func waitForCommandLoopIdleForTesting(timeoutMilliseconds: Int = 1_000) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + (Double(timeoutMilliseconds) / 1000.0)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if commandLoopTask == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "UITestTmuxBridge",
            code: 64,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for command loop to become idle"]
        )
    }

    @MainActor
    func focusExistingTerminalTileForTesting(
        sessionName: String? = nil
    ) throws -> FocusExistingTerminalTileSnapshot {
        var args = [focusExistingTerminalTileCommand]
        if let sessionName, sessionName.isEmpty == false {
            args.append(sessionName)
        }
        return try focusExistingTerminalTile(args)
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

        return try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            var samples: [TerminalViewportTextSampleSnapshot] = []
            samples.reserveCapacity(sampleCount)
            let startUptime = ProcessInfo.processInfo.systemUptime

            for sampleIndex in 0..<sampleCount {
                let snapshot = try await MainActor.run {
                    try self.terminalViewportTextSnapshotForTesting(tileID: tileID)
                }
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
        }.value
    }

    func measureTerminalScrollBurstForTesting(
        tileID: UUID,
        verticalDelta: Double,
        repeatCount: Int,
        intervalMilliseconds: Int,
        sampleCount: Int,
        sampleIntervalMilliseconds: Int,
        phaseMode: TrackpadScrollPhaseMode
    ) async throws -> TerminalScrollBurstMeasurementSnapshot {
        guard repeatCount > 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 53,
                userInfo: [NSLocalizedDescriptionKey: "repeatCount must be greater than zero"]
            )
        }
        guard intervalMilliseconds >= 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 54,
                userInfo: [NSLocalizedDescriptionKey: "intervalMilliseconds must be non-negative"]
            )
        }
        guard sampleCount > 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 55,
                userInfo: [NSLocalizedDescriptionKey: "sampleCount must be greater than zero"]
            )
        }
        guard sampleIntervalMilliseconds >= 0 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 56,
                userInfo: [NSLocalizedDescriptionKey: "sampleIntervalMilliseconds must be non-negative"]
            )
        }

        let terminalView = try await measuredTerminalViewForTesting(tileID: tileID)
        let syntheticEvents = TrackpadScrollPhaseProfile.syntheticSequence(
            repeatCount: repeatCount,
            mode: phaseMode
        )
        let deliveredDeltaEventCount = syntheticEvents.reduce(into: 0) { partialResult, event in
            if event.deliversDelta {
                partialResult += 1
            }
        }
        let initialViewport = try await terminalViewportTextSnapshotAfterRegistrationForTesting(tileID: tileID)
        let sender = GhosttyTerminalView.InternalScrollInjectionSnapshot(
            mode: "bridge-internal",
            sent: true,
            trusted: true,
            precision: true,
            phaseMode: phaseMode.rawValue,
            scrollPixels: verticalDelta,
            scrollRepeat: repeatCount,
            scrollIntervalMs: intervalMilliseconds,
            deliveredEventCount: syntheticEvents.count,
            deliveredDeltaEventCount: deliveredDeltaEventCount,
            usesAlternateScroll: initialViewport.usesAlternateScroll
        )

        terminalView.prepareForInternalTrackpadScrollInjectionForTesting()

        let startUptime = ProcessInfo.processInfo.systemUptime
        let samplingTask = Task { @MainActor [self] in
            var samples: [TerminalViewportTextSampleSnapshot] = []
            samples.reserveCapacity(sampleCount)

            for sampleIndex in 0..<sampleCount {
                if sampleIndex > 0, sampleIntervalMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(sampleIntervalMilliseconds))
                }
                let snapshot = try await terminalViewportTextSnapshotAfterRegistrationForTesting(tileID: tileID)
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000.0
                samples.append(
                    TerminalViewportTextSampleSnapshot(
                        sampleIndex: sampleIndex,
                        elapsedMs: elapsedMs,
                        snapshot: snapshot
                    )
                )
            }

            return samples
        }

        let injectionTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))

            for (eventIndex, event) in syntheticEvents.enumerated() {
                terminalView.dispatchInternalTrackpadScrollStepForTesting(
                    verticalDelta: event.deliversDelta ? verticalDelta : 0,
                    phase: event.phase,
                    momentumPhase: event.momentumPhase
                )

                if eventIndex + 1 < syntheticEvents.count, intervalMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                }
            }
        }

        let samples = try await samplingTask.value
        try await injectionTask.value

        return TerminalScrollBurstMeasurementSnapshot(
            sender: sender,
            sampling: TerminalViewportTextSamplingSnapshot(samples: samples)
        )
    }

    private func dumpTerminalViewportText(_ args: [String]) async throws -> GhosttyTerminalView.ViewportTextSnapshot {
        let tileID = try tileID(from: args, command: dumpTerminalViewportTextCommand)
        return try await terminalViewportTextSnapshotAfterRegistrationForTesting(tileID: tileID)
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

    private func measureTerminalScrollBurst(_ args: [String]) async throws -> TerminalScrollBurstMeasurementSnapshot {
        guard args.count >= 8 else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 57,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(measureTerminalScrollBurstCommand) requires <tileID> <verticalDelta> <repeatCount> <intervalMs> <sampleCount> <sampleIntervalMs> <phaseMode>"
                ]
            )
        }

        let tileID = try tileID(from: args, command: measureTerminalScrollBurstCommand)
        guard let verticalDelta = Double(args[2]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 58,
                userInfo: [NSLocalizedDescriptionKey: "Invalid verticalDelta: \(args[2])"]
            )
        }
        guard let repeatCount = Int(args[3]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 59,
                userInfo: [NSLocalizedDescriptionKey: "Invalid repeatCount: \(args[3])"]
            )
        }
        guard let intervalMs = Int(args[4]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 60,
                userInfo: [NSLocalizedDescriptionKey: "Invalid intervalMs: \(args[4])"]
            )
        }
        guard let sampleCount = Int(args[5]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 61,
                userInfo: [NSLocalizedDescriptionKey: "Invalid sampleCount: \(args[5])"]
            )
        }
        guard let sampleIntervalMs = Int(args[6]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 62,
                userInfo: [NSLocalizedDescriptionKey: "Invalid sampleIntervalMs: \(args[6])"]
            )
        }
        guard let phaseMode = TrackpadScrollPhaseMode(rawValue: args[7]) else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 63,
                userInfo: [NSLocalizedDescriptionKey: "Invalid phaseMode: \(args[7])"]
            )
        }

        return try await measureTerminalScrollBurstForTesting(
            tileID: tileID,
            verticalDelta: verticalDelta,
            repeatCount: repeatCount,
            intervalMilliseconds: intervalMs,
            sampleCount: sampleCount,
            sampleIntervalMilliseconds: sampleIntervalMs,
            phaseMode: phaseMode
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

    private func measuredTerminalViewForTesting(tileID: UUID) async throws -> GhosttyTerminalView {
        try await waitForTerminalViewRegistration(
            tileID: tileID,
            timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
        )
        return try terminalView(
            for: [measureTerminalScrollBurstCommand, tileID.uuidString],
            command: measureTerminalScrollBurstCommand
        )
    }

    private func terminalViewportTextSnapshotAfterRegistrationForTesting(
        tileID: UUID
    ) async throws -> GhosttyTerminalView.ViewportTextSnapshot {
        try await waitForTerminalViewRegistration(
            tileID: tileID,
            timeoutMilliseconds: terminalViewRegistrationTimeoutMilliseconds
        )
        return try terminalViewportTextSnapshotForTesting(tileID: tileID)
    }

    private func terminalView(for args: [String], command: String) throws -> GhosttyTerminalView {
        uiTestBridgeDebugLog("terminalView lookup command=\(command) args=\(args)")
        let tileID = try tileID(from: args, command: command)
        guard let terminalView = resolvedTerminalView(for: tileID) else {
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
        if tileID == mainTerminalStore.surfaceID,
           let sessionRef = mainTerminalStore.sessionRef {
            return sessionRef
        }

        if let renderedSessionRef = resolvedRenderedState(for: tileID)?.context.sessionRef {
            return renderedSessionRef
        }

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

    private func workbenchOrViewportID(forTileID tileID: UUID) -> UUID {
        if tileID == mainTerminalStore.surfaceID {
            return mainTerminalStore.viewportID
        }

        if let renderedWorkbenchID = resolvedRenderedState(for: tileID)?.context.workbenchID {
            return renderedWorkbenchID
        }

        if let workbench = workbenchStore.workbenches.first(where: { workbench in
            workbench.tiles.contains(where: { $0.id == tileID })
        }) {
            return workbench.id
        }

        return tileID
    }

    private func resolvedTerminalLeafID(for tileID: UUID) -> UUID? {
        let renderedMode = resolvedRenderedState(for: tileID)?.context.terminalHostMode
        let expectedMode = renderedMode ?? terminalHostMode
        if expectedMode == .next {
            return TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID)
        }
        return TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID) ?? tileID
    }

    private func resolvedRenderedSurfaceHandle(for tileID: UUID) -> GhosttySurfaceHandle? {
        let tileRenderedState = GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID)
        let expectedMode = tileRenderedState?.context.terminalHostMode ?? terminalHostMode
        if expectedMode == .next,
           let activeLeafID = TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID),
           let terminalView = SurfacePool.shared.view(leafID: activeLeafID),
           let surface = terminalView.surface {
            return GhosttySurfaceHandle(surface: surface)
        }
        return GhosttyTerminalSurfaceRegistry.shared.surfaceHandle(forTileID: tileID)
    }

    private func resolvedRenderedState(for tileID: UUID) -> GhosttyRenderedTerminalSurfaceState? {
        if let surfaceHandle = resolvedRenderedSurfaceHandle(for: tileID),
           let renderedState = GhosttyTerminalSurfaceRegistry.shared.renderedState(forSurfaceHandle: surfaceHandle),
           renderedState.context.tileID == tileID {
            return renderedState
        }
        return GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID)
    }

    private func resolvedTerminalView(for tileID: UUID) -> GhosttyTerminalView? {
        let renderedMode = resolvedRenderedState(for: tileID)?.context.terminalHostMode
        let expectedMode = renderedMode ?? terminalHostMode
        if expectedMode == .next,
           let activeLeafID = TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forTileID: tileID),
           let terminalView = SurfacePool.shared.view(leafID: activeLeafID) {
            return terminalView
        }

        if let surfaceHandle = resolvedRenderedSurfaceHandle(for: tileID),
           let terminalView = SurfacePool.shared.view(forSurfaceHandle: surfaceHandle) {
            return terminalView
        }

        if let resolvedLeafID = resolvedTerminalLeafID(for: tileID),
           let terminalView = SurfacePool.shared.view(leafID: resolvedLeafID) {
            return terminalView
        }

        guard expectedMode == .next,
              let surfaceHandle = GhosttyTerminalSurfaceRegistry.shared.surfaceHandle(forTileID: tileID)
        else {
            return nil
        }
        return SurfacePool.shared.view(forSurfaceHandle: surfaceHandle)
    }

    private func resolveRenderedLiveTargetOrNil(
        renderedClientTTY: String,
        target: TargetRef,
        hostsConfig: HostsConfig
    ) async -> WorkbenchV2TerminalLiveTarget? {
        let resolver = resolveRenderedLiveTarget
        let timeoutMilliseconds = renderedLiveTargetTimeoutMilliseconds
        let resolved = await withTaskGroup(of: WorkbenchV2TerminalLiveTarget?.self) { group in
            group.addTask {
                try? await resolver(renderedClientTTY, target, hostsConfig)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if resolved == nil {
            uiTestBridgeDebugLog(
                "resolveRenderedLiveTarget timeout tty=\(renderedClientTTY) target=\(target) timeoutMs=\(timeoutMilliseconds)"
            )
        }
        return resolved
    }

    private func waitForTerminalViewRegistration(
        tileID: UUID,
        timeoutMilliseconds: Int = 5_000
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            let renderedMode = resolvedRenderedState(for: tileID)?
                .context
                .terminalHostMode
            let expectedMode = renderedMode ?? terminalHostMode
            let hasRenderedState = resolvedRenderedState(for: tileID) != nil
            if resolvedTerminalView(for: tileID) != nil,
               (expectedMode != .next || hasRenderedState) {
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
