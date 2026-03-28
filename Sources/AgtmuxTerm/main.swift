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
// Ghostty runtime bootstraps lazily on first visible surface attach so launch can
// reach foreground/key-window state before libghostty/Metal setup starts.
// ---------------------------------------------------------------------------

// XCUITest calls app.terminate() which sends SIGTERM.
// Without a custom handler NSApplication runs full teardown (Metal/Ghostty dealloc),
// which can take seconds and leaves the process in a "Running Background" zombie state
// that blocks the next test's launch(). Exit immediately on SIGTERM to avoid this race.
// The handler also terminates the daemon child process owned by this app instance.
let environment = ProcessInfo.processInfo.environment
let userDefaults = UserDefaults.standard
let isUITest = CommandLine.arguments.contains { $0.hasPrefix("-XCTest") }
    || UITestTmuxBridge.automationRequested(
        environment: environment,
        userDefaults: userDefaults
    )
let enableUITestPolling = isUITest && !UITestTmuxBridge.inventoryOnlyRequested(
    environment: environment,
    userDefaults: userDefaults
)
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
do {
    let orphanedPIDs = try TmuxControlModeProcessRegistry.reapOrphanedLocalControlModeProcessesIfNeeded()
    if !orphanedPIDs.isEmpty {
        fputs(
            "AgtmuxTerm: reaped \(orphanedPIDs.count) orphaned local tmux control-mode clients before startup.\n",
            stderr
        )
    }
} catch {
    fputs("AgtmuxTerm: failed to inspect orphaned local tmux control-mode clients: \(error)\n", stderr)
}
signal(SIGTERM, agtmuxTermSIGTERMHandler)

// 1. Bootstrap NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.finishLaunching()

// 2. Create AppViewModel and start daemon polling.
//
// main.swift top-level code always executes on the main thread, so using
// MainActor.assumeIsolated is correct and avoids forcing everything async.
let xpcClient: AgtmuxDaemonXPCClient? = useXPCDaemonService ? AgtmuxDaemonXPCClient() : nil
let daemonSupervisor = AgtmuxDaemonSupervisor()
let enableBroadPolling = !isUITest || enableUITestPolling
let enableLocalMetadataByDefault =
    environment["AGTMUX_ENABLE_LOCAL_METADATA"] == "1"
    || userDefaults.bool(forKey: "EnableLocalMetadata")
let uiTestBridgeRequested = UITestTmuxBridge.bridgeRequested(
    environment: environment,
    userDefaults: userDefaults
)

let interruptCleanupQueue = DispatchQueue(label: "local.agtmux.term.sigint-cleanup")
signal(SIGINT, SIG_IGN)
let interruptCleanupSource: DispatchSourceSignal = {
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: interruptCleanupQueue)
    source.setEventHandler {
        daemonSupervisor.stopIfOwned()

        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await TmuxControlModeProcessRegistry.shared.terminateTrackedProcesses()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 1.0)
        _exit(0)
    }
    source.resume()
    return source
}()
_ = interruptCleanupSource

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
            daemonSupervisor.startIfNeededAsync()
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
    localMetadataClient = PreferredLocalMetadataClient(
        primary: xpcClient,
        fallback: AgtmuxDaemonClient(),
        startFallbackRuntimeIfNeeded: {
            daemonSupervisor.startIfNeeded()
        },
        log: { message in
            fputs(message, stderr)
        }
    )
} else {
    localMetadataClient = AgtmuxDaemonClient()
}

let viewModel: AppViewModel = MainActor.assumeIsolated {
    let vm = AppViewModel(
        localClient: localMetadataClient,
        localMetadataProjectionMode: enableLocalMetadataByDefault ? .live : .inventoryOnly
    )
    return vm
}

let mainTerminalStore: MainTerminalStore = MainActor.assumeIsolated {
    MainTerminalStore()
}

let uiTestTmuxBridge: UITestTmuxBridge? = MainActor.assumeIsolated { () -> UITestTmuxBridge? in
    guard uiTestBridgeRequested else { return nil }
    return UITestTmuxBridge(
        viewModel: viewModel,
        mainTerminalStore: mainTerminalStore,
        enableMetadataMode: {
            viewModel.enableUITestMetadataMode()
            viewModel.enableLocalMetadataProjection()
            kickOffManagedDaemonBringUp()
            viewModel.startPolling()
        }
    )
}

let chromeState: CockpitChromeState = MainActor.assumeIsolated {
    CockpitChromeState()
}

let terminationCleanupObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: nil
) { _ in
    MainActor.assumeIsolated {
        viewModel.stopPolling()
    }

    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        await TmuxControlModeProcessRegistry.shared.terminateTrackedProcesses()
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 1.0)
}
_ = terminationCleanupObserver

// 4. Build the SwiftUI view hierarchy wrapped in NSHostingView.
let cockpit = CockpitView()
    .environmentObject(viewModel)
    .environment(viewModel.sidebarStore)
    .environment(viewModel.runtimeStore)
    .environment(viewModel.healthStore)
    .environment(mainTerminalStore)
    .environment(chromeState)

let hostingView = NonDraggableHostingView(rootView: cockpit)
hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

func forceWindowHostingPass(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    window.displayIfNeeded()
}

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
// Keep the host window opaque so the embedded Ghostty IOSurface is not forced
// through full-window blur/transparency composition during scroll.
window.isOpaque = true
window.backgroundColor = NSColor(
    calibratedRed: 0.04,
    green: 0.06,
    blue: 0.08,
    alpha: 1.0
)
window.isRestorable = false
window.contentView = hostingView
window.makeKeyAndOrderFront(nil)
forceWindowHostingPass(window)

let windowChromeController: WindowChromeController = MainActor.assumeIsolated {
    let controller = WindowChromeController(
        chromeState: chromeState,
        viewModel: viewModel,
        mainTerminalStore: mainTerminalStore
    )
    controller.install(on: window)
    return controller
}
_ = windowChromeController

@MainActor
func forceForeground(_ app: NSApplication, window: NSWindow) {
    app.unhide(nil)
    NSRunningApplication.current.unhide()
    forceWindowHostingPass(window)
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
            kickOffManagedDaemonBringUp: {
                if enableLocalMetadataByDefault {
                    kickOffManagedDaemonBringUp()
                }
            },
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
    }
    daemonSupervisor.stopIfOwned()
}
