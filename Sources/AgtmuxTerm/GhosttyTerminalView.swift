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
    private static let scrollPresentationDrawPumpIntervalSeconds = 1.0 / 90.0
    private static let scrollPresentationDrawPumpTailSeconds = 0.18

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

    struct ScrollTelemetrySnapshot: Codable, Equatable {
        let scrollToRenderRequest: ScrollTelemetryMetricSummary
        let scrollToFirstDraw: ScrollTelemetryMetricSummary
        let scrollToLayerPresent: ScrollTelemetryMetricSummary
        let renderRequestToDraw: ScrollTelemetryMetricSummary
        let drawGap: ScrollTelemetryMetricSummary
        let layerPresentGap: ScrollTelemetryMetricSummary
        let drawCount: Int
        let layerPresentCount: Int
        let pendingScrollToRenderCount: Int
        let pendingScrollToDrawCount: Int
        let pendingScrollToLayerPresentCount: Int
        let pendingRenderToDrawCount: Int
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
    private var scrollPresentationDrawPending = false
    private var scrollPresentationDrawPumpScheduled = false
    private var scrollPresentationDrawPumpGeneration: UInt64 = 0
    private var lastScrollInputUptime: TimeInterval?
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
    private var renderToDrawSamplesMs: [Double] = []
    private var drawGapSamplesMs: [Double] = []
    private var layerPresentGapSamplesMs: [Double] = []
    private var drawCount = 0
    private var layerPresentCount = 0
    private var lastHostDrawUptime: TimeInterval?
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
        guard let surface else { return }
        noteScrollInputTelemetry()
        // Pass deltas raw — Ghostty expects the same sign convention as
        // NSEvent.scrollingDeltaY (positive = up). Negating was inverting scroll.
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        // Match Ghostty's own SurfaceView: 2x multiplier for trackpad precision.
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.toScrollMods(event))
        scheduleScrollPresentationDrawIfNeeded()
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
        for state in pendingScrollToDrawStates {
            AgtmuxSignpost.scrollLatency.endInterval("scrollToFirstDraw", state)
        }
        pendingScrollToDrawStates.removeAll(keepingCapacity: true)
        for uptime in pendingScrollToDrawUptimes {
            scrollToDrawSamplesMs.append((now - uptime) * 1000.0)
        }
        pendingScrollToDrawUptimes.removeAll(keepingCapacity: true)

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
    func noteLayerPresentationTelemetryForTesting() {
        noteLayerPresentationTelemetry()
    }

    @MainActor
    func resetScrollTelemetryForTesting() {
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
        renderToDrawSamplesMs.removeAll(keepingCapacity: false)
        drawGapSamplesMs.removeAll(keepingCapacity: false)
        layerPresentGapSamplesMs.removeAll(keepingCapacity: false)
        drawCount = 0
        layerPresentCount = 0
        lastHostDrawUptime = nil
        lastLayerPresentUptime = nil
    }

    @MainActor
    func noteScrollInputTelemetryForTesting(now: TimeInterval? = nil) {
        noteScrollInputTelemetry(now: now ?? ProcessInfo.processInfo.systemUptime)
    }

    @MainActor
    func scrollTelemetrySnapshotForTesting() -> ScrollTelemetrySnapshot {
        ScrollTelemetrySnapshot(
            scrollToRenderRequest: summary(for: scrollToRenderSamplesMs),
            scrollToFirstDraw: summary(for: scrollToDrawSamplesMs),
            scrollToLayerPresent: summary(for: scrollToLayerPresentSamplesMs),
            renderRequestToDraw: summary(for: renderToDrawSamplesMs),
            drawGap: summary(for: drawGapSamplesMs),
            layerPresentGap: summary(for: layerPresentGapSamplesMs),
            drawCount: drawCount,
            layerPresentCount: layerPresentCount,
            pendingScrollToRenderCount: pendingScrollToRenderUptimes.count,
            pendingScrollToDrawCount: pendingScrollToDrawUptimes.count,
            pendingScrollToLayerPresentCount: pendingScrollToLayerPresentUptimes.count,
            pendingRenderToDrawCount: pendingRenderToDrawUptimes.count
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
    /// a full main-thread draw for every high-frequency trackpad event. A short-lived
    /// follow-up pump keeps draw cadence stable for the rest of the burst.
    @MainActor
    func scheduleScrollPresentationDrawIfNeeded() {
        guard hasSurfaceForScrollPresentationDraw() else { return }
        guard scrollPresentationDrawPending == false else { return }
        scrollPresentationDrawPending = true

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scrollPresentationDrawPending = false
                self.performScrollPresentationDraw()
                self.scheduleNextScrollPresentationDrawPumpIfNeeded()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    @MainActor
    func performScrollPresentationDraw() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    @MainActor
    private func scheduleNextScrollPresentationDrawPumpIfNeeded() {
        guard scrollPresentationDrawPumpScheduled == false else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard shouldContinueScrollPresentationDrawPump(now: now) else { return }

        scrollPresentationDrawPumpScheduled = true
        let generation = scrollPresentationDrawPumpGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.scrollPresentationDrawPumpIntervalSeconds
        ) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard generation == self.scrollPresentationDrawPumpGeneration else { return }
                self.scrollPresentationDrawPumpScheduled = false
                _ = self.runScrollPresentationDrawPumpPass(
                    now: ProcessInfo.processInfo.systemUptime
                )
            }
        }
    }

    @MainActor
    private func runScrollPresentationDrawPumpPass(
        now: TimeInterval,
        reschedule: Bool = true
    ) -> Bool {
        guard shouldContinueScrollPresentationDrawPump(now: now) else {
            scrollPresentationDrawPumpScheduled = false
            return false
        }

        performScrollPresentationDraw()
        if reschedule {
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
    private func invalidateScrollPresentationDrawPump() {
        scrollPresentationDrawPending = false
        scrollPresentationDrawPumpScheduled = false
        lastScrollInputUptime = nil
        scrollPresentationDrawPumpGeneration &+= 1
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
    private func noteScrollInputTelemetry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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
