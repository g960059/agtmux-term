import Foundation

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

    private let viewModel: AppViewModel
    private let env: [String: String]
    private var commandLoopTask: Task<Void, Never>?
    private var createdSessions: Set<String> = []

    init(viewModel: AppViewModel, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.viewModel = viewModel
        self.env = env
    }

    func startIfNeeded() async {
        guard env["AGTMUX_UITEST"] == "1" else { return }

        if let scenarioJSON = env["AGTMUX_UITEST_TMUX_SCENARIO"],
           !scenarioJSON.isEmpty {
            await runBootstrapScenario(from: scenarioJSON)
        }

        startCommandLoopIfNeeded()
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
