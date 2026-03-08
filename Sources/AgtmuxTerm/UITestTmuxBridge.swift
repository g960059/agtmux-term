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

    private let viewModel: AppViewModel
    private let env: [String: String]
    private var commandLoopTask: Task<Void, Never>?
    private var createdSessions: Set<String> = []
    private let activeTerminalTargetCommand = "__agtmux_dump_active_terminal_target__"

    init(viewModel: AppViewModel, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.viewModel = viewModel
        self.env = env
    }

    func startIfNeeded() async {
        guard env["AGTMUX_UITEST"] == "1" else { return }

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
        guard request.args.first == activeTerminalTargetCommand else { return nil }

        do {
            let snapshot = try await activeTerminalTargetSnapshot()
            let data = try JSONEncoder().encode(snapshot)
            let stdout = String(decoding: data, as: UTF8.self)
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
            sessionRef: sessionRef,
            renderedClientTTY: renderedClientTTY,
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
}
