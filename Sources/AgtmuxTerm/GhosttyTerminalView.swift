import AppKit
import GhosttyKit
import os

/// An NSView that hosts a Ghostty terminal surface rendered via Metal.
///
/// Responsibilities:
/// - Owns a ghostty_surface_t and frees it on deinit.
/// - Acts as a plain NSView; Ghostty uses layer-hosting (sets view.layer = IOSurfaceLayer
///   before wantsLayer = true). Do NOT override wantsLayer or makeBackingLayer.
/// - Routes keyboard, mouse, and scroll input to libghostty.
/// - Implements NSTextInputClient for IME (Japanese, Chinese, etc.).
class GhosttyTerminalView: NSView, NSTextInputClient {
    private static let scrollPresentationDrawPumpIntervalSeconds = 1.0 / 120.0
    private static let scrollPresentationDrawPumpTailSeconds = 0.18
    private static let scrollPresentationDrawRecoveryProbeDelaySeconds = 1.0 / 180.0
    private static let preciseAlternateScrollDirtyDrawFastPathTailSeconds = 0.18
    private static let rendererOwnedRenderCallbackTailSeconds = 0.18
    private static let scrollDirectionFlipEpsilon = 0.001
    struct SurfaceMetrics: Equatable {
        let pixelWidth: UInt32
        let pixelHeight: UInt32
        let xScale: Double
        let yScale: Double
        let displayID: UInt32
    }

    struct ScrollTelemetryMetricSummary: Codable, Equatable {
        let count: Int
        let p50Ms: Double?
        let p95Ms: Double?
        let maxMs: Double?
    }

    struct ScrollTelemetryValueSummary: Codable, Equatable {
        let count: Int
        let p50: Double?
        let p95: Double?
        let max: Double?
    }

    struct AlternateScrollTelemetrySnapshot: Codable, Equatable {
        let preciseEventCount: Int
        let preciseStepCount: Int
        let preciseFirstEventElapsedMs: Int
        let preciseMessageQueueCount: Int
        let preciseFirstMessageQueueElapsedMs: Int
        let preciseMailboxNotifyCount: Int
        let preciseFirstMailboxNotifyElapsedMs: Int
        let preciseWriteQueueCount: Int
        let preciseWriteQueueBytes: Int
        let preciseFirstWriteQueueElapsedMs: Int
        let preciseWriteCompletedCount: Int
        let preciseWriteCompletedBytes: Int
        let preciseFirstWriteCompletedElapsedMs: Int
        let preciseDrainTurnCount: Int
        let preciseDrainedMessageCount: Int
        let preciseDrainRequeueCount: Int
        let preciseFirstDrainTurnElapsedMs: Int
        let preciseReadChunkCount: Int
        let preciseReadChunkBytes: Int
        let preciseReadChunkMaxBytes: Int
        let preciseFirstReadChunkElapsedMs: Int
        let preciseUpSequenceCount: Int
        let preciseDownSequenceCount: Int
        let preciseApplicationCursorSequenceCount: Int
        let preciseNormalCursorSequenceCount: Int
        let preciseReadEscapeByteCount: Int
        let preciseReadPrintableByteCount: Int
        let preciseReadNewlineByteCount: Int
    }

    struct ScrollTelemetrySnapshot: Codable, Equatable {
        let firstScrollInputElapsedMs: Double?
        let firstPreciseScrollInputElapsedMs: Double?
        let firstDirectPhaseScrollInputElapsedMs: Double?
        let firstMomentumPhaseScrollInputElapsedMs: Double?
        let scrollToRenderRequest: ScrollTelemetryMetricSummary
        let scrollToFirstDraw: ScrollTelemetryMetricSummary
        let scrollToLayerPresent: ScrollTelemetryMetricSummary
        let renderRequestToDraw: ScrollTelemetryMetricSummary
        let drawGap: ScrollTelemetryMetricSummary
        let scrollPresentationDrawGap: ScrollTelemetryMetricSummary
        let scrollPresentationImmediateQueueDelay: ScrollTelemetryMetricSummary
        let scrollPresentationPumpWakeLateness: ScrollTelemetryMetricSummary
        let scrollPresentationRecoveryProbeWakeLateness: ScrollTelemetryMetricSummary
        let layerPresentGap: ScrollTelemetryMetricSummary
        let scrollInputGap: ScrollTelemetryMetricSummary
        let scrollInputHandler: ScrollTelemetryMetricSummary
        let scrollInputDispatch: ScrollTelemetryMetricSummary
        let scrollInputVerticalDeltaAbs: ScrollTelemetryValueSummary
        let scrollToFirstDrawSamplesMs: [Double]
        let scrollToLayerPresentSamplesMs: [Double]
        let scrollPresentationDrawGapSamplesMs: [Double]
        let scrollPresentationImmediateQueueDelaySamplesMs: [Double]
        let scrollPresentationPumpWakeLatenessSamplesMs: [Double]
        let scrollPresentationRecoveryProbeWakeLatenessSamplesMs: [Double]
        let layerPresentGapSamplesMs: [Double]
        let scrollInputGapSamplesMs: [Double]
        let scrollInputHandlerSamplesMs: [Double]
        let scrollInputDispatchSamplesMs: [Double]
        let scrollInputVerticalDeltaAbsSamples: [Double]
        let drawCount: Int
        let scrollPresentationDrawCount: Int
        let layerPresentCount: Int
        let scrollInputCount: Int
        let preciseScrollInputCount: Int
        let directPhaseScrollInputCount: Int
        let momentumPhaseScrollInputCount: Int
        let pendingScrollToRenderCount: Int
        let pendingScrollToDrawCount: Int
        let pendingScrollToLayerPresentCount: Int
        let pendingRenderToDrawCount: Int
        let alternateScroll: AlternateScrollTelemetrySnapshot
    }

    struct ViewportTextSnapshot: Codable, Equatable {
        let text: String
        let lineCount: Int
        let characterCount: Int
        let usesAlternateScroll: Bool
    }

    struct InternalScrollInjectionSnapshot: Codable, Equatable {
        let mode: String
        let sent: Bool
        let trusted: Bool
        let precision: Bool
        let phaseMode: String
        let scrollPixels: Double
        let scrollRepeat: Int
        let scrollIntervalMs: Int
        let deliveredEventCount: Int
        let deliveredDeltaEventCount: Int
        let usesAlternateScroll: Bool
    }

    private enum ScrollVerticalDirection: Equatable {
        case up
        case down
    }

    private enum ScrollCadenceMode: Equatable {
        case legacyHybrid
        case ghosttyOwned
    }

    // MARK: - State

    private(set) var surface: ghostty_surface_t?
    private var observedWindow: NSWindow?
    private var windowObserverTokens: [NSObjectProtocol] = []
    private var lastAppliedSurfaceMetrics: SurfaceMetrics?
    private var desiredSurfaceFocus = false
    private var appliedSurfaceFocus = false
    private weak var observedRenderLayer: CALayer?
    private var renderLayerContentsObservation: NSKeyValueObservation?
    private(set) var debugKeyDownCount = 0
    private(set) var debugLastKeyCode: UInt16?
    private(set) var debugLastCharacters: String?
    private(set) var debugLastCharactersIgnoringModifiers: String?
    private(set) var debugLastModifierFlagsRawValue: UInt?
    private(set) var debugLastSendKeyResult: Bool?
    private(set) var debugRecentInputEvents: [String] = []
    private var scrollCadenceMode: ScrollCadenceMode = .legacyHybrid
    private var scrollPresentationDrawPending = false
    private var scrollPresentationContinuationScheduled = false
    private var scrollPresentationContinuationGeneration: UInt64 = 0
    private var scrollPresentationContinuationDueUptime: TimeInterval?
    private var scrollPresentationDrawPumpScheduled = false
    private var scrollPresentationDrawPumpDueUptime: TimeInterval?
    private var scrollPresentationRecoveryProbeScheduled = false
    private var scrollPresentationRecoveryProbeDueUptime: TimeInterval?
    private var scrollPresentationRecoveryProbeDrawUptime: TimeInterval?
    private var paneRetargetPresentationDrawPending = false
    private var paneRetargetPresentationRecoveryProbeScheduled = false
    private var paneRetargetPresentationRecoveryProbeGeneration: UInt64 = 0
    private var lastScrollInputUptime: TimeInterval?
    private var lastScrollPresentationDrawUptime: TimeInterval?
    private var lastPaneRetargetPresentationDrawUptime: TimeInterval?
    private var scrollPresentationDirectGestureActive = false
    private var lastPreciseScrollVerticalDirection: ScrollVerticalDirection?
    private var pendingScrollToRenderStates: [OSSignpostIntervalState] = []
    private var pendingScrollToDrawStates: [OSSignpostIntervalState] = []
    private var pendingScrollToLayerPresentStates: [OSSignpostIntervalState] = []
    private var pendingRenderToDrawStates: [OSSignpostIntervalState] = []
    private var pendingScrollToRenderUptimes: [TimeInterval] = []
    private var pendingScrollToDrawUptimes: [TimeInterval] = []
    private var pendingScrollToLayerPresentUptimes: [TimeInterval] = []
    private var pendingRenderToDrawUptimes: [TimeInterval] = []
    private var scrollToRenderSamplesMs: [Double] = []
    private var scrollToDrawSamplesMs: [Double] = []
    private var scrollToLayerPresentSamplesMs: [Double] = []
    private var scrollInputGapSamplesMs: [Double] = []
    private var scrollInputHandlerSamplesMs: [Double] = []
    private var scrollInputDispatchSamplesMs: [Double] = []
    private var scrollInputVerticalDeltaAbsSamples: [Double] = []
    private var renderToDrawSamplesMs: [Double] = []
    private var drawGapSamplesMs: [Double] = []
    private var scrollPresentationDrawGapSamplesMs: [Double] = []
    private var scrollPresentationImmediateQueueDelaySamplesMs: [Double] = []
    private var scrollPresentationPumpWakeLatenessSamplesMs: [Double] = []
    private var scrollPresentationRecoveryProbeWakeLatenessSamplesMs: [Double] = []
    private var layerPresentGapSamplesMs: [Double] = []
    private var scrollInputCount = 0
    private var preciseScrollInputCount = 0
    private var directPhaseScrollInputCount = 0
    private var momentumPhaseScrollInputCount = 0
    private var scrollTelemetryResetUptime: TimeInterval?
    private var firstScrollInputElapsedMs: Double?
    private var firstPreciseScrollInputElapsedMs: Double?
    private var firstDirectPhaseScrollInputElapsedMs: Double?
    private var firstMomentumPhaseScrollInputElapsedMs: Double?
    private var drawCount = 0
    private var scrollPresentationDrawCount = 0
    private var layerPresentCount = 0
    private var lastHostDrawUptime: TimeInterval?
    private var lastScrollInputEventUptime: TimeInterval?
    private var preciseAlternateScrollDirtyDrawEligibleUntilUptime: TimeInterval?
    private var rendererOwnedRenderCallbackEligibleUntilUptime: TimeInterval?
    private var lastScrollPresentationDrawTelemetryUptime: TimeInterval?
    private var lastLayerPresentUptime: TimeInterval?

    // MARK: - IME state

    private var markedText = NSMutableAttributedString()
    /// Text fragments accumulated during a keyDown -> interpretKeyEvents call.
    /// These must be replayed as key events, not paste/text insertion.
    private var keyTextAccumulator: [String] = []
    /// True while we are inside keyDown (i.e. interpretKeyEvents is running).
    private var inKeyDown = false

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibilityDefaults()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibilityDefaults()
    }

    deinit {
        removeWindowObservers()
        renderLayerContentsObservation?.invalidate()
        // clearSurface() may have already freed the surface (SurfacePool GC path).
        // If surface is still non-nil, free it here.
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    /// Free the current surface and nil it out.
    ///
    /// Called by SurfacePool.gc() before releasing its strong reference.
    /// Sets surface = nil so deinit won't double-free.
    func clearSurface() {
        if let s = surface {
            ghostty_surface_free(s)
            surface = nil
        }
        lastAppliedSurfaceMetrics = nil
        appliedSurfaceFocus = false
        invalidateScrollPresentationDrawPump()
        syncRenderLayerContentsObservation()
        resetScrollTelemetryForTesting()
    }

    /// Replace the current surface with a new one.
    ///
    /// Frees the old surface (if any), then installs the new surface and requests a redraw.
    func attachSurface(_ newSurface: ghostty_surface_t) {
        if let old = surface {
            ghostty_surface_free(old)
        }
        surface = newSurface
        lastAppliedSurfaceMetrics = nil
        syncSurfaceMetrics(shouldMarkDirty: false, force: true)
        applySurfaceFocusIfNeeded(force: true)
        invalidateScrollPresentationDrawPump()
        syncRenderLayerContentsObservation()
        resetScrollTelemetryForTesting()
        needsDisplay = true
    }

    func configureAccessibility(
        identifier: String,
        label: String
    ) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    @MainActor
    func setTerminalHostMode(_ mode: TerminalHostMode) {
        let nextMode: ScrollCadenceMode = switch mode {
        case .legacy:
            .legacyHybrid
        case .next:
            .ghosttyOwned
        }
        guard scrollCadenceMode != nextMode else { return }
        scrollCadenceMode = nextMode
        invalidateScrollPresentationDrawPump()
    }

    @MainActor
    func prefersRendererOwnedRenderCallbackDispatch(now: TimeInterval) -> Bool {
        guard scrollCadenceMode == .ghosttyOwned,
              let rendererOwnedRenderCallbackEligibleUntilUptime
        else {
            return false
        }
        return now <= rendererOwnedRenderCallbackEligibleUntilUptime
    }

    @MainActor
    func triggerRendererOwnedRenderCallback(now: TimeInterval) {
        triggerDirtyDrawForRenderCallback(now: now)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        syncRenderLayerContentsObservation()
        syncSurfaceMetrics(shouldMarkDirty: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservers()
        syncRenderLayerContentsObservation()
        guard window != nil else { return }
        desiredSurfaceFocus = window?.firstResponder === self
        applySurfaceFocusIfNeeded(force: true)
        syncSurfaceMetrics(shouldMarkDirty: true, force: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceMetrics(shouldMarkDirty: true)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            desiredSurfaceFocus = true
            applySurfaceFocusIfNeeded(force: false)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            desiredSurfaceFocus = false
            applySurfaceFocusIfNeeded(force: false)
        }
        return result
    }

    // MARK: - Tracking areas (required for mouseMoved / scroll to work)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect:    bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner:   self,
            userInfo: nil
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    private func configureAccessibilityDefaults() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    // MARK: - Draw

    /// Called by GhosttyApp's dirty scheduler to request the next render.
    ///
    /// `ghostty_surface_draw()` forces an immediate draw attempt on the host thread.
    /// For steady-state scrolling that is more aggressive than necessary and competes
    /// with input processing on the main thread. `ghostty_surface_refresh()` hands the
    /// work back to libghostty's render queue so the IOSurface layer can present on its
    /// own pacing instead of doing the full draw synchronously here.
    func triggerDraw() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    @MainActor
    func triggerDirtyDrawForRenderCallback(now: TimeInterval) {
        if prefersImmediateDirtyDrawForRenderCallback(now: now) {
            performImmediatePresentationDraw()
            return
        }
        triggerDraw()
    }

    // MARK: - NSTextInputClient (IME)

    func setMarkedText(_ string: Any,
                       selectedRange: NSRange,
                       replacementRange: NSRange) {
        let str: String
        if let attributed = string as? NSAttributedString {
            str = attributed.string
        } else {
            str = string as? String ?? ""
        }
        markedText = NSMutableAttributedString(string: str)
        if !inKeyDown {
            syncPreeditToSurface(clearIfNeeded: true)
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let attributed = string as? NSAttributedString {
            str = attributed.string
        } else {
            str = string as? String ?? ""
        }
        let hadMarkedText = markedText.length > 0
        markedText = NSMutableAttributedString()
        if hadMarkedText {
            syncPreeditToSurface(clearIfNeeded: true)
        }
        if inKeyDown {
            // Accumulate during interpretKeyEvents; send after keyDown returns.
            keyTextAccumulator.append(str)
        } else {
            // IME commit outside a keyDown (e.g. selecting from candidate list).
            sendText(str)
        }
    }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // Convert from ghostty coordinates (top-left origin) to NSScreen (bottom-left origin).
        guard let screen = window?.screen else { return .zero }
        let screenH = screen.frame.height
        return NSRect(x: x, y: screenH - y - h, width: w, height: h)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        syncPreeditToSurface(clearIfNeeded: true)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Text helper

    private func sendText(_ text: String) {
        sendTextToSurface(text)
    }

    private func sendKeyActionToSurface(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = GhosttyInput.toGhosttyKey(event, translationMods: translationMods)
        key.action = action
        key.composing = composing

        if let text, text.isEmpty == false,
           let first = text.utf8.first,
           first >= 0x20
        {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }

        return ghostty_surface_key(surface, key)
    }

    func sendKeyToSurface(
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        sendKeyActionToSurface(
            GHOSTTY_ACTION_PRESS,
            event: event,
            translationMods: translationMods,
            text: text,
            composing: composing
        )
    }

    func sendTextToSurface(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    func syncPreeditToSurface(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func translationEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }

        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.toMods(event.modifierFlags)
            )
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        guard translationMods != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationMods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    func sendTmuxNextPaneKeysForTesting(windowNumber: Int) -> Bool {
        // Match the real responder path closely enough for tmux prefix handling.
        // Ctrl-A travels through the modified key path; the next-pane key is a
        // normal text-producing keyDown.
        let controlDown = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x3B
        )!
        let ctrlA = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0x00
        )!
        let controlUp = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.002,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x3B
        )!
        let nextPane = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.003,
            windowNumber: windowNumber,
            context: nil,
            characters: "o",
            charactersIgnoringModifiers: "o",
            isARepeat: false,
            keyCode: 0x1F
        )!

        flagsChanged(with: controlDown)
        keyDown(with: ctrlA)
        let sentCtrlA = debugLastSendKeyResult ?? false
        flagsChanged(with: controlUp)
        keyDown(with: nextPane)
        let sentNextPane = debugLastSendKeyResult ?? false
        return sentCtrlA && sentNextPane
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        debugKeyDownCount += 1
        debugLastKeyCode = event.keyCode
        debugLastCharacters = event.characters
        debugLastCharactersIgnoringModifiers = event.charactersIgnoringModifiers
        debugLastModifierFlagsRawValue = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue

        let translationEvent = translationEvent(for: event)

        let markedTextBefore = markedText.length > 0
        inKeyDown = true
        keyTextAccumulator = []
        defer {
            inKeyDown = false
            keyTextAccumulator = []
        }

        // AppKit text input must run before terminal key encoding so IME commit
        // cannot be pre-consumed as a raw Return/Enter key.
        interpretKeyEvents([translationEvent])
        syncPreeditToSurface(clearIfNeeded: markedTextBefore)

        if !keyTextAccumulator.isEmpty {
            var sentAny = false
            var sentAll = true
            for text in keyTextAccumulator {
                let sent = sendKeyToSurface(
                    event: event,
                    translationMods: translationEvent.modifierFlags,
                    text: text,
                    composing: false
                )
                sentAny = true
                sentAll = sentAll && sent
            }
            debugLastSendKeyResult = sentAny ? sentAll : nil
            recordDebugInputEvent(
                kind: "keyDown",
                event: event,
                sendResult: debugLastSendKeyResult
            )
            return
        }

        debugLastSendKeyResult = sendKeyToSurface(
            event: event,
            translationMods: translationEvent.modifierFlags,
            text: translationEvent.agtmuxGhosttyCharacters,
            composing: markedText.length > 0 || markedTextBefore
        )
        recordDebugInputEvent(
            kind: "keyDown",
            event: event,
            sendResult: debugLastSendKeyResult
        )
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKeyActionToSurface(GHOSTTY_ACTION_RELEASE, event: event)
        recordDebugInputEvent(kind: "keyUp", event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39:
            mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C:
            mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E:
            mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D:
            mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36:
            mod = GHOSTTY_MODS_SUPER.rawValue
        default:
            return
        }

        if hasMarkedText() { return }

        let mods = GhosttyInput.toMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = sendKeyActionToSurface(action, event: event)
        recordDebugInputEvent(
            kind: action == GHOSTTY_ACTION_PRESS ? "flagsDown" : "flagsUp",
            event: event
        )
    }

    override var acceptsFirstResponder: Bool { true }

    var accessibilityFocused: Bool {
        get { window?.firstResponder === self }
        set {
            guard newValue else { return }
            window?.makeFirstResponder(self)
        }
    }

    override func accessibilityValue() -> Any? {
        visibleViewportTextForTesting()
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func doCommand(by selector: Selector) {
        // `interpretKeyEvents` routes many non-text inputs here. We encode the final
        // terminal key after IME/text processing in `keyDown`, so this must not beep
        // or short-circuit composition/commit flows.
    }

    private func recordDebugInputEvent(
        kind: String,
        event: NSEvent,
        sendResult: Bool? = nil
    ) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let chars: String
        let charsIgnoringModifiers: String
        if event.type == .keyDown || event.type == .keyUp {
            chars = event.characters ?? ""
            charsIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        } else {
            chars = ""
            charsIgnoringModifiers = ""
        }
        let summary = "\(kind) keyCode=\(event.keyCode) chars=\(chars.debugDescription) charsIgnoring=\(charsIgnoringModifiers.debugDescription) flags=\(flags)\(sendResult.map { " sent=\($0)" } ?? "")"
        debugRecentInputEvents.append(summary)
        if debugRecentInputEvents.count > 12 {
            debugRecentInputEvents.removeFirst(debugRecentInputEvents.count - 12)
        }
    }

    @MainActor
    func applySurfaceMetricsForTesting(
        _ metrics: SurfaceMetrics,
        shouldMarkDirty: Bool = true,
        force: Bool = false
    ) {
        applySurfaceMetricsIfNeeded(
            metrics,
            shouldMarkDirty: shouldMarkDirty,
            force: force
        )
    }

    func hasSurfaceForMetricsSync() -> Bool {
        surface != nil
    }

    func updateSurfaceContentScale(xScale: Double, yScale: Double) {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }

    func updateSurfaceSize(pixelWidth: UInt32, pixelHeight: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
    }

    func updateSurfaceDisplayID(_ displayID: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func hasSurfaceForScrollPresentationDraw() -> Bool {
        surface != nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Terminal key handling depends on the Ghostty view being first responder.
        // AppKit does not reliably assign that to a custom NSView on click, so
        // claim it explicitly before forwarding the mouse event to libghostty.
        window?.makeFirstResponder(self)
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_LEFT,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_RIGHT,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_RIGHT,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_MIDDLE,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface,
                                     GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_MIDDLE,
                                     GhosttyInput.toMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let loc = convert(event.locationInWindow, from: nil)
        // Ghostty uses top-left origin; NSView is bottom-left, so flip Y.
        ghostty_surface_mouse_pos(surface,
                                   loc.x,
                                   bounds.height - loc.y,
                                   GhosttyInput.toMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        dispatchScrollInput(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY,
            precision: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        )
    }

    @MainActor
    func injectTrackpadScrollStepForTesting(
        horizontalDelta: Double = 0,
        verticalDelta: Double,
        precision: Bool = true,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) {
        dispatchScrollInput(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta,
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase
        )
    }

    private func dispatchScrollInput(
        horizontalDelta rawHorizontalDelta: Double,
        verticalDelta rawVerticalDelta: Double,
        precision: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) {
        guard let surface else { return }
        let handlerStartUptime = ProcessInfo.processInfo.systemUptime
        // Pass deltas raw — Ghostty expects the same sign convention as
        // NSEvent.scrollingDeltaY (positive = up). Negating was inverting scroll.
        var horizontalDelta = rawHorizontalDelta
        var verticalDelta = rawVerticalDelta
        let usesAlternateScroll = ghostty_surface_uses_alternate_scroll(surface)
        if precision {
            let precisionMultiplier = Self.precisionScrollMultiplier(
                usesAlternateScroll: usesAlternateScroll,
                phase: phase,
                momentumPhase: momentumPhase
            )
            horizontalDelta *= precisionMultiplier
            verticalDelta *= precisionMultiplier
        }
        noteScrollInputTelemetry(
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase,
            verticalDelta: verticalDelta
        )
        updateScrollPresentationGestureState(
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase,
            verticalDelta: verticalDelta
        )
        updatePreciseAlternateScrollDirtyDrawEligibility(
            usesAlternateScroll: usesAlternateScroll,
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase,
            verticalDelta: verticalDelta,
            now: handlerStartUptime
        )
        updateRendererOwnedRenderCallbackEligibility(
            usesAlternateScroll: usesAlternateScroll,
            precision: precision,
            verticalDelta: verticalDelta,
            now: handlerStartUptime
        )
        let scrollMods = GhosttyInput.packedScrollMods(
            precision: precision,
            momentumPhase: momentumPhase,
            phase: phase
        )
        let dispatchStartUptime = ProcessInfo.processInfo.systemUptime
        ghostty_surface_mouse_scroll(
            surface,
            horizontalDelta,
            verticalDelta,
            scrollMods
        )
        let dispatchEndUptime = ProcessInfo.processInfo.systemUptime
        let hostScrollPresentationEnabled = shouldUseHostScrollPresentation(
            usesAlternateScroll: usesAlternateScroll,
            precision: precision
        )
        if hostScrollPresentationEnabled {
            scheduleScrollPresentationDrawIfNeeded()
        }
        noteScrollInputExecutionTelemetry(
            handlerStartUptime: handlerStartUptime,
            dispatchStartUptime: dispatchStartUptime,
            dispatchEndUptime: dispatchEndUptime,
            handlerEndUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    @MainActor
    func noteRenderRequestTelemetry() {
        guard pendingScrollToRenderStates.isEmpty == false
            || pendingScrollToDrawStates.isEmpty == false
        else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime

        for state in pendingScrollToRenderStates {
            AgtmuxSignpost.scrollLatency.endInterval("scrollToRenderRequest", state)
        }
        pendingScrollToRenderStates.removeAll(keepingCapacity: true)
        for uptime in pendingScrollToRenderUptimes {
            scrollToRenderSamplesMs.append((now - uptime) * 1000.0)
        }
        pendingScrollToRenderUptimes.removeAll(keepingCapacity: true)

        let renderToDrawID = AgtmuxSignpost.scrollLatency.makeSignpostID()
        let renderToDrawState = AgtmuxSignpost.scrollLatency.beginInterval(
            "renderRequestToDraw",
            id: renderToDrawID
        )
        pendingRenderToDrawStates.append(renderToDrawState)
        pendingRenderToDrawUptimes.append(now)
    }

    @MainActor
    func noteHostDrawTelemetry() {
        let now = ProcessInfo.processInfo.systemUptime
        completePendingScrollToDrawTelemetry(at: now)

        for state in pendingRenderToDrawStates {
            AgtmuxSignpost.scrollLatency.endInterval("renderRequestToDraw", state)
        }
        pendingRenderToDrawStates.removeAll(keepingCapacity: true)
        for uptime in pendingRenderToDrawUptimes {
            renderToDrawSamplesMs.append((now - uptime) * 1000.0)
        }
        pendingRenderToDrawUptimes.removeAll(keepingCapacity: true)

        if let lastHostDrawUptime {
            drawGapSamplesMs.append((now - lastHostDrawUptime) * 1000.0)
        }
        lastHostDrawUptime = now
        drawCount += 1
    }

    @MainActor
    func noteScrollPresentationDrawTelemetryForTesting(now: TimeInterval) {
        noteScrollPresentationDrawTelemetry(now: now)
    }

    @MainActor
    func noteScrollPresentationImmediateQueueDelayTelemetryForTesting(
        scheduledAt: TimeInterval,
        now: TimeInterval
    ) {
        noteScrollPresentationImmediateQueueDelayTelemetry(
            scheduledAt: scheduledAt,
            now: now
        )
    }

    @MainActor
    func noteScrollPresentationDrawPumpWakeLatenessTelemetryForTesting(
        scheduledFor: TimeInterval,
        now: TimeInterval
    ) {
        noteScrollPresentationDrawPumpWakeLatenessTelemetry(
            scheduledFor: scheduledFor,
            now: now
        )
    }

    @MainActor
    func noteScrollPresentationRecoveryProbeWakeLatenessTelemetryForTesting(
        scheduledFor: TimeInterval,
        now: TimeInterval
    ) {
        noteScrollPresentationRecoveryProbeWakeLatenessTelemetry(
            scheduledFor: scheduledFor,
            now: now
        )
    }

    @MainActor
    private func noteScrollPresentationDrawTelemetry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        completePendingScrollToDrawTelemetry(at: now)
        if let lastScrollPresentationDrawTelemetryUptime {
            scrollPresentationDrawGapSamplesMs.append(
                (now - lastScrollPresentationDrawTelemetryUptime) * 1000.0
            )
        }
        lastScrollPresentationDrawTelemetryUptime = now
        scrollPresentationDrawCount += 1
    }

    @MainActor
    private func noteScrollPresentationImmediateQueueDelayTelemetry(
        scheduledAt: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        scrollPresentationImmediateQueueDelaySamplesMs.append(
            max(0, (now - scheduledAt) * 1000.0)
        )
    }

    @MainActor
    private func noteScrollPresentationDrawPumpWakeLatenessTelemetry(
        scheduledFor: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        scrollPresentationPumpWakeLatenessSamplesMs.append(
            max(0, (now - scheduledFor) * 1000.0)
        )
    }

    @MainActor
    private func noteScrollPresentationRecoveryProbeWakeLatenessTelemetry(
        scheduledFor: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        scrollPresentationRecoveryProbeWakeLatenessSamplesMs.append(
            max(0, (now - scheduledFor) * 1000.0)
        )
    }

    @MainActor
    private func completePendingScrollToDrawTelemetry(at now: TimeInterval) {
        for state in pendingScrollToDrawStates {
            AgtmuxSignpost.scrollLatency.endInterval("scrollToFirstDraw", state)
        }
        pendingScrollToDrawStates.removeAll(keepingCapacity: true)
        for uptime in pendingScrollToDrawUptimes {
            scrollToDrawSamplesMs.append((now - uptime) * 1000.0)
        }
        pendingScrollToDrawUptimes.removeAll(keepingCapacity: true)
    }

    @MainActor
    func noteLayerPresentationTelemetryForTesting() {
        noteLayerPresentationTelemetry()
    }

    @MainActor
    func noteLayerPresentationForTesting(now: TimeInterval) {
        lastLayerPresentUptime = now
    }

    @MainActor
    func resetScrollTelemetryForTesting() {
        scrollTelemetryResetUptime = ProcessInfo.processInfo.systemUptime
        pendingScrollToRenderStates.removeAll(keepingCapacity: false)
        pendingScrollToDrawStates.removeAll(keepingCapacity: false)
        pendingScrollToLayerPresentStates.removeAll(keepingCapacity: false)
        pendingRenderToDrawStates.removeAll(keepingCapacity: false)
        pendingScrollToRenderUptimes.removeAll(keepingCapacity: false)
        pendingScrollToDrawUptimes.removeAll(keepingCapacity: false)
        pendingScrollToLayerPresentUptimes.removeAll(keepingCapacity: false)
        pendingRenderToDrawUptimes.removeAll(keepingCapacity: false)
        scrollToRenderSamplesMs.removeAll(keepingCapacity: false)
        scrollToDrawSamplesMs.removeAll(keepingCapacity: false)
        scrollToLayerPresentSamplesMs.removeAll(keepingCapacity: false)
        scrollInputGapSamplesMs.removeAll(keepingCapacity: false)
        scrollInputHandlerSamplesMs.removeAll(keepingCapacity: false)
        scrollInputDispatchSamplesMs.removeAll(keepingCapacity: false)
        scrollInputVerticalDeltaAbsSamples.removeAll(keepingCapacity: false)
        renderToDrawSamplesMs.removeAll(keepingCapacity: false)
        drawGapSamplesMs.removeAll(keepingCapacity: false)
        scrollPresentationDrawGapSamplesMs.removeAll(keepingCapacity: false)
        scrollPresentationImmediateQueueDelaySamplesMs.removeAll(keepingCapacity: false)
        scrollPresentationPumpWakeLatenessSamplesMs.removeAll(keepingCapacity: false)
        scrollPresentationRecoveryProbeWakeLatenessSamplesMs.removeAll(keepingCapacity: false)
        layerPresentGapSamplesMs.removeAll(keepingCapacity: false)
        scrollInputCount = 0
        preciseScrollInputCount = 0
        directPhaseScrollInputCount = 0
        momentumPhaseScrollInputCount = 0
        firstScrollInputElapsedMs = nil
        firstPreciseScrollInputElapsedMs = nil
        firstDirectPhaseScrollInputElapsedMs = nil
        firstMomentumPhaseScrollInputElapsedMs = nil
        drawCount = 0
        scrollPresentationDrawCount = 0
        layerPresentCount = 0
        lastScrollInputEventUptime = nil
        preciseAlternateScrollDirtyDrawEligibleUntilUptime = nil
        lastHostDrawUptime = nil
        lastScrollPresentationDrawTelemetryUptime = nil
        lastLayerPresentUptime = nil
        paneRetargetPresentationDrawPending = false
        paneRetargetPresentationRecoveryProbeScheduled = false
        lastPaneRetargetPresentationDrawUptime = nil
        paneRetargetPresentationRecoveryProbeGeneration &+= 1
        if let surface {
            ghostty_surface_reset_alternate_scroll_telemetry(surface)
        }
    }

    @MainActor
    func noteScrollInputTelemetryForTesting(
        now: TimeInterval? = nil,
        precision: Bool = false,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        verticalDelta: Double = 0
    ) {
        noteScrollInputTelemetry(
            now: now ?? ProcessInfo.processInfo.systemUptime,
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase,
            verticalDelta: verticalDelta
        )
    }

    @MainActor
    func noteScrollInputExecutionTelemetryForTesting(
        handlerDurationMs: Double,
        dispatchDurationMs: Double
    ) {
        scrollInputHandlerSamplesMs.append(handlerDurationMs)
        scrollInputDispatchSamplesMs.append(dispatchDurationMs)
    }

    @MainActor
    func updateScrollPresentationGestureStateForTesting(
        precision: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        verticalDelta: Double,
        now: TimeInterval
    ) {
        lastScrollInputUptime = now
        updateScrollPresentationGestureState(
            precision: precision,
            phase: phase,
            momentumPhase: momentumPhase,
            verticalDelta: verticalDelta
        )
    }

    @MainActor
    func noteScrollPresentationDrawForTesting(now: TimeInterval) {
        lastScrollPresentationDrawUptime = now
    }

    func precisionScrollMultiplierForTesting(
        usesAlternateScroll: Bool,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) -> Double {
        Self.precisionScrollMultiplier(
            usesAlternateScroll: usesAlternateScroll,
            phase: phase,
            momentumPhase: momentumPhase
        )
    }

    @MainActor
    func shouldThrottleImmediateScrollPresentationDrawForTesting(now: TimeInterval) -> Bool {
        shouldThrottleImmediateScrollPresentationDraw(now: now)
    }

    @MainActor
    func shouldUseHostScrollPresentationContinuationForTesting(now: TimeInterval) -> Bool {
        shouldUseHostScrollPresentationContinuation(now: now)
    }

    @MainActor
    func configureScrollPresentationContinuationForTesting(
        pumpDue: TimeInterval?,
        recoveryDue: TimeInterval?,
        recoveryDrawUptime: TimeInterval?
    ) {
        scrollPresentationDrawPumpScheduled = pumpDue != nil
        scrollPresentationDrawPumpDueUptime = pumpDue
        scrollPresentationRecoveryProbeScheduled = recoveryDue != nil
        scrollPresentationRecoveryProbeDueUptime = recoveryDue
        scrollPresentationRecoveryProbeDrawUptime = recoveryDrawUptime
    }

    @MainActor
    func nextScrollPresentationContinuationDueForTesting() -> TimeInterval? {
        nextScrollPresentationContinuationDueUptime()
    }

    struct ScrollPresentationContinuationState: Equatable {
        let pumpDueUptime: TimeInterval?
        let recoveryDueUptime: TimeInterval?
        let recoveryDrawUptime: TimeInterval?
        let lastDrawUptime: TimeInterval?
    }

    @MainActor
    func scrollPresentationContinuationStateForTesting() -> ScrollPresentationContinuationState {
        ScrollPresentationContinuationState(
            pumpDueUptime: scrollPresentationDrawPumpDueUptime,
            recoveryDueUptime: scrollPresentationRecoveryProbeDueUptime,
            recoveryDrawUptime: scrollPresentationRecoveryProbeDrawUptime,
            lastDrawUptime: lastScrollPresentationDrawUptime
        )
    }

    @MainActor
    func runScheduledScrollPresentationContinuationWakeForTesting(now: TimeInterval) {
        runScheduledScrollPresentationContinuationWake(now: now)
    }

    func scrollTelemetrySnapshotForTesting() -> ScrollTelemetrySnapshot {
        ScrollTelemetrySnapshot(
            firstScrollInputElapsedMs: firstScrollInputElapsedMs,
            firstPreciseScrollInputElapsedMs: firstPreciseScrollInputElapsedMs,
            firstDirectPhaseScrollInputElapsedMs: firstDirectPhaseScrollInputElapsedMs,
            firstMomentumPhaseScrollInputElapsedMs: firstMomentumPhaseScrollInputElapsedMs,
            scrollToRenderRequest: summary(for: scrollToRenderSamplesMs),
            scrollToFirstDraw: summary(for: scrollToDrawSamplesMs),
            scrollToLayerPresent: summary(for: scrollToLayerPresentSamplesMs),
            renderRequestToDraw: summary(for: renderToDrawSamplesMs),
            drawGap: summary(for: drawGapSamplesMs),
            scrollPresentationDrawGap: summary(for: scrollPresentationDrawGapSamplesMs),
            scrollPresentationImmediateQueueDelay: summary(for: scrollPresentationImmediateQueueDelaySamplesMs),
            scrollPresentationPumpWakeLateness: summary(for: scrollPresentationPumpWakeLatenessSamplesMs),
            scrollPresentationRecoveryProbeWakeLateness: summary(for: scrollPresentationRecoveryProbeWakeLatenessSamplesMs),
            layerPresentGap: summary(for: layerPresentGapSamplesMs),
            scrollInputGap: summary(for: scrollInputGapSamplesMs),
            scrollInputHandler: summary(for: scrollInputHandlerSamplesMs),
            scrollInputDispatch: summary(for: scrollInputDispatchSamplesMs),
            scrollInputVerticalDeltaAbs: valueSummary(for: scrollInputVerticalDeltaAbsSamples),
            scrollToFirstDrawSamplesMs: scrollToDrawSamplesMs,
            scrollToLayerPresentSamplesMs: scrollToLayerPresentSamplesMs,
            scrollPresentationDrawGapSamplesMs: scrollPresentationDrawGapSamplesMs,
            scrollPresentationImmediateQueueDelaySamplesMs: scrollPresentationImmediateQueueDelaySamplesMs,
            scrollPresentationPumpWakeLatenessSamplesMs: scrollPresentationPumpWakeLatenessSamplesMs,
            scrollPresentationRecoveryProbeWakeLatenessSamplesMs: scrollPresentationRecoveryProbeWakeLatenessSamplesMs,
            layerPresentGapSamplesMs: layerPresentGapSamplesMs,
            scrollInputGapSamplesMs: scrollInputGapSamplesMs,
            scrollInputHandlerSamplesMs: scrollInputHandlerSamplesMs,
            scrollInputDispatchSamplesMs: scrollInputDispatchSamplesMs,
            scrollInputVerticalDeltaAbsSamples: scrollInputVerticalDeltaAbsSamples,
            drawCount: drawCount,
            scrollPresentationDrawCount: scrollPresentationDrawCount,
            layerPresentCount: layerPresentCount,
            scrollInputCount: scrollInputCount,
            preciseScrollInputCount: preciseScrollInputCount,
            directPhaseScrollInputCount: directPhaseScrollInputCount,
            momentumPhaseScrollInputCount: momentumPhaseScrollInputCount,
            pendingScrollToRenderCount: pendingScrollToRenderUptimes.count,
            pendingScrollToDrawCount: pendingScrollToDrawUptimes.count,
            pendingScrollToLayerPresentCount: pendingScrollToLayerPresentUptimes.count,
            pendingRenderToDrawCount: pendingRenderToDrawUptimes.count,
            alternateScroll: alternateScrollTelemetrySnapshot()
        )
    }

    func viewportTextSnapshotForTesting() -> ViewportTextSnapshot {
        let text = visibleViewportTextForTesting()
        let lineCount = text.isEmpty ? 0 : text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
        return ViewportTextSnapshot(
            text: text,
            lineCount: lineCount,
            characterCount: text.count,
            usesAlternateScroll: surface.map(ghostty_surface_uses_alternate_scroll) ?? false
        )
    }

    func visibleViewportTextForTesting() -> String {
        guard let surface else { return "" }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let rawText = text.text else { return "" }
        return String(cString: rawText)
    }

    private func alternateScrollTelemetrySnapshot() -> AlternateScrollTelemetrySnapshot {
        guard let surface else {
            return AlternateScrollTelemetrySnapshot(
                preciseEventCount: 0,
                preciseStepCount: 0,
                preciseFirstEventElapsedMs: 0,
                preciseMessageQueueCount: 0,
                preciseFirstMessageQueueElapsedMs: 0,
                preciseMailboxNotifyCount: 0,
                preciseFirstMailboxNotifyElapsedMs: 0,
                preciseWriteQueueCount: 0,
                preciseWriteQueueBytes: 0,
                preciseFirstWriteQueueElapsedMs: 0,
                preciseWriteCompletedCount: 0,
                preciseWriteCompletedBytes: 0,
                preciseFirstWriteCompletedElapsedMs: 0,
                preciseDrainTurnCount: 0,
                preciseDrainedMessageCount: 0,
                preciseDrainRequeueCount: 0,
                preciseFirstDrainTurnElapsedMs: 0,
                preciseReadChunkCount: 0,
                preciseReadChunkBytes: 0,
                preciseReadChunkMaxBytes: 0,
                preciseFirstReadChunkElapsedMs: 0,
                preciseUpSequenceCount: 0,
                preciseDownSequenceCount: 0,
                preciseApplicationCursorSequenceCount: 0,
                preciseNormalCursorSequenceCount: 0,
                preciseReadEscapeByteCount: 0,
                preciseReadPrintableByteCount: 0,
                preciseReadNewlineByteCount: 0
            )
        }
        let snapshot = ghostty_surface_alternate_scroll_telemetry(surface)
        let preciseEventCount = Int(snapshot.precise_event_count)
        let preciseStepCount = Int(snapshot.precise_step_count)
        let preciseFirstEventElapsedMs = Int(snapshot.precise_first_event_elapsed_ms)
        let preciseMessageQueueCount = Int(snapshot.precise_message_queue_count)
        let preciseFirstMessageQueueElapsedMs = Int(snapshot.precise_first_message_queue_elapsed_ms)
        let preciseMailboxNotifyCount = Int(snapshot.precise_mailbox_notify_count)
        let preciseFirstMailboxNotifyElapsedMs = Int(snapshot.precise_first_mailbox_notify_elapsed_ms)
        let preciseWriteQueueCount = Int(snapshot.precise_write_queue_count)
        let preciseWriteQueueBytes = Int(snapshot.precise_write_queue_bytes)
        let preciseFirstWriteQueueElapsedMs = Int(snapshot.precise_first_write_queue_elapsed_ms)
        let preciseWriteCompletedCount = Int(snapshot.precise_write_completed_count)
        let preciseWriteCompletedBytes = Int(snapshot.precise_write_completed_bytes)
        let preciseFirstWriteCompletedElapsedMs = Int(snapshot.precise_first_write_completed_elapsed_ms)
        let preciseDrainTurnCount = Int(snapshot.precise_drain_turn_count)
        let preciseDrainedMessageCount = Int(snapshot.precise_drained_message_count)
        let preciseDrainRequeueCount = Int(snapshot.precise_drain_requeue_count)
        let preciseFirstDrainTurnElapsedMs = Int(snapshot.precise_first_drain_turn_elapsed_ms)
        let preciseReadChunkCount = Int(snapshot.precise_read_chunk_count)
        let preciseReadChunkBytes = Int(snapshot.precise_read_chunk_bytes)
        let preciseReadChunkMaxBytes = Int(snapshot.precise_read_chunk_max_bytes)
        let preciseFirstReadChunkElapsedMs = Int(snapshot.precise_first_read_chunk_elapsed_ms)
        let preciseUpSequenceCount = Int(snapshot.precise_up_sequence_count)
        let preciseDownSequenceCount = Int(snapshot.precise_down_sequence_count)
        let preciseApplicationCursorSequenceCount = Int(snapshot.precise_application_cursor_sequence_count)
        let preciseNormalCursorSequenceCount = Int(snapshot.precise_normal_cursor_sequence_count)
        let preciseReadEscapeByteCount = Int(snapshot.precise_read_escape_byte_count)
        let preciseReadPrintableByteCount = Int(snapshot.precise_read_printable_byte_count)
        let preciseReadNewlineByteCount = Int(snapshot.precise_read_newline_byte_count)
        return AlternateScrollTelemetrySnapshot(
            preciseEventCount: preciseEventCount,
            preciseStepCount: preciseStepCount,
            preciseFirstEventElapsedMs: preciseFirstEventElapsedMs,
            preciseMessageQueueCount: preciseMessageQueueCount,
            preciseFirstMessageQueueElapsedMs: preciseFirstMessageQueueElapsedMs,
            preciseMailboxNotifyCount: preciseMailboxNotifyCount,
            preciseFirstMailboxNotifyElapsedMs: preciseFirstMailboxNotifyElapsedMs,
            preciseWriteQueueCount: preciseWriteQueueCount,
            preciseWriteQueueBytes: preciseWriteQueueBytes,
            preciseFirstWriteQueueElapsedMs: preciseFirstWriteQueueElapsedMs,
            preciseWriteCompletedCount: preciseWriteCompletedCount,
            preciseWriteCompletedBytes: preciseWriteCompletedBytes,
            preciseFirstWriteCompletedElapsedMs: preciseFirstWriteCompletedElapsedMs,
            preciseDrainTurnCount: preciseDrainTurnCount,
            preciseDrainedMessageCount: preciseDrainedMessageCount,
            preciseDrainRequeueCount: preciseDrainRequeueCount,
            preciseFirstDrainTurnElapsedMs: preciseFirstDrainTurnElapsedMs,
            preciseReadChunkCount: preciseReadChunkCount,
            preciseReadChunkBytes: preciseReadChunkBytes,
            preciseReadChunkMaxBytes: preciseReadChunkMaxBytes,
            preciseFirstReadChunkElapsedMs: preciseFirstReadChunkElapsedMs,
            preciseUpSequenceCount: preciseUpSequenceCount,
            preciseDownSequenceCount: preciseDownSequenceCount,
            preciseApplicationCursorSequenceCount: preciseApplicationCursorSequenceCount,
            preciseNormalCursorSequenceCount: preciseNormalCursorSequenceCount,
            preciseReadEscapeByteCount: preciseReadEscapeByteCount,
            preciseReadPrintableByteCount: preciseReadPrintableByteCount,
            preciseReadNewlineByteCount: preciseReadNewlineByteCount
        )
    }

    @MainActor
    func runScrollPresentationDrawPumpPassForTesting(now: TimeInterval) -> Bool {
        runScrollPresentationDrawPumpPass(now: now, reschedule: false)
    }

    private func syncRenderLayerContentsObservation() {
        let currentLayer = surface == nil ? nil : layer
        guard observedRenderLayer !== currentLayer else { return }

        renderLayerContentsObservation?.invalidate()
        renderLayerContentsObservation = nil
        observedRenderLayer = currentLayer

        guard let currentLayer else { return }
        renderLayerContentsObservation = currentLayer.observe(\.contents, options: [.new]) { [weak self] _, change in
            guard change.newValue != nil else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.noteLayerPresentationTelemetry()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.noteLayerPresentationTelemetry()
                }
            }
        }
    }

    /// Coalesce scroll-triggered synchronous draws to one per main-run-loop turn.
    ///
    /// Pure viewport scrolling updates the IOSurface layer without surfacing through
    /// `GHOSTTY_ACTION_RENDER`, so the normal dirty-draw scheduler never sees it.
    /// Requesting one synchronous draw per turn tightens frame pacing without doing
    /// a full main-thread draw for every high-frequency trackpad event. A
    /// short-lived draw pump keeps that cadence alive for the rest of the burst.
    @MainActor
    func scheduleScrollPresentationDrawIfNeeded() {
        guard hasSurfaceForScrollPresentationDraw() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if shouldThrottleImmediateScrollPresentationDraw(now: now) {
            scheduleNextScrollPresentationDrawPumpIfNeeded()
            return
        }
        guard scrollPresentationDrawPending == false else { return }
        scrollPresentationDrawPending = true
        let scheduledAt = now
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scrollPresentationDrawPending = false
                let drawUptime = ProcessInfo.processInfo.systemUptime
                self.noteScrollPresentationImmediateQueueDelayTelemetry(
                    scheduledAt: scheduledAt,
                    now: drawUptime
                )
                self.lastScrollPresentationDrawUptime = drawUptime
                self.performScrollPresentationDraw()
                self.scheduleScrollPresentationRecoveryProbeIfNeeded(forDrawAt: drawUptime)
                if self.shouldUseHostScrollPresentationContinuation(now: drawUptime) {
                    self.scheduleNextScrollPresentationDrawPumpIfNeeded()
                }
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    @MainActor
    func performScrollPresentationDraw() {
        noteScrollPresentationDrawTelemetry()
        performImmediatePresentationDraw()
    }

    @MainActor
    func shouldUseHostScrollPresentation(
        usesAlternateScroll: Bool,
        precision: Bool
    ) -> Bool {
        guard scrollCadenceMode == .legacyHybrid else { return false }
        return !(usesAlternateScroll && precision)
    }

    @MainActor
    func prefersImmediateDirtyDrawForRenderCallback(now: TimeInterval) -> Bool {
        guard let preciseAlternateScrollDirtyDrawEligibleUntilUptime else { return false }
        return now <= preciseAlternateScrollDirtyDrawEligibleUntilUptime
    }

    @MainActor
    private func performImmediatePresentationDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    /// Same-window pane retargets should keep the existing Ghostty surface alive.
    /// Schedule a coalesced immediate draw on the current surface so the view does
    /// not momentarily show a blank/black frame while tmux focus and sidebar state
    /// converge on the new pane.
    @MainActor
    func schedulePaneRetargetPresentationRefreshIfNeeded() {
        guard surface != nil else { return }
        guard paneRetargetPresentationDrawPending == false else { return }

        paneRetargetPresentationDrawPending = true
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.paneRetargetPresentationDrawPending = false
                let drawUptime = ProcessInfo.processInfo.systemUptime
                self.lastPaneRetargetPresentationDrawUptime = drawUptime
                self.performImmediatePresentationDraw()
                self.schedulePaneRetargetPresentationRecoveryProbeIfNeeded(forDrawAt: drawUptime)
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    @MainActor
    private func scheduleNextScrollPresentationDrawPumpIfNeeded() {
        guard scrollPresentationDrawPumpScheduled == false else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard shouldUseHostScrollPresentationContinuation(now: now) else { return }

        scrollPresentationDrawPumpScheduled = true
        scrollPresentationDrawPumpDueUptime =
            now + Self.scrollPresentationDrawPumpIntervalSeconds
        scheduleNextScrollPresentationContinuationWakeIfNeeded(now: now)
    }

    @MainActor
    private func scheduleScrollPresentationRecoveryProbeIfNeeded(forDrawAt drawUptime: TimeInterval) {
        guard scrollPresentationRecoveryProbeScheduled == false else { return }
        guard shouldUseHostScrollPresentationContinuation(now: drawUptime) else { return }

        scrollPresentationRecoveryProbeScheduled = true
        scrollPresentationRecoveryProbeDueUptime =
            drawUptime + Self.scrollPresentationDrawRecoveryProbeDelaySeconds
        scrollPresentationRecoveryProbeDrawUptime = drawUptime
        scheduleNextScrollPresentationContinuationWakeIfNeeded(now: drawUptime)
    }

    @MainActor
    private func scheduleNextScrollPresentationContinuationWakeIfNeeded(now: TimeInterval) {
        let nextDue = nextScrollPresentationContinuationDueUptime()
        guard let nextDue else {
            scrollPresentationContinuationScheduled = false
            scrollPresentationContinuationDueUptime = nil
            return
        }

        if scrollPresentationContinuationScheduled,
           let scheduledDue = scrollPresentationContinuationDueUptime,
           scheduledDue <= nextDue
        {
            return
        }

        scrollPresentationContinuationGeneration &+= 1
        let generation = scrollPresentationContinuationGeneration
        scrollPresentationContinuationScheduled = true
        scrollPresentationContinuationDueUptime = nextDue
        let delay = max(0, nextDue - now)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard generation == self.scrollPresentationContinuationGeneration else { return }
                let callbackNow = ProcessInfo.processInfo.systemUptime
                self.scrollPresentationContinuationScheduled = false
                self.scrollPresentationContinuationDueUptime = nil
                self.runScheduledScrollPresentationContinuationWake(now: callbackNow)
            }
        }
    }

    @MainActor
    private func nextScrollPresentationContinuationDueUptime() -> TimeInterval? {
        let pumpDue = scrollPresentationDrawPumpScheduled
            ? scrollPresentationDrawPumpDueUptime
            : nil
        let recoveryDue = scrollPresentationRecoveryProbeScheduled
            ? scrollPresentationRecoveryProbeDueUptime
            : nil

        switch (pumpDue, recoveryDue) {
        case let (pump?, recovery?):
            return min(pump, recovery)
        case let (pump?, nil):
            return pump
        case let (nil, recovery?):
            return recovery
        case (nil, nil):
            return nil
        }
    }

    @MainActor
    private func runScheduledScrollPresentationContinuationWake(now: TimeInterval) {
        let pumpWasDue: Bool
        if scrollPresentationDrawPumpScheduled,
           let scheduledFor = scrollPresentationDrawPumpDueUptime,
           scheduledFor <= now
        {
            pumpWasDue = true
            noteScrollPresentationDrawPumpWakeLatenessTelemetry(
                scheduledFor: scheduledFor,
                now: now
            )
            scrollPresentationDrawPumpScheduled = false
            scrollPresentationDrawPumpDueUptime = nil
        } else {
            pumpWasDue = false
        }

        let staleRecoveryDrawUptime: TimeInterval?
        let recoveryWasDue: Bool
        if scrollPresentationRecoveryProbeScheduled,
           let scheduledFor = scrollPresentationRecoveryProbeDueUptime,
           let drawUptime = scrollPresentationRecoveryProbeDrawUptime,
           scheduledFor <= now
        {
            recoveryWasDue = true
            staleRecoveryDrawUptime = drawUptime
            noteScrollPresentationRecoveryProbeWakeLatenessTelemetry(
                scheduledFor: scheduledFor,
                now: now
            )
            scrollPresentationRecoveryProbeScheduled = false
            scrollPresentationRecoveryProbeDueUptime = nil
            scrollPresentationRecoveryProbeDrawUptime = nil
        } else {
            recoveryWasDue = false
            staleRecoveryDrawUptime = nil
        }

        let pumpDrew: Bool
        if pumpWasDue {
            pumpDrew = runScrollPresentationDrawPumpPass(now: now)
        } else {
            pumpDrew = false
        }

        if recoveryWasDue,
           pumpDrew == false,
           let drawUptime = staleRecoveryDrawUptime
        {
            _ = runScrollPresentationRecoveryProbePass(drawUptime: drawUptime, now: now)
        }

        scheduleNextScrollPresentationContinuationWakeIfNeeded(now: now)
    }

    @MainActor
    private func schedulePaneRetargetPresentationRecoveryProbeIfNeeded(forDrawAt drawUptime: TimeInterval) {
        guard paneRetargetPresentationRecoveryProbeScheduled == false else { return }

        paneRetargetPresentationRecoveryProbeScheduled = true
        let generation = paneRetargetPresentationRecoveryProbeGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.scrollPresentationDrawRecoveryProbeDelaySeconds
        ) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard generation == self.paneRetargetPresentationRecoveryProbeGeneration else { return }
                self.paneRetargetPresentationRecoveryProbeScheduled = false
                guard self.lastPaneRetargetPresentationDrawUptime == drawUptime else { return }
                guard self.shouldRecoverDelayedScrollPresentation(afterDrawAt: drawUptime) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.lastPaneRetargetPresentationDrawUptime = now
                self.performImmediatePresentationDraw()
            }
        }
    }

    @MainActor
    private func runScrollPresentationDrawPumpPass(
        now: TimeInterval,
        reschedule: Bool = true
    ) -> Bool {
        guard shouldUseHostScrollPresentationContinuation(now: now) else {
            scrollPresentationDrawPumpScheduled = false
            scrollPresentationDrawPumpDueUptime = nil
            return false
        }

        lastScrollPresentationDrawUptime = now
        performScrollPresentationDraw()
        scheduleScrollPresentationRecoveryProbeIfNeeded(forDrawAt: now)
        if reschedule {
            scheduleNextScrollPresentationDrawPumpIfNeeded()
        }
        return true
    }

    @MainActor
    func runScrollPresentationRecoveryProbePassForTesting(
        drawUptime: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        runScrollPresentationRecoveryProbePass(drawUptime: drawUptime, now: now)
    }

    @MainActor
    private func runScrollPresentationRecoveryProbePass(
        drawUptime: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard shouldContinueScrollPresentationDrawPump(now: now) else { return false }
        guard drawUptime == lastScrollPresentationDrawUptime else { return false }
        guard shouldRecoverDelayedScrollPresentation(afterDrawAt: drawUptime) else { return false }

        lastScrollPresentationDrawUptime = now
        performScrollPresentationDraw()
        scheduleScrollPresentationRecoveryProbeIfNeeded(forDrawAt: now)
        if shouldUseHostScrollPresentationContinuation(now: now) {
            scheduleNextScrollPresentationDrawPumpIfNeeded()
        }
        return true
    }

    @MainActor
    private func shouldContinueScrollPresentationDrawPump(now: TimeInterval) -> Bool {
        guard hasSurfaceForScrollPresentationDraw(),
              let lastScrollInputUptime else { return false }
        return now - lastScrollInputUptime <= Self.scrollPresentationDrawPumpTailSeconds
    }

    @MainActor
    private func shouldUseHostScrollPresentationContinuation(now: TimeInterval) -> Bool {
        guard shouldContinueScrollPresentationDrawPump(now: now) else { return false }
        return isDirectScrollPresentationGestureActive(now: now) == false
    }

    @MainActor
    private func shouldThrottleImmediateScrollPresentationDraw(now: TimeInterval) -> Bool {
        guard isDirectScrollPresentationGestureActive(now: now) == false else { return false }
        guard shouldContinueScrollPresentationDrawPump(now: now),
              let lastScrollPresentationDrawUptime else { return false }
        guard now - lastScrollPresentationDrawUptime < Self.scrollPresentationDrawPumpIntervalSeconds,
              let lastLayerPresentUptime else { return false }
        // Only suppress another immediate draw after the last scroll draw has
        // actually produced a visible layer update.
        return lastLayerPresentUptime >= lastScrollPresentationDrawUptime
    }

    @MainActor
    private func shouldRecoverDelayedScrollPresentation(afterDrawAt drawUptime: TimeInterval) -> Bool {
        guard let lastLayerPresentUptime else { return true }
        return lastLayerPresentUptime < drawUptime
    }

    private func invalidateScrollPresentationDrawPump() {
        scrollPresentationDrawPending = false
        scrollPresentationContinuationScheduled = false
        scrollPresentationContinuationDueUptime = nil
        scrollPresentationDrawPumpScheduled = false
        scrollPresentationDrawPumpDueUptime = nil
        scrollPresentationRecoveryProbeScheduled = false
        scrollPresentationRecoveryProbeDueUptime = nil
        scrollPresentationRecoveryProbeDrawUptime = nil
        paneRetargetPresentationDrawPending = false
        paneRetargetPresentationRecoveryProbeScheduled = false
        lastScrollInputUptime = nil
        lastScrollPresentationDrawUptime = nil
        lastPaneRetargetPresentationDrawUptime = nil
        preciseAlternateScrollDirtyDrawEligibleUntilUptime = nil
        rendererOwnedRenderCallbackEligibleUntilUptime = nil
        scrollPresentationDirectGestureActive = false
        lastPreciseScrollVerticalDirection = nil
        scrollPresentationContinuationGeneration &+= 1
        paneRetargetPresentationRecoveryProbeGeneration &+= 1
    }

    @MainActor
    private func updateScrollPresentationGestureState(
        precision: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        verticalDelta: Double
    ) {
        if precision == false {
            scrollPresentationDirectGestureActive = false
            lastPreciseScrollVerticalDirection = nil
            return
        }

        let wasDirectGestureActive = scrollPresentationDirectGestureActive
        if Self.isTerminalScrollPhase(phase) {
            scrollPresentationDirectGestureActive = false
        } else if Self.isActiveDirectScrollPhase(phase) {
            scrollPresentationDirectGestureActive = true
        }

        let momentumBoundaryStarted = momentumPhase.contains(.began)

        let currentDirection = Self.verticalScrollDirection(for: verticalDelta)
        let directionFlipped = currentDirection.map { direction in
            guard let lastPreciseScrollVerticalDirection else { return false }
            guard lastPreciseScrollVerticalDirection != direction else { return false }
            return wasDirectGestureActive
                || Self.isActiveDirectScrollPhase(phase)
                || Self.isActiveMomentumScrollPhase(momentumPhase)
        } ?? false

        if (scrollPresentationDirectGestureActive && wasDirectGestureActive == false)
            || momentumBoundaryStarted
            || directionFlipped
        {
            invalidateScheduledScrollPresentationWakeupsForGestureBoundary()
        }

        if let currentDirection {
            lastPreciseScrollVerticalDirection = currentDirection
        } else if Self.isTerminalScrollPhase(phase), Self.isTerminalScrollPhase(momentumPhase) {
            lastPreciseScrollVerticalDirection = nil
        }
    }

    @MainActor
    private func isDirectScrollPresentationGestureActive(now: TimeInterval) -> Bool {
        guard scrollPresentationDirectGestureActive,
              let lastScrollInputUptime else { return false }
        return now - lastScrollInputUptime <= Self.scrollPresentationDrawPumpTailSeconds
    }

    @MainActor
    private func invalidateScheduledScrollPresentationWakeupsForGestureBoundary() {
        scrollPresentationContinuationScheduled = false
        scrollPresentationContinuationDueUptime = nil
        scrollPresentationDrawPumpScheduled = false
        scrollPresentationDrawPumpDueUptime = nil
        scrollPresentationRecoveryProbeScheduled = false
        scrollPresentationRecoveryProbeDueUptime = nil
        scrollPresentationRecoveryProbeDrawUptime = nil
        lastScrollPresentationDrawUptime = nil
        scrollPresentationContinuationGeneration &+= 1
    }

    @MainActor
    private func updatePreciseAlternateScrollDirtyDrawEligibility(
        usesAlternateScroll: Bool,
        precision: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        verticalDelta: Double,
        now: TimeInterval
    ) {
        guard usesAlternateScroll, precision else {
            preciseAlternateScrollDirtyDrawEligibleUntilUptime = nil
            return
        }

        let hasDirection = Self.verticalScrollDirection(for: verticalDelta) != nil
        let directActive = Self.isActiveDirectScrollPhase(phase)
        let momentumActive = Self.isActiveMomentumScrollPhase(momentumPhase)
        if hasDirection && (directActive || momentumActive) {
            preciseAlternateScrollDirtyDrawEligibleUntilUptime =
                now + Self.preciseAlternateScrollDirtyDrawFastPathTailSeconds
            return
        }

        if Self.isTerminalScrollPhase(phase), Self.isTerminalScrollPhase(momentumPhase) {
            preciseAlternateScrollDirtyDrawEligibleUntilUptime = nil
        }
    }

    @MainActor
    private func updateRendererOwnedRenderCallbackEligibility(
        usesAlternateScroll _: Bool,
        precision: Bool,
        verticalDelta: Double,
        now: TimeInterval
    ) {
        guard scrollCadenceMode == .ghosttyOwned,
              precision,
              abs(verticalDelta) > Self.scrollDirectionFlipEpsilon
        else {
            rendererOwnedRenderCallbackEligibleUntilUptime = nil
            return
        }

        rendererOwnedRenderCallbackEligibleUntilUptime =
            now + Self.rendererOwnedRenderCallbackTailSeconds
    }

    @MainActor
    func setRendererOwnedRenderCallbackEligibilityForTesting(
        usesAlternateScroll: Bool,
        precision: Bool,
        verticalDelta: Double,
        now: TimeInterval
    ) {
        updateRendererOwnedRenderCallbackEligibility(
            usesAlternateScroll: usesAlternateScroll,
            precision: precision,
            verticalDelta: verticalDelta,
            now: now
        )
    }

    private static func verticalScrollDirection(for deltaY: Double) -> ScrollVerticalDirection? {
        if deltaY > Self.scrollDirectionFlipEpsilon {
            return .up
        }
        if deltaY < -Self.scrollDirectionFlipEpsilon {
            return .down
        }
        return nil
    }

    private static func isActiveDirectScrollPhase(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.began) || phase.contains(.changed) || phase.contains(.stationary)
    }

    private static func isActiveMomentumScrollPhase(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.began) || phase.contains(.changed) || phase.contains(.stationary)
    }

    private static func isTerminalScrollPhase(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.ended) || phase.contains(.cancelled)
    }

    private static func precisionScrollMultiplier(
        usesAlternateScroll: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Double {
        if usesAlternateScroll {
            return 2.0
        }
        return 2.0
    }


    private func updateWindowObservers() {
        guard observedWindow !== window else { return }
        removeWindowObservers()
        observedWindow = window

        guard let window else { return }
        let center = NotificationCenter.default
        windowObserverTokens = [
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.syncSurfaceMetrics(shouldMarkDirty: true, force: true)
            },
            center.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.syncSurfaceMetrics(shouldMarkDirty: true)
            }
        ]
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObserverTokens {
            center.removeObserver(token)
        }
        windowObserverTokens.removeAll()
        observedWindow = nil
    }

    private func syncSurfaceMetrics(
        shouldMarkDirty: Bool,
        force: Bool = false
    ) {
        guard let metrics = currentSurfaceMetrics() else { return }
        applySurfaceMetricsIfNeeded(
            metrics,
            shouldMarkDirty: shouldMarkDirty,
            force: force
        )
    }

    private func applySurfaceFocusIfNeeded(force: Bool) {
        guard let surface else { return }
        guard force || appliedSurfaceFocus != desiredSurfaceFocus else { return }
        appliedSurfaceFocus = desiredSurfaceFocus
        ghostty_surface_set_focus(surface, desiredSurfaceFocus)
    }

    private func currentSurfaceMetrics() -> SurfaceMetrics? {
        guard hasSurfaceForMetricsSync(),
              let window else { return nil }

        let viewBounds = bounds
        let backingBounds = convertToBacking(viewBounds)
        let pixelWidth = UInt32(max(0, Int(backingBounds.width.rounded())))
        let pixelHeight = UInt32(max(0, Int(backingBounds.height.rounded())))
        let fallbackScale = Double(window.backingScaleFactor)
        let xScale = viewBounds.width > 0
            ? Double(backingBounds.width / viewBounds.width)
            : fallbackScale
        let yScale = viewBounds.height > 0
            ? Double(backingBounds.height / viewBounds.height)
            : fallbackScale
        return SurfaceMetrics(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            xScale: xScale,
            yScale: yScale,
            displayID: window.screen?.agtmuxDisplayID ?? 0
        )
    }

    private func applySurfaceMetricsIfNeeded(
        _ metrics: SurfaceMetrics,
        shouldMarkDirty: Bool,
        force: Bool = false
    ) {
        let previousMetrics = lastAppliedSurfaceMetrics
        guard force || previousMetrics != metrics else { return }
        lastAppliedSurfaceMetrics = metrics

        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        if force
            || previousMetrics?.xScale != metrics.xScale
            || previousMetrics?.yScale != metrics.yScale {
            updateSurfaceContentScale(
                xScale: metrics.xScale,
                yScale: metrics.yScale
            )
        }

        if force
            || previousMetrics?.pixelWidth != metrics.pixelWidth
            || previousMetrics?.pixelHeight != metrics.pixelHeight {
            updateSurfaceSize(
                pixelWidth: metrics.pixelWidth,
                pixelHeight: metrics.pixelHeight
            )
        }

        if force || previousMetrics?.displayID != metrics.displayID {
            updateSurfaceDisplayID(metrics.displayID)
        }

        if shouldMarkDirty {
            SurfacePool.shared.markDirty(view: self)
        }
    }

    @MainActor
    private func noteScrollInputTelemetry(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        precision: Bool = false,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        verticalDelta: Double = 0
    ) {
        if let lastScrollInputEventUptime {
            scrollInputGapSamplesMs.append((now - lastScrollInputEventUptime) * 1000.0)
        }
        if let scrollTelemetryResetUptime {
            let elapsedMs = (now - scrollTelemetryResetUptime) * 1000.0
            if firstScrollInputElapsedMs == nil {
                firstScrollInputElapsedMs = elapsedMs
            }
            if precision && firstPreciseScrollInputElapsedMs == nil {
                firstPreciseScrollInputElapsedMs = elapsedMs
            }
            if Self.isActiveDirectScrollPhase(phase) && firstDirectPhaseScrollInputElapsedMs == nil {
                firstDirectPhaseScrollInputElapsedMs = elapsedMs
            }
            if Self.isActiveMomentumScrollPhase(momentumPhase) && firstMomentumPhaseScrollInputElapsedMs == nil {
                firstMomentumPhaseScrollInputElapsedMs = elapsedMs
            }
        }
        lastScrollInputEventUptime = now
        scrollInputCount += 1
        if precision {
            preciseScrollInputCount += 1
        }
        if Self.isActiveDirectScrollPhase(phase) {
            directPhaseScrollInputCount += 1
        }
        if Self.isActiveMomentumScrollPhase(momentumPhase) {
            momentumPhaseScrollInputCount += 1
        }
        scrollInputVerticalDeltaAbsSamples.append(abs(verticalDelta))
        lastScrollInputUptime = now
        let renderID = AgtmuxSignpost.scrollLatency.makeSignpostID()
        let renderState = AgtmuxSignpost.scrollLatency.beginInterval(
            "scrollToRenderRequest",
            id: renderID
        )
        pendingScrollToRenderStates.append(renderState)
        pendingScrollToRenderUptimes.append(now)

        let drawID = AgtmuxSignpost.scrollLatency.makeSignpostID()
        let drawState = AgtmuxSignpost.scrollLatency.beginInterval(
            "scrollToFirstDraw",
            id: drawID
        )
        pendingScrollToDrawStates.append(drawState)
        pendingScrollToDrawUptimes.append(now)

        let layerPresentID = AgtmuxSignpost.scrollLatency.makeSignpostID()
        let layerPresentState = AgtmuxSignpost.scrollLatency.beginInterval(
            "scrollToLayerPresent",
            id: layerPresentID
        )
        pendingScrollToLayerPresentStates.append(layerPresentState)
        pendingScrollToLayerPresentUptimes.append(now)
    }

    @MainActor
    private func noteScrollInputExecutionTelemetry(
        handlerStartUptime: TimeInterval,
        dispatchStartUptime: TimeInterval,
        dispatchEndUptime: TimeInterval,
        handlerEndUptime: TimeInterval
    ) {
        scrollInputDispatchSamplesMs.append((dispatchEndUptime - dispatchStartUptime) * 1000.0)
        scrollInputHandlerSamplesMs.append((handlerEndUptime - handlerStartUptime) * 1000.0)
    }

    @MainActor
    private func noteLayerPresentationTelemetry() {
        let now = ProcessInfo.processInfo.systemUptime
        for state in pendingScrollToLayerPresentStates {
            AgtmuxSignpost.scrollLatency.endInterval("scrollToLayerPresent", state)
        }
        pendingScrollToLayerPresentStates.removeAll(keepingCapacity: true)
        for uptime in pendingScrollToLayerPresentUptimes {
            scrollToLayerPresentSamplesMs.append((now - uptime) * 1000.0)
        }
        pendingScrollToLayerPresentUptimes.removeAll(keepingCapacity: true)

        if let lastLayerPresentUptime {
            layerPresentGapSamplesMs.append((now - lastLayerPresentUptime) * 1000.0)
        }
        lastLayerPresentUptime = now
        layerPresentCount += 1
    }

    private func summary(for samples: [Double]) -> ScrollTelemetryMetricSummary {
        guard samples.isEmpty == false else {
            return ScrollTelemetryMetricSummary(count: 0, p50Ms: nil, p95Ms: nil, maxMs: nil)
        }

        let sorted = samples.sorted()
        return ScrollTelemetryMetricSummary(
            count: sorted.count,
            p50Ms: percentile(50, sortedSamples: sorted),
            p95Ms: percentile(95, sortedSamples: sorted),
            maxMs: sorted.last
        )
    }

    private func valueSummary(for samples: [Double]) -> ScrollTelemetryValueSummary {
        guard samples.isEmpty == false else {
            return ScrollTelemetryValueSummary(count: 0, p50: nil, p95: nil, max: nil)
        }

        let sorted = samples.sorted()
        return ScrollTelemetryValueSummary(
            count: sorted.count,
            p50: percentile(50, sortedSamples: sorted),
            p95: percentile(95, sortedSamples: sorted),
            max: sorted.last
        )
    }

    private func percentile(_ percentile: Double, sortedSamples: [Double]) -> Double {
        guard sortedSamples.isEmpty == false else { return .zero }
        let index = Int(ceil((percentile / 100.0) * Double(sortedSamples.count)) - 1.0)
        let boundedIndex = max(0, min(sortedSamples.count - 1, index))
        return sortedSamples[boundedIndex]
    }
}

private extension NSScreen {
    var agtmuxDisplayID: UInt32? {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
