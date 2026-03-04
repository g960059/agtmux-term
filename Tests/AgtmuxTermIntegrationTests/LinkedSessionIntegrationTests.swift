import Foundation
import XCTest

/// Integration tests that exercise linked-session behavior against a real tmux binary.
final class LinkedSessionIntegrationTests: XCTestCase {
    private var parentSession = ""
    private let tmuxPath = "/opt/homebrew/bin/tmux"

    override func setUp() async throws {
        guard FileManager.default.fileExists(atPath: tmuxPath) else {
            throw XCTSkip("tmux not found at \(tmuxPath)")
        }

        parentSession = "agtmux-test-\(Int.random(in: 100_000...999_999))"
        let result = try shellRun([tmuxPath, "new-session", "-d", "-s", parentSession])
        guard result.status == 0 else {
            throw XCTSkip("could not create tmux session: \(result.stderr)")
        }
    }

    override func tearDown() async throws {
        _ = try? shellRun([tmuxPath, "kill-session", "-t", parentSession])
    }

    /// Basic linked-session lifecycle: create -> verify -> destroy.
    func testCreateAndDestroyLinkedSession() async throws {
        let linkedName = "agtmux-linked-\(UUID().uuidString)"

        let create = try shellRun([tmuxPath, "new-session", "-d", "-s", linkedName, "-t", parentSession])
        XCTAssertEqual(create.status, 0, "new-session failed: \(create.stderr)")

        let list = try shellRun([tmuxPath, "list-sessions", "-F", "#{session_name}"])
        XCTAssertTrue(list.stdout.contains(linkedName), "linked session not found")

        _ = try shellRun([tmuxPath, "kill-session", "-t", linkedName])
        let listAfter = try shellRun([tmuxPath, "list-sessions", "-F", "#{session_name}"])
        XCTAssertFalse(listAfter.stdout.contains(linkedName), "linked session should be gone")
    }

    /// Ensure inherited TMUX/TMUX_PANE does not cause SIGTERM to this parent process.
    func testAttachSessionWithTmuxEnvInherited() throws {
        var env = ProcessInfo.processInfo.environment
        env["TMUX"] = "/tmp/tmux-test-fake/default,12345,0"
        env["TMUX_PANE"] = "%99"

        let result = shellRunWithEnv(
            [
                "/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE",
                tmuxPath, "attach-session", "-t", parentSession, "-d",
            ],
            env: env,
            timeout: 3.0
        )

        XCTAssertTrue(
            result.status == 0 || result.status == 1,
            "attach-session exited with unexpected status \(result.status): \(result.stderr)"
        )
    }

    // MARK: - Shell helpers

    struct ShellResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    func shellRun(_ args: [String]) throws -> ShellResult {
        shellRunWithEnv(args, env: ProcessInfo.processInfo.environment, timeout: 10)
    }

    func shellRunWithEnv(_ args: [String], env: [String: String], timeout: TimeInterval) -> ShellResult {
        guard !args.isEmpty else {
            return ShellResult(status: 127, stdout: "", stderr: "empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ShellResult(status: 127, stdout: "", stderr: "\(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
        }

        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
