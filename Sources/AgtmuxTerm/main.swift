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
let enableUITestGhosttySurfaces = ProcessInfo.processInfo.environment["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] == "1"
let enableUITestPolling = isUITest
    && ProcessInfo.processInfo.environment["AGTMUX_UITEST_INVENTORY_ONLY"] != "1"
let requiresGhosttyRuntime = !isUITest || enableUITestGhosttySurfaces
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
if requiresGhosttyRuntime {
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
if requiresGhosttyRuntime {
    _ = GhosttyApp.shared
}

// 3. Create AppViewModel and start daemon polling.
//
// main.swift top-level code always executes on the main thread, so using
// MainActor.assumeIsolated is correct and avoids forcing everything async.
let xpcClient: AgtmuxDaemonXPCClient? = useXPCDaemonService ? AgtmuxDaemonXPCClient() : nil
let daemonSupervisor: AgtmuxDaemonSupervisor? = useXPCDaemonService ? nil : AgtmuxDaemonSupervisor()
let enableBroadPolling = !isUITest || enableUITestPolling

final class XPCManagedDaemonBringUpLauncher: @unchecked Sendable {
    private let xpcClient: AgtmuxDaemonXPCClient

    init(xpcClient: AgtmuxDaemonXPCClient) {
        self.xpcClient = xpcClient
    }

    func startIfNeeded() async {
        try? await xpcClient.startManagedDaemonIfNeeded()
    }
}

typealias DetachedAsyncLauncher = @Sendable (@escaping @Sendable () async -> Void) -> Void

func kickOffManagedDaemonBringUp(
    useXPCDaemonService: Bool,
    startXPCManagedDaemonIfNeeded: @escaping @Sendable () async -> Void,
    startManagedDaemonSupervisorIfNeededAsync: @escaping () -> Void,
    launchDetachedAsyncWork: @escaping DetachedAsyncLauncher = { operation in
        Task.detached(priority: .background) {
            await operation()
        }
    }
) {
    if useXPCDaemonService {
        launchDetachedAsyncWork(startXPCManagedDaemonIfNeeded)
    } else {
        startManagedDaemonSupervisorIfNeededAsync()
    }
}

let xpcManagedDaemonBringUpLauncher = xpcClient.map(XPCManagedDaemonBringUpLauncher.init)

func kickOffManagedDaemonBringUp() {
    kickOffManagedDaemonBringUp(
        useXPCDaemonService: xpcManagedDaemonBringUpLauncher != nil,
        startXPCManagedDaemonIfNeeded: {
            if let xpcManagedDaemonBringUpLauncher {
                await xpcManagedDaemonBringUpLauncher.startIfNeeded()
            }
        },
        startManagedDaemonSupervisorIfNeededAsync: {
            daemonSupervisor?.startIfNeededAsync()
        }
    )
}

func runStartupSequence(
    enableBroadPolling: Bool,
    initialSync: @escaping () async -> Void,
    kickOffManagedDaemonBringUp: @escaping () -> Void,
    startPolling: @escaping @MainActor () -> Void
) async {
    if enableBroadPolling {
        kickOffManagedDaemonBringUp()
    }

    await initialSync()

    if enableBroadPolling {
        await MainActor.run {
            startPolling()
        }
    }
}

let localMetadataClient: any ProductLocalMetadataClient
if let xpcClient {
    localMetadataClient = xpcClient
} else {
    localMetadataClient = AgtmuxDaemonClient()
}

let viewModel: AppViewModel = MainActor.assumeIsolated {
    let vm = AppViewModel(localClient: localMetadataClient)
    return vm
}

let uiTestTmuxBridge: UITestTmuxBridge? = MainActor.assumeIsolated {
    guard isUITest else { return nil }
    return UITestTmuxBridge(
        viewModel: viewModel,
        enableMetadataMode: {
            viewModel.enableUITestMetadataMode()
            kickOffManagedDaemonBringUp()
            viewModel.startPolling()
        }
    )
}

// 4. Create the Workbench V2 store for the normal cockpit path.
let workbenchStoreV2: WorkbenchStoreV2 = MainActor.assumeIsolated {
    do {
        return try WorkbenchStoreV2(
            env: ProcessInfo.processInfo.environment,
            persistence: isUITest ? nil : .live()
        )
    } catch {
        fatalError("WorkbenchStoreV2 init failed: \(error)")
    }
}

let chromeState: CockpitChromeState = MainActor.assumeIsolated {
    CockpitChromeState()
}

// 5. Build the SwiftUI view hierarchy wrapped in NSHostingView.
let cockpit = CockpitView()
    .environmentObject(viewModel)
    .environment(viewModel.sidebarStore)
    .environment(viewModel.runtimeStore)
    .environment(viewModel.healthStore)
    .environment(workbenchStoreV2)
    .environment(chromeState)

let hostingView = NonDraggableHostingView(rootView: cockpit)
hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

// 5. Create the window.
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
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
        workbenchStoreV2: workbenchStoreV2
    )
    controller.install(on: window)
    return controller
}
_ = windowChromeController

@MainActor
func forceForeground(_ app: NSApplication, window: NSWindow) {
    app.unhide(nil)
    NSRunningApplication.current.unhide()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    app.activate(ignoringOtherApps: true)
}

@MainActor
func sustainForegroundForUITest(
    _ app: NSApplication,
    window: NSWindow,
    remainingAttempts: Int = 24
) {
    forceForeground(app, window: window)
    guard remainingAttempts > 0 else { return }
    guard !app.isActive || !window.isKeyWindow else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        sustainForegroundForUITest(
            app,
            window: window,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

// 6. Kick async startup once run loop is alive.
DispatchQueue.main.async {
    Task {
        await runStartupSequence(
            enableBroadPolling: enableBroadPolling,
            initialSync: {
                if let uiTestTmuxBridge {
                    await uiTestTmuxBridge.startIfNeeded()
                } else {
                    await viewModel.performInitialSync()
                }
            },
            kickOffManagedDaemonBringUp: kickOffManagedDaemonBringUp,
            startPolling: {
                viewModel.startPolling()
            }
        )
    }

    // XCTest may launch with dontMakeFrontmost=1. Re-activate after the
    // run loop starts so accessibility can attach to a foreground app.
    forceForeground(app, window: window)
    if isUITest {
        sustainForegroundForUITest(app, window: window)
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
