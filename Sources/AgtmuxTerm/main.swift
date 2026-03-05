import AppKit
import SwiftUI
import GhosttyKit
import AgtmuxTermCore

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

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

// 0. Initialise Ghostty global state (allocator, logging, etc.) in normal runs.
//
// UI tests do not require real Ghostty surfaces; skipping init keeps launch stable
// under XCTest activation timing constraints.
if !isUITest {
    let ghosttyInitResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
    guard ghosttyInitResult == 0 else {
        fatalError("ghostty_init failed with code \(ghosttyInitResult)")
    }
    // Handle CLI subcommands (ghostty +inspect-config, etc.) if present.
    ghostty_cli_try_action()
}

// 1. Bootstrap NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 2. Initialise GhosttyApp singleton (triggers ghostty_app_new) for normal runs.
if !isUITest {
    _ = GhosttyApp.shared
}

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
    return vm
}

let uiTestTmuxBridge: UITestTmuxBridge? = MainActor.assumeIsolated {
    isUITest ? UITestTmuxBridge(viewModel: viewModel) : nil
}

// 4. Create WorkspaceStore with a default tab.
let workspaceStore: WorkspaceStore = MainActor.assumeIsolated {
    let store = WorkspaceStore()
    store.createTab()
    return store
}

let chromeState: CockpitChromeState = MainActor.assumeIsolated {
    CockpitChromeState()
}

// 5. Build the SwiftUI view hierarchy wrapped in NSHostingView.
let cockpit = CockpitView()
    .environmentObject(viewModel)
    .environment(workspaceStore)
    .environment(chromeState)

let hostingView = NonDraggableHostingView(rootView: cockpit)
hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 680)

// 5. Create the window.
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 1080, height: 680),
    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.title = ""
window.titleVisibility = .hidden
window.titlebarAppearsTransparent = true
window.isMovableByWindowBackground = false
window.isOpaque = false
window.backgroundColor = .clear
window.isRestorable = false
window.contentView = hostingView
window.makeKeyAndOrderFront(nil)

let windowChromeController: WindowChromeController = MainActor.assumeIsolated {
    let controller = WindowChromeController(
        chromeState: chromeState,
        viewModel: viewModel,
        workspaceStore: workspaceStore
    )
    controller.install(on: window)
    return controller
}
_ = windowChromeController

@MainActor
func forceForeground(_ app: NSApplication, window: NSWindow) {
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    app.activate(ignoringOtherApps: true)
}

// 6. Kick async startup once run loop is alive.
DispatchQueue.main.async {
    if let uiTestTmuxBridge {
        Task { await uiTestTmuxBridge.startIfNeeded() }
    }

    Task { await viewModel.fetchAll() }
    if !isUITest {
        viewModel.startPolling()
    }

    // XCTest may launch with dontMakeFrontmost=1. Re-activate after the
    // run loop starts so accessibility can attach to a foreground app.
    forceForeground(app, window: window)
    if isUITest {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            forceForeground(app, window: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            forceForeground(app, window: window)
        }
    }
}

// 6. Run the app event loop.
MainActor.assumeIsolated {
    forceForeground(app, window: window)
}
app.run()

if isUITest {
    _exit(0)
} else {
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
}
