import AppKit
import GhosttyKit

/// An NSView that hosts a Ghostty terminal surface rendered via Metal.
///
/// Responsibilities:
/// - Owns a ghostty_surface_t and frees it on deinit.
/// - Acts as a plain NSView; Ghostty uses layer-hosting (sets view.layer = IOSurfaceLayer
///   before wantsLayer = true). Do NOT override wantsLayer or makeBackingLayer.
/// - Routes keyboard, mouse, and scroll input to libghostty.
/// - Implements NSTextInputClient for IME (Japanese, Chinese, etc.).
class GhosttyTerminalView: NSView, NSTextInputClient {

    // MARK: - State

    private(set) var surface: ghostty_surface_t?
    private var drawCount = 0

    // MARK: - IME state

    private var markedText = NSMutableAttributedString()
    /// Text accumulated during a keyDown → interpretKeyEvents call.
    private var keyTextAccumulator = ""
    /// True while we are inside keyDown (i.e. interpretKeyEvents is running).
    private var inKeyDown = false

    // MARK: - Lifecycle

    deinit {
        // clearSurface() may have already freed the surface (SurfacePool GC path).
        // If surface is still non-nil, free it here.
        if let surface {
            ghostty_surface_free(surface)
        }
        releaseSurfaceFromApp()
    }

    /// Free the current surface and nil it out.
    ///
    /// Called by SurfacePool.gc() before releasing its strong reference.
    /// Sets surface = nil so deinit won't double-free.
    func clearSurface() {
        if let s = surface {
            ghostty_surface_free(s)
            releaseSurfaceFromApp()
            surface = nil
        }
    }

    /// Replace the current surface with a new one.
    ///
    /// Frees the old surface (if any), removes it from GhosttyApp.activeSurfaces,
    /// then installs the new surface and requests a redraw.
    func attachSurface(_ newSurface: ghostty_surface_t) {
        if let old = surface {
            ghostty_surface_free(old)
            releaseSurfaceFromApp()
        }
        surface = newSurface
        needsDisplay = true
    }

    func releaseSurfaceFromApp() {
        GhosttyApp.shared.releaseSurface(for: self)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_size(surface,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
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

    // MARK: - Draw

    /// Called by GhosttyApp.tick() on every wakeup to trigger Metal rendering.
    func triggerDraw() {
        guard let surface else { return }
        drawCount += 1
        if drawCount <= 3 {
            print("[triggerDraw] #\(drawCount) surface=\(surface)")
        }
        ghostty_surface_draw(surface)
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
            keyTextAccumulator += str
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

    func sendKeyToSurface(
        event: NSEvent,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = GhosttyInput.toGhosttyKey(event)
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

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let markedTextBefore = markedText.length > 0
        inKeyDown = true
        keyTextAccumulator = ""
        defer {
            inKeyDown = false
            keyTextAccumulator = ""
        }

        // AppKit text input must run before terminal key encoding so IME commit
        // cannot be pre-consumed as a raw Return/Enter key.
        interpretKeyEvents([event])
        syncPreeditToSurface(clearIfNeeded: markedTextBefore)

        if !keyTextAccumulator.isEmpty {
            sendText(keyTextAccumulator)
            return
        }

        _ = sendKeyToSurface(
            event: event,
            text: event.characters,
            composing: markedText.length > 0 || markedTextBefore
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func doCommand(by selector: Selector) {
        // `interpretKeyEvents` routes many non-text inputs here. We encode the final
        // terminal key after IME/text processing in `keyDown`, so this must not beep
        // or short-circuit composition/commit flows.
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
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
    }
}
