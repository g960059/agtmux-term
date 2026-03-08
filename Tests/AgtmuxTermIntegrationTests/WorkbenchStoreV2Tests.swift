import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchStoreV2Tests: XCTestCase {
    @MainActor
    func testStoreStartsWithSingleEmptyWorkbench() {
        let store = WorkbenchStoreV2()

        XCTAssertEqual(store.workbenches.count, 1)
        XCTAssertEqual(store.activeWorkbenchIndex, 0)
        XCTAssertTrue(store.activeWorkbench?.root.isEmpty == true)
        XCTAssertNil(store.activeWorkbench?.focusedTileID)
    }

    @MainActor
    func testOpenTerminalPlacesTerminalTileAndUpdatesFocus() {
        let store = WorkbenchStoreV2()
        let sessionRef = SessionRef(
            target: .remote(hostKey: "devbox"),
            sessionName: "backend"
        )

        let result = store.openTerminal(sessionRef: sessionRef)

        guard case .tile(let tile)? = store.activeWorkbench?.root else {
            return XCTFail("Expected a terminal tile")
        }
        XCTAssertEqual(result, .opened(workbenchID: store.workbenches[0].id, tileID: tile.id))
        XCTAssertEqual(tile.kind, .terminal(sessionRef: sessionRef))
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tile.id)
    }

    @MainActor
    func testOpenTerminalRevealsExistingTileInSameWorkbench() {
        let store = WorkbenchStoreV2()
        let sessionRef = SessionRef(target: .local, sessionName: "main")

        let first = store.openTerminal(sessionRef: sessionRef)
        let second = store.openTerminal(sessionRef: sessionRef)

        guard case .tile(let tile)? = store.activeWorkbench?.root else {
            return XCTFail("Expected the original terminal tile to remain present")
        }
        XCTAssertEqual(second, .revealedExisting(workbenchID: store.workbenches[0].id, tileID: tile.id))
        XCTAssertEqual(first.tileID, tile.id)
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tile.id)
    }

    @MainActor
    func testOpenTerminalRevealsExistingTileAndKeepsStoredSessionIdentityStable() {
        let store = WorkbenchStoreV2()
        let initial = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenRepoRoot: "/tmp/a"
        )
        let updated = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenRepoRoot: "/tmp/b"
        )

        let first = store.openTerminal(sessionRef: initial)
        let second = store.openTerminal(sessionRef: updated)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let storedRef) = tile.kind else {
            return XCTFail("Expected the existing terminal tile to be updated in place")
        }

        XCTAssertEqual(second, .revealedExisting(workbenchID: store.workbenches[0].id, tileID: first.tileID))
        XCTAssertEqual(tile.id, first.tileID, "Same-session retarget must preserve tile identity")
        XCTAssertEqual(storedRef.target, .local)
        XCTAssertEqual(storedRef.sessionName, "main")
        XCTAssertEqual(storedRef.lastSeenRepoRoot, "/tmp/b")
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
    }

    @MainActor
    func testOpenTerminalRevealsExistingTileAcrossWorkbenches() {
        let store = WorkbenchStoreV2()
        let sessionRef = SessionRef(target: .local, sessionName: "shared")

        let initial = store.openTerminal(sessionRef: sessionRef)
        let firstWorkbenchID = store.workbenches[0].id
        let secondWorkbench = store.createWorkbench(title: "Scratch")

        XCTAssertEqual(store.activeWorkbench?.id, secondWorkbench.id)
        XCTAssertTrue(store.activeWorkbench?.root.isEmpty == true)

        let revealed = store.openTerminal(sessionRef: sessionRef)

        XCTAssertEqual(revealed, .revealedExisting(workbenchID: firstWorkbenchID, tileID: initial.tileID))
        XCTAssertEqual(store.activeWorkbench?.id, firstWorkbenchID)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, initial.tileID)
        XCTAssertEqual(store.workbenches[0].tiles.count, 1)
        XCTAssertTrue(store.workbenches[1].root.isEmpty)
    }

    @MainActor
    func testOpenTerminalAcrossWorkbenchesKeepsStoredSessionIdentityStable() {
        let store = WorkbenchStoreV2()
        let initial = SessionRef(
            target: .local,
            sessionName: "shared"
        )
        let updated = SessionRef(
            target: .local,
            sessionName: "shared",
            lastSeenRepoRoot: "/tmp/updated"
        )

        let first = store.openTerminal(sessionRef: initial)
        _ = store.createWorkbench(title: "Scratch")

        let revealed = store.openTerminal(sessionRef: updated)

        XCTAssertEqual(revealed, .revealedExisting(workbenchID: store.workbenches[0].id, tileID: first.tileID))
        XCTAssertEqual(store.activeWorkbench?.id, store.workbenches[0].id)
        guard let tile = store.activeWorkbench?.tiles.first(where: { $0.id == first.tileID }),
              case .terminal(let storedRef) = tile.kind else {
            return XCTFail("Expected the original terminal tile to be updated across workbenches")
        }
        XCTAssertEqual(storedRef.target, .local)
        XCTAssertEqual(storedRef.sessionName, "shared")
        XCTAssertEqual(storedRef.lastSeenRepoRoot, "/tmp/updated")
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
        XCTAssertTrue(store.workbenches[1].root.isEmpty)
    }

    @MainActor
    func testFocusedTerminalTileContextReturnsFocusedTerminalSessionRef() {
        let store = WorkbenchStoreV2()
        let sessionRef = SessionRef(
            target: .local,
            sessionName: "shared"
        )

        let result = store.openTerminal(sessionRef: sessionRef)
        let context = store.focusedTerminalTileContext

        XCTAssertEqual(context?.workbenchID, store.activeWorkbench?.id)
        XCTAssertEqual(context?.tileID, result.tileID)
        XCTAssertEqual(context?.sessionRef, sessionRef)
    }

    @MainActor
    func testOpenTerminalForPanePopulatesActivePaneSelection() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@3"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: pane, hostsConfig: .empty)
        let selection = store.activePaneSelection(
            panes: [pane],
            hostsConfig: .empty
        )

        XCTAssertEqual(selection?.workbenchID, store.activeWorkbench?.id)
        XCTAssertEqual(selection?.tileID, result.tileID)
        XCTAssertEqual(selection?.source, "local")
        XCTAssertEqual(selection?.sessionName, "shared")
        XCTAssertEqual(selection?.windowID, "@3")
        XCTAssertEqual(selection?.paneID, "%9")
        XCTAssertEqual(selection?.paneInventoryID, pane.id)
    }

    @MainActor
    func testOpenTerminalForPaneRevealsExistingTileAndMovesCanonicalActivePane() {
        let store = WorkbenchStoreV2()
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )

        let first = store.openTerminal(for: firstPane, hostsConfig: .empty)
        let second = store.openTerminal(for: secondPane, hostsConfig: .empty)
        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )

        XCTAssertEqual(second, .revealedExisting(workbenchID: store.workbenches[0].id, tileID: first.tileID))
        guard let context = store.focusedTerminalTileContext else {
            return XCTFail("Expected focused terminal tile context")
        }
        XCTAssertEqual(context.tileID, first.tileID)
        XCTAssertEqual(context.sessionRef, SessionRef(target: .local, sessionName: "shared"))
        XCTAssertEqual(selection?.tileID, first.tileID)
        XCTAssertEqual(selection?.windowID, "@2")
        XCTAssertEqual(selection?.paneID, "%9")
        XCTAssertEqual(selection?.paneInventoryID, secondPane.id)
    }

    @MainActor
    func testSyncTerminalNavigationUpdatesActivePaneSelectionWithoutMutatingStoredSessionRef() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(sessionRef: SessionRef(target: .local, sessionName: "shared"))
        let didChange = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: secondPane.windowId,
            preferredPaneID: secondPane.paneId
        )
        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )

        XCTAssertTrue(didChange)
        XCTAssertEqual(selection?.tileID, result.tileID)
        XCTAssertEqual(selection?.windowID, "@2")
        XCTAssertEqual(selection?.paneID, "%9")
        XCTAssertEqual(selection?.paneInventoryID, secondPane.id)
        guard let context = store.focusedTerminalTileContext else {
            return XCTFail("Expected focused terminal tile context")
        }
        XCTAssertEqual(context.sessionRef, SessionRef(target: .local, sessionName: "shared"))
    }

    @MainActor
    func testStaleObservedPaneUpdatesCanonicalSelectionWithoutDiscardingPendingNavigationTarget() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let selectionAfterClick = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        XCTAssertEqual(selectionAfterClick?.paneID, secondPane.paneId)
        XCTAssertEqual(selectionAfterClick?.windowID, secondPane.windowId)

        let didAcceptStaleObservation = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        let selectionAfterStaleObservation = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        guard let contextAfterStaleObservation = store.activePaneContext else {
            return XCTFail("Expected active pane context after stale observation")
        }

        XCTAssertTrue(
            didAcceptStaleObservation,
            "observed live pane truth must still be recorded even when a newer same-session navigation target is pending"
        )
        XCTAssertEqual(
            selectionAfterStaleObservation?.paneID,
            firstPane.paneId,
            "canonical selection must fail closed to last observed live pane until retarget converges"
        )
        XCTAssertEqual(selectionAfterStaleObservation?.windowID, firstPane.windowId)
        XCTAssertEqual(selectionAfterStaleObservation?.paneInventoryID, firstPane.id)
        XCTAssertEqual(
            contextAfterStaleObservation.activePaneRef.paneID,
            secondPane.paneId,
            "pending navigation target must remain available to the renderer after recording stale observed truth"
        )
    }

    @MainActor
    func testPendingDesiredPaneDoesNotOverrideLastObservedPaneSelection() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        guard let context = store.activePaneContext else {
            return XCTFail("Expected active pane context while same-session retarget is pending")
        }

        XCTAssertEqual(
            selection?.paneID,
            firstPane.paneId,
            "canonical selection must stay on last observed tmux pane until retarget converges"
        )
        XCTAssertEqual(selection?.windowID, firstPane.windowId)
        XCTAssertEqual(selection?.paneInventoryID, firstPane.id)
        XCTAssertEqual(
            context.activePaneRef.paneID,
            secondPane.paneId,
            "navigation target must still point at the requested pane while convergence is pending"
        )
    }

    @MainActor
    func testDesiredPaneSurvivesTransientRegressionAfterSingleMatchingObservation() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%0",
            sessionName: "shared",
            windowId: "@0"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@0"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: secondPane.windowId,
            preferredPaneID: secondPane.paneId
        )

        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        guard let context = store.activePaneContext else {
            return XCTFail("Expected active pane context while convergence is still pending")
        }

        XCTAssertEqual(
            selection?.paneID,
            secondPane.paneId,
            "transient attach regressions may change the last observed tmux pane"
        )
        XCTAssertEqual(
            context.activePaneRef.paneID,
            firstPane.paneId,
            "one matching observation must not clear the desired pane before convergence is stable"
        )
    }

    @MainActor
    func testObservedPaneChangeWhileDesiredPanePendingPromotesObservedTruth() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let thirdPane = AgtmuxPane(
            source: "local",
            paneId: "%11",
            sessionName: "shared",
            windowId: "@3"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let didAcceptObservedTruth = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: thirdPane.windowId,
            preferredPaneID: thirdPane.paneId
        )
        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane, thirdPane],
            hostsConfig: .empty
        )
        guard let context = store.activePaneContext else {
            return XCTFail("Expected active pane context after observed pane change")
        }

        XCTAssertTrue(
            didAcceptObservedTruth,
            "observed live pane changes must update canonical selection even while a stale desired pane is pending"
        )
        XCTAssertEqual(selection?.paneID, thirdPane.paneId)
        XCTAssertEqual(selection?.windowID, thirdPane.windowId)
        XCTAssertEqual(selection?.paneInventoryID, thirdPane.id)
        XCTAssertEqual(
            context.activePaneRef.paneID,
            secondPane.paneId,
            "pending navigation intent should remain available for the renderer until convergence or explicit cancellation"
        )
    }

    @MainActor
    func testSameSessionRetargetAllowsLaterRenderedClientReverseSyncAfterFirstMatchingObservation() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: secondPane.windowId,
            preferredPaneID: secondPane.paneId
        )

        let selectionAfterConvergence = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        guard let contextAfterConvergence = store.activePaneContext else {
            return XCTFail("Expected active pane context after first matching observation")
        }

        XCTAssertEqual(selectionAfterConvergence?.paneID, secondPane.paneId)
        XCTAssertEqual(
            contextAfterConvergence.activePaneRef.paneID,
            secondPane.paneId,
            "after the rendered client first reaches the requested pane, the renderer target should already be the retargeted pane"
        )

        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )

        let selectionAfterReverseSync = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )
        guard let contextAfterReverseSync = store.activePaneContext else {
            return XCTFail("Expected active pane context after reverse sync")
        }

        XCTAssertEqual(selectionAfterReverseSync?.paneID, firstPane.paneId)
        XCTAssertEqual(selectionAfterReverseSync?.paneInventoryID, firstPane.id)
        XCTAssertEqual(
            contextAfterReverseSync.activePaneRef.paneID,
            firstPane.paneId,
            "terminal-originated reverse sync after the first matching retarget observation must cancel stale desired state"
        )
    }

    @MainActor
    func testTerminalOriginatedSessionSwitchRebindsVisibleTileIdentityAndActiveSelection() throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "alpha",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%7",
            sessionName: "beta",
            windowId: "@3"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = try store.syncTerminalObservation(
            tileID: result.tileID,
            observedSessionName: firstPane.sessionName,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )

        let didRebind = try store.syncTerminalObservation(
            tileID: result.tileID,
            observedSessionName: secondPane.sessionName,
            preferredWindowID: secondPane.windowId,
            preferredPaneID: secondPane.paneId
        )
        let selection = store.activePaneSelection(
            panes: [firstPane, secondPane],
            hostsConfig: .empty
        )

        guard let focusedContext = store.focusedTerminalTileContext else {
            return XCTFail("Expected focused terminal context after rendered-client session switch")
        }
        guard let activePaneContext = store.activePaneContext else {
            return XCTFail("Expected active pane context after rendered-client session switch")
        }

        XCTAssertTrue(didRebind, "Observed session switch on the rendered client must rebind the tile identity")
        XCTAssertEqual(focusedContext.tileID, result.tileID)
        XCTAssertEqual(
            focusedContext.sessionRef,
            SessionRef(target: .local, sessionName: secondPane.sessionName),
            "Rendered-client session switch must update the visible tile to the observed session"
        )
        XCTAssertEqual(selection?.sessionName, secondPane.sessionName)
        XCTAssertEqual(selection?.paneID, secondPane.paneId)
        XCTAssertEqual(selection?.paneInventoryID, secondPane.id)
        XCTAssertEqual(activePaneContext.activePaneRef.sessionName, secondPane.sessionName)
        XCTAssertEqual(activePaneContext.activePaneRef.paneID, secondPane.paneId)
    }

    @MainActor
    func testTerminalOriginatedSessionSwitchFailsLoudlyOnDuplicateVisibleDestinationSession() throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "alpha",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%7",
            sessionName: "beta",
            windowId: "@3"
        )
        let store = WorkbenchStoreV2()

        let firstResult = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.createWorkbench(title: "Second")
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)
        store.switchWorkbench(to: store.workbenches[0].id)

        XCTAssertThrowsError(
            try store.syncTerminalObservation(
                tileID: firstResult.tileID,
                observedSessionName: secondPane.sessionName,
                preferredWindowID: secondPane.windowId,
                preferredPaneID: secondPane.paneId
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkbenchStoreV2Error,
                .observedSessionCollision(
                    target: .local,
                    sessionName: secondPane.sessionName
                )
            )
        }

        XCTAssertEqual(
            store.focusedTerminalTileContext?.sessionRef,
            SessionRef(target: .local, sessionName: firstPane.sessionName),
            "Collision must keep the original tile identity intact"
        )
    }

    @MainActor
    func testSameSessionRetargetIncrementsFocusRestoreNonce() {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        _ = store.openTerminal(for: firstPane, hostsConfig: .empty)
        guard let firstContext = store.activePaneContext else {
            return XCTFail("expected first active pane context")
        }
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)
        guard let secondContext = store.activePaneContext else {
            return XCTFail("expected second active pane context")
        }

        XCTAssertEqual(firstContext.activePaneRef.paneID, firstPane.paneId)
        XCTAssertEqual(secondContext.activePaneRef.paneID, secondPane.paneId)
        XCTAssertEqual(firstContext.workbenchID, secondContext.workbenchID)
        XCTAssertGreaterThan(
            secondContext.focusRequestNonce,
            firstContext.focusRequestNonce,
            "same-session pane retarget must publish a new terminal focus-restore request even when tile focus is unchanged"
        )
    }

    @MainActor
    func testObservedPaneSyncDoesNotBumpFocusRestoreNonce() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: pane, hostsConfig: .empty)
        guard let initialContext = store.activePaneContext else {
            return XCTFail("expected initial active pane context")
        }
        _ = store.syncTerminalNavigation(
            tileID: result.tileID,
            preferredWindowID: pane.windowId,
            preferredPaneID: pane.paneId
        )
        guard let observedContext = store.activePaneContext else {
            return XCTFail("expected observed active pane context")
        }

        XCTAssertEqual(
            observedContext.focusRequestNonce,
            initialContext.focusRequestNonce,
            "terminal-originated observation must not fabricate a new focus-restore request"
        )
    }

    @MainActor
    func testActivePaneSelectionPersistsWhenFocusedTileIsNotTerminal() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@3"
        )
        let store = WorkbenchStoreV2()

        let result = store.openTerminal(for: pane, hostsConfig: .empty)
        let browserTileID = store.openBrowserPlaceholder(
            url: URL(string: "https://example.com/companion")!,
            placement: .right,
            pinned: true
        )
        let selection = store.activePaneSelection(
            panes: [pane],
            hostsConfig: .empty
        )

        XCTAssertEqual(store.activeWorkbench?.focusedTileID, browserTileID)
        XCTAssertEqual(selection?.tileID, result.tileID)
        XCTAssertEqual(selection?.paneInventoryID, pane.id)
    }

    @MainActor
    func testActivePaneSelectionFailsClosedOnPaneInstanceMismatch() {
        let staleInstance = AgtmuxSyncV2PaneInstanceID(
            paneId: "%9",
            generation: 1,
            birthTs: Date(timeIntervalSince1970: 1_778_822_200)
        )
        let currentInstance = AgtmuxSyncV2PaneInstanceID(
            paneId: "%9",
            generation: 2,
            birthTs: Date(timeIntervalSince1970: 1_778_822_260)
        )
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@3",
            paneInstanceID: currentInstance
        )
        let tile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: "shared"
                )
            )
        )
        let store = WorkbenchStoreV2(
            workbenches: [
                Workbench(
                    title: "Main",
                    root: .tile(tile),
                    focusedTileID: tile.id,
                    activePaneRef: ActivePaneRef(
                        target: .local,
                        sessionName: "shared",
                        windowID: "@3",
                        paneID: "%9",
                        paneInstanceID: staleInstance
                    )
                )
            ]
        )

        let selection = store.activePaneSelection(
            panes: [pane],
            hostsConfig: .empty
        )

        XCTAssertEqual(selection?.tileID, tile.id)
        XCTAssertNil(
            selection?.paneInventoryID,
            "paneInstanceID mismatch must not fall back to a reused pane location"
        )
    }

    @MainActor
    func testFixtureBootstrapLoadsSeededWorkbench() throws {
        let seeded = Workbench(
            title: "Seeded",
            root: .tile(
                WorkbenchTile(
                    kind: .browser(
                        url: URL(string: "https://example.com/workbench")!,
                        sourceContext: "/tmp/worktree"
                    ),
                    pinned: true
                )
            )
        )
        let fixtureJSON = String(
            data: try JSONEncoder().encode([seeded]),
            encoding: .utf8
        )

        let store = try WorkbenchStoreV2(
            env: [WorkbenchStoreV2.fixtureEnvironmentKey: fixtureJSON ?? ""],
            persistence: nil
        )

        XCTAssertEqual(store.workbenches, [seeded])
        XCTAssertEqual(store.activeWorkbench?.displayTitle, "Seeded")
    }

    @MainActor
    func testBrowserAndDocumentPlaceholderHelpersCreatePinnedCompanionTiles() {
        let browserStore = WorkbenchStoreV2()
        let browserURL = URL(string: "https://example.com/companion")!
        let browserTileID = browserStore.openBrowserPlaceholder(
            url: browserURL,
            sourceContext: "/tmp/worktree",
            pinned: true
        )

        guard case .tile(let browserTile)? = browserStore.activeWorkbench?.root else {
            return XCTFail("Expected a browser placeholder tile")
        }
        XCTAssertEqual(browserTile.id, browserTileID)
        XCTAssertTrue(browserTile.pinned)

        let documentStore = WorkbenchStoreV2()
        let documentRef = DocumentRef(target: .local, path: "/tmp/spec.md")
        let documentTileID = documentStore.openDocumentPlaceholder(
            ref: documentRef,
            pinned: true
        )

        guard case .tile(let documentTile)? = documentStore.activeWorkbench?.root else {
            return XCTFail("Expected a document placeholder tile")
        }
        XCTAssertEqual(documentTile.id, documentTileID)
        XCTAssertEqual(documentTile.kind, .document(ref: documentRef))
        XCTAssertTrue(documentTile.pinned)
    }

    @MainActor
    func testConfiguredRemoteHostnameMapsToConfiguredHostKeyInV2TerminalTile() {
        let hostsConfig = HostsConfig(hosts: [
            RemoteHost(
                id: "staging",
                displayName: "Staging",
                hostname: "staging.example.com",
                user: "alice",
                transport: .ssh
            )
        ])
        let pane = AgtmuxPane(
            source: "staging.example.com",
            paneId: "%42",
            sessionName: "backend",
            windowId: "@1"
        )
        let store = WorkbenchStoreV2()

        let sessionRef = SessionRef(
            target: .remote(hostKey: hostsConfig.remoteHostKey(for: pane.source)),
            sessionName: pane.sessionName,
            lastSeenRepoRoot: pane.currentPath
        )

        store.openTerminal(sessionRef: sessionRef)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let storedSessionRef) = tile.kind else {
            return XCTFail("Expected a terminal tile")
        }
        XCTAssertEqual(storedSessionRef.target, .remote(hostKey: "staging"))
        XCTAssertEqual(storedSessionRef.sessionName, "backend")
    }

    // MARK: - removeTile

    @MainActor
    func testRemoveTileCollapsesLeafSplit() {
        let tileA = WorkbenchTile(kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "a")))
        let tileB = WorkbenchTile(kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "b")))
        let workbench = Workbench(
            title: "Split",
            root: .split(WorkbenchSplit(axis: .horizontal, first: .tile(tileA), second: .tile(tileB))),
            focusedTileID: tileA.id
        )
        let store = WorkbenchStoreV2(workbenches: [workbench])

        store.removeTile(id: tileB.id)

        guard case .tile(let remaining)? = store.activeWorkbench?.root else {
            return XCTFail("Expected split to collapse to a single tile")
        }
        XCTAssertEqual(remaining.id, tileA.id)
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
    }

    @MainActor
    func testRemoveTileRepairsFocusToSiblingWhenFocusedTileIsRemoved() {
        let tileA = WorkbenchTile(kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "a")))
        let tileB = WorkbenchTile(kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "b")))
        let workbench = Workbench(
            title: "Split",
            root: .split(WorkbenchSplit(axis: .horizontal, first: .tile(tileA), second: .tile(tileB))),
            focusedTileID: tileA.id
        )
        let store = WorkbenchStoreV2(workbenches: [workbench])

        store.removeTile(id: tileA.id)

        XCTAssertEqual(store.activeWorkbench?.focusedTileID, tileB.id,
                       "Focus must be repaired to the sibling when the focused tile is removed")
        XCTAssertEqual(store.activeWorkbench?.tiles.count, 1)
    }

    @MainActor
    func testRemoveTileFromNestedSplitCollapsesCorrectly() {
        // Build: split(split(A, B), C)  →  remove A  →  split(B, C)
        let refA = SessionRef(target: .local, sessionName: "a")
        let refB = SessionRef(target: .local, sessionName: "b")
        let refC = SessionRef(target: .local, sessionName: "c")

        let tileA = WorkbenchTile(kind: .terminal(sessionRef: refA))
        let tileB = WorkbenchTile(kind: .terminal(sessionRef: refB))
        let tileC = WorkbenchTile(kind: .terminal(sessionRef: refC))
        let workbench = Workbench(
            title: "Nested",
            root: .split(WorkbenchSplit(
                axis: .horizontal,
                first: .split(WorkbenchSplit(
                    axis: .vertical,
                    first: .tile(tileA),
                    second: .tile(tileB)
                )),
                second: .tile(tileC)
            )),
            focusedTileID: tileC.id
        )
        let nestedStore = WorkbenchStoreV2(workbenches: [workbench])
        nestedStore.removeTile(id: tileA.id)

        guard case .split(let topSplit)? = nestedStore.activeWorkbench?.root else {
            return XCTFail("Expected outer split to remain after removing A")
        }
        let remainingIDs = Set(nestedStore.activeWorkbench?.tiles.map(\.id) ?? [])
        XCTAssertFalse(remainingIDs.contains(tileA.id), "tileA should be gone")
        XCTAssertTrue(remainingIDs.contains(tileB.id))
        XCTAssertTrue(remainingIDs.contains(tileC.id))
        XCTAssertEqual(nestedStore.activeWorkbench?.tiles.count, 2)
        _ = topSplit // consumed
    }

    @MainActor
    func testRemoveTileOnEmptyOrAbsentIDIsNoop() {
        let store = WorkbenchStoreV2()
        store.removeTile(id: UUID())
        XCTAssertTrue(store.activeWorkbench?.root.isEmpty == true)
    }

    // MARK: - rebindTerminal

    @MainActor
    func testRebindTerminalClearsHintFieldsWhenTargetChanges() {
        let store = WorkbenchStoreV2()
        let original = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenSessionID: "$1",
            lastSeenRepoRoot: "/tmp/repo"
        )
        let result = store.openTerminal(sessionRef: original)

        let updated = SessionRef(
            target: .remote(hostKey: "prod"),
            sessionName: "main",
            lastSeenSessionID: "$99",
            lastSeenRepoRoot: "/srv/app"
        )
        store.rebindTerminal(tileID: result.tileID, to: updated)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let stored) = tile.kind else {
            return XCTFail("Expected terminal tile after rebind")
        }
        XCTAssertEqual(tile.id, result.tileID, "Tile identity must be preserved")
        XCTAssertEqual(stored.target, .remote(hostKey: "prod"))
        XCTAssertEqual(stored.sessionName, "main")
        XCTAssertNil(stored.lastSeenSessionID, "Hint field must be cleared on target change")
        XCTAssertNil(stored.lastSeenRepoRoot, "Hint field must be cleared on target change")
    }

    @MainActor
    func testRebindTerminalClearsHintFieldsWhenSessionNameChanges() {
        let store = WorkbenchStoreV2()
        let original = SessionRef(
            target: .local,
            sessionName: "old",
            lastSeenSessionID: "$1",
            lastSeenRepoRoot: "/tmp/repo"
        )
        let result = store.openTerminal(sessionRef: original)

        let updated = SessionRef(target: .local, sessionName: "new", lastSeenSessionID: "$2")
        store.rebindTerminal(tileID: result.tileID, to: updated)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let stored) = tile.kind else {
            return XCTFail("Expected terminal tile")
        }
        XCTAssertEqual(stored.sessionName, "new")
        XCTAssertNil(stored.lastSeenSessionID, "Hint field must be cleared on sessionName change")
        XCTAssertNil(stored.lastSeenRepoRoot)
    }

    @MainActor
    func testRebindTerminalPreservesHintFieldsWhenTargetAndSessionNameUnchanged() {
        let store = WorkbenchStoreV2()
        let original = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenSessionID: "$1",
            lastSeenRepoRoot: "/tmp/repo"
        )
        let result = store.openTerminal(sessionRef: original)

        // Same target + sessionName, new hints passed in
        let updated = SessionRef(
            target: .local,
            sessionName: "main",
            lastSeenSessionID: "$2",
            lastSeenRepoRoot: "/tmp/repo2"
        )
        store.rebindTerminal(tileID: result.tileID, to: updated)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let stored) = tile.kind else {
            return XCTFail("Expected terminal tile")
        }
        XCTAssertEqual(stored.lastSeenSessionID, "$2", "Hints from new ref should be kept when target/session unchanged")
        XCTAssertEqual(stored.lastSeenRepoRoot, "/tmp/repo2")
    }

    // MARK: - rebindDocument

    @MainActor
    func testRebindDocumentPreservesPinning() {
        let store = WorkbenchStoreV2()
        let originalRef = DocumentRef(target: .local, path: "/tmp/old.md")
        let tileID = store.openDocumentPlaceholder(ref: originalRef, pinned: true)

        let newRef = DocumentRef(target: .remote(hostKey: "staging"), path: "/srv/app/README.md")
        store.rebindDocument(tileID: tileID, to: newRef)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .document(let stored) = tile.kind else {
            return XCTFail("Expected document tile after rebind")
        }
        XCTAssertEqual(tile.id, tileID, "Tile identity must be preserved")
        XCTAssertEqual(stored, newRef)
        XCTAssertTrue(tile.pinned, "Pinning must be preserved by rebindDocument")
    }

    @MainActor
    func testRebindDocumentOnAbsentIDIsNoop() {
        let store = WorkbenchStoreV2()
        let ref = DocumentRef(target: .local, path: "/tmp/spec.md")
        store.openDocumentPlaceholder(ref: ref)
        let before = store.activeWorkbench?.root
        store.rebindDocument(tileID: UUID(), to: DocumentRef(target: .local, path: "/tmp/other.md"))
        XCTAssertEqual(store.activeWorkbench?.root, before)
    }

    @MainActor
    func testUnconfiguredRemoteHostnameRemainsExplicitInV2TerminalTile() {
        let hostsConfig = HostsConfig.empty
        let pane = AgtmuxPane(
            source: "orphan.example.com",
            paneId: "%9",
            sessionName: "ops",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        let sessionRef = SessionRef(
            target: .remote(hostKey: hostsConfig.remoteHostKey(for: pane.source)),
            sessionName: pane.sessionName,
            lastSeenRepoRoot: pane.currentPath
        )

        store.openTerminal(sessionRef: sessionRef)

        guard case .tile(let tile)? = store.activeWorkbench?.root,
              case .terminal(let storedSessionRef) = tile.kind else {
            return XCTFail("Expected a terminal tile")
        }
        XCTAssertEqual(storedSessionRef.target, .remote(hostKey: "orphan.example.com"))
        XCTAssertEqual(storedSessionRef.sessionName, "ops")
    }

    @MainActor
    func testUnconfiguredRemoteHostnameRemainsExplicitInActivePaneSelection() {
        let pane = AgtmuxPane(
            source: "orphan.example.com",
            paneId: "%9",
            sessionName: "ops",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()

        _ = store.openTerminal(for: pane, hostsConfig: .empty)
        let selection = store.activePaneSelection(
            panes: [pane],
            hostsConfig: .empty
        )

        XCTAssertEqual(selection?.source, "orphan.example.com")
        XCTAssertEqual(selection?.paneInventoryID, pane.id)
    }
}
