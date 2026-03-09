import XCTest
@testable import AgtmuxTermCore

final class PaneDisplayStateTests: XCTestCase {
    func testLegacyFallbackKeepsCollapsedPaneSemanticsInOneAdapter() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%3",
            sessionName: "demo",
            windowId: "@1",
            activityState: .waitingInput,
            presence: .managed,
            provider: .codex,
            currentCmd: "node",
            ageSecs: 18
        )

        let display = PaneDisplayState(pane: pane, presentation: nil)

        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(for: pane), .waitingUserInput)
        XCTAssertEqual(PaneDisplayCompatFallback.freshnessText(for: pane), "18s")
        XCTAssertTrue(PaneDisplayCompatFallback.needsAttention(for: pane))
        XCTAssertEqual(display.provider, .codex)
        XCTAssertEqual(display.presence, .managed)
        XCTAssertEqual(display.primaryState, .waitingUserInput)
        XCTAssertEqual(display.freshnessText, "18s")
        XCTAssertTrue(display.isManaged)
        XCTAssertTrue(display.needsAttention)
    }

    func testV3PresentationBeatsLegacyCollapseForFreshnessAndAttention() throws {
        let bootstrap = try AgtmuxSyncV3FixtureLoader.bootstrap(named: "freshness-degraded", filePath: #filePath)
        let snapshot = try XCTUnwrap(bootstrap.panes.first)
        let pane = AgtmuxPane(
            source: "local",
            paneId: snapshot.paneID,
            sessionName: snapshot.sessionName,
            windowId: snapshot.windowID,
            activityState: .running,
            presence: .managed,
            provider: snapshot.provider,
            currentCmd: "zsh",
            ageSecs: 45,
            metadataSessionKey: snapshot.sessionKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: snapshot.paneInstanceID.paneId,
                generation: snapshot.paneInstanceID.generation,
                birthTs: snapshot.paneInstanceID.birthTs
            )
        )

        let display = PaneDisplayState(
            pane: pane,
            presentation: PanePresentationState(snapshot: snapshot)
        )

        XCTAssertEqual(display.primaryState, .running)
        XCTAssertEqual(display.freshnessText, "degraded")
        XCTAssertTrue(display.isManaged)
        XCTAssertFalse(display.needsAttention)
    }
}
