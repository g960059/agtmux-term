import XCTest
@testable import AgtmuxTermCore

final class PaneMetadataCompatFallbackTests: XCTestCase {
    func testActivityStateMappingMatchesLegacyAgtmuxPaneCollapse() {
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.running)), .running)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.waitingApproval)), .waitingApproval)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.waitingUserInput)), .waitingInput)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.error)), .error)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.idle)), .idle)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.completedIdle)), .idle)
        XCTAssertEqual(PaneMetadataCompatFallback.activityState(from: makePresentation(.inactive)), .unknown)
    }

    private func makePresentation(_ primary: PanePresentationPrimaryState) -> PanePresentationState {
        let blocking: AgtmuxSyncV3BlockingState
        let threadLifecycle: AgtmuxSyncV3ThreadLifecycle
        let turnOutcome: AgtmuxSyncV3TurnOutcome

        switch primary {
        case .running:
            blocking = .none
            threadLifecycle = .active
            turnOutcome = .none
        case .waitingApproval:
            blocking = .waitingApproval
            threadLifecycle = .active
            turnOutcome = .none
        case .waitingUserInput:
            blocking = .waitingUserInput
            threadLifecycle = .active
            turnOutcome = .none
        case .error:
            blocking = .none
            threadLifecycle = .errored
            turnOutcome = .errored
        case .idle:
            blocking = .none
            threadLifecycle = .idle
            turnOutcome = .none
        case .completedIdle:
            blocking = .none
            threadLifecycle = .idle
            turnOutcome = .completed
        case .inactive:
            blocking = .none
            threadLifecycle = .notLoaded
            turnOutcome = .none
        }

        return PanePresentationState(
            snapshot: AgtmuxSyncV3PaneSnapshot(
                sessionName: "demo",
                windowID: "@1",
                sessionKey: "codex:%3",
                paneID: "%3",
                paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                    paneId: "%3",
                    generation: 1,
                    birthTs: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                provider: .codex,
                presence: .managed,
                agent: AgtmuxSyncV3AgentState(lifecycle: .running),
                thread: AgtmuxSyncV3ThreadState(
                    lifecycle: threadLifecycle,
                    blocking: blocking,
                    execution: .thinking,
                    flags: AgtmuxSyncV3ThreadFlags(reviewMode: false, subagentActive: false),
                    turn: AgtmuxSyncV3TurnState(
                        outcome: turnOutcome,
                        sequence: 1,
                        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        completedAt: turnOutcome == .none ? nil : Date(timeIntervalSince1970: 1_700_000_010)
                    )
                ),
                pendingRequests: [],
                attention: AgtmuxSyncV3AttentionSummary(
                    activeKinds: [],
                    highestPriority: .none,
                    unresolvedCount: 0,
                    generation: 1,
                    latestAt: nil
                ),
                freshness: AgtmuxSyncV3FreshnessSummary(
                    snapshot: .fresh,
                    blocking: .fresh,
                    execution: .fresh
                ),
                providerRaw: nil,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_020)
            )
        )
    }
}
