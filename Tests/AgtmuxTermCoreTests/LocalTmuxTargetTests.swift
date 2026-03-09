import XCTest
@testable import AgtmuxTermCore

final class LocalTmuxTargetTests: XCTestCase {
    override func tearDown() {
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(nil)
        super.tearDown()
    }

    func testExplicitSocketNameTakesHighestPrecedence() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_NAME": "named-socket",
            "AGTMUX_TMUX_SOCKET_PATH": "/tmp/path.sock",
            "AGTMUX_TMUX_SOCKET": "/tmp/explicit.sock",
            "TMUX": "/tmp/inherited.sock,123,1"
        ]

        XCTAssertEqual(LocalTmuxTarget.socketArguments(from: env), ["-L", "named-socket"])
    }

    func testExplicitSocketPathUsedWhenNameMissing() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_PATH": "/tmp/path.sock",
            "AGTMUX_TMUX_SOCKET": "/tmp/explicit.sock",
            "TMUX": "/tmp/inherited.sock,123,1"
        ]

        XCTAssertEqual(LocalTmuxTarget.socketArguments(from: env), ["-S", "/tmp/path.sock"])
    }

    func testLegacyExplicitSocketPathStillWorksWhenPathAliasMissing() {
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

    func testDaemonCLIArgumentsUseExplicitSocketPathWithoutQueryingTmux() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_PATH": "/tmp/explicit.sock"
        ]

        XCTAssertEqual(
            LocalTmuxTarget.daemonCLIArguments(from: env),
            ["--tmux-socket", "/tmp/explicit.sock"]
        )
    }

    func testDaemonCLIArgumentsResolveSocketNameIntoExplicitDaemonPath() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_NAME": "named-socket"
        ]

        XCTAssertEqual(
            LocalTmuxTarget.daemonCLIArguments(from: env) { receivedEnv in
                XCTAssertEqual(receivedEnv["AGTMUX_TMUX_SOCKET_NAME"], "named-socket")
                return "/private/tmp/tmux-501/named-socket"
            },
            ["--tmux-socket", "/private/tmp/tmux-501/named-socket"]
        )
    }

    func testDaemonCLIArgumentsPreferBootstrapResolvedRuntimeSocketPathOverSocketNameLookup() {
        let env: [String: String] = [
            "AGTMUX_TMUX_SOCKET_NAME": "named-socket"
        ]
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath("/private/tmp/tmux-501/runtime.sock")

        XCTAssertEqual(
            LocalTmuxTarget.daemonCLIArguments(from: env),
            ["--tmux-socket", "/private/tmp/tmux-501/runtime.sock"]
        )
    }
}
