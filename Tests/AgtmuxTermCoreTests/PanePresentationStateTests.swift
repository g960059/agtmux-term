import XCTest
@testable import AgtmuxTermCore

final class PanePresentationStateTests: XCTestCase {
    private func fixturePresentation(_ name: String, filePath: StaticString = #filePath) throws -> PanePresentationState {
        let bootstrap = try AgtmuxSyncV3FixtureLoader.bootstrap(named: name, filePath: filePath)
        let pane = try XCTUnwrap(bootstrap.panes.first)
        return PanePresentationState(snapshot: pane)
    }

    func testDerivePresentationFromCanonicalCodexRunningFixture() throws {
        let presentation = try fixturePresentation("codex-running")

        XCTAssertEqual(presentation.primaryState, .running)
        XCTAssertEqual(presentation.execution, .thinking)
        XCTAssertEqual(presentation.freshnessState, .fresh)
        XCTAssertFalse(presentation.needsUserAction)
    }

    func testDerivePresentationFromCanonicalCodexWaitingApprovalFixture() throws {
        let presentation = try fixturePresentation("codex-waiting-approval")

        XCTAssertEqual(presentation.primaryState, .waitingApproval)
        XCTAssertTrue(presentation.needsUserAction)
        XCTAssertEqual(presentation.pendingRequestIDs, ["req_codex_approval_001"])
        XCTAssertEqual(presentation.attentionSummary.highestPriority, .approval)
        XCTAssertTrue(presentation.reviewMode)
    }

    func testDerivePresentationFromCanonicalCodexCompletedIdleFixture() throws {
        let presentation = try fixturePresentation("codex-completed-idle")

        XCTAssertEqual(presentation.primaryState, .completedIdle)
        XCTAssertEqual(presentation.turnOutcome, .completed)
        XCTAssertFalse(presentation.needsUserAction)
        XCTAssertTrue(presentation.showsAttentionSummary)
    }

    func testDerivePresentationFromCanonicalClaudeApprovalFixture() throws {
        let presentation = try fixturePresentation("claude-approval")

        XCTAssertEqual(presentation.primaryState, .waitingApproval)
        XCTAssertEqual(presentation.provider, .claude)
        XCTAssertTrue(presentation.needsUserAction)
        XCTAssertEqual(presentation.pendingRequestIDs, ["req_claude_approval_001"])
    }

    func testDerivePresentationFromCanonicalClaudeStopIdleFixture() throws {
        let presentation = try fixturePresentation("claude-stop-idle")

        XCTAssertEqual(presentation.primaryState, .completedIdle)
        XCTAssertEqual(presentation.provider, .claude)
        XCTAssertEqual(presentation.turnOutcome, .completed)
        XCTAssertFalse(presentation.needsUserAction)
    }

    func testDerivePresentationFromCanonicalUnmanagedDemotionFixture() throws {
        let presentation = try fixturePresentation("unmanaged-demotion")

        XCTAssertEqual(presentation.primaryState, .idle)
        XCTAssertEqual(presentation.presence, .unmanaged)
        XCTAssertNil(presentation.provider)
        XCTAssertEqual(presentation.freshnessState, .down)
    }

    func testDerivePresentationFromCanonicalErrorFixture() throws {
        let presentation = try fixturePresentation("error")

        XCTAssertEqual(presentation.primaryState, .error)
        XCTAssertEqual(presentation.turnOutcome, .errored)
        XCTAssertTrue(presentation.showsAttentionSummary)
        XCTAssertEqual(presentation.attentionSummary.highestPriority, .error)
    }

    func testDerivePresentationFromCanonicalFreshnessDegradedFixture() throws {
        let presentation = try fixturePresentation("freshness-degraded")

        XCTAssertEqual(presentation.primaryState, .running)
        XCTAssertEqual(presentation.execution, .streaming)
        XCTAssertEqual(presentation.freshnessState, .degraded)
    }
}
