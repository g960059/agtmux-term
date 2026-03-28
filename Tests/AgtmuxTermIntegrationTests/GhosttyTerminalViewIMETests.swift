import XCTest
import AppKit
import GhosttyKit
@testable import AgtmuxTerm
import AgtmuxTermCore

@MainActor
final class GhosttyTerminalViewIMETests: XCTestCase {
    func testMarkedTextEnterCommitPrefersIMEOverRawReturn() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true
        view.interpretation = {
            view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: makeKeyDownEvent(characters: "\r", keyCode: 0x24))

        XCTAssertTrue(view.sentTexts.isEmpty)
        XCTAssertEqual(view.sentPreedits.first ?? nil, "にほんご")
        XCTAssertEqual(view.sentPreedits.last ?? "not-nil", nil)
        XCTAssertEqual(view.sentRawKeys.map(\.characters), ["日本語"])
    }

    func testInsertTextClearsPreeditWhenMarkedTextEnds() {
        let view = GhosttyTerminalViewSpy()

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.sentPreedits, ["にほんご", nil])
        XCTAssertEqual(view.sentTexts, ["日本語"])
    }

    func testControlModifiedLetterUsesPrintableGhosttyText() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        view.keyDown(with: makeKeyDownEvent(characters: "\u{1}", keyCode: 0x00, modifierFlags: [.control]))

        XCTAssertEqual(view.sentRawKeys.count, 1)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "a")
        XCTAssertEqual(view.sentRawKeys.first?.composing, false)
    }

    func testFlagsChangedEventConvertsWithoutRepeatQueryCrash() {
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x3B
        )!

        let key = GhosttyInput.toGhosttyKey(event)

        XCTAssertEqual(key.action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.keycode, 0x3B)
        XCTAssertEqual(key.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, GHOSTTY_MODS_CTRL.rawValue)
    }

    func testSurfaceAttachmentContextRequiresDisplayID() {
        XCTAssertNil(
            GhosttyTerminalView.resolveSurfaceAttachmentContext(
                backingScaleFactor: 2.0,
                screenBackingScaleFactor: 2.0,
                displayID: nil
            )
        )
    }

    func testSurfaceAttachmentContextUsesResolvedScaleAndDisplayID() {
        let context = GhosttyTerminalView.resolveSurfaceAttachmentContext(
            backingScaleFactor: 0,
            screenBackingScaleFactor: 1.5,
            displayID: 42
        )

        XCTAssertEqual(context?.scaleFactor, 1.5)
        XCTAssertEqual(context?.displayID, 42)
    }

    func testKeyDownTextAccumulatorReplaysAsRawKeyEventInsteadOfPaste() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        view.keyDown(with: makeKeyDownEvent(characters: "o", keyCode: 0x1F))

        XCTAssertTrue(view.sentTexts.isEmpty)
        XCTAssertEqual(view.sentRawKeys.count, 1)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "o")
        XCTAssertEqual(view.scheduledInteractivePresentationCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
    }

    func testInsertTextSchedulesInteractivePresentationDraw() {
        let view = GhosttyTerminalViewSpy()

        view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.sentTexts, ["hello"])
        XCTAssertEqual(view.scheduledInteractivePresentationCount, 1)
    }

    func testKeyDownDoesNotScheduleHostInteractivePresentationRecovery() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        view.keyDown(with: makeKeyDownEvent(characters: "a", keyCode: 0x00))

        XCTAssertEqual(view.scheduledInteractivePresentationCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
    }

    func testFailedRawKeyDoesNotScheduleHostRefresh() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = false

        view.keyDown(with: makeKeyDownEvent(characters: "a", keyCode: 0x00))

        XCTAssertEqual(view.scheduledInteractivePresentationCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
    }

    func testModifierKeyChangesDoNotScheduleHostInteractivePresentationRecovery() {
        let view = GhosttyTerminalViewSpy()

        let flagsDown = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x3B
        )!

        view.flagsChanged(with: flagsDown)

        XCTAssertEqual(view.scheduledInteractivePresentationCount, 0)
    }

    func testInsertTextSchedulesGhosttyRuntimeTick() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperScheduleInteractivePresentationAfterInput = true
        var scheduledTickCount = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTickCount += 1
        }) {
            view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        XCTAssertGreaterThanOrEqual(scheduledTickCount, 1)
    }

    func testScrollRuntimeTickCanUseCoalescedSchedulerPath() {
        let view = GhosttyTerminalView()
        var scheduledTickCount = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTickCount += 1
        }) {
            view.scheduleGhosttyRuntimeTickAfterSurfaceInput(coalesced: true)
        }

        XCTAssertEqual(scheduledTickCount, 1)
    }

    func testInsertTextAfterFirstLayerSkipsGhosttyRuntimeTick() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperScheduleInteractivePresentationAfterInput = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)
        var scheduledTickCount = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTickCount += 1
        }) {
            view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        XCTAssertEqual(scheduledTickCount, 0)
    }

    func testInsertTextArmsInteractivePresentationRecoveryProbeForRealInput() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperScheduleInteractivePresentationAfterInput = true

        view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        let continuationState = view.interactivePresentationContinuationStateForTesting()
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
        XCTAssertFalse(continuationState.pumpScheduled)
        XCTAssertNil(continuationState.pumpDueUptime)
        XCTAssertTrue(continuationState.recoveryScheduled)
        XCTAssertNotNil(continuationState.recoveryDueUptime)
    }

    func testInsertTextUsesRendererOwnedPresentationPathAfterFirstLayerPresent() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperScheduleInteractivePresentationAfterInput = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)

        view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        let continuationState = view.interactivePresentationContinuationStateForTesting()
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertTrue(continuationState.recoveryScheduled)
        XCTAssertNotNil(continuationState.recoveryDueUptime)
    }

    func testResetScrollTelemetryPreservesInitialLayerCompletionForInteractiveInput() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperScheduleInteractivePresentationAfterInput = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)
        view.resetScrollTelemetryForTesting()

        view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        let continuationState = view.interactivePresentationContinuationStateForTesting()
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertTrue(continuationState.recoveryScheduled)
    }

    func testRenderCallbackPresentationRequestsRendererRefreshBeforeFirstLayerPresent() {
        let view = GhosttyTerminalViewSpy()
        view.useSuperRenderCallbackPresentation = true

        view.performRenderCallbackPresentationDraw()

        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
    }

    func testRenderCallbackPresentationStaysRendererOwnedAfterFirstLayerPresent() {
        let view = GhosttyTerminalViewSpy()
        view.useSuperRenderCallbackPresentation = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)

        view.performRenderCallbackPresentationDraw()

        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
    }

    func testRendererFrameCompletedTelemetryCountsPresentationWhenTelemetryCollectionEnabled() {
        let view = GhosttyTerminalView()
        view.resetScrollTelemetryForTesting()

        view.noteRendererFrameCompletedTelemetry()

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().layerPresentCount, 1)
        XCTAssertFalse(view.prefersRenderLayerContentsObservationForTesting())
        XCTAssertTrue(view.prefersRendererFrameCompletedObservationForTesting())
    }

    func testInteractivePresentationRecoveryProbeRedrawsDelayedInput() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let drawUptime = 10.0
        let recoveryDue = drawUptime + 0.01

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: recoveryDue,
            pumpDue: nil,
            recoveryDue: recoveryDue,
            recoveryDrawUptime: drawUptime,
            lastInputUptime: drawUptime,
            lastDrawUptime: drawUptime
        )

        view.runScheduledInteractivePresentationContinuationWakeForTesting(now: recoveryDue)

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
        XCTAssertTrue(view.interactivePresentationContinuationStateForTesting().recoveryScheduled)
    }

    func testInteractivePresentationRecoveryProbeStopsAfterLayerPresentation() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let drawUptime = 10.0
        let recoveryDue = drawUptime + 0.01

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: recoveryDue,
            pumpDue: nil,
            recoveryDue: recoveryDue,
            recoveryDrawUptime: drawUptime,
            lastInputUptime: drawUptime,
            lastDrawUptime: drawUptime
        )
        view.noteLayerPresentationForTesting(now: drawUptime + 0.001)

        view.runScheduledInteractivePresentationContinuationWakeForTesting(now: recoveryDue)

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertFalse(view.interactivePresentationContinuationStateForTesting().recoveryScheduled)
    }

    func testInteractivePresentationDrawPumpKeepsBurstAlive() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let startUptime = 20.0
        let pumpDue = startUptime + 0.01

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: pumpDue,
            pumpDue: pumpDue,
            recoveryDue: nil,
            recoveryDrawUptime: nil,
            lastInputUptime: startUptime,
            lastDrawUptime: startUptime
        )

        view.runScheduledInteractivePresentationContinuationWakeForTesting(now: pumpDue)

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
        XCTAssertTrue(view.interactivePresentationContinuationStateForTesting().recoveryScheduled)
    }

    func testInteractivePresentationDrawPumpAvoidsGhosttyRuntimeTick() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let startUptime = 20.0
        let pumpDue = startUptime + 0.01
        var scheduledTickCount = 0

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: pumpDue,
            pumpDue: pumpDue,
            recoveryDue: nil,
            recoveryDrawUptime: nil,
            lastInputUptime: startUptime,
            lastDrawUptime: startUptime
        )

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTickCount += 1
        }) {
            view.runScheduledInteractivePresentationContinuationWakeForTesting(now: pumpDue)
        }

        XCTAssertEqual(scheduledTickCount, 0)
    }

    func testInteractivePresentationDrawPumpSurvivesSlowTmuxEchoWindow() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let startUptime = 30.0
        let pumpDue = startUptime + 0.50

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: pumpDue,
            pumpDue: pumpDue,
            recoveryDue: nil,
            recoveryDrawUptime: nil,
            lastInputUptime: startUptime,
            lastDrawUptime: startUptime
        )

        view.runScheduledInteractivePresentationContinuationWakeForTesting(now: pumpDue)

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
        XCTAssertTrue(view.interactivePresentationContinuationStateForTesting().recoveryScheduled)
    }

    func testInteractivePresentationDrawPumpStopsAfterSlowEchoTailExpires() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        let startUptime = 40.0
        let pumpDue = startUptime + 0.80

        view.configureInteractivePresentationContinuationForTesting(
            continuationDue: pumpDue,
            pumpDue: pumpDue,
            recoveryDue: nil,
            recoveryDrawUptime: nil,
            lastInputUptime: startUptime,
            lastDrawUptime: startUptime
        )

        view.runScheduledInteractivePresentationContinuationWakeForTesting(now: pumpDue)

        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertFalse(view.interactivePresentationContinuationStateForTesting().recoveryScheduled)
    }

    func testKeyDownUsesRendererOwnedPresentationPathAfterFirstLayerPresent() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true
        view.canScheduleImmediatePresentation = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)

        view.keyDown(with: makeKeyDownEvent(characters: "a", keyCode: 0x00))

        let continuationState = view.interactivePresentationContinuationStateForTesting()
        XCTAssertEqual(view.scheduledInteractivePresentationCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertTrue(continuationState.recoveryScheduled)
        XCTAssertNotNil(continuationState.recoveryDueUptime)
    }

    func testRendererOwnedRenderCallbackCoalescesPresentationDrawForVisibleSurface() {
        let view = GhosttyTerminalViewSpy()
        view.setRendererPresentationSurfacePresenceForTesting(true)
        view.useSuperRenderCallbackPresentation = true

        view.triggerRendererOwnedRenderCallback(now: ProcessInfo.processInfo.systemUptime)
        view.triggerRendererOwnedRenderCallback(now: ProcessInfo.processInfo.systemUptime + 0.001)

        XCTAssertEqual(view.hostDrawTelemetryCount, 2)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 2)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 2)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertFalse(view.rendererPresentationDrawPendingForTesting())
    }

    func testRendererOwnedRenderCallbackUsesImmediateDrawDuringDirtyDrawFastPath() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.forceImmediateDirtyDrawForRenderCallback = true

        view.triggerRendererOwnedRenderCallback(now: ProcessInfo.processInfo.systemUptime)

        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
    }

    func testRendererOwnedRenderCallbackUsesImmediateDrawDuringActiveDirectScrollGesture() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.useSuperPrefersImmediateDirtyDrawForRenderCallback = true
        let now = ProcessInfo.processInfo.systemUptime
        view.noteLayerPresentationForTesting(now: now)
        view.setLastScrollUsedAlternateScrollForTesting(false)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .began,
            momentumPhase: [],
            verticalDelta: 10,
            now: now
        )

        view.triggerRendererOwnedRenderCallback(now: now + 0.001)

        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 0)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
    }

    func testRendererOwnedRenderCallbackStaysRendererOwnedDuringActiveDirectAlternateScrollGesture() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.setRendererPresentationSurfacePresenceForTesting(true)
        view.useSuperRenderCallbackPresentation = true
        view.useSuperPrefersImmediateDirtyDrawForRenderCallback = true
        let now = ProcessInfo.processInfo.systemUptime
        view.noteLayerPresentationForTesting(now: now)
        view.setLastScrollUsedAlternateScrollForTesting(true)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .began,
            momentumPhase: [],
            verticalDelta: 10,
            now: now
        )

        view.triggerRendererOwnedRenderCallback(now: now + 0.001)

        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 1)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
    }

    func testRendererOwnedRenderCallbackStaysRendererOwnedAfterFirstLayerPresent() {
        let view = GhosttyTerminalViewSpy()
        view.setRendererPresentationSurfacePresenceForTesting(true)
        view.useSuperRenderCallbackPresentation = true
        view.noteLayerPresentationForTesting(now: ProcessInfo.processInfo.systemUptime)

        view.triggerRendererOwnedRenderCallback(now: ProcessInfo.processInfo.systemUptime)

        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 1)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
        XCTAssertFalse(view.rendererPresentationDrawPendingForTesting())
    }

    func testRenderActionRunsImmediateDirectDrawPassOutsideTick() {
        let view = GhosttyTerminalViewSpy()
        view.useSuperRenderCallbackPresentation = true
        let leafID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0xB001)

        SurfacePool.shared.resetForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        }

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%1",
            surfaceHandle: surfaceHandle
        )
        _ = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        SurfacePool.shared.resetTelemetryForTesting()
        view.scheduledRefreshDrawCount = 0
        view.renderCallbackPresentationDrawCount = 0
        view.hostDrawTelemetryCount = 0
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()

        var scheduledDirectDrawPassCount = 0
        GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDrawPassCount += 1
        }) {
            GhosttyApp.withTestTickExecutionState(false) {
                XCTAssertTrue(
                    GhosttyApp.dispatchRenderActionForTesting(surfaceHandle: surfaceHandle)
                )
            }
        }

        let appTelemetry = GhosttyApp.surfaceDrawTelemetrySnapshotForTesting()
        let poolTelemetry = SurfacePool.shared.telemetrySnapshotForTesting()
        XCTAssertEqual(scheduledDirectDrawPassCount, 0)
        XCTAssertEqual(appTelemetry.immediateDirectDrawPassCount, 1)
        XCTAssertEqual(appTelemetry.scheduledDirectDrawPassCount, 0)
        XCTAssertEqual(poolTelemetry.markDirtyForDirectDrawCount, 1)
        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 1)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
    }

    func testRenderActionDefersDirectDrawUntilPostTickDirtyPass() {
        let view = GhosttyTerminalViewSpy()
        view.useSuperRenderCallbackPresentation = true
        let leafID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0xB002)

        SurfacePool.shared.resetForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        }

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%2",
            surfaceHandle: surfaceHandle
        )
        _ = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        SurfacePool.shared.resetTelemetryForTesting()
        view.scheduledRefreshDrawCount = 0
        view.renderCallbackPresentationDrawCount = 0
        view.hostDrawTelemetryCount = 0
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()

        var scheduledDirectDrawPassCount = 0
        GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDrawPassCount += 1
        }) {
            GhosttyApp.withTestTickExecutionState(true) {
                XCTAssertTrue(
                    GhosttyApp.dispatchRenderActionForTesting(surfaceHandle: surfaceHandle)
                )
            }
        }

        XCTAssertEqual(scheduledDirectDrawPassCount, 0)
        XCTAssertEqual(view.hostDrawTelemetryCount, 0)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 0)

        GhosttyApp.runDirtyDrawPassForTesting()

        let appTelemetry = GhosttyApp.surfaceDrawTelemetrySnapshotForTesting()
        let poolTelemetry = SurfacePool.shared.telemetrySnapshotForTesting()
        XCTAssertEqual(appTelemetry.immediateDirectDrawPassCount, 0)
        XCTAssertEqual(appTelemetry.scheduledDirectDrawPassCount, 0)
        XCTAssertEqual(poolTelemetry.markDirtyForDirectDrawCount, 1)
        XCTAssertEqual(view.hostDrawTelemetryCount, 1)
        XCTAssertEqual(view.renderCallbackPresentationDrawCount, 1)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 1)
    }

    func testRenderActionUsesResolvedActiveViewForDirtyDraw() {
        let activeView = GhosttyTerminalViewSpy()
        activeView.useSuperRenderCallbackPresentation = true
        let staleHandleView = GhosttyTerminalViewSpy()
        staleHandleView.useSuperRenderCallbackPresentation = true
        let callbackHandle = GhosttySurfaceHandle(rawValue: 0xB003)
        let activeHandle = GhosttySurfaceHandle(rawValue: 0xB004)
        let activeSurfaceID = UUID()
        let staleSurfaceID = UUID()
        let context = GhosttyTerminalSurfaceContext(
            viewportID: UUID(),
            surfaceID: activeSurfaceID,
            surfaceKey: "main-terminal:local:vm-agtmux-term",
            sessionRef: SessionRef(target: .local, sessionName: "vm agtmux-term")
        )

        SurfacePool.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        }

        SurfacePool.shared.register(
            view: activeView,
            leafID: activeSurfaceID,
            tmuxPaneID: "%1",
            surfaceHandle: activeHandle
        )
        SurfacePool.shared.register(
            view: staleHandleView,
            leafID: staleSurfaceID,
            tmuxPaneID: "%2",
            surfaceHandle: callbackHandle
        )
        SurfacePool.shared.background(leafID: staleSurfaceID)
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(
            activeSurfaceID,
            forSurfaceID: activeSurfaceID
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: callbackHandle,
            context: context,
            attachCommand: "tmux attach-session -t 'vm agtmux-term'"
        )

        _ = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        SurfacePool.shared.resetTelemetryForTesting()
        activeView.scheduledRefreshDrawCount = 0
        activeView.renderCallbackPresentationDrawCount = 0
        activeView.hostDrawTelemetryCount = 0
        staleHandleView.scheduledRefreshDrawCount = 0
        staleHandleView.renderCallbackPresentationDrawCount = 0
        staleHandleView.hostDrawTelemetryCount = 0
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()

        GhosttyApp.withTestTickExecutionState(false) {
            XCTAssertTrue(
                GhosttyApp.dispatchRenderActionForTesting(surfaceHandle: callbackHandle)
            )
        }

        let poolTelemetry = SurfacePool.shared.telemetrySnapshotForTesting()
        XCTAssertEqual(poolTelemetry.markDirtyForDirectDrawCount, 1)
        XCTAssertEqual(activeView.hostDrawTelemetryCount, 1)
        XCTAssertEqual(activeView.renderCallbackPresentationDrawCount, 1)
        XCTAssertEqual(activeView.scheduledRefreshDrawCount, 1)
        XCTAssertEqual(staleHandleView.hostDrawTelemetryCount, 0)
        XCTAssertEqual(staleHandleView.renderCallbackPresentationDrawCount, 0)
        XCTAssertEqual(staleHandleView.scheduledRefreshDrawCount, 0)
    }

    func testRenderActionRecordsRenderRequestTelemetryWhenObserved() {
        let view = GhosttyTerminalViewSpy()
        view.useSuperRenderCallbackPresentation = true
        let leafID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0xB005)
        let scrollInputUptime = ProcessInfo.processInfo.systemUptime

        SurfacePool.shared.resetForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            GhosttyApp.resetSurfaceDrawTelemetryForTesting()
            GhosttyApp.setRendererFrameRequestedObservationEnabled(false, for: surfaceHandle)
        }

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%5",
            surfaceHandle: surfaceHandle
        )
        _ = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        SurfacePool.shared.resetTelemetryForTesting()
        view.scheduledRefreshDrawCount = 0
        view.renderCallbackPresentationDrawCount = 0
        view.hostDrawTelemetryCount = 0
        view.resetScrollTelemetryForTesting()
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        GhosttyApp.setRendererFrameRequestedObservationEnabled(true, for: surfaceHandle)
        view.noteScrollInputTelemetryForTesting(
            now: scrollInputUptime,
            precision: true,
            phase: .began,
            verticalDelta: -24
        )

        GhosttyApp.withTestTickExecutionState(false) {
            XCTAssertTrue(
                GhosttyApp.dispatchRenderActionForTesting(surfaceHandle: surfaceHandle)
            )
        }

        let appTelemetry = GhosttyApp.surfaceDrawTelemetrySnapshotForTesting()
        let viewTelemetry = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(appTelemetry.renderCallbackCount, 1)
        XCTAssertEqual(viewTelemetry.renderRequestCount, 1)
    }

    func testScrollPresentationStatesEnableLayerObservation() {
        let view = GhosttyTerminalView()

        view.configureScrollPresentationObservationStateForTesting(
            drawPending: true,
            continuationScheduled: true,
            pumpScheduled: true,
            recoveryScheduled: true
        )

        XCTAssertTrue(view.prefersRenderLayerContentsObservationForTesting())
    }

    func testScrollPresentationDrawPumpAvoidsGhosttyRuntimeTick() {
        let view = GhosttyTerminalViewSpy()
        view.scrollPresentationSurfacePresent = true
        let startUptime = 60.0
        let pumpDue = startUptime + 0.01
        var scheduledTickCount = 0

        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: [],
            momentumPhase: [],
            verticalDelta: -20,
            now: startUptime
        )
        view.configureScrollPresentationContinuationForTesting(
            pumpDue: pumpDue,
            recoveryDue: nil,
            recoveryDrawUptime: nil
        )

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTickCount += 1
        }) {
            view.runScheduledScrollPresentationContinuationWakeForTesting(now: pumpDue)
        }

        XCTAssertEqual(scheduledTickCount, 0)
    }

    func testScrollInputPrefersRendererOwnedPresentationPath() {
        let view = GhosttyTerminalView()

        XCTAssertFalse(
            view.shouldUseHostScrollPresentation(
                usesAlternateScroll: false,
                precision: false
            )
        )
        XCTAssertFalse(
            view.shouldUseHostScrollPresentation(
                usesAlternateScroll: false,
                precision: true
            )
        )
        XCTAssertFalse(
            view.shouldUseHostScrollPresentation(
                usesAlternateScroll: true,
                precision: true
            )
        )
    }

    func testScrollInputAfterFirstLayerArmsRendererOwnedRecoveryProbe() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.noteLayerPresentationForTesting(now: 80.0)

        view.armRendererOwnedScrollPresentationRecoveryForTesting(now: 100.0)

        let continuationState = view.scrollPresentationContinuationStateForTesting()
        XCTAssertNil(continuationState.pumpDueUptime)
        XCTAssertEqual(continuationState.recoveryDrawUptime, 100.0)
        XCTAssertEqual(continuationState.lastDrawUptime, 100.0)
        XCTAssertNotNil(continuationState.recoveryDueUptime)
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 0)
    }

    func testScrollRecoveryProbeReschedulesToLatestRendererOwnedInput() {
        let view = GhosttyTerminalViewSpy()
        view.canScheduleImmediatePresentation = true
        view.noteLayerPresentationForTesting(now: 80.0)

        view.armRendererOwnedScrollPresentationRecoveryForTesting(now: 100.0)
        let firstContinuationState = view.scrollPresentationContinuationStateForTesting()
        XCTAssertNotNil(firstContinuationState.recoveryDueUptime)

        view.armRendererOwnedScrollPresentationRecoveryForTesting(now: 100.01)

        let secondContinuationState = view.scrollPresentationContinuationStateForTesting()
        XCTAssertEqual(secondContinuationState.recoveryDrawUptime, 100.01)
        XCTAssertEqual(secondContinuationState.lastDrawUptime, 100.01)
        XCTAssertNotNil(secondContinuationState.recoveryDueUptime)
        XCTAssertGreaterThan(
            secondContinuationState.recoveryDueUptime ?? 0,
            firstContinuationState.recoveryDueUptime ?? 0
        )
    }

    func testScrollPresentationRecoveryProbeFallsBackToImmediateDraw() {
        let view = GhosttyTerminalViewSpy()
        view.scrollPresentationSurfacePresent = true
        let startUptime = 70.0
        let recoveryDue = startUptime + 0.01

        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: [],
            momentumPhase: [],
            verticalDelta: -20,
            now: startUptime
        )
        view.noteScrollPresentationDrawForTesting(now: startUptime)
        view.configureScrollPresentationContinuationForTesting(
            pumpDue: nil,
            recoveryDue: recoveryDue,
            recoveryDrawUptime: startUptime
        )

        XCTAssertTrue(
            view.runScrollPresentationRecoveryProbePassForTesting(
                drawUptime: startUptime,
                now: recoveryDue
            )
        )
        XCTAssertEqual(view.scheduledRefreshDrawCount, 0)
        XCTAssertEqual(view.scrollTelemetrySnapshotForTesting().immediatePresentationDrawCount, 1)
    }

    func testTmuxNextPanePerfSeamSendsPrefixThenNextPaneKey() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        let sent = view.sendTmuxNextPaneKeysForTesting(windowNumber: 0)

        XCTAssertTrue(sent)
        XCTAssertEqual(view.sentRawKeys.count, 2)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "a")
        XCTAssertEqual(view.sentRawKeys.last?.characters, "o")
        XCTAssertTrue(view.sentTexts.isEmpty)
    }

    func testMouseDownClaimsFirstResponderBeforeSurfaceInput() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let view = GhosttyTerminalViewSpy(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        root.addSubview(view)
        window.contentView = root

        let event = makeMouseDownEvent(windowNumber: window.windowNumber)
        view.mouseDown(with: event)

        XCTAssertTrue(window.firstResponder === view)
    }

    private func makeKeyDownEvent(
        characters: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeMouseDownEvent(windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }
}

@MainActor
private final class GhosttyTerminalViewSpy: GhosttyTerminalView {
    var sentPreedits: [String?] = []
    var sentTexts: [String] = []
    var sentRawKeys: [(characters: String?, composing: Bool)] = []
    var scheduledInteractivePresentationCount = 0
    var scheduledRefreshDrawCount = 0
    var renderCallbackPresentationDrawCount = 0
    var hostDrawTelemetryCount = 0
    var canScheduleImmediatePresentation = false
    var forceImmediateDirtyDrawForRenderCallback = false
    var useSuperPrefersImmediateDirtyDrawForRenderCallback = false
    var useSuperRenderCallbackPresentation = false
    var useSuperScheduleInteractivePresentationAfterInput = false
    var sendKeyResult = false
    var interpretation: (() -> Void)?
    var scrollPresentationSurfacePresent = false
    private var currentMarkedText = ""

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if let interpretation {
            interpretation()
            return
        }

        for event in eventArray {
            if event.modifierFlags.contains(.control) {
                continue
            }

            guard let characters = event.characters, characters.isEmpty == false else {
                continue
            }

            insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func sendKeyToSurface(
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String?,
        composing: Bool
    ) -> Bool {
        sentRawKeys.append((characters: text ?? event.characters, composing: composing))
        return sendKeyResult
    }

    override func sendTextToSurface(_ text: String) {
        sentTexts.append(text)
    }

    override func scheduleInteractivePresentationAfterInput() {
        scheduledInteractivePresentationCount += 1
        if useSuperScheduleInteractivePresentationAfterInput {
            super.scheduleInteractivePresentationAfterInput()
        }
    }

    override func canScheduleImmediatePresentationDraw() -> Bool {
        canScheduleImmediatePresentation
    }

    override func hasSurfaceForScrollPresentationDraw() -> Bool {
        scrollPresentationSurfacePresent
    }

    override func noteHostDrawTelemetry() {
        hostDrawTelemetryCount += 1
    }

    override func triggerDraw() {
        scheduledRefreshDrawCount += 1
    }

    override func performRenderCallbackPresentationDraw() {
        renderCallbackPresentationDrawCount += 1
        if useSuperRenderCallbackPresentation {
            super.performRenderCallbackPresentationDraw()
        }
    }

    override func prefersImmediateDirtyDrawForRenderCallback(now: TimeInterval) -> Bool {
        if useSuperPrefersImmediateDirtyDrawForRenderCallback {
            return super.prefersImmediateDirtyDrawForRenderCallback(now: now)
        }
        return forceImmediateDirtyDrawForRenderCallback
    }

    override func syncPreeditToSurface(clearIfNeeded: Bool = true) {
        if currentMarkedText.isEmpty == false {
            sentPreedits.append(currentMarkedText)
        } else if clearIfNeeded {
            sentPreedits.append(nil)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            currentMarkedText = attributed.string
        case let plain as String:
            currentMarkedText = plain
        default:
            currentMarkedText = ""
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        currentMarkedText = ""
        super.unmarkText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        currentMarkedText = ""
        super.insertText(string, replacementRange: replacementRange)
    }
}
