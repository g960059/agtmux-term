import Foundation
import AgtmuxTermCore

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
        let workbenchID: String
        let tileID: String
        let sessionName: String
        let windowID: String
        let paneID: String
        let selectedPaneInventoryID: String
        let attachCommand: String
        let renderedAttachCommand: String
        let renderedClientTTY: String
        let renderedClientWindowID: String
        let renderedClientPaneID: String
        let renderedSurfaceGeneration: UInt64
    }

    private struct SidebarStateSnapshot: Codable {
        let statusFilter: String
        let panes: [AgtmuxPane]
        let panePresentations: [UITestSidebarPanePresentationSnapshot]
        let filteredPanes: [AgtmuxPane]
        let filteredPanePresentations: [UITestSidebarPanePresentationSnapshot]
        let attentionCount: Int
        let localDaemonIssueTitle: String?
        let localDaemonIssueDetail: String?
        let bootstrapProbeSummary: UITestBootstrapProbeSummary
        let bootstrapTargetSummary: UITestBootstrapTargetSummary?
        let managedDaemonSocketPath: String
        let tmuxSocketArguments: [String]
        let daemonCLIArguments: [String]
        let bootstrapResolvedTmuxSocketPath: String?
        let appDirectResolvedSocketProbe: String?
        let appDirectResolvedSocketProbeError: String?
        let daemonProcessCommands: [String]
        let daemonLaunchRecord: DaemonLaunchRecordSnapshot?
        let managedDaemonStderrTail: String?
    }

    private struct DaemonLaunchRecordSnapshot: Codable {
        let binaryPath: String
        let arguments: [String]
        let environment: [String: String]
        let reusedExistingRuntime: Bool
    }

    private let viewModel: AppViewModel
    private let enableMetadataMode: @MainActor () async -> Void
    private let env: [String: String]
    private var commandLoopTask: Task<Void, Never>?
    private var createdSessions: Set<String> = []
    private let activeTerminalTargetCommand = "__agtmux_dump_active_terminal_target__"
    private let sidebarStateCommand = "__agtmux_dump_sidebar_state__"
    private let enableMetadataCommand = "__agtmux_enable_metadata__"

    init(
        viewModel: AppViewModel,
        enableMetadataMode: @escaping @MainActor () async -> Void = {},
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.viewModel = viewModel
        self.enableMetadataMode = enableMetadataMode
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
                                error: "scenario decode failed: \(error.localizedDescription)")
            )
            return
        }

        do {
            let windowName = scenario.windowName ?? "main"
            let paneCount = max(1, scenario.paneCount ?? 1)
            let shellCommand = scenario.shellCommand ?? "/bin/sleep 600"

            // Ensure idempotency for repeated launches.
            _ = try? await TmuxCommandRunner.shared.run(
                ["kill-session", "-t", scenario.sessionName],
                source: "local"
            )

            _ = try await TmuxCommandRunner.shared.run(
                ["new-session", "-d", "-s", scenario.sessionName, "-n", windowName, shellCommand],
                source: "local"
            )
            createdSessions.insert(scenario.sessionName)

            if paneCount > 1 {
                for _ in 1..<paneCount {
                    _ = try await TmuxCommandRunner.shared.run(
                        ["split-window", "-t", "\(scenario.sessionName):\(windowName)", "-h", shellCommand],
                        source: "local"
                    )
                }
            }

            let windowOutput = try await TmuxCommandRunner.shared.run(
                ["list-windows", "-t", scenario.sessionName, "-F", "#{window_id}"],
                source: "local"
            )
            let windowID = windowOutput
                .components(separatedBy: "\n")
                .first(where: { !$0.isEmpty }) ?? "@0"

            let panesOutput = try await TmuxCommandRunner.shared.run(
                ["list-panes", "-t", scenario.sessionName, "-F", "#{pane_id}"],
                source: "local"
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
                    error: nil
                )
            )
        } catch {
            writeBootstrapResult(
                BootstrapResult(ok: false, sessionName: scenario.sessionName, windowID: nil, paneIDs: [],
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
                let snapshot = SidebarStateSnapshot(
                    statusFilter: viewModel.statusFilter.rawValue,
                    panes: viewModel.panes,
                    panePresentations: viewModel.panes.map(sidebarPanePresentationSnapshot(for:)),
                    filteredPanes: viewModel.filteredPanes,
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
                        DaemonLaunchRecordSnapshot(
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
        guard let workbench = workbenchStoreV2.activeWorkbench else {
            throw NSError(
                domain: "UITestTmuxBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No active workbench"]
            )
        }

        let selection = workbenchStoreV2.activePaneSelection(
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

        guard let activePaneContext = workbenchStoreV2.activePaneContext,
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

        let renderedClientTarget = try await WorkbenchV2TerminalNavigationResolver.liveTarget(
            renderedClientTTY: renderedClientTTY,
            target: sessionRef.target,
            hostsConfig: viewModel.hostsConfig
        )

        return ActiveTerminalTargetSnapshot(
            workbenchID: selection.workbenchID.uuidString,
            tileID: terminalTile.id.uuidString,
            sessionName: sessionRef.sessionName,
            windowID: selection.windowID,
            paneID: selection.paneID,
            selectedPaneInventoryID: selectedPaneInventoryID,
            attachCommand: attachPlan.command,
            renderedAttachCommand: renderedState.attachCommand,
            renderedClientTTY: renderedClientTTY,
            renderedClientWindowID: renderedClientTarget.windowID,
            renderedClientPaneID: renderedClientTarget.paneID,
            renderedSurfaceGeneration: renderedState.generation
        )
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

    private func resolveBootstrapTmuxSocketPath() async throws -> String {
        let output = try await TmuxCommandRunner.shared.run(
            ["display-message", "-p", "#{socket_path}"],
            source: "local"
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
