import XCTest
import AgtmuxTermCore

final class LocalTmuxTargetTests: XCTestCase {
    private func makeUserDefaultsSuite() -> UserDefaults {
        let suiteName = "LocalTmuxTargetTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTmuxTargetTests.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    private func writeMarker(at markerURL: URL) throws {
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: markerURL, options: .atomic)
    }

    func testSocketArgumentsIgnoreDefaultsWhenBridgeMarkerIsAbsent() {
        let defaults = makeUserDefaultsSuite()
        defaults.set("agtmux-test-socket", forKey: LocalTmuxTarget.socketNameDefaultsKey)

        XCTAssertEqual(
            LocalTmuxTarget.socketArguments(from: [:], userDefaults: defaults),
            []
        )
    }

    func testSocketArgumentsHonorDefaultsWhenBridgeMarkerExists() throws {
        let defaults = makeUserDefaultsSuite()
        let markerURL = makeMarkerURL()
        defaults.set("agtmux-test-socket", forKey: LocalTmuxTarget.socketNameDefaultsKey)
        try writeMarker(at: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }

        XCTAssertEqual(
            LocalTmuxTarget.socketArguments(
                from: [:],
                userDefaults: defaults,
                markerURL: markerURL
            ),
            ["-L", "agtmux-test-socket"]
        )
    }

    func testConfigArgumentsIgnoreDefaultsWhenBridgeMarkerIsAbsent() {
        let defaults = makeUserDefaultsSuite()
        defaults.set("/dev/null", forKey: LocalTmuxTarget.configPathDefaultsKey)

        XCTAssertEqual(
            LocalTmuxTarget.configArguments(from: [:], userDefaults: defaults),
            []
        )
    }

    func testConfigArgumentsHonorDefaultsWhenBridgeMarkerExists() throws {
        let defaults = makeUserDefaultsSuite()
        let markerURL = makeMarkerURL()
        defaults.set("/dev/null", forKey: LocalTmuxTarget.configPathDefaultsKey)
        try writeMarker(at: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }

        XCTAssertEqual(
            LocalTmuxTarget.configArguments(
                from: [:],
                userDefaults: defaults,
                markerURL: markerURL
            ),
            ["-f", "/dev/null"]
        )
    }
}
