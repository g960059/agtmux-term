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

    func testSidebarStateSummaryUsesPresentationSnapshotsWithoutRawPaneFallback() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "alpha",
            windowId: "@1",
            activityState: .running,
            presence: .managed,
            provider: .claude,
            evidenceMode: .heuristic,
            currentCmd: "zsh",
            updatedAt: now
        )
        let display = PaneDisplayState(
            pane: pane,
            presentation: PanePresentationState(
                snapshot: makeSnapshot(
                    sessionName: "alpha",
                    windowID: "@1",
                    sessionKey: "codex:%1",
                    paneID: "%1",
                    provider: .codex,
                    presence: .managed,
                    threadLifecycle: .idle,
                    blocking: .none,
                    execution: .none,
                    freshness: .init(snapshot: .stale, blocking: .fresh, execution: .fresh)
                )
            )
        )
        let presentation = UITestSidebarDiagnostics.panePresentationSnapshot(for: pane, display: display)
        let snapshot = UITestSidebarStateSnapshot(
            statusFilter: "all",
            panePresentations: [presentation],
            filteredPanePresentations: [presentation],
            attentionCount: 0,
            localDaemonIssueTitle: nil,
            localDaemonIssueDetail: nil,
            bootstrapProbeSummary: UITestBootstrapProbeSummary(
                ok: true,
                transportVersion: "sync-v3",
                totalPanes: 1,
                managedPanes: 1,
                error: nil
            ),
            bootstrapTargetSummary: UITestBootstrapTargetSummary(
                sessionName: "alpha",
                paneID: "%1",
                presence: "managed",
                provider: "codex",
                primaryState: PanePresentationPrimaryState.completedIdle.rawValue,
                freshness: PanePresentationFreshnessState.degraded.rawValue,
                sessionKey: "codex:%1",
                paneInstanceID: "AgtmuxSyncV3PaneInstanceID(paneId: \"%1\", generation: 1, birthTs: \(now))"
            ),
            managedDaemonSocketPath: "/tmp/agtmuxd.sock",
            tmuxSocketArguments: ["-L", "alpha"],
            daemonCLIArguments: ["--socket", "/tmp/agtmuxd.sock"],
            bootstrapResolvedTmuxSocketPath: "/tmp/tmux.sock",
            appDirectResolvedSocketProbe: "ok",
            appDirectResolvedSocketProbeError: nil,
            daemonProcessCommands: ["agtmux daemon"],
            daemonLaunchRecord: UITestDaemonLaunchRecordSnapshot(
                binaryPath: "/tmp/agtmux",
                arguments: ["daemon"],
                environment: ["PATH": "/usr/bin"],
                reusedExistingRuntime: false
            ),
            managedDaemonStderrTail: nil
        )

        let summary = UITestSidebarDiagnostics.sidebarStateSummary(
            snapshot,
            sessionName: "alpha",
            paneID: "%1"
        )

        XCTAssertTrue(summary.contains("all=presence=managed,provider=codex,primary=completed_idle"))
        XCTAssertTrue(summary.contains("filtered=presence=managed,provider=codex,primary=completed_idle"))
        XCTAssertTrue(summary.contains("current_cmd=zsh"))
        XCTAssertFalse(summary.contains("activity="))
        XCTAssertTrue(summary.contains("filteredCount=1"))
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
