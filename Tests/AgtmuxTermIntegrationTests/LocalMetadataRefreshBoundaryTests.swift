import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalMetadataRefreshBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBootstrapResultDefersAndClearsOnInventoryPresentEmptyV2Bootstrap() {
        let result = LocalMetadataRefreshBoundary.bootstrapResult(
            from: .v2(
                AgtmuxSyncV2Bootstrap(
                    epoch: 1,
                    snapshotSeq: 0,
                    panes: [],
                    sessions: [],
                    generatedAt: now,
                    replayCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 0)
                )
            ),
            cache: LocalMetadataOverlayCache(metadataByPaneKey: [:], presentationByPaneKey: [:]),
            inventoryCount: 2,
            bootstrapNotReadyBackoff: 0.5,
            now: now
        )

        guard case let .deferred(plan) = result else {
            return XCTFail("expected deferred plan")
        }

        XCTAssertEqual(plan.state.syncPrimed, false)
        XCTAssertNil(plan.state.transportVersion)
        XCTAssertNil(plan.state.daemonIssue)
        XCTAssertEqual(plan.state.nextRefreshAt, now.addingTimeInterval(0.5))
        XCTAssertEqual(plan.cacheAction, .clear)
        XCTAssertEqual(plan.replayResetVersion, .v2)
        XCTAssertEqual(
            plan.logMessage,
            "sync-v2 bootstrap not ready; local inventory has 2 panes but bootstrap returned panes=0"
        )
        XCTAssertEqual(plan.shouldPublishSnapshotCache, true)
    }

    func testBootstrapResultDefersAndClearsOnInventoryPresentEmptyV3Bootstrap() {
        let result = LocalMetadataRefreshBoundary.bootstrapResult(
            from: .v3(
                AgtmuxSyncV3Bootstrap(
                    version: 3,
                    panes: [],
                    generatedAt: now,
                    replayCursor: AgtmuxSyncV3Cursor(seq: 0)
                )
            ),
            cache: LocalMetadataOverlayCache(metadataByPaneKey: [:], presentationByPaneKey: [:]),
            inventoryCount: 1,
            bootstrapNotReadyBackoff: 0.75,
            now: now
        )

        guard case let .deferred(plan) = result else {
            return XCTFail("expected deferred plan")
        }

        XCTAssertEqual(plan.state.syncPrimed, false)
        XCTAssertNil(plan.state.transportVersion)
        XCTAssertNil(plan.state.daemonIssue)
        XCTAssertEqual(plan.state.nextRefreshAt, now.addingTimeInterval(0.75))
        XCTAssertEqual(plan.cacheAction, .clear)
        XCTAssertEqual(plan.replayResetVersion, .v3)
        XCTAssertEqual(
            plan.logMessage,
            "sync-v3 bootstrap not ready; local inventory has 1 panes but bootstrap returned panes=0"
        )
        XCTAssertEqual(plan.shouldPublishSnapshotCache, true)
    }

    func testPublishPlanMarksPrimedSetsVersionAndSchedulesNextRefresh() {
        let cache = LocalMetadataOverlayCache(
            metadataByPaneKey: ["k": makePane()],
            presentationByPaneKey: [:]
        )

        let plan = LocalMetadataRefreshBoundary.publishPlan(
            cache: cache,
            inventoryCount: 1,
            successInterval: 1.5,
            syncPrimed: true,
            transportVersion: .v3,
            daemonIssue: nil,
            now: now
        )

        XCTAssertEqual(plan.state.syncPrimed, true)
        XCTAssertEqual(plan.state.transportVersion, .v3)
        XCTAssertNil(plan.state.daemonIssue)
        XCTAssertEqual(plan.state.nextRefreshAt, now.addingTimeInterval(1.5))
        XCTAssertEqual(plan.cacheAction, .replace(cache))
        XCTAssertEqual(plan.shouldPublishSnapshotCache, true)
        XCTAssertNil(plan.replayResetVersion)
        XCTAssertNil(plan.logMessage)
    }

    func testClearPlanPreservesNoPublishWhenInventoryMissing() {
        let issue = LocalDaemonIssue.localDaemonUnavailable(detail: "daemon unavailable")
        let nextAt = now.addingTimeInterval(3.0)

        let plan = LocalMetadataRefreshBoundary.clearPlan(
            inventoryCount: 0,
            nextRefreshAt: nextAt,
            syncPrimed: false,
            transportVersion: nil,
            daemonIssue: issue
        )

        XCTAssertEqual(plan.state.syncPrimed, false)
        XCTAssertNil(plan.state.transportVersion)
        XCTAssertEqual(plan.state.daemonIssue, issue)
        XCTAssertEqual(plan.state.nextRefreshAt, nextAt)
        XCTAssertEqual(plan.cacheAction, .clear)
        XCTAssertEqual(plan.shouldPublishSnapshotCache, false)
        XCTAssertNil(plan.replayResetVersion)
        XCTAssertNil(plan.logMessage)
    }

    private func makePane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "vm agtmux-term",
            windowId: "@1",
            activityState: .running,
            presence: .managed,
            provider: .codex,
            evidenceMode: .deterministic,
            updatedAt: now,
            metadataSessionKey: "opaque-session-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%1",
                generation: 1,
                birthTs: now
            )
        )
    }
}
