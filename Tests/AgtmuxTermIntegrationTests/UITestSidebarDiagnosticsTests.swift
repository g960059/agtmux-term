import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class UITestSidebarDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBootstrapProbeSummaryUsesSyncV3TransportAndManagedCount() {
        let bootstrap = AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [
                makeSnapshot(
                    sessionName: "alpha",
                    windowID: "@1",
                    sessionKey: "codex:%1",
                    paneID: "%1",
                    provider: .codex,
                    presence: .managed,
                    threadLifecycle: .active,
                    blocking: .none,
                    execution: .streaming
                ),
                makeSnapshot(
                    sessionName: "alpha",
                    windowID: "@1",
                    sessionKey: "shell:%2",
                    paneID: "%2",
                    provider: nil,
                    presence: .unmanaged,
                    threadLifecycle: .idle,
                    blocking: .none,
                    execution: .none
                )
            ],
            generatedAt: now,
            replayCursor: AgtmuxSyncV3Cursor(seq: 5)
        )

        let summary = UITestSidebarDiagnostics.bootstrapProbeSummary(from: bootstrap)

        XCTAssertEqual(summary.transportVersion, "sync-v3")
        XCTAssertTrue(summary.ok)
        XCTAssertEqual(summary.totalPanes, 2)
        XCTAssertEqual(summary.managedPanes, 1)
        XCTAssertNil(summary.error)
    }

    func testBootstrapTargetSummaryUsesPresentationAndExactIdentityFields() {
        let snapshot = makeSnapshot(
            sessionName: "alpha",
            windowID: "@1",
            sessionKey: "codex:%1",
            paneID: "%1",
            provider: .codex,
            presence: .managed,
            threadLifecycle: .active,
            blocking: .waitingApproval,
            execution: .toolRunning,
            freshness: .init(snapshot: .stale, blocking: .fresh, execution: .fresh)
        )
        let bootstrap = AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [snapshot],
            generatedAt: now,
            replayCursor: AgtmuxSyncV3Cursor(seq: 9)
        )

        let target = UITestSidebarDiagnostics.bootstrapTargetSummary(
            from: bootstrap,
            requestedSessionName: "alpha",
            requestedPaneID: "%1"
        )

        XCTAssertEqual(target?.sessionName, "alpha")
        XCTAssertEqual(target?.paneID, "%1")
        XCTAssertEqual(target?.presence, "managed")
        XCTAssertEqual(target?.provider, "codex")
        XCTAssertEqual(target?.primaryState, PanePresentationPrimaryState.waitingApproval.rawValue)
        XCTAssertEqual(target?.freshness, PanePresentationFreshnessState.degraded.rawValue)
        XCTAssertEqual(target?.sessionKey, "codex:%1")
        XCTAssertEqual(target?.paneInstanceID, String(describing: snapshot.paneInstanceID))
    }

    func testPanePresentationSnapshotPrefersDisplaySemanticsOverLegacyActivity() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "alpha",
            windowId: "@1",
            activityState: .unknown,
            presence: .unmanaged,
            provider: nil,
            evidenceMode: .none,
            currentCmd: "zsh",
            updatedAt: now
        )
        let presentation = PanePresentationState(
            snapshot: makeSnapshot(
                sessionName: "alpha",
                windowID: "@1",
                sessionKey: "codex:%1",
                paneID: "%1",
                provider: .codex,
                presence: .managed,
                threadLifecycle: .active,
                blocking: .waitingUserInput,
                execution: .none
            )
        )
        let display = PaneDisplayState(pane: pane, presentation: presentation)

        let summary = UITestSidebarDiagnostics.panePresentationSnapshot(for: pane, display: display)

        XCTAssertEqual(summary.presence, "managed")
        XCTAssertEqual(summary.provider, "codex")
        XCTAssertEqual(summary.primaryState, PanePresentationPrimaryState.waitingUserInput.rawValue)
        XCTAssertTrue(summary.isManaged)
        XCTAssertTrue(summary.needsAttention)
        XCTAssertEqual(summary.currentCommand, "zsh")
    }

    private func makeSnapshot(
        sessionName: String,
        windowID: String,
        sessionKey: String,
        paneID: String,
        provider: Provider?,
        presence: AgtmuxSyncV3Presence,
        threadLifecycle: AgtmuxSyncV3ThreadLifecycle,
        blocking: AgtmuxSyncV3BlockingState,
        execution: AgtmuxSyncV3ExecutionState,
        freshness: AgtmuxSyncV3FreshnessSummary = .init(snapshot: .fresh, blocking: .fresh, execution: .fresh)
    ) -> AgtmuxSyncV3PaneSnapshot {
        let paneInstanceID = AgtmuxSyncV3PaneInstanceID(
            paneId: paneID,
            generation: 1,
            birthTs: now
        )
        return AgtmuxSyncV3PaneSnapshot(
            sessionName: sessionName,
            windowID: windowID,
            sessionKey: sessionKey,
            paneID: paneID,
            paneInstanceID: paneInstanceID,
            provider: provider,
            presence: presence,
            agent: AgtmuxSyncV3AgentState(lifecycle: provider == nil ? .unknown : .running),
            thread: AgtmuxSyncV3ThreadState(
                lifecycle: threadLifecycle,
                blocking: blocking,
                execution: execution,
                flags: AgtmuxSyncV3ThreadFlags(reviewMode: blocking == .waitingApproval, subagentActive: false),
                turn: AgtmuxSyncV3TurnState(
                    outcome: threadLifecycle == .idle ? .completed : .none,
                    sequence: 1,
                    startedAt: now,
                    completedAt: threadLifecycle == .idle ? now : nil
                )
            ),
            pendingRequests: [],
            attention: AgtmuxSyncV3AttentionSummary(
                activeKinds: blocking == .waitingApproval ? [.approval] : blocking == .waitingUserInput ? [.question] : [],
                highestPriority: blocking == .waitingApproval ? .approval : blocking == .waitingUserInput ? .question : .none,
                unresolvedCount: blocking == .none ? 0 : 1,
                generation: 1,
                latestAt: blocking == .none ? nil : now
            ),
            freshness: freshness,
            providerRaw: nil,
            updatedAt: now
        )
    }
}
