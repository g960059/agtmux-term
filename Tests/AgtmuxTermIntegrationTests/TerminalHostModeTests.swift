import XCTest
@testable import AgtmuxTerm

final class TerminalHostModeTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TerminalHostMode.userDefaultsKey)
        super.tearDown()
    }

    func testDefaultsToLegacyWhenEnvironmentIsMissingOrUnknown() {
        XCTAssertEqual(TerminalHostMode(environment: [:]), .legacy)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "bogus"]), .legacy)
    }

    func testParsesNextHostModeSynonyms() {
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "next"]), .next)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "native"]), .next)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "renderer-owned"]), .next)
    }

    func testHostViewIdentityIncludesMode() {
        let surfaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertNotEqual(
            TerminalHostContainer.hostViewIdentity(surfaceID: surfaceID, mode: .legacy),
            TerminalHostContainer.hostViewIdentity(surfaceID: surfaceID, mode: .next)
        )
    }

    func testNextHostPaneCacheKeyFallsBackToTileIdentity() {
        let surfaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            NextGhosttyIslandViewController.paneCacheKey(
                visiblePaneIdentity: nil,
                fallbackSurfaceID: surfaceID
            ),
            "__tile:\(surfaceID.uuidString)"
        )
        XCTAssertEqual(
            NextGhosttyIslandViewController.paneCacheKey(
                visiblePaneIdentity: "shared|@1|%1|",
                fallbackSurfaceID: surfaceID
            ),
            "shared|@1|%1|"
        )
    }

    func testNextHostRetentionPolicyKeepsActivePaneAndMostRecentInactivePanes() {
        let trimmed = NextGhosttyIslandViewController.trimmedRetentionOrder(
            ["pane-a", "pane-b", "pane-c", "pane-d", "pane-e"],
            activePaneKey: "pane-c",
            limit: 4
        )
        XCTAssertEqual(trimmed, ["pane-b", "pane-c", "pane-d", "pane-e"])
    }

    @MainActor
    func testRuntimeOverrideWinsOverEnvironmentUntilCleared() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: TerminalHostMode.userDefaultsKey)
        let runtime = TerminalHostModeRuntime(userDefaults: defaults)
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }

        XCTAssertEqual(
            runtime.resolved(environment: [TerminalHostMode.environmentKey: "legacy"]),
            .legacy
        )

        runtime.setOverride(.next)
        XCTAssertEqual(
            runtime.resolved(environment: [TerminalHostMode.environmentKey: "legacy"]),
            .next
        )

        runtime.setOverride(nil)
        XCTAssertEqual(
            runtime.resolved(environment: [TerminalHostMode.environmentKey: "legacy"]),
            .legacy
        )
    }

    @MainActor
    func testRuntimeFallsBackToUserDefaultsWhenEnvironmentMissing() {
        let defaults = UserDefaults.standard
        defaults.set("next", forKey: TerminalHostMode.userDefaultsKey)
        let runtime = TerminalHostModeRuntime(userDefaults: defaults)
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }

        XCTAssertEqual(runtime.resolved(environment: [:]), .next)
    }

    @MainActor
    func testEnvironmentWinsOverUserDefaultsWithoutRuntimeOverride() {
        let defaults = UserDefaults.standard
        defaults.set("next", forKey: TerminalHostMode.userDefaultsKey)
        let runtime = TerminalHostModeRuntime(userDefaults: defaults)
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }

        XCTAssertEqual(
            runtime.resolved(environment: [TerminalHostMode.environmentKey: "legacy"]),
            .legacy
        )
    }
}
