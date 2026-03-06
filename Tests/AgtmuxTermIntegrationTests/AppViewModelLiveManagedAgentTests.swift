import Darwin
import Foundation
import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class AppViewModelLiveManagedAgentTests: XCTestCase {
    private actor StubInventoryClient: LocalPaneInventoryClient {
        private let panes: [AgtmuxPane]

        init(panes: [AgtmuxPane]) {
            self.panes = panes
        }

        func fetchPanes() async throws -> [AgtmuxPane] {
            panes
        }
    }

    private struct ShellResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct LiveHarness {
        let baseDir: URL
        let daemonSocketPath: String
        let daemonLogPath: String
        let tmuxPath: String
        let socketName: String
        let sessionName: String
        let claudePaneID: String
        let codexPaneID: String
        let inventoryPanes: [AgtmuxPane]
        let daemonProcess: Process
    }

    private func waitUntil(
        timeout: TimeInterval = 30.0,
        intervalMs: UInt64 = 250,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return await condition()
    }

    private func shellRun(
        _ args: [String],
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 15.0
    ) throws -> ShellResult {
        guard let executable = args.first else {
            throw XCTSkip("empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func assertCommandAvailable(_ path: String, name: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("\(name) not found at \(path)")
        }
    }

    private func assertAuthReady() throws {
        let claude = try shellRun(["/opt/homebrew/bin/claude", "auth", "status"], timeout: 10.0)
        guard claude.status == 0 else {
            throw XCTSkip("claude auth unavailable: \(claude.stderr)")
        }

        let codex = try shellRun(["/opt/homebrew/bin/codex", "login", "status"], timeout: 10.0)
        guard codex.status == 0 else {
            throw XCTSkip("codex auth unavailable: \(codex.stderr)")
        }
    }

    private func resolveDaemonBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["AGTMUX_LIVE_TEST_BIN"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sibling = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("agtmux")
            .appendingPathComponent("target")
            .appendingPathComponent("debug")
            .appendingPathComponent("agtmux")
            .path
        guard FileManager.default.isExecutableFile(atPath: sibling) else {
            throw XCTSkip("agtmux daemon binary not found; set AGTMUX_LIVE_TEST_BIN")
        }
        return sibling
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func tmuxBaseArgs(path: String, socketName: String) -> [String] {
        [path, "-f", "/dev/null", "-L", socketName]
    }

    private func tmuxRun(path: String, socketName: String, _ args: [String]) throws -> ShellResult {
        try shellRun(tmuxBaseArgs(path: path, socketName: socketName) + args)
    }

    private func tmuxSendLine(path: String, socketName: String, paneID: String, text: String) throws {
        let base = tmuxBaseArgs(path: path, socketName: socketName)
        let literal = try shellRun(base + ["send-keys", "-t", paneID, "-l", text])
        XCTAssertEqual(literal.status, 0, "tmux send-keys -l failed: \(literal.stderr)")
        let enter = try shellRun(base + ["send-keys", "-t", paneID, "C-m"])
        XCTAssertEqual(enter.status, 0, "tmux send-keys Enter failed: \(enter.stderr)")
    }

    private func tmuxCapture(path: String, socketName: String, paneID: String) throws -> String {
        let result = try tmuxRun(path: path, socketName: socketName, [
            "capture-pane", "-t", paneID, "-p", "-S", "-80"
        ])
        XCTAssertEqual(result.status, 0, "tmux capture-pane failed: \(result.stderr)")
        return result.stdout
    }

    private func waitForSocket(_ path: String, timeout: TimeInterval = 10.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("daemon socket not ready at \(path)")
    }

    private func makeInventoryPanes(
        tmuxPath: String,
        socketName: String,
        sessionName: String,
        paneIDs: [String]
    ) throws -> [AgtmuxPane] {
        let result = try tmuxRun(path: tmuxPath, socketName: socketName, [
            "list-panes",
            "-t", "\(sessionName):agents",
            "-F", "#{pane_id}\t#{session_name}\t#{window_id}\t#{window_name}"
        ])
        XCTAssertEqual(result.status, 0, "tmux list-panes failed: \(result.stderr)")

        let panesByID = Dictionary(
            uniqueKeysWithValues: result.stdout
                .split(separator: "\n")
                .compactMap { line -> (String, AgtmuxPane)? in
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard fields.count == 4 else { return nil }
                    let paneID = String(fields[0])
                    return (
                        paneID,
                        AgtmuxPane(
                            source: "local",
                            paneId: paneID,
                            sessionName: String(fields[1]),
                            windowId: String(fields[2]),
                            windowName: String(fields[3]),
                            activityState: .unknown,
                            presence: .unmanaged,
                            evidenceMode: .none,
                            currentCmd: "zsh"
                        )
                    )
                }
        )

        return try paneIDs.map { paneID in
            guard let pane = panesByID[paneID] else {
                throw XCTSkip("inventory pane \(paneID) missing from tmux list-panes output")
            }
            return pane
        }
    }

    private func startLiveHarness() throws -> LiveHarness {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        let claudePath = "/opt/homebrew/bin/claude"
        let codexPath = "/opt/homebrew/bin/codex"

        try assertCommandAvailable(tmuxPath, name: "tmux")
        try assertCommandAvailable(claudePath, name: "claude")
        try assertCommandAvailable(codexPath, name: "codex")
        try assertAuthReady()

        let daemonBinary = try resolveDaemonBinary()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let baseDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("agtmux-live-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let claudeDir = baseDir.appendingPathComponent("claude-work", isDirectory: true)
        let codexDir = baseDir.appendingPathComponent("codex-work", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let claudeGit = try shellRun(["/usr/bin/git", "-C", claudeDir.path, "init", "-q"])
        XCTAssertEqual(claudeGit.status, 0, "git init for claude workdir failed: \(claudeGit.stderr)")
        let codexGit = try shellRun(["/usr/bin/git", "-C", codexDir.path, "init", "-q"])
        XCTAssertEqual(codexGit.status, 0, "git init for codex workdir failed: \(codexGit.stderr)")

        let socketName = "agtmuxlive\(Int(Date().timeIntervalSince1970))\(Int.random(in: 1000...9999))"
        let sessionName = "agtmux-live-\(Int.random(in: 100_000...999_999))"
        let daemonSocketPath = baseDir.appendingPathComponent("agtmuxd.sock").path
        let daemonLogPath = baseDir.appendingPathComponent("daemon.log").path

        FileManager.default.createFile(atPath: daemonLogPath, contents: Data())
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: daemonLogPath))

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: daemonBinary)
        daemon.arguments = ["--socket-path", daemonSocketPath, "daemon", "--poll-interval-ms", "500"]
        var daemonEnv = ProcessInfo.processInfo.environment
        daemonEnv["AGTMUX_TMUX_SOCKET_NAME"] = socketName
        daemon.environment = daemonEnv
        daemon.standardInput = FileHandle.nullDevice
        daemon.standardOutput = logHandle
        daemon.standardError = logHandle
        try daemon.run()

        try waitForSocket(daemonSocketPath)

        let newSession = try tmuxRun(path: tmuxPath, socketName: socketName, [
            "new-session", "-d", "-s", sessionName, "-n", "agents", "zsh", "-l"
        ])
        XCTAssertEqual(newSession.status, 0, "tmux new-session failed: \(newSession.stderr)")
        let split = try tmuxRun(path: tmuxPath, socketName: socketName, [
            "split-window", "-h", "-t", "\(sessionName):agents", "zsh", "-l"
        ])
        XCTAssertEqual(split.status, 0, "tmux split-window failed: \(split.stderr)")

        let list = try tmuxRun(path: tmuxPath, socketName: socketName, [
            "list-panes", "-t", "\(sessionName):agents", "-F", "#{pane_index} #{pane_id}"
        ])
        XCTAssertEqual(list.status, 0, "tmux list-panes failed: \(list.stderr)")
        let sortedPaneIDs = list.stdout
            .split(separator: "\n")
            .sorted { lhs, rhs in
                Int(lhs.split(separator: " ").first ?? "0") ?? 0
                    < Int(rhs.split(separator: " ").first ?? "0") ?? 0
            }
            .compactMap { line in line.split(separator: " ").dropFirst().first.map(String.init) }
        guard sortedPaneIDs.count == 2 else {
            throw XCTSkip("expected 2 tmux panes, got \(sortedPaneIDs.count)")
        }

        let claudePaneID = sortedPaneIDs[0]
        let codexPaneID = sortedPaneIDs[1]
        let inventoryPanes = try makeInventoryPanes(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: sessionName,
            paneIDs: [claudePaneID, codexPaneID]
        )

        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: claudePaneID,
            text: "cd \(shellQuote(claudeDir.path))"
        )
        Thread.sleep(forTimeInterval: 1.0)
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: claudePaneID,
            text: "claude --dangerously-skip-permissions --model sonnet"
        )
        Thread.sleep(forTimeInterval: 6.0)
        let claudeCapture = try tmuxCapture(path: tmuxPath, socketName: socketName, paneID: claudePaneID)
        if claudeCapture.range(
            of: "Do you trust the contents of this directory|Yes, continue|Quick safety check|Yes, I trust this folder",
            options: .regularExpression
        ) != nil {
            _ = try shellRun(tmuxBaseArgs(path: tmuxPath, socketName: socketName) + [
                "send-keys", "-t", claudePaneID, "C-m"
            ])
        }

        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: codexPaneID,
            text: "cd \(shellQuote(codexDir.path))"
        )
        Thread.sleep(forTimeInterval: 1.0)
        let codexPrompt = "reply with probe-ok after sleep 30 by running bash -lc 'sleep 30; printf probe-ok'"
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: codexPaneID,
            text: "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json -m gpt-5.4 -c model_reasoning_effort='\"medium\"' \(shellQuote(codexPrompt))"
        )

        return LiveHarness(
            baseDir: baseDir,
            daemonSocketPath: daemonSocketPath,
            daemonLogPath: daemonLogPath,
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: sessionName,
            claudePaneID: claudePaneID,
            codexPaneID: codexPaneID,
            inventoryPanes: inventoryPanes,
            daemonProcess: daemon
        )
    }

    private func stopLiveHarness(_ harness: LiveHarness) {
        if harness.daemonProcess.isRunning {
            harness.daemonProcess.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if harness.daemonProcess.isRunning {
                kill(harness.daemonProcess.processIdentifier, SIGKILL)
            }
        }
        _ = try? tmuxRun(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            ["kill-server"]
        )
        try? FileManager.default.removeItem(at: harness.baseDir)
    }

    private func waitForManagedProviders(
        socketPath: String,
        paneIDs: [String],
        timeout: TimeInterval = 35.0
    ) async throws -> AgtmuxSyncV2Bootstrap {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastBootstrap: AgtmuxSyncV2Bootstrap?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                lastBootstrap = bootstrap
                let panesByID = Dictionary(uniqueKeysWithValues: bootstrap.panes.map { ($0.paneId, $0) })
                let claudeReady = panesByID[paneIDs[0]]?.presence == .managed
                    && panesByID[paneIDs[0]]?.provider == .claude
                let codexReady = panesByID[paneIDs[1]]?.presence == .managed
                    && panesByID[paneIDs[1]]?.provider == .codex
                if claudeReady && codexReady {
                    return bootstrap
                }
            } catch {
                // daemon may still be warming up; retry until deadline
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let detail = lastBootstrap.map { bootstrap in
            bootstrap.panes
                .filter { paneIDs.contains($0.paneId) }
                .map { "\($0.paneId)=\($0.presence.rawValue)/\($0.provider?.rawValue ?? "nil")" }
                .joined(separator: ", ")
        } ?? "no bootstrap"
        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "managed providers did not appear in daemon bootstrap: \(detail)"]
        )
    }

    @MainActor
    func testLiveManagedClaudeAndCodexAppearInAppViewModel() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )

        let model = AppViewModel(
            localClient: AgtmuxDaemonClient(socketPath: harness.daemonSocketPath),
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil(timeout: 10.0) {
            guard model.panes.count == 2 else { return false }
            let providers = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.paneId, $0.provider) })
            let presences = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.paneId, $0.presence) })
            return presences[harness.claudePaneID] == .managed
                && providers[harness.claudePaneID] == .claude
                && presences[harness.codexPaneID] == .managed
                && providers[harness.codexPaneID] == .codex
        }

        if !overlayApplied {
            let summary = model.panes
                .map { "\($0.paneId)=\($0.presence.rawValue)/\($0.provider?.rawValue ?? "nil")" }
                .joined(separator: ", ")
            let log = (try? String(contentsOfFile: harness.daemonLogPath, encoding: .utf8)) ?? ""
            XCTFail("live managed overlay missing in AppViewModel: \(summary)\n\(log)")
        }
    }
}
