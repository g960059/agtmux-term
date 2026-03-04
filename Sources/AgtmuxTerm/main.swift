import AppKit
import SwiftUI
import GhosttyKit
import AgtmuxTermCore

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

// 0. Initialise Ghostty global state (allocator, logging, etc.).
//
// ghostty_init() must be called before any other ghostty_* function.
// Specifically, ghostty_config_new() dereferences state.alloc which is
// set up here. Calling it out-of-order causes a null-pointer crash.
// Mirrors the pattern used in Ghostty's own pkg/macos/Sources/main.swift.

// XCUITest calls app.terminate() which sends SIGTERM.
// Without a custom handler NSApplication runs full teardown (Metal/Ghostty dealloc),
// which can take seconds and leaves the process in a "Running Background" zombie state
// that blocks the next test's launch(). Exit immediately on SIGTERM to avoid this race.
// The handler also terminates the daemon child process owned by this app instance.
let isUITest = CommandLine.arguments.contains { $0.hasPrefix("-XCTest") }
    || ProcessInfo.processInfo.environment["AGTMUX_UITEST"] == "1"
let xpcDisabled = ProcessInfo.processInfo.environment["AGTMUX_XPC_DISABLED"] == "1"
let xpcServiceBundled: Bool = {
    // SwiftPM (`swift run`) does not embed XPC services.
    // Only use NSXPCConnection(serviceName:) when running from a real .app bundle
    // that contains our service in Contents/XPCServices.
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else { return false }

    let serviceURL = bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("XPCServices")
        .appendingPathComponent("AgtmuxDaemonService.xpc")
    return FileManager.default.fileExists(atPath: serviceURL.path)
}()
let useXPCDaemonService = !isUITest && !xpcDisabled && xpcServiceBundled
if !isUITest && !xpcDisabled && !xpcServiceBundled {
    fputs("AgtmuxTerm: bundled XPC service not found; falling back to in-process daemon supervisor.\n", stderr)
}
signal(SIGTERM, agtmuxTermSIGTERMHandler)

let ghosttyInitResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard ghosttyInitResult == 0 else {
    fatalError("ghostty_init failed with code \(ghosttyInitResult)")
}
// Handle CLI subcommands (ghostty +inspect-config, etc.) if present.
// Skip when launched under XCUITest: XCUITest injects arguments like
// -XCTestSessionIdentifier that Ghostty's CLI parser may not return from.
if !isUITest {
    ghostty_cli_try_action()
}

// 1. Bootstrap NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 2. Initialise GhosttyApp singleton (triggers ghostty_app_new).
_ = GhosttyApp.shared

// 3. Create AppViewModel and start daemon polling.
//
// main.swift top-level code always executes on the main thread, so using
// MainActor.assumeIsolated is correct and avoids forcing everything async.
let xpcClient: AgtmuxDaemonXPCClient? = useXPCDaemonService ? AgtmuxDaemonXPCClient() : nil
let daemonSupervisor: AgtmuxDaemonSupervisor? = useXPCDaemonService ? nil : AgtmuxDaemonSupervisor()

if let xpcClient {
    Task { try? await xpcClient.startManagedDaemonIfNeeded() }
} else {
    daemonSupervisor?.startIfNeededAsync()
}

let localSnapshotClient: any LocalSnapshotClient
if let xpcClient {
    localSnapshotClient = xpcClient
} else {
    localSnapshotClient = AgtmuxDaemonClient()
}

let viewModel: AppViewModel = MainActor.assumeIsolated {
    let vm = AppViewModel(localClient: localSnapshotClient)
    vm.startPolling()
    return vm
}

// 4. Create WorkspaceStore with a default tab.
let workspaceStore: WorkspaceStore = MainActor.assumeIsolated {
    let store = WorkspaceStore()
    store.createTab(title: "Main")
    return store
}

// 5. Build the SwiftUI view hierarchy wrapped in NSHostingView.
let cockpit = CockpitView()
    .environmentObject(viewModel)
    .environment(workspaceStore)

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

if let xpcClient {
    let sema = DispatchSemaphore(value: 0)
    Task {
        await xpcClient.stopManagedDaemonIfOwned()
        await xpcClient.invalidate()
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 2.0)
} else {
    daemonSupervisor?.stopIfOwned()
}
