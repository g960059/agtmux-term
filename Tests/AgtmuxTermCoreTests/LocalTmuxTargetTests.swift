import XCTest
@testable import AgtmuxTermCore

final class LocalTmuxTargetTests: XCTestCase {
    override func tearDown() {
        AgtmuxManagedDaemonRuntime.setBootstrapResolvedTmuxSocketPath(nil)
        super.tearDown()
    }

    private func makeUserDefaultsSuite() -> UserDefaults {
        let suiteName = "LocalTmuxTargetCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTmuxTargetCoreTests.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    private func writeMarker(at markerURL: URL) throws {
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: markerURL, options: .atomic)
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

    func testConfigArgumentsHonorUITestConfigPath() {
        let env: [String: String] = [
            "AGTMUX_UITEST_TMUX_CONFIG_PATH": "/dev/null"
        ]

        XCTAssertEqual(LocalTmuxTarget.configArguments(from: env), ["-f", "/dev/null"])
        XCTAssertEqual(LocalTmuxTarget.shellEscapedConfigArguments(from: env), "-f /dev/null")
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

    func testSocketArgumentsIgnoreUITestDefaultsWhenMarkerIsAbsent() {
        let defaults = makeUserDefaultsSuite()
        defaults.set("stale-socket", forKey: LocalTmuxTarget.socketNameDefaultsKey)

        XCTAssertEqual(
            LocalTmuxTarget.socketArguments(from: [:], userDefaults: defaults),
            []
        )
    }

    func testSocketArgumentsHonorUITestDefaultsWhenMarkerExists() throws {
        let defaults = makeUserDefaultsSuite()
        let markerURL = makeMarkerURL()
        defaults.set("stale-socket", forKey: LocalTmuxTarget.socketNameDefaultsKey)
        try writeMarker(at: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }

        XCTAssertEqual(
            LocalTmuxTarget.socketArguments(
                from: [:],
                userDefaults: defaults,
                markerURL: markerURL
            ),
            ["-L", "stale-socket"]
        )
    }
}
