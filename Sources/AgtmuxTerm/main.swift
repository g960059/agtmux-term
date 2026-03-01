import AppKit
import SwiftUI
import GhosttyKit

// ---------------------------------------------------------------------------
// Phase 2 entry point.
//
// Architecture:
//   NSApplication → NSWindow → NSHostingView<CockpitView>
//
// AppViewModel is injected as an EnvironmentObject so every SwiftUI descendant
// (SidebarView, FilterBarView, SessionRowView, TerminalPanel) can observe it.
//
// GhosttyApp singleton is initialised before the window is shown so that
// ghostty_app_new runs before any surface is created.
// ---------------------------------------------------------------------------

// 1. Bootstrap NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 2. Initialise GhosttyApp singleton (triggers ghostty_app_new).
_ = GhosttyApp.shared

// 3. Create AppViewModel and start daemon polling.
//
// main.swift top-level code always executes on the main thread, so using
// MainActor.assumeIsolated is correct and avoids forcing everything async.
let viewModel: AppViewModel = MainActor.assumeIsolated {
    let vm = AppViewModel()
    vm.startPolling()
    return vm
}

// 4. Build the SwiftUI view hierarchy wrapped in NSHostingView.
let cockpit = CockpitView()
    .environmentObject(viewModel)

let hostingView = NSHostingView(rootView: cockpit)
hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 680)

// 5. Create the window.
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 1080, height: 680),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "agtmux-term"
window.contentView = hostingView
window.makeKeyAndOrderFront(nil)

// 6. Run the app event loop.
app.activate(ignoringOtherApps: true)
app.run()
