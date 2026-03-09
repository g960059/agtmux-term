import XCTest
@testable import AgtmuxTermCore

final class PanePresentationStateTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    private func makeSnapshot(
        provider: Provider? = .codex,
        presence: PanePresence = .managed,
        agentLifecycle: AgtmuxSyncV3AgentLifecycle = .running,
        threadLifecycle: AgtmuxSyncV3ThreadLifecycle = .active,
        blocking: AgtmuxSyncV3BlockingState = .none,
        execution: AgtmuxSyncV3ExecutionState = .toolRunning,
        reviewMode: Bool = false,
        subagentActive: Bool = false,
        outcome: AgtmuxSyncV3TurnOutcome = .none,
        pendingRequests: [AgtmuxSyncV3PendingRequest] = [],
        attentionKinds: [AgtmuxSyncV3AttentionKind] = [],
        highestPriority: AgtmuxSyncV3AttentionPriority = .none,
        unresolvedCount: UInt32 = 0,
        freshness: AgtmuxSyncV3FreshnessSummary = .init(snapshot: .fresh, blocking: .fresh, execution: .fresh)
    ) -> AgtmuxSyncV3PaneSnapshot {
        AgtmuxSyncV3PaneSnapshot(
            sessionName: "demo",
            windowID: "@1",
            sessionKey: "codex:%1",
            paneID: "%1",
            paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                paneId: "%1",
                generation: 1,
                birthTs: date("2026-03-09T22:00:00Z")
            ),
            provider: provider,
            presence: presence,
            agent: AgtmuxSyncV3AgentState(lifecycle: agentLifecycle),
            thread: AgtmuxSyncV3ThreadState(
                lifecycle: threadLifecycle,
                blocking: blocking,
                execution: execution,
                flags: AgtmuxSyncV3ThreadFlags(
                    reviewMode: reviewMode,
                    subagentActive: subagentActive
                ),
                turn: AgtmuxSyncV3TurnState(
                    outcome: outcome,
                    sequence: 7,
                    startedAt: date("2026-03-09T22:00:00Z"),
                    completedAt: outcome == .none ? nil : date("2026-03-09T22:00:10Z")
                )
            ),
            pendingRequests: pendingRequests,
            attention: AgtmuxSyncV3AttentionSummary(
                activeKinds: attentionKinds,
                highestPriority: highestPriority,
                unresolvedCount: unresolvedCount,
                generation: 4,
                latestAt: date("2026-03-09T22:00:10Z")
            ),
            freshness: freshness,
            providerRaw: nil,
            updatedAt: date("2026-03-09T22:00:10Z")
        )
    }

    private func approvalRequest() -> AgtmuxSyncV3PendingRequest {
        AgtmuxSyncV3PendingRequest(
            requestID: "req-approval",
            kind: .approval,
            title: "Apply patch",
            detail: "Approve workspace modifications",
            createdAt: date("2026-03-09T22:00:01Z"),
            updatedAt: date("2026-03-09T22:00:01Z"),
            status: .pending,
            source: AgtmuxSyncV3PendingRequestSource(provider: .codex, sourceKind: "codex_appserver")
        )
    }

    private func questionRequest() -> AgtmuxSyncV3PendingRequest {
        AgtmuxSyncV3PendingRequest(
            requestID: "req-question",
            kind: .userInput,
            title: "Need answer",
            detail: "Choose A or B",
            createdAt: date("2026-03-09T22:00:01Z"),
            updatedAt: date("2026-03-09T22:00:01Z"),
            status: .pending,
            source: AgtmuxSyncV3PendingRequestSource(provider: .claude, sourceKind: "claude_hooks")
        )
    }

    func testDeriveRunningState() {
        let presentation = PanePresentationState(snapshot: makeSnapshot())

        XCTAssertEqual(presentation.primaryState, .running)
        XCTAssertEqual(presentation.execution, .toolRunning)
        XCTAssertEqual(presentation.freshnessState, .fresh)
        XCTAssertFalse(presentation.needsUserAction)
        XCTAssertEqual(presentation.identity.sessionName, "demo")
    }

    func testDeriveWaitingApprovalState() {
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                blocking: .waitingApproval,
                pendingRequests: [approvalRequest()],
                attentionKinds: [.approval],
                highestPriority: .approval,
                unresolvedCount: 1
            )
        )

        XCTAssertEqual(presentation.primaryState, .waitingApproval)
        XCTAssertTrue(presentation.needsUserAction)
        XCTAssertEqual(presentation.pendingRequestIDs, ["req-approval"])
        XCTAssertEqual(presentation.attentionSummary.highestPriority, .approval)
    }

    func testDeriveWaitingUserInputState() {
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                provider: .claude,
                blocking: .waitingUserInput,
                execution: .none,
                pendingRequests: [questionRequest()],
                attentionKinds: [.question],
                highestPriority: .question,
                unresolvedCount: 1
            )
        )

        XCTAssertEqual(presentation.primaryState, .waitingUserInput)
        XCTAssertTrue(presentation.needsUserAction)
        XCTAssertTrue(presentation.showsAttentionSummary)
        XCTAssertEqual(presentation.pendingRequestIDs, ["req-question"])
    }

    func testDeriveCompletedIdleStateWithoutReintroducingWaiting() {
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                agentLifecycle: .completed,
                threadLifecycle: .idle,
                blocking: .none,
                execution: .none,
                outcome: .completed,
                attentionKinds: [.completion],
                highestPriority: .completion
            )
        )

        XCTAssertEqual(presentation.primaryState, .completedIdle)
        XCTAssertEqual(presentation.turnOutcome, .completed)
        XCTAssertFalse(presentation.needsUserAction)
    }

    func testDeriveErrorState() {
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                agentLifecycle: .errored,
                threadLifecycle: .errored,
                execution: .none,
                outcome: .errored,
                attentionKinds: [.error],
                highestPriority: .error
            )
        )

        XCTAssertEqual(presentation.primaryState, .error)
        XCTAssertTrue(presentation.showsAttentionSummary)
        XCTAssertEqual(presentation.attentionSummary.highestPriority, .error)
    }

    func testDeriveDegradedFreshnessWhenAnyAxisIsStale() {
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                freshness: .init(snapshot: .fresh, blocking: .stale, execution: .fresh)
            )
        )

        XCTAssertEqual(presentation.freshnessState, .degraded)
    }
}
