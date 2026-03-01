import AppKit
import GhosttyKit

// ---------------------------------------------------------------------------
// T-005: Minimal NSApplication-based hello-world that renders a Ghostty terminal.
// ---------------------------------------------------------------------------

// 1. Bootstrap NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 2. Initialize GhosttyApp singleton (triggers ghostty_app_new).
//    This is a lazy static so accessing .shared is sufficient.
_ = GhosttyApp.shared

// 3. Create the terminal view.
let termView = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

// 4. Create a new surface for the default shell ($SHELL / login shell).
if let surface = GhosttyApp.shared.newSurface(for: termView, command: nil) {
    termView.attachSurface(surface)
} else {
    // Surface creation failure is fatal — surface not created means the
    // terminal cannot render. Exit with a non-zero code so CI/scripts notice.
    fputs("agtmux-term: ghostty_surface_new failed — cannot start terminal\n", stderr)
    exit(1)
}

// 5. Create the window.
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "agtmux-term"
window.contentView = termView
window.makeKeyAndOrderFront(nil)

// 6. Focus the terminal view so key events arrive immediately.
window.makeFirstResponder(termView)

// 7. Set focus on the surface.
if let surface = termView.surface {
    ghostty_surface_set_focus(surface, true)
}

// 8. Run the app event loop.
app.activate(ignoringOtherApps: true)
app.run()
