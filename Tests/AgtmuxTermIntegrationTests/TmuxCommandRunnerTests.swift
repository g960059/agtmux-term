import XCTest
@testable import AgtmuxTerm

final class TmuxCommandRunnerTests: XCTestCase {
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
