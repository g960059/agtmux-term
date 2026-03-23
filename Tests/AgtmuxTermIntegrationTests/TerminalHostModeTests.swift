import XCTest
@testable import AgtmuxTerm
@testable import AgtmuxTermCore

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

    func testVisiblePaneIdentityDropsBlankPersistedPaneRefs() {
        let paneRef = ActivePaneRef(
            target: .local,
            sessionName: "vm agtmux-term",
            windowID: "",
            paneID: "   "
        )

        XCTAssertNil(WorkbenchTerminalPaneIdentity.normalized(paneRef))
        XCTAssertNil(WorkbenchTerminalPaneIdentity.visiblePaneIdentity(for: paneRef))
    }

    func testVisiblePaneIdentityNormalizesWhitespaceAndPreservesPaneIdentity() {
        let paneRef = ActivePaneRef(
            target: .local,
            sessionName: "vm agtmux-term",
            windowID: " @7 ",
            paneID: " %42 ",
            paneInstanceID: .init(
                paneId: "%42",
                generation: 3,
                birthTs: Date(timeIntervalSince1970: 1234)
            )
        )

        XCTAssertEqual(
            WorkbenchTerminalPaneIdentity.normalized(paneRef),
            ActivePaneRef(
                target: .local,
                sessionName: "vm agtmux-term",
                windowID: "@7",
                paneID: "%42",
                paneInstanceID: .init(
                    paneId: "%42",
                    generation: 3,
                    birthTs: Date(timeIntervalSince1970: 1234)
                )
            )
        )
        XCTAssertEqual(
            WorkbenchTerminalPaneIdentity.visiblePaneIdentity(for: paneRef),
            "vm agtmux-term|@7|%42|%42@3@1234.0"
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

    func testBootstrapRenderPolicyAllowsNextHostLocalTerminalWithResolvedAttachPlan() {
        let attachPlan = WorkbenchV2TerminalAttachPlan(
            command: "tmux attach-session -t main",
            surfaceKey: "local:main:%0",
            transport: .local,
            displayTarget: "local"
        )

        XCTAssertTrue(
            WorkbenchTerminalBootstrapRenderPolicy.shouldRenderSurface(
                terminalState: .bootstrapping,
                attachResolution: .success(attachPlan),
                sessionTarget: .local,
                terminalHostMode: .next
            )
        )
    }

    func testBootstrapRenderPolicyKeepsLegacyHostAndRemoteBootstrapsDeferred() {
        let attachPlan = WorkbenchV2TerminalAttachPlan(
            command: "tmux attach-session -t main",
            surfaceKey: "local:main:%0",
            transport: .local,
            displayTarget: "local"
        )

        XCTAssertFalse(
            WorkbenchTerminalBootstrapRenderPolicy.shouldRenderSurface(
                terminalState: .bootstrapping,
                attachResolution: .success(attachPlan),
                sessionTarget: .local,
                terminalHostMode: .legacy
            )
        )

        XCTAssertFalse(
            WorkbenchTerminalBootstrapRenderPolicy.shouldRenderSurface(
                terminalState: .bootstrapping,
                attachResolution: .success(attachPlan),
                sessionTarget: .remote(hostKey: "prod"),
                terminalHostMode: .next
            )
        )

        XCTAssertFalse(
            WorkbenchTerminalBootstrapRenderPolicy.shouldRenderSurface(
                terminalState: .ready,
                attachResolution: .success(attachPlan),
                sessionTarget: .local,
                terminalHostMode: .next
            )
        )
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
