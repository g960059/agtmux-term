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

    private struct MetadataCallCounts {
        let bootstrapV3Calls: Int
        let changesV3Calls: Int
    }

    private actor RecordingMetadataClient: ProductLocalMetadataClient {
        private let base: AgtmuxDaemonClient
        private var bootstrapV3Calls = 0
        private var changesV3Calls = 0

        init(socketPath: String) {
            self.base = AgtmuxDaemonClient(socketPath: socketPath)
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            try await base.fetchSnapshot()
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapV3Calls += 1
            return try await base.fetchUIBootstrapV3()
        }

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            changesV3Calls += 1
            return try await base.fetchUIChangesV3(limit: limit)
        }

        func resetUIChangesV3() async {
            await base.resetUIChangesV3()
        }

        func counts() -> MetadataCallCounts {
            MetadataCallCounts(
                bootstrapV3Calls: bootstrapV3Calls,
                changesV3Calls: changesV3Calls
            )
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

    private enum CodexLaunchMode {
        case exec
        case interactive
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

    private static let codexCompletedIdlePrompt = """
    Ask me exactly one short yes/no question about this repository and then wait for my answer.
    Do not run tools.
    Do not continue until I reply.
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

    private func assertClaudePromptExecutionReady() throws {
        let claudeModel = environmentValue("CLAUDE_MODEL") ?? "claude-sonnet-4-6"
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let probeDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("agtmux-claude-probe-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDir) }

        let gitInit = try shellRun(["/usr/bin/git", "-C", probeDir.path, "init", "-q"])
        XCTAssertEqual(gitInit.status, 0, "git init for claude probe failed: \(gitInit.stderr)")

        let probeCommand = """
        cd \(shellQuote(probeDir.path)) && unset CLAUDECODE && claude --dangerously-skip-permissions --model \(shellQuote(claudeModel)) -p \(shellQuote("Reply with OK only."))
        """
        let probe = try shellRun(["/bin/zsh", "-lc", probeCommand], timeout: 20.0)
        guard probe.status == 0 else {
            let detail = probe.stderr.isEmpty ? probe.stdout : probe.stderr
            let normalizedDetail = detail.lowercased()
            let isAuthFailure =
                normalizedDetail.contains("failed to authenticate")
                || normalizedDetail.contains("authentication_error")
                || normalizedDetail.contains("oauth token has expired")
            if isAuthFailure {
                throw XCTSkip("claude prompt execution unavailable: \(detail)")
            }
            throw NSError(
                domain: "AppViewModelLiveManagedAgentTests",
                code: 13,
                userInfo: [
                    NSLocalizedDescriptionKey: "claude prompt execution probe failed unexpectedly: \(detail)"
                ]
            )
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

    private func tmuxCapture(
        path: String,
        socketName: String,
        paneID: String,
        startLine: Int = -80
    ) throws -> String {
        let result = try tmuxRun(path: path, socketName: socketName, [
            "capture-pane", "-t", paneID, "-p", "-S", String(startLine)
        ])
        XCTAssertEqual(result.status, 0, "tmux capture-pane failed: \(result.stderr)")
        return result.stdout
    }

    private func captureMatchesAllPatterns(
        _ capture: String,
        requiredPatterns: [String]
    ) -> Bool {
        requiredPatterns.allSatisfy { pattern in
            capture.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func acceptTmuxTrustPromptIfPresent(
        path: String,
        socketName: String,
        paneID: String,
        requiredPatterns: [String],
        timeout: TimeInterval = 0.0
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let capture = try tmuxCapture(
                path: path,
                socketName: socketName,
                paneID: paneID,
                startLine: -200
            )
            if captureMatchesAllPatterns(capture, requiredPatterns: requiredPatterns) {
                let confirm = try shellRun(tmuxBaseArgs(path: path, socketName: socketName) + [
                    "send-keys", "-t", paneID, "C-m"
                ])
                XCTAssertEqual(confirm.status, 0, "tmux send-keys Enter failed: \(confirm.stderr)")
                return
            }

            guard Date() < deadline else {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
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
        codexPrompt: String? = nil,
        codexLaunchMode: CodexLaunchMode = .exec
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
        // Unset CLAUDECODE so Claude can start even when tests run inside a Claude Code session.
        try tmuxSendLine(path: tmuxPath, socketName: socketName, paneID: claudePaneID,
                         text: "unset CLAUDECODE")
        Thread.sleep(forTimeInterval: 0.2)
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
        try acceptTmuxTrustPromptIfPresent(
            path: tmuxPath,
            socketName: socketName,
            paneID: claudePaneID,
            requiredPatterns: [
                "Do you trust the contents of this\\s+directory|Quick safety check",
            ],
            timeout: 0.0
        )

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
        let codexCommand: String = switch codexLaunchMode {
        case .exec:
            "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json -m \(shellQuote(codexModel)) -c model_reasoning_effort='\"medium\"' \(shellQuote(resolvedCodexPrompt))"
        case .interactive:
            "codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox -m \(shellQuote(codexModel)) -c model_reasoning_effort='\"medium\"' \(shellQuote(resolvedCodexPrompt))"
        }
        try tmuxSendLine(
            path: tmuxPath,
            socketName: socketName,
            paneID: codexPaneID,
            text: codexCommand
        )
        if codexLaunchMode == .interactive {
            Thread.sleep(forTimeInterval: 6.0)
            try acceptTmuxTrustPromptIfPresent(
                path: tmuxPath,
                socketName: socketName,
                paneID: codexPaneID,
                requiredPatterns: [
                    "Do you trust the contents of this\\s+directory",
                ],
                timeout: 20.0
            )
        }

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
    ) async throws -> AgtmuxSyncV3Bootstrap {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastBootstrap: AgtmuxSyncV3Bootstrap?

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV3()
                lastBootstrap = bootstrap
                let panesByID = Dictionary(uniqueKeysWithValues: bootstrap.panes.map { ($0.paneID, $0) })
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
                .filter { expectedProviders.keys.contains($0.paneID) }
                .map { "\($0.paneID)=\($0.presence.rawValue)/\($0.provider?.rawValue ?? "nil")/\(PanePresentationState(snapshot: $0).primaryState.rawValue)" }
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
    ) async throws -> AgtmuxSyncV3Bootstrap {
        try await waitForManagedProviderAssignments(
            socketPath: socketPath,
            expectedProviders: [
                paneIDs[0]: .claude,
                paneIDs[1]: .codex,
            ],
            timeout: timeout
        )
    }

    private struct AppPaneSurface {
        let pane: AgtmuxPane
        let display: PaneDisplayState
        let presentation: PanePresentationState?
    }

    @MainActor
    private func appPaneSurface(model: AppViewModel, inventoryPane: AgtmuxPane) -> AppPaneSurface? {
        guard let pane = model.panes.first(where: {
            $0.paneId == inventoryPane.paneId
                && $0.sessionName == inventoryPane.sessionName
                && $0.windowId == inventoryPane.windowId
        }) else {
            return nil
        }
        return AppPaneSurface(
            pane: pane,
            display: model.paneDisplayState(for: pane),
            presentation: model.panePresentation(for: pane)
        )
    }

    private func daemonSnapshotSummary(_ snapshot: AgtmuxSyncV3PaneSnapshot?) -> String {
        guard let snapshot else { return "missing" }
        let presentation = PanePresentationState(snapshot: snapshot)
        return [
            "presence=\(snapshot.presence.rawValue)",
            "provider=\(snapshot.provider?.rawValue ?? "nil")",
            "primary=\(presentation.primaryState.rawValue)",
            "session_key=\(snapshot.sessionKey)",
            "pane_instance=\(snapshot.paneInstanceID)"
        ].joined(separator: " ")
    }

    private func appSurfaceSummary(_ surface: AppPaneSurface?) -> String {
        guard let surface else { return "missing" }
        return [
            "presence=\(surface.pane.presence.rawValue)",
            "provider=\(surface.pane.provider?.rawValue ?? "nil")",
            "display_primary=\(surface.display.primaryState.rawValue)",
            "display_attention=\(surface.display.needsAttention)",
            "session_key=\(surface.pane.metadataSessionKey ?? "nil")",
            "pane_instance=\(String(describing: surface.pane.paneInstanceID))",
            "presentation=\(surface.presentation?.primaryState.rawValue ?? "nil")"
        ].joined(separator: " ")
    }

    private func legacyPaneInstanceID(from paneInstanceID: AgtmuxSyncV3PaneInstanceID) -> AgtmuxSyncV2PaneInstanceID {
        AgtmuxSyncV2PaneInstanceID(
            paneId: paneInstanceID.paneId,
            generation: paneInstanceID.generation,
            birthTs: paneInstanceID.birthTs
        )
    }

    private func changeSummary(_ change: AgtmuxSyncV3PaneChange?) -> String {
        guard let change else { return "missing" }
        let fieldGroups = change.fieldGroups.map(\.rawValue).joined(separator: ",")
        switch change.kind {
        case .remove:
            return "remove session_key=\(change.sessionKey) pane_id=\(change.paneInstanceID.paneId) field_groups=\(fieldGroups)"
        case .upsert:
            guard let pane = change.pane else {
                return "upsert missing-pane session_key=\(change.sessionKey) pane_id=\(change.paneInstanceID.paneId)"
            }
            let presentation = PanePresentationState(snapshot: pane)
            return [
                "upsert",
                "session_key=\(pane.sessionKey)",
                "pane_id=\(pane.paneID)",
                "provider=\(pane.provider?.rawValue ?? "nil")",
                "presence=\(pane.presence.rawValue)",
                "primary=\(presentation.primaryState.rawValue)",
                "field_groups=\(fieldGroups)"
            ].joined(separator: " ")
        }
    }

    private func currentV3Snapshot(
        socketPath: String,
        paneID: String
    ) async throws -> AgtmuxSyncV3PaneSnapshot? {
        let bootstrap = try await AgtmuxDaemonClient(socketPath: socketPath).fetchUIBootstrapV3()
        return bootstrap.panes.first(where: { $0.paneID == paneID })
    }

    private func waitForV3BootstrapPane(
        socketPath: String,
        paneID: String,
        provider: Provider,
        expectedPrimaryState: PanePresentationPrimaryState,
        timeout: TimeInterval = 45.0
    ) async throws -> AgtmuxSyncV3PaneSnapshot {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSummary = "no bootstrap"

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV3()
                if let pane = bootstrap.panes.first(where: { $0.paneID == paneID }) {
                    let presentation = PanePresentationState(snapshot: pane)
                    lastSummary = "\(pane.paneID)=\(pane.provider?.rawValue ?? "nil")/\(pane.presence.rawValue)/\(presentation.primaryState.rawValue)"
                    if pane.provider == provider,
                       pane.presence == .managed,
                       presentation.primaryState == expectedPrimaryState {
                        return pane
                    }
                } else {
                    lastSummary = "pane \(paneID) missing from bootstrap"
                }
            } catch {
                lastSummary = String(describing: error)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "sync-v3 bootstrap did not surface pane \(paneID) as \(provider.rawValue)/\(expectedPrimaryState.rawValue); last=\(lastSummary)"
            ]
        )
    }

    private func waitForV3ChangeForPane(
        client: AgtmuxDaemonClient,
        paneID: String,
        ignoringPrimaryState: PanePresentationPrimaryState,
        timeout: TimeInterval = 120.0
    ) async throws -> AgtmuxSyncV3PaneChange {
        let deadline = Date().addingTimeInterval(timeout)
        var lastChange: AgtmuxSyncV3PaneChange?

        while Date() < deadline {
            do {
                let response = try await client.fetchUIChangesV3(limit: 64)
                switch response {
                case let .changes(payload):
                    if let relevant = payload.changes.first(where: { change in
                        guard change.paneInstanceID.paneId == paneID else { return false }
                        switch change.kind {
                        case .remove:
                            return true
                        case .upsert:
                            guard let pane = change.pane else { return false }
                            return PanePresentationState(snapshot: pane).primaryState != ignoringPrimaryState
                        }
                    }) {
                        return relevant
                    }
                    lastChange = payload.changes.last(where: { $0.paneInstanceID.paneId == paneID })
                case .resyncRequired:
                    await client.resetUIChangesV3()
                    _ = try await client.fetchUIBootstrapV3()
                }
            } catch {
                lastChange = nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 9,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "sync-v3 changes did not produce a relevant exact-row update for pane \(paneID); last=\(changeSummary(lastChange))"
            ]
        )
    }

    private func waitForV3BootstrapDemotion(
        socketPath: String,
        paneID: String,
        timeout: TimeInterval = 45.0
    ) async throws -> AgtmuxSyncV3PaneSnapshot? {
        let client = AgtmuxDaemonClient(socketPath: socketPath)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSummary = "no bootstrap"

        while Date() < deadline {
            do {
                let bootstrap = try await client.fetchUIBootstrapV3()
                guard let pane = bootstrap.panes.first(where: { $0.paneID == paneID }) else {
                    return nil
                }
                let presentation = PanePresentationState(snapshot: pane)
                lastSummary = daemonSnapshotSummary(pane)
                if pane.provider == nil,
                   pane.presence != .managed,
                   (presentation.primaryState == .inactive || presentation.primaryState == .idle) {
                    return pane
                }
            } catch {
                lastSummary = String(describing: error)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 12,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "sync-v3 bootstrap did not demote pane \(paneID) to inactive shell truth; last=\(lastSummary)"
            ]
        )
    }

    @MainActor
    private func waitForAppPanePresentationToMatchSnapshot(
        model: AppViewModel,
        client: RecordingMetadataClient,
        inventoryPane: AgtmuxPane,
        snapshot: AgtmuxSyncV3PaneSnapshot,
        requireChangesV3: Bool,
        timeout: TimeInterval = 25.0
    ) async throws -> AgtmuxPane {
        let expectedPresentation = PanePresentationState(snapshot: snapshot)
        let expectedPaneInstanceID = legacyPaneInstanceID(from: snapshot.paneInstanceID)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSurface: AppPaneSurface?
        var lastCounts = await client.counts()

        while Date() < deadline {
            await model.fetchAll()
            lastCounts = await client.counts()
            lastSurface = appPaneSurface(model: model, inventoryPane: inventoryPane)

            if let surface = lastSurface,
               let presentation = surface.presentation,
               (!requireChangesV3 || lastCounts.changesV3Calls > 0),
               surface.pane.provider == snapshot.provider,
               surface.pane.presence == (snapshot.presence == .managed ? .managed : .unmanaged),
               surface.pane.metadataSessionKey == snapshot.sessionKey,
               surface.pane.paneInstanceID == expectedPaneInstanceID,
               surface.display.provider == snapshot.provider,
               surface.display.presence == (snapshot.presence == .managed ? .managed : .unmanaged),
               surface.display.primaryState == expectedPresentation.primaryState,
               surface.display.isManaged == (snapshot.presence == .managed),
               presentation == expectedPresentation {
                return surface.pane
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 10,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "app row did not match sync-v3 snapshot for \(inventoryPane.paneId); daemon=\(daemonSnapshotSummary(snapshot)) app=\(appSurfaceSummary(lastSurface)) counts=v3b\(lastCounts.bootstrapV3Calls)/v3c\(lastCounts.changesV3Calls)"
            ]
        )
    }

    @MainActor
    private func waitForAppPaneToClearV3Overlay(
        model: AppViewModel,
        client: RecordingMetadataClient,
        inventoryPane: AgtmuxPane,
        requireChangesV3: Bool = true,
        timeout: TimeInterval = 25.0
    ) async throws -> AgtmuxPane {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSurface: AppPaneSurface?
        var lastCounts = await client.counts()

        while Date() < deadline {
            await model.fetchAll()
            lastCounts = await client.counts()
            lastSurface = appPaneSurface(model: model, inventoryPane: inventoryPane)

            if let surface = lastSurface,
               (!requireChangesV3 || lastCounts.changesV3Calls > 0),
               surface.pane.provider == nil,
               surface.pane.presence == .unmanaged,
               surface.pane.metadataSessionKey == nil,
               surface.display.primaryState == .inactive,
               !surface.display.isManaged,
               !surface.display.needsAttention,
               surface.presentation == nil {
                return surface.pane
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "AppViewModelLiveManagedAgentTests",
            code: 11,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "app row did not clear sync-v3 overlay for \(inventoryPane.paneId); app=\(appSurfaceSummary(lastSurface)) counts=v3b\(lastCounts.bootstrapV3Calls)/v3c\(lastCounts.changesV3Calls)"
            ]
        )
    }

    @MainActor
    func testTrustPromptMatcherRejectsGenericContinuePrompts() {
        let genericPrompt = """
        Error: login failed
        Press enter to continue
        """

        XCTAssertFalse(
            captureMatchesAllPatterns(
                genericPrompt,
                requiredPatterns: [
                    "Do you trust the contents of this\\s+directory",
                ]
            )
        )
    }

    @MainActor
    func testTrustPromptMatcherAcceptsKnownTrustPromptVariants() {
        let claudePrompt = """
        Quick safety check
        Yes, I trust this folder
        """
        let codexPrompt = """
        Do you trust the contents of this
        directory?
        1. Yes, continue
        2. No, quit
        """

        XCTAssertTrue(
            captureMatchesAllPatterns(
                claudePrompt,
                requiredPatterns: [
                    "Do you trust the contents of this\\s+directory|Quick safety check",
                ]
            )
        )
        XCTAssertTrue(
            captureMatchesAllPatterns(
                codexPrompt,
                requiredPatterns: [
                    "Do you trust the contents of this\\s+directory",
                ]
            )
        )
    }

    @MainActor
    func testLiveManagedClaudeAndCodexAppearInAppViewModel() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        let bootstrap = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )
        let claudeSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.claudePaneID }))
        let codexSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.codexPaneID }))
        let claudeInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.claudePaneID }))
        let codexInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID }))

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: claudeInventoryPane,
            snapshot: claudeSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: codexSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )

        let counts = await recordingClient.counts()
        XCTAssertGreaterThan(counts.bootstrapV3Calls, 0, "live product path must bootstrap through sync-v3")
    }

    /// Semantic replacement for T-E2E-015b.
    /// The metadata-enabled XCUITest lane is environment-blocked on this host,
    /// so this live AppViewModel proof is the product gate for plain-zsh -> Codex promotion.
    @MainActor
    func testLivePlainZshAgentLaunchSurfacesManagedFilterProviderAndActivity() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        let bootstrap = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )
        let claudeSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.claudePaneID }))
        let codexSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.codexPaneID }))
        let claudeInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.claudePaneID }))
        let codexInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID }))

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let claudeAppPane = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: claudeInventoryPane,
            snapshot: claudeSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )
        let codexAppPane = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: codexSnapshot,
            requireChangesV3: false,
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
        XCTAssertNotEqual(
            codexSnapshot.freshness.snapshot,
            .down,
            "T-E2E-015b replacement: plain zsh Codex bootstrap freshness must not fall back to down once managed/provider truth is visible"
        )
        XCTAssertEqual(
            model.paneDisplayState(for: claudeAppPane).primaryState,
            PanePresentationState(snapshot: claudeSnapshot).primaryState,
            "Claude row display state must follow sync-v3 presentation truth under the managed filter"
        )
        XCTAssertEqual(
            model.paneDisplayState(for: codexAppPane).primaryState,
            PanePresentationState(snapshot: codexSnapshot).primaryState,
            "Codex row display state must follow sync-v3 presentation truth under the managed filter"
        )
        let counts = await recordingClient.counts()
        XCTAssertGreaterThan(counts.bootstrapV3Calls, 0, "managed-filter product path must bootstrap through sync-v3")
    }

    @MainActor
    func testLiveCodexActivityTruthReachesExactAppRowWithoutBleed() async throws {
        // Codex semantic-state proof now uses exec mode on the main lane.
        // Interactive launch stays covered by a narrower sentinel below.
        let harness = try startLiveHarness(codexLaunchMode: .exec)
        defer { stopLiveHarness(harness) }

        let bootstrap = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )
        let claudeInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.claudePaneID }))
        let codexInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID }))
        let initialClaudeSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.claudePaneID }))
        let runningCodexSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let codexRunningPane = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: runningCodexSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: claudeInventoryPane,
            snapshot: initialClaudeSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )

        XCTAssertEqual(
            model.paneDisplayState(for: codexRunningPane).primaryState,
            .running,
            "Codex row must surface running when the daemon reports running"
        )
        XCTAssertEqual(
            codexRunningPane.provider,
            .codex,
            "Codex row must keep exact-row provider truth"
        )
        let observer = AgtmuxDaemonClient(socketPath: harness.daemonSocketPath)
        _ = try await observer.fetchUIBootstrapV3()
        let change = try await waitForV3ChangeForPane(
            client: observer,
            paneID: harness.codexPaneID,
            ignoringPrimaryState: .running,
            timeout: 120.0
        )

        switch change.kind {
        case .upsert:
            let updatedSnapshot = try XCTUnwrap(change.pane)
            do {
                let updatedPane = try await waitForAppPanePresentationToMatchSnapshot(
                    model: model,
                    client: recordingClient,
                    inventoryPane: codexInventoryPane,
                    snapshot: updatedSnapshot,
                    requireChangesV3: true,
                    timeout: 30.0
                )
                XCTAssertNotEqual(
                    model.paneDisplayState(for: updatedPane).primaryState,
                    .running,
                    "Codex row must not remain stale-running after completion upsert"
                )
            } catch {
                let latestSnapshot = try await currentV3Snapshot(
                    socketPath: harness.daemonSocketPath,
                    paneID: harness.codexPaneID
                )
                switch latestSnapshot {
                case .some(let snapshot):
                    let latestPane = try await waitForAppPanePresentationToMatchSnapshot(
                        model: model,
                        client: recordingClient,
                        inventoryPane: codexInventoryPane,
                        snapshot: snapshot,
                        requireChangesV3: true,
                        timeout: 30.0
                    )
                    XCTAssertNotEqual(
                        model.paneDisplayState(for: latestPane).primaryState,
                        .running,
                        "Codex row must not remain stale-running after post-upsert fallback reconciliation"
                    )
                case .none:
                    let clearedPane = try await waitForAppPaneToClearV3Overlay(
                        model: model,
                        client: recordingClient,
                        inventoryPane: codexInventoryPane,
                        timeout: 30.0
                    )
                    XCTAssertEqual(model.paneDisplayState(for: clearedPane).primaryState, .inactive)
                }
            }
        case .remove:
            let demotedSnapshot = try await currentV3Snapshot(
                socketPath: harness.daemonSocketPath,
                paneID: harness.codexPaneID
            )
            switch demotedSnapshot {
            case .some(let updatedSnapshot):
                let updatedPane = try await waitForAppPanePresentationToMatchSnapshot(
                    model: model,
                    client: recordingClient,
                    inventoryPane: codexInventoryPane,
                    snapshot: updatedSnapshot,
                    requireChangesV3: true,
                    timeout: 30.0
                )
                XCTAssertEqual(model.paneDisplayState(for: updatedPane).primaryState, .idle)
            case .none:
                let clearedPane = try await waitForAppPaneToClearV3Overlay(
                    model: model,
                    client: recordingClient,
                    inventoryPane: codexInventoryPane,
                    timeout: 30.0
                )
                XCTAssertEqual(model.paneDisplayState(for: clearedPane).primaryState, .inactive)
            }
        }

        if let latestClaudeSnapshot = try await currentV3Snapshot(
            socketPath: harness.daemonSocketPath,
            paneID: harness.claudePaneID
        ) {
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: claudeInventoryPane,
                snapshot: latestClaudeSnapshot,
                requireChangesV3: true,
                timeout: 20.0
            )
        }
    }

    @MainActor
    func testLiveCodexInteractiveRunningSentinelStillSurfacesExactRunningTruth() async throws {
        let harness = try startLiveHarness(codexLaunchMode: .interactive)
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [harness.codexPaneID: .codex]
        )

        let runningCodexSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )

        XCTAssertEqual(runningCodexSnapshot.provider, .codex)
        XCTAssertEqual(runningCodexSnapshot.presence, .managed)
        XCTAssertEqual(PanePresentationState(snapshot: runningCodexSnapshot).primaryState, .running)
    }

    @MainActor
    func testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed() async throws {
        try assertClaudePromptExecutionReady()
        let harness = try startLiveHarness(claudePrompt: Self.claudeLifecyclePrompt)
        defer { stopLiveHarness(harness) }

        let bootstrap = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [harness.claudePaneID: .claude]
        )
        let claudeInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.claudePaneID }))
        let codexInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID }))
        let initialClaudeSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.claudePaneID }))
        let initialCodexSnapshot = try await currentV3Snapshot(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID
        )

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let claudePane = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: claudeInventoryPane,
            snapshot: initialClaudeSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )
        if let initialCodexSnapshot {
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: codexInventoryPane,
                snapshot: initialCodexSnapshot,
                requireChangesV3: false,
                timeout: 20.0
            )
        }

        XCTAssertEqual(
            model.paneDisplayState(for: claudePane).primaryState,
            PanePresentationState(snapshot: initialClaudeSnapshot).primaryState,
            "Claude row must surface the daemon's sync-v3 presentation state on the exact row"
        )
        XCTAssertEqual(
            claudePane.provider,
            .claude,
            "Claude row must keep exact-row provider truth"
        )

        if let latestCodexSnapshot = try await currentV3Snapshot(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID
        ) {
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: codexInventoryPane,
                snapshot: latestCodexSnapshot,
                requireChangesV3: true,
                timeout: 20.0
            )
        }
    }

    @MainActor
    func testLiveCodexManagedExitDemotesExactRowBackToShellTruth() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [harness.codexPaneID: .codex]
        )

        let codexInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID }))
        let initialSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )
        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: initialSnapshot,
            requireChangesV3: false,
            timeout: 20.0
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

        let demotedSnapshot = try await waitForV3BootstrapDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            timeout: 30.0
        )

        switch demotedSnapshot {
        case .some(let updatedSnapshot):
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: codexInventoryPane,
                snapshot: updatedSnapshot,
                requireChangesV3: false,
                timeout: 30.0
            )
        case .none:
            _ = try await waitForAppPaneToClearV3Overlay(
                model: model,
                client: recordingClient,
                inventoryPane: codexInventoryPane,
                requireChangesV3: false,
                timeout: 30.0
            )
        }

        let finalSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: codexInventoryPane))
        XCTAssertEqual(finalSurface.pane.presence, .unmanaged)
        XCTAssertNil(finalSurface.pane.provider)
        if let demotedSnapshot {
            XCTAssertEqual(
                finalSurface.display.primaryState,
                PanePresentationState(snapshot: demotedSnapshot).primaryState
            )
        } else {
            XCTAssertEqual(finalSurface.display.primaryState, .inactive)
            XCTAssertNil(finalSurface.presentation)
        }
    }

    @MainActor
    func testLiveSameSessionCodexNoBleedAfterSiblingDemotion() async throws {
        let harness = try startSameSessionCodexHarness()
        defer { stopSameSessionCodexHarness(harness) }

        let bootstrap = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [
                harness.firstCodexPaneID: .codex,
                harness.secondCodexPaneID: .codex,
            ]
        )
        let firstInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.firstCodexPaneID }))
        let secondInventoryPane = try XCTUnwrap(harness.inventoryPanes.first(where: { $0.paneId == harness.secondCodexPaneID }))
        let initialSecondSnapshot = try XCTUnwrap(bootstrap.panes.first(where: { $0.paneID == harness.secondCodexPaneID }))
        let firstRunningSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.firstCodexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )
        let secondRunningSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.secondCodexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )
        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: firstInventoryPane,
            snapshot: firstRunningSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: secondInventoryPane,
            snapshot: secondRunningSnapshot,
            requireChangesV3: false,
            timeout: 20.0
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

        let firstDemotedSnapshot = try await waitForV3BootstrapDemotion(
            socketPath: harness.daemonSocketPath,
            paneID: harness.firstCodexPaneID,
            timeout: 30.0
        )
        let latestSecondSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.secondCodexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 20.0
        )

        switch firstDemotedSnapshot {
        case .some(let updatedSnapshot):
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: firstInventoryPane,
                snapshot: updatedSnapshot,
                requireChangesV3: false,
                timeout: 30.0
            )
        case .none:
            _ = try await waitForAppPaneToClearV3Overlay(
                model: model,
                client: recordingClient,
                inventoryPane: firstInventoryPane,
                requireChangesV3: false,
                timeout: 30.0
            )
        }
        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: secondInventoryPane,
            snapshot: latestSecondSnapshot,
            requireChangesV3: false,
            timeout: 20.0
        )

        let firstSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: firstInventoryPane))
        let secondSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: secondInventoryPane))
        XCTAssertEqual(firstSurface.pane.presence, .unmanaged)
        XCTAssertNil(firstSurface.pane.provider)
        if let firstDemotedSnapshot {
            XCTAssertEqual(
                firstSurface.display.primaryState,
                PanePresentationState(snapshot: firstDemotedSnapshot).primaryState
            )
        } else {
            XCTAssertEqual(firstSurface.display.primaryState, .inactive)
            XCTAssertNil(firstSurface.presentation)
        }
        XCTAssertEqual(secondSurface.pane.presence, .managed)
        XCTAssertEqual(secondSurface.pane.provider, .codex)
        XCTAssertEqual(secondSurface.display.primaryState, .running)
        XCTAssertEqual(
            PanePresentationState(snapshot: initialSecondSnapshot).provider,
            secondSurface.pane.provider,
            "sibling Codex row must keep its own exact-row provider truth"
        )
    }

    @MainActor
    func testLiveCodexCompletedIdleWithoutPendingRequestDoesNotSurfaceAttentionFilter() async throws {
        let harness = try startLiveHarness(
            claudePrompt: Self.claudeLifecyclePrompt,
            codexPrompt: Self.codexCompletedIdlePrompt,
            codexLaunchMode: .interactive
        )
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviderAssignments(
            socketPath: harness.daemonSocketPath,
            expectedProviders: [harness.codexPaneID: .codex]
        )
        let claudeInventoryPane = try XCTUnwrap(
            harness.inventoryPanes.first(where: { $0.paneId == harness.claudePaneID })
        )
        let codexInventoryPane = try XCTUnwrap(
            harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID })
        )
        let codexCompletedSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            provider: .codex,
            expectedPrimaryState: .completedIdle,
            timeout: 45.0
        )

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        let codexPane = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: codexCompletedSnapshot,
            requireChangesV3: false,
            timeout: 25.0
        )
        try waitForTmuxCurrentCommand(
            path: harness.tmuxPath,
            socketName: harness.socketName,
            paneID: harness.codexPaneID,
            expected: "node",
            timeout: 20.0
        )

        let codexSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: codexInventoryPane))
        let claudeSurface: AppPaneSurface
        if let latestClaudeSnapshot = try await currentV3Snapshot(
            socketPath: harness.daemonSocketPath,
            paneID: harness.claudePaneID
        ) {
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: claudeInventoryPane,
                snapshot: latestClaudeSnapshot,
                requireChangesV3: true,
                timeout: 20.0
            )
            claudeSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: claudeInventoryPane))
            XCTAssertEqual(
                claudeSurface.display.primaryState,
                PanePresentationState(snapshot: latestClaudeSnapshot).primaryState
            )
        } else {
            claudeSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: claudeInventoryPane))
        }

        XCTAssertEqual(codexPane.provider, .codex)
        XCTAssertEqual(codexPane.presence, .managed)
        XCTAssertEqual(codexSurface.pane.metadataSessionKey, codexCompletedSnapshot.sessionKey)
        XCTAssertEqual(
            codexSurface.pane.paneInstanceID,
            legacyPaneInstanceID(from: codexCompletedSnapshot.paneInstanceID)
        )
        XCTAssertEqual(codexSurface.display.primaryState, .completedIdle)
        XCTAssertFalse(codexSurface.display.needsAttention)
        let codexPresentation = try XCTUnwrap(codexSurface.presentation)
        XCTAssertEqual(codexPresentation.primaryState, .completedIdle)
        XCTAssertEqual(codexPresentation.pendingRequestIDs, [])
        XCTAssertFalse(codexPresentation.needsUserAction)
        if codexPresentation.showsAttentionSummary {
            XCTAssertEqual(codexPresentation.attentionSummary.highestPriority, .completion)
        }

        XCTAssertFalse(
            claudeSurface.display.needsAttention,
            "sibling Claude row must not bleed into the attention filter while Codex is merely completed_idle"
        )

        XCTAssertEqual(model.attentionCount, 0)
        model.statusFilter = .attention
        XCTAssertTrue(model.filteredPanes.isEmpty)
        try? await Task.sleep(for: .seconds(16))
        await model.fetchAll()
        let quietCodexSurface = try XCTUnwrap(appPaneSurface(model: model, inventoryPane: codexInventoryPane))
        XCTAssertNotEqual(
            quietCodexSurface.display.freshnessText,
            "down",
            "quiet completed-idle Codex rows must not surface row-level freshness down after the daemon settles fallback freshness"
        )
        let counts = await recordingClient.counts()
        XCTAssertGreaterThan(counts.bootstrapV3Calls, 0, "completed_idle live lane must bootstrap through sync-v3")
    }

    @MainActor
    func testLiveSyncV3BootstrapAndChangesUpdateExactCodexRowWithoutFallingBackToV2() async throws {
        let harness = try startLiveHarness()
        defer { stopLiveHarness(harness) }

        _ = try await waitForManagedProviders(
            socketPath: harness.daemonSocketPath,
            paneIDs: [harness.claudePaneID, harness.codexPaneID]
        )

        let codexInventoryPane = try XCTUnwrap(
            harness.inventoryPanes.first(where: { $0.paneId == harness.codexPaneID })
        )
        let initialSnapshot = try await waitForV3BootstrapPane(
            socketPath: harness.daemonSocketPath,
            paneID: harness.codexPaneID,
            provider: .codex,
            expectedPrimaryState: .running,
            timeout: 45.0
        )

        let recordingClient = RecordingMetadataClient(socketPath: harness.daemonSocketPath)
        let model = AppViewModel(
            localClient: recordingClient,
            localInventoryClient: StubInventoryClient(panes: harness.inventoryPanes),
            hostsConfig: .empty
        )

        _ = try await waitForAppPanePresentationToMatchSnapshot(
            model: model,
            client: recordingClient,
            inventoryPane: codexInventoryPane,
            snapshot: initialSnapshot,
            requireChangesV3: false,
            timeout: 25.0
        )

        let initialCounts = await recordingClient.counts()
        XCTAssertGreaterThan(initialCounts.bootstrapV3Calls, 0, "AppViewModel must bootstrap from sync-v3 in the live canary lane")

        let observer = AgtmuxDaemonClient(socketPath: harness.daemonSocketPath)
        _ = try await observer.fetchUIBootstrapV3()
        let change = try await waitForV3ChangeForPane(
            client: observer,
            paneID: harness.codexPaneID,
            ignoringPrimaryState: .running,
            timeout: 120.0
        )

        switch change.kind {
        case .upsert:
            let updatedSnapshot = try XCTUnwrap(change.pane)
            _ = try await waitForAppPanePresentationToMatchSnapshot(
                model: model,
                client: recordingClient,
                inventoryPane: codexInventoryPane,
                snapshot: updatedSnapshot,
                requireChangesV3: true,
                timeout: 30.0
            )
        case .remove:
            let demotedSnapshot = try await currentV3Snapshot(
                socketPath: harness.daemonSocketPath,
                paneID: harness.codexPaneID
            )
            switch demotedSnapshot {
            case .some(let updatedSnapshot):
                _ = try await waitForAppPanePresentationToMatchSnapshot(
                    model: model,
                    client: recordingClient,
                    inventoryPane: codexInventoryPane,
                    snapshot: updatedSnapshot,
                    requireChangesV3: true,
                    timeout: 30.0
                )
            case .none:
                _ = try await waitForAppPaneToClearV3Overlay(
                    model: model,
                    client: recordingClient,
                    inventoryPane: codexInventoryPane,
                    timeout: 30.0
                )
            }
        }

        let finalCounts = await recordingClient.counts()
        XCTAssertGreaterThan(finalCounts.changesV3Calls, 0, "AppViewModel must poll sync-v3 changes after bootstrap in the live canary lane")
    }
}
