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

    private struct SameSessionCodexHarness {
        let baseDir: URL
        let daemonSocketPath: String
        let daemonLogPath: String
        let tmuxPath: String
        let socketName: String
        let sessionName: String
        let firstCodexPaneID: String
        let secondCodexPaneID: String
        let inventoryPanes: [AgtmuxPane]
        let daemonProcess: Process
    }

    private static let claudeLifecyclePrompt = """
    Step 1: use bash to run 'sleep 12'.
    Step 2: use bash to count lines in /etc/hosts.
    Step 3: reply with the count only.
    """

    private static let codexLifecyclePrompt = """
    Step 1: use bash to run 'sleep 12'.
    Step 2: use bash to count lines in /etc/hosts.
    Step 3: reply with the count only.
    """

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

    private func isShellCommand(_ command: String?) -> Bool {
        guard let command else {
            return false
        }
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "zsh", "bash", "fish", "sh", "csh", "tcsh", "ksh", "dash", "nu", "pwsh":
            return true
        default:
            return false
        }
    }

    private func environmentValue(_ key: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
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

    private func waitForTmuxCurrentCommand(
        path: String,
        socketName: String,
        paneID: String,
        expected: String,
        timeout: TimeInterval = 30.0
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastActual = ""

        while Date() < deadline {
            let result = try tmuxRun(path: path, socketName: socketName, [
                "display-message", "-p", "-t", paneID, "#{pane_current_command}"
            ])
            XCTAssertEqual(result.status, 0, "tmux display-message failed: \(result.stderr)")
            lastActual = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if lastActual == expected {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTFail("pane \(paneID) did not return to tmux current command \(expected); last=\(lastActual)")
    }

    private func waitForTmuxShellCommand(
        path: String,
        socketName: String,
        paneID: String,
        timeout: TimeInterval = 30.0
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastActual = ""

        while Date() < deadline {
            let result = try tmuxRun(path: path, socketName: socketName, [
                "display-message", "-p", "-t", paneID, "#{pane_current_command}"
            ])
            XCTAssertEqual(result.status, 0, "tmux display-message failed: \(result.stderr)")
            lastActual = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if isShellCommand(lastActual) {
                return lastActual
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTFail("pane \(paneID) did not return to a shell command; last=\(lastActual)")
        return lastActual
    }

    private func waitForPaneChildProcess(
        path: String,
        socketName: String,
        paneID: String,
        timeout: TimeInterval = 30.0
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let panePIDResult = try tmuxRun(path: path, socketName: socketName, [
                "display-message", "-p", "-t", paneID, "#{pane_pid}"
            ])
            XCTAssertEqual(panePIDResult.status, 0, "tmux pane_pid lookup failed: \(panePIDResult.stderr)")
            let shellPID = panePIDResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shellPID.isEmpty {
                let childLookup = try shellRun(["/usr/bin/pgrep", "-P", shellPID], timeout: 5.0)
                if childLookup.status == 0,
                   !childLookup.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTFail("no child process appeared under pane shell for \(paneID)")
    }

    private func killPaneChildren(
        path: String,
        socketName: String,
        paneID: String
    ) throws {
        let panePIDResult = try tmuxRun(path: path, socketName: socketName, [
            "display-message", "-p", "-t", paneID, "#{pane_pid}"
        ])
        XCTAssertEqual(panePIDResult.status, 0, "tmux pane_pid lookup failed: \(panePIDResult.stderr)")
        let shellPID = panePIDResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(shellPID.isEmpty, "expected pane shell pid for \(paneID)")

        let childLookup = try shellRun(["/usr/bin/pgrep", "-P", shellPID], timeout: 5.0)
        let childPIDs = childLookup.stdout
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
        XCTAssertFalse(childPIDs.isEmpty, "expected live child processes under pane \(paneID)")

        for pid in childPIDs {
            _ = try shellRun(["/bin/kill", "-TERM", pid], timeout: 5.0)
        }
        Thread.sleep(forTimeInterval: 1.0)
        for pid in childPIDs {
            _ = try shellRun(["/bin/kill", "-KILL", pid], timeout: 5.0)
        }
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

    private func startLiveHarness(
        claudePrompt: String? = nil,
        codexPrompt: String? = nil
    ) throws -> LiveHarness {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        let claudePath = "/opt/homebrew/bin/claude"
        let codexPath = "/opt/homebrew/bin/codex"
        let claudeModel = environmentValue("CLAUDE_MODEL") ?? "claude-sonnet-4-6"
        let codexModel = environmentValue("CODEX_MODEL") ?? "gpt-5.4"

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
        let resolvedClaudePrompt = claudePrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: claudePaneID,
            text: {
                if let resolvedClaudePrompt, !resolvedClaudePrompt.isEmpty {
                    return "claude --dangerously-skip-permissions --model \(shellQuote(claudeModel)) -p \(shellQuote(resolvedClaudePrompt))"
                }
                return "claude --dangerously-skip-permissions --model \(shellQuote(claudeModel))"
            }()
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
        let resolvedCodexPrompt = codexPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? codexPrompt!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.codexLifecyclePrompt
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: codexPaneID,
            text: "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json -m \(shellQuote(codexModel)) -c model_reasoning_effort='\"medium\"' \(shellQuote(resolvedCodexPrompt))"
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

    private func startSameSessionCodexHarness() throws -> SameSessionCodexHarness {
        let tmuxPath = "/opt/homebrew/bin/tmux"
        let codexPath = "/opt/homebrew/bin/codex"
        let codexModel = environmentValue("CODEX_MODEL") ?? "gpt-5.4"

        try assertCommandAvailable(tmuxPath, name: "tmux")
        try assertCommandAvailable(codexPath, name: "codex")
        try assertAuthReady()

        let daemonBinary = try resolveDaemonBinary()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let baseDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("agtmux-live-codex-nobleed-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let sharedDir = baseDir.appendingPathComponent("shared-work", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let codexGit = try shellRun(["/usr/bin/git", "-C", sharedDir.path, "init", "-q"])
        XCTAssertEqual(codexGit.status, 0, "git init for shared codex workdir failed: \(codexGit.stderr)")

        let socketName = "agtmuxlivecodex\(Int(Date().timeIntervalSince1970))\(Int.random(in: 1000...9999))"
        let sessionName = "agtmux-codex-\(Int.random(in: 100_000...999_999))"
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

        let firstPaneID = sortedPaneIDs[0]
        let secondPaneID = sortedPaneIDs[1]
        let inventoryPanes = try makeInventoryPanes(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: sessionName,
            paneIDs: [firstPaneID, secondPaneID]
        )

        let firstPrompt = "Run exactly one bash command and do not run any additional commands. Wait 30 seconds by using sleep 30. bash -lc 'sleep 30; printf \"wait_result=first\\n\"'. Do not simulate, infer, or guess. Output only one non-empty line. Required output format: wait_result=first"
        let secondPrompt = "Run exactly one bash command and do not run any additional commands. Wait 30 seconds by using sleep 30. bash -lc 'sleep 30; printf \"wait_result=second\\n\"'. Do not simulate, infer, or guess. Output only one non-empty line. Required output format: wait_result=second"

        for paneID in [firstPaneID, secondPaneID] {
            try tmuxSendLine(
                path: tmuxPath,
                socketName: socketName,
                paneID: paneID,
                text: "cd \(shellQuote(sharedDir.path))"
            )
            Thread.sleep(forTimeInterval: 1.0)
        }

        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: firstPaneID,
            text: "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json -m \(shellQuote(codexModel)) -c model_reasoning_effort='\"medium\"' \(shellQuote(firstPrompt))"
        )
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: secondPaneID,
            text: "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json -m \(shellQuote(codexModel)) -c model_reasoning_effort='\"medium\"' \(shellQuote(secondPrompt))"
        )

        return SameSessionCodexHarness(
            baseDir: baseDir,
            daemonSocketPath: daemonSocketPath,
            daemonLogPath: daemonLogPath,
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: sessionName,
            firstCodexPaneID: firstPaneID,
            secondCodexPaneID: secondPaneID,
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

    private func stopSameSessionCodexHarness(_ harness: SameSessionCodexHarness) {
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

    private func waitForManagedProviderAssignments(
        socketPath: String,
        expectedProviders: [String: Provider],
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
                let allReady = expectedProviders.allSatisfy { paneID, provider in
                    panesByID[paneID]?.presence == .managed && panesByID[paneID]?.provider == provider
                }
                if allReady {
                    return bootstrap
                }
            } catch {
                // daemon may still be warming up; retry until deadline
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let detail = lastBootstrap.map { bootstrap in
            bootstrap.panes
                .filter { expectedProviders.keys.contains($0.paneId) }
                .map { "\($0.paneId)=\($0.presence.rawValue)/\($0.provider?.rawValue ?? "nil")" }
                .joined(separator: ", ")
        } ?? "no bootstrap"
        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "managed providers did not appear in daemon bootstrap: \(detail)"]
        )
    }

    private func waitForManagedProviders(
        socketPath: String,
        paneIDs: [String],
        timeout: TimeInterval = 35.0
    ) async throws -> AgtmuxSyncV2Bootstrap {
        try await waitForManagedProviderAssignments(
            socketPath: socketPath,
            expectedProviders: [
                paneIDs[0]: .claude,
                paneIDs[1]: .codex,
            ],
            timeout: timeout
        )
    }

    private func relevantPanesByID(
        _ panes: [AgtmuxPane],
        paneIDs: [String]
    ) -> [String: AgtmuxPane] {
        Dictionary(
            uniqueKeysWithValues: panes
                .filter { paneIDs.contains($0.paneId) }
                .map { ($0.paneId, $0) }
        )
    }

    private func paneSummary(_ pane: AgtmuxPane?) -> String {
        guard let pane else { return "missing" }
        return [
            "presence=\(pane.presence.rawValue)",
            "provider=\(pane.provider?.rawValue ?? "nil")",
            "activity=\(pane.activityState.rawValue)",
            "evidence=\(pane.evidenceMode.rawValue)",
            "session_key=\(pane.metadataSessionKey ?? "nil")",
            "pane_instance=\(String(describing: pane.paneInstanceID))"
        ].joined(separator: " ")
    }

    private func paneTruthSummary(
        panesByID: [String: AgtmuxPane],
        paneIDs: [String]
    ) -> String {
        paneIDs
            .map { paneID in "\(paneID){\(paneSummary(panesByID[paneID]))}" }
            .joined(separator: ", ")
    }

    private func waitForDaemonPaneActivity(
        socketPath: String,
        paneID: String,
        expected: ActivityState,
        timeout: TimeInterval = 45.0
    ) async throws -> AgtmuxPane {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastPane: AgtmuxPane?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                let panesByID = relevantPanesByID(bootstrap.panes, paneIDs: [paneID])
                if let pane = panesByID[paneID] {
                    lastPane = pane
                    if pane.activityState == expected {
                        return pane
                    }
                }
            } catch {
                // daemon may still be warming up; retry until deadline
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "daemon pane \(paneID) did not reach \(expected.rawValue); last=\(paneSummary(lastPane))"
            ]
        )
    }

    private func waitForDaemonPaneActivityAny(
        socketPath: String,
        paneID: String,
        expectedStates: [ActivityState],
        timeout: TimeInterval = 90.0
    ) async throws -> AgtmuxPane {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastPane: AgtmuxPane?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                let panesByID = relevantPanesByID(bootstrap.panes, paneIDs: [paneID])
                if let pane = panesByID[paneID] {
                    lastPane = pane
                    if expectedStates.contains(where: { $0 == pane.activityState }) {
                        return pane
                    }
                }
            } catch {
                // daemon may still be warming up; retry until deadline
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let expectedLabels = expectedStates.map(\.rawValue).joined(separator: ", ")
        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "daemon pane \(paneID) did not reach any of [\(expectedLabels)]; last=\(paneSummary(lastPane))"
            ]
        )
    }

    private func waitForDaemonCompletionOrShellDemotion(
        socketPath: String,
        paneID: String,
        timeout: TimeInterval = 90.0
    ) async throws -> AgtmuxPane {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastPane: AgtmuxPane?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                let panesByID = relevantPanesByID(bootstrap.panes, paneIDs: [paneID])
                if let pane = panesByID[paneID] {
                    lastPane = pane
                    let managedCompletion = pane.presence == .managed
                        && (pane.activityState == .waitingInput || pane.activityState == .idle)
                    let shellDemotion = pane.presence == .unmanaged
                        && pane.provider == nil
                        && pane.activityState == .unknown
                        && isShellCommand(pane.currentCmd)
                    if managedCompletion || shellDemotion {
                        return pane
                    }
                }
            } catch {
                // daemon may still be warming up; retry until deadline
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "daemon pane \(paneID) did not reach managed completion or shell demotion; last=\(paneSummary(lastPane))"
            ]
        )
    }

    private func assertDemotedPaneStaysUnmanagedWhileSiblingRunning(
        socketPath: String,
        demotedPaneID: String,
        runningPaneID: String,
        duration: TimeInterval = 10.0
    ) async throws {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(duration)
        var lastDemoted: AgtmuxPane?
        var lastRunning: AgtmuxPane?

        while Date() < deadline {
            let bootstrap = try await client.fetchUIBootstrapV2()
            let panesByID = relevantPanesByID(bootstrap.panes, paneIDs: [demotedPaneID, runningPaneID])
            lastDemoted = panesByID[demotedPaneID]
            lastRunning = panesByID[runningPaneID]

            let demotedOkay = lastDemoted?.presence == .unmanaged
                && lastDemoted?.provider == nil
                && lastDemoted?.activityState == .unknown
                && isShellCommand(lastDemoted?.currentCmd)
            let runningOkay = lastRunning?.presence == .managed
                && lastRunning?.provider == .codex
                && lastRunning?.activityState == .running

            if !(demotedOkay && runningOkay) {
                throw NSError(
                    domain: "AppViewModelLiveManagedAgentTests",
                    code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "demoted pane or running sibling drifted during no-bleed window; demoted=\(paneSummary(lastDemoted)) running=\(paneSummary(lastRunning))"
                    ]
                )
            }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }


    private func panesMatchDaemonTruth(
        daemonPanesByID: [String: AgtmuxPane],
        appPanesByID: [String: AgtmuxPane],
        paneIDs: [String]
    ) -> Bool {
        paneIDs.allSatisfy { paneID in
            guard let daemonPane = daemonPanesByID[paneID],
                  let appPane = appPanesByID[paneID] else {
                return false
            }

            return appPane.presence == daemonPane.presence
                && appPane.provider == daemonPane.provider
                && appPane.activityState == daemonPane.activityState
                && appPane.evidenceMode == daemonPane.evidenceMode
                && appPane.metadataSessionKey == daemonPane.metadataSessionKey
                && appPane.paneInstanceID == daemonPane.paneInstanceID
        }
    }

    @MainActor
    private func waitForAppRowsToMatchDaemonTruth(
        model: AppViewModel,
        socketPath: String,
        paneIDs: [String],
        timeout: TimeInterval = 20.0
    ) async throws -> (daemon: [String: AgtmuxPane], app: [String: AgtmuxPane]) {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastDaemon: [String: AgtmuxPane] = [:]
        var lastApp: [String: AgtmuxPane] = [:]

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                lastDaemon = relevantPanesByID(bootstrap.panes, paneIDs: paneIDs)
            } catch {
                // daemon may still be warming up; retry until deadline
            }

            await model.fetchAll()
            lastApp = relevantPanesByID(model.panes, paneIDs: paneIDs)

            if panesMatchDaemonTruth(
                daemonPanesByID: lastDaemon,
                appPanesByID: lastApp,
                paneIDs: paneIDs
            ) {
                return (lastDaemon, lastApp)
            }

            try? await Task.sleep(for: .milliseconds(750))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "app rows did not converge to daemon truth; daemon=\(paneTruthSummary(panesByID: lastDaemon, paneIDs: paneIDs)) app=\(paneTruthSummary(panesByID: lastApp, paneIDs: paneIDs))"
            ]
        )
    }

    @MainActor
    private func waitForAppPaneToSurfaceDaemonActivity(
        model: AppViewModel,
        socketPath: String,
        paneID: String,
        expectedActivity: ActivityState,
        timeout: TimeInterval = 30.0
    ) async throws -> (daemon: AgtmuxPane, app: AgtmuxPane) {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastDaemon: AgtmuxPane?
        var lastApp: AgtmuxPane?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV2()
                let daemonPanes = relevantPanesByID(bootstrap.panes, paneIDs: [paneID])
                lastDaemon = daemonPanes[paneID]
            } catch {
                // daemon may still be warming up; retry until deadline
            }

            await model.fetchAll()
            lastApp = relevantPanesByID(model.panes, paneIDs: [paneID])[paneID]

            if let daemon = lastDaemon,
               let app = lastApp,
               daemon.activityState == expectedActivity,
               app.presence == daemon.presence,
               app.provider == daemon.provider,
               app.activityState == daemon.activityState,
               app.evidenceMode == daemon.evidenceMode,
               app.metadataSessionKey == daemon.metadataSessionKey,
               app.paneInstanceID == daemon.paneInstanceID {
                return (daemon, app)
            }

            try? await Task.sleep(for: .milliseconds(300))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "app row \(paneID) did not surface daemon activity \(expectedActivity.rawValue); daemon=\(paneSummary(lastDaemon)) app=\(paneSummary(lastApp))"
            ]
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

    @MainActor
    func testLivePlainZshAgentLaunchSurfacesManagedFilterProviderAndActivity() async throws {
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

        let truth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 20.0
        )

        model.statusFilter = .managed
        let filteredPaneIDs = Set(model.filteredPanes.map(\.paneId))
        XCTAssertEqual(
            filteredPaneIDs,
            Set([harness.claudePaneID, harness.codexPaneID]),
            "plain zsh panes that launched live Claude/Codex must remain visible under the managed filter"
        )

        XCTAssertEqual(model.filteredPanes.count, 2)
        XCTAssertEqual(model.filteredPanes.first { $0.paneId == harness.claudePaneID }?.provider, .claude)
        XCTAssertEqual(model.filteredPanes.first { $0.paneId == harness.codexPaneID }?.provider, .codex)
        XCTAssertEqual(
            model.filteredPanes.first { $0.paneId == harness.claudePaneID }?.activityState,
            truth.daemon[harness.claudePaneID]?.activityState,
            "Claude row activity must match daemon truth under the managed filter"
        )
        XCTAssertEqual(
            model.filteredPanes.first { $0.paneId == harness.codexPaneID }?.activityState,
            truth.daemon[harness.codexPaneID]?.activityState,
            "Codex row activity must match daemon truth under the managed filter"
        )
    }

    @MainActor
    func testLiveCodexActivityTruthReachesExactAppRowWithoutBleed() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )

        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            expected: .running,
            timeout: 45.0
        )

        let model = AppViewModel(
            localClient: AgtmuxDaemonClient(socketPath: harness.daemonSocketPath),
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let runningTruth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 20.0
        )

        XCTAssertEqual(
            runningTruth.app[harness.codexPaneID]?.activityState,
            .running,
            "Codex row must surface running when the daemon reports running"
        )
        XCTAssertEqual(
            runningTruth.app[harness.codexPaneID]?.provider,
            .codex,
            "Codex row must keep exact-row provider truth"
        )
        XCTAssertEqual(
            runningTruth.app[harness.claudePaneID]?.provider,
            runningTruth.daemon[harness.claudePaneID]?.provider,
            "Sibling pane must preserve its own daemon provider truth"
        )
        XCTAssertEqual(
            runningTruth.app[harness.claudePaneID]?.activityState,
            runningTruth.daemon[harness.claudePaneID]?.activityState,
            "Sibling pane must preserve its own daemon activity truth"
        )

        _ = try await waitForDaemonCompletionOrShellDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            timeout: 120.0
        )

        let completionTruth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 25.0
        )

        XCTAssertEqual(
            completionTruth.app[harness.codexPaneID]?.presence,
            completionTruth.daemon[harness.codexPaneID]?.presence,
            "Codex row must converge to current daemon presence after leaving running"
        )
        XCTAssertEqual(
            completionTruth.app[harness.codexPaneID]?.provider,
            completionTruth.daemon[harness.codexPaneID]?.provider,
            "Codex row must converge to current daemon provider after leaving running"
        )
        XCTAssertEqual(
            completionTruth.app[harness.codexPaneID]?.activityState,
            completionTruth.daemon[harness.codexPaneID]?.activityState,
            "Codex row must converge to current daemon activity after leaving running"
        )
        XCTAssertNotEqual(
            completionTruth.app[harness.codexPaneID]?.activityState,
            .running,
            "Codex row must not remain stale-running after completion or shell demotion"
        )
    }

    @MainActor
    func testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed() async throws {
        let harness = try startLiveHarness(claudePrompt: Self.claudeLifecyclePrompt)
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )

        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.claudePaneID,
            expected: .running,
            timeout: 45.0
        )

        let model = AppViewModel(
            localClient: AgtmuxDaemonClient(socketPath: harness.daemonSocketPath),
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let runningTruth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 20.0
        )

        XCTAssertEqual(
            runningTruth.app[harness.claudePaneID]?.activityState,
            .running,
            "Claude row must surface running when the daemon reports running"
        )
        XCTAssertEqual(
            runningTruth.app[harness.claudePaneID]?.provider,
            .claude,
            "Claude row must keep exact-row provider truth"
        )
        XCTAssertEqual(
            runningTruth.app[harness.codexPaneID]?.provider,
            runningTruth.daemon[harness.codexPaneID]?.provider,
            "Sibling Codex row must preserve its own daemon provider truth"
        )
        XCTAssertEqual(
            runningTruth.app[harness.codexPaneID]?.activityState,
            runningTruth.daemon[harness.codexPaneID]?.activityState,
            "Sibling Codex row must preserve its own daemon activity truth"
        )

        _ = try await waitForDaemonCompletionOrShellDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.claudePaneID,
            timeout: 120.0
        )

        let completionTruth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 25.0
        )

        XCTAssertEqual(
            completionTruth.app[harness.claudePaneID]?.presence,
            completionTruth.daemon[harness.claudePaneID]?.presence,
            "Claude row must converge to current daemon presence after leaving running"
        )
        XCTAssertEqual(
            completionTruth.app[harness.claudePaneID]?.provider,
            completionTruth.daemon[harness.claudePaneID]?.provider,
            "Claude row must converge to current daemon provider after leaving running"
        )
        XCTAssertEqual(
            completionTruth.app[harness.claudePaneID]?.activityState,
            completionTruth.daemon[harness.claudePaneID]?.activityState,
            "Claude row must converge to current daemon activity after leaving running"
        )
        XCTAssertNotEqual(
            completionTruth.app[harness.claudePaneID]?.activityState,
            .running,
            "Claude row must not remain stale-running after completion or shell demotion"
        )
    }

    @MainActor
    func testLiveCodexManagedExitDemotesExactRowBackToShellTruth() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )

        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            expected: .running,
            timeout: 45.0
        )
        try waitForPaneChildProcess(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.codexPaneID,
            timeout: 45.0
        )

        try killPaneChildren(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.codexPaneID
        )
        let shellCommand = try waitForTmuxShellCommand(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.codexPaneID,
            timeout: 20.0
        )
        XCTAssertTrue(isShellCommand(shellCommand))

        let demotedPane = try await waitForDaemonCompletionOrShellDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            timeout: 30.0
        )
        XCTAssertEqual(demotedPane.presence, .unmanaged)
        XCTAssertNil(demotedPane.provider)
        XCTAssertEqual(demotedPane.activityState, .unknown)
        XCTAssertTrue(isShellCommand(demotedPane.currentCmd))

        let model = AppViewModel(
            localClient: AgtmuxDaemonClient(socketPath: harness.daemonSocketPath),
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )
        let truth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID],
            timeout: 20.0
        )

        XCTAssertEqual(truth.app[harness.codexPaneID]?.presence, .unmanaged)
        XCTAssertNil(truth.app[harness.codexPaneID]?.provider)
        XCTAssertEqual(truth.app[harness.codexPaneID]?.activityState, .unknown)
    }

    @MainActor
    func testLiveSameSessionCodexNoBleedAfterSiblingDemotion() async throws {
        let harness = try startSameSessionCodexHarness()
        defer { stopSameSessionCodexHarness(harness) }

        _ = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [
                harness.firstCodexPaneID: .codex,
                harness.secondCodexPaneID: .codex,
            ]
        )

        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.firstCodexPaneID,
            expected: .running,
            timeout: 45.0
        )
        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.secondCodexPaneID,
            expected: .running,
            timeout: 45.0
        )
        try waitForPaneChildProcess(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.firstCodexPaneID,
            timeout: 45.0
        )
        try waitForPaneChildProcess(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.secondCodexPaneID,
            timeout: 45.0
        )

        try killPaneChildren(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.firstCodexPaneID
        )
        let firstShell = try waitForTmuxShellCommand(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.firstCodexPaneID,
            timeout: 20.0
        )
        XCTAssertTrue(isShellCommand(firstShell))

        _ = try await waitForDaemonCompletionOrShellDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.firstCodexPaneID,
            timeout: 30.0
        )
        _ = try await waitForDaemonPaneActivity(
            socketPath: harness.daemonSocketPath,
            paneID: harness.secondCodexPaneID,
            expected: .running,
            timeout: 20.0
        )
        try await assertDemotedPaneStaysUnmanagedWhileSiblingRunning(
            socketPath: harness.daemonSocketPath,
            demotedPaneID: harness.firstCodexPaneID,
            runningPaneID: harness.secondCodexPaneID,
            duration: 10.0
        )

        let model = AppViewModel(
            localClient: AgtmuxDaemonClient(socketPath: harness.daemonSocketPath),
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )
        let truth = try await waitForAppRowsToMatchDaemonTruth(
            model: model,
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.firstCodexPaneID, harness.secondCodexPaneID],
            timeout: 20.0
        )

        XCTAssertEqual(truth.app[harness.firstCodexPaneID]?.presence, .unmanaged)
        XCTAssertNil(truth.app[harness.firstCodexPaneID]?.provider)
        XCTAssertEqual(truth.app[harness.firstCodexPaneID]?.activityState, .unknown)
        XCTAssertEqual(truth.app[harness.secondCodexPaneID]?.presence, .managed)
        XCTAssertEqual(truth.app[harness.secondCodexPaneID]?.provider, .codex)
        XCTAssertEqual(truth.app[harness.secondCodexPaneID]?.activityState, .running)
    }

    @MainActor
    func testLiveCodexWaitingInputSurfacesAttentionFilter() async throws {
        throw XCTSkip(
            "Real Codex waiting_input via codex exec is not yet calibrated after immediate shell demotion; tracked by T-119. " +
            "Deterministic waiting_input attention coverage remains in AppViewModelA0Tests."
        )
    }
}
