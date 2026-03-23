import Foundation
import XCTest
@testable import AgtmuxTerm

final class TmuxCommandRunnerTests: XCTestCase {
    override func tearDown() {
        unsetenv("AGTMUX_TMUX_SOCKET_NAME")
        unsetenv("AGTMUX_UITEST_TMUX_CONFIG_PATH")
        super.tearDown()
    }

    func testNormalizedLocalEnvironmentClearsInheritedTmuxStateAndPreservesSocketOverrides() {
        let normalized = TmuxCommandRunner.normalizedLocalEnvironment(
            from: [
                "PATH": "/custom/bin:/bin",
                "TMUX": "/tmp/stale.sock,123,1",
                "TMUX_PANE": "%9",
                "CLAUDECODE": "1",
                "AGTMUX_TMUX_SOCKET_PATH": "/tmp/agtmux.sock",
                "USER": "virtualmachine",
                "HOME": "/Users/virtualmachine"
            ]
        )

        XCTAssertNil(normalized["TMUX"])
        XCTAssertNil(normalized["TMUX_PANE"])
        XCTAssertNil(normalized["CLAUDECODE"])
        XCTAssertEqual(normalized["AGTMUX_TMUX_SOCKET_PATH"], "/tmp/agtmux.sock")
        XCTAssertEqual(normalized["USER"], "virtualmachine")
        XCTAssertEqual(normalized["HOME"], "/Users/virtualmachine")
    }

    func testRunCapturesStdoutFromIsolatedLocalTmuxServer() async throws {
        let socketName = "agtmux-runner-test-\(UUID().uuidString.lowercased())"
        let sessionName = "runner-test"
        setenv("AGTMUX_TMUX_SOCKET_NAME", socketName, 1)
        setenv("AGTMUX_UITEST_TMUX_CONFIG_PATH", "/dev/null", 1)
        defer {
            unsetenv("AGTMUX_TMUX_SOCKET_NAME")
            unsetenv("AGTMUX_UITEST_TMUX_CONFIG_PATH")
        }

        _ = try await TmuxCommandRunner.shared.run(
            ["new-session", "-d", "-s", sessionName, "/bin/sleep", "30"],
            source: "local"
        )

        let output = try await TmuxCommandRunner.shared.run(
            ["list-sessions", "-F", "#{session_name}"],
            source: "local"
        )

        _ = try? await TmuxCommandRunner.shared.run(
            ["kill-server"],
            source: "local"
        )

        XCTAssertTrue(
            output.split(separator: "\n").contains(Substring(sessionName)),
            "expected isolated tmux stdout to include \(sessionName), got: \(output)"
        )
    }

    func testTmuxFailedLocalizedDescriptionIncludesArgsCodeAndStderr() {
        let error = TmuxCommandError.failed(
            args: ["list-panes", "-t", "bench"],
            code: 4,
            stderr: "can't find session: bench"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "tmux list-panes -t bench failed with exit code 4: can't find session: bench"
        )
    }

    func testTmuxTimeoutLocalizedDescriptionIncludesCommand() {
        let error = TmuxCommandError.timeout(args: ["display-message", "-p", "#{socket_path}"])

        XCTAssertEqual(
            error.localizedDescription,
            "tmux display-message -p #{socket_path} timed out"
        )
    }
}
