import Foundation
@testable import AgtmuxTermCore

enum AgtmuxSyncV3FixtureLoader {
    static let daemonFixtureCommit = "cb198cca7226666fbb26df34d4e17582a208c3e6"

    static func bootstrap(named name: String, filePath: StaticString = #filePath) throws -> AgtmuxSyncV3Bootstrap {
        let data = try Data(contentsOf: fixtureURL(named: name, filePath: filePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgtmuxSyncV3Bootstrap.self, from: data)
    }

    static func fixtureURL(named name: String, filePath: StaticString = #filePath) -> URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["AGTMUX_SYNC_V3_FIXTURES_ROOT"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let testFileURL = URL(fileURLWithPath: "\(filePath)")
            let repoRoot = testFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            root = repoRoot
                .deletingLastPathComponent()
                .appendingPathComponent("agtmux", isDirectory: true)
                .appendingPathComponent("fixtures", isDirectory: true)
                .appendingPathComponent("sync-v3", isDirectory: true)
        }
        return root.appendingPathComponent("\(name).json")
    }
}
