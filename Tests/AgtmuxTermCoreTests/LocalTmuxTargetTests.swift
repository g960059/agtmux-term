import XCTest
@testable import AgtmuxTermCore

final class LocalTmuxTargetTests: XCTestCase {
    func testExplicitSocketNameTakesHighestPrecedence() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_NAME": "named-socket",
            "AGTMUX_TMUX_SOCKET": "/tmp/explicit.sock",
            "TMUX": "/tmp/inherited.sock,123,1"
        ]

        XCTAssertEqual(LocalTmuxTarget.socketArguments(from: env), ["-L", "named-socket"])
    }

    func testExplicitSocketPathUsedWhenNameMissing() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET": "/tmp/explicit.sock",
            "TMUX": "/tmp/inherited.sock,123,1"
        ]

        XCTAssertEqual(LocalTmuxTarget.socketArguments(from: env), ["-S", "/tmp/explicit.sock"])
    }

    func testInheritedTMUXIsIgnoredWithoutExplicitOverride() {
        let env: [String: String] = [
            "TMUX": "/tmp/inherited.sock,123,1"
        ]

        XCTAssertEqual(
            LocalTmuxTarget.socketArguments(from: env),
            [],
            "Inherited TMUX must not force local commands onto a stale socket"
        )
    }
}
