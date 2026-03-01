import AppKit
import QuartzCore
import GhosttyKit

/// An NSView that hosts a Ghostty terminal surface rendered via Metal.
///
/// Responsibilities:
/// - Owns a ghostty_surface_t and frees it on deinit.
/// - Exposes a CAMetalLayer as the backing layer for libghostty GPU rendering.
/// - Routes keyboard, mouse, and scroll input to libghostty.
/// - Implements NSTextInputClient for IME (Japanese, Chinese, etc.).
class GhosttyTerminalView: NSView, NSTextInputClient {

    // MARK: - State

    private(set) var surface: ghostty_surface_t?

    // MARK: - IME state

    private var markedText = NSMutableAttributedString()
    /// Text accumulated during a keyDown → interpretKeyEvents call.
    private var keyTextAccumulator = ""
    /// True while we are inside keyDown (i.e. interpretKeyEvents is running).
    private var inKeyDown = false

    // MARK: - Layer

    /// Force layer-backed rendering using CAMetalLayer.
    override var wantsLayer: Bool {
        get { true }
        set {}
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    // MARK: - Lifecycle

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
        GhosttyApp.shared.releaseSurface(for: self)
    }

    /// Replace the current surface with a new one.
    ///
    /// Frees the old surface (if any), removes it from GhosttyApp.activeSurfaces,
    /// then installs the new surface and requests a redraw.
    func attachSurface(_ newSurface: ghostty_surface_t) {
        if let old = surface {
            ghostty_surface_free(old)
            GhosttyApp.shared.releaseSurface(for: self)
        }
        surface = newSurface
        // libghostty renders directly into the CAMetalLayer that was passed as
        // nsview in ghostty_surface_config_s; no further setup is needed here.
        needsDisplay = true
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

    // MARK: - Draw

    /// Called by GhosttyApp.tick() on every wakeup to trigger Metal rendering.
    func triggerDraw() {
        guard let surface else { return }
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
        guard let surface else { return }
        str.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let attributed = string as? NSAttributedString {
            str = attributed.string
        } else {
            str = string as? String ?? ""
        }
        markedText = NSMutableAttributedString()
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

    func unmarkText() { markedText = NSMutableAttributedString() }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Text helper

    private func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        inKeyDown = true
        keyTextAccumulator = ""

        // ghostty_surface_key returns true when libghostty consumed the key
        // (e.g. keybinding). In that case we do NOT pass through to IME.
        var consumed = false
        if let surface {
            let key = GhosttyInput.toGhosttyKey(event)
            consumed = ghostty_surface_key(surface, key)
        }

        if !consumed {
            // Let the IME pipeline produce text via insertText(_:replacementRange:).
            interpretKeyEvents([event])
            if !keyTextAccumulator.isEmpty {
                sendText(keyTextAccumulator)
            }
        }

        inKeyDown = false
        keyTextAccumulator = ""
    }

    override var acceptsFirstResponder: Bool { true }

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
        ghostty_surface_mouse_scroll(surface,
                                      event.scrollingDeltaX,
                                      -event.scrollingDeltaY,
                                      GhosttyInput.toScrollMods(event))
    }
}
