import AppKit
import GhosttyKit
import CoreFoundation

/// Singleton that owns the ghostty_app_t lifecycle.
///
/// Design constraints:
/// - wakeup_cb must be a @convention(c) function pointer (no captures).
///   We reference GhosttyApp.shared which is a static property and thus
///   not a closure capture in the C-function-pointer sense.
final class GhosttyApp {
    static let shared = GhosttyApp()
    private static var initializedShared: GhosttyApp?
    private static let schedulerExperimentDisabled =
        ProcessInfo.processInfo.environment["AGTMUX_GHOSTTY_SCHEDULER_EXPERIMENT_DISABLED"] == "1"

    typealias BridgeActionDispatcher = @MainActor (
        ghostty_target_s,
        ghostty_action_s
    ) throws -> GhosttyCLIOSCBridgeResult?
    typealias BridgeFailureReporter = @MainActor (Error) -> Void
    typealias BridgeMainActorObserver = @MainActor () -> Void

    @MainActor
    private static var bridgeActionDispatcher: BridgeActionDispatcher = { target, action in
        try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
            target: target,
            action: action,
            store: workbenchStoreV2,
            registry: .shared
        )
    }

    @MainActor
    private static var bridgeFailureReporter: BridgeFailureReporter = { error in
        reportBridgeFailure(error)
    }

    @MainActor
    private static var bridgeMainActorObserver: BridgeMainActorObserver = {}

    private(set) var app: ghostty_app_t?

    // Wakeup coalescing: prevents N queue items from accumulating when
    // libghostty fires wakeup_cb multiple times before tick() runs.
    private let wakeupLock = NSLock()
    private var wakeupPending = false
    @MainActor
    private var tickExecutionDepth = 0

    private init() {
        Self.initializedShared = self
        var runtimeConfig = ghostty_runtime_config_s()

        // Pass self as userdata (passUnretained — singleton, never deallocated).
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        // @convention(c) closure: no captures allowed.
        // GhosttyApp.shared is a static reference, not a capture.
        runtimeConfig.wakeup_cb = { _ in
            // libghostty calls this from an internal timer thread.
            GhosttyApp.shared.enqueueTick()
        }

        // action_cb is required by libghostty during surface init.
        runtimeConfig.action_cb = { app, target, action in
            GhosttyApp.handleAction(app, target: target, action: action)
        }
        // Clipboard callbacks: non-optional in Zig (*const fn), so nil → crash
        // if clipboard is ever accessed. Provide no-op stubs for MVP.
        runtimeConfig.read_clipboard_cb = { _, _, _ in }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.close_surface_cb = nil   // optional (?*const fn) — nil is safe
        runtimeConfig.supports_selection_clipboard = false

        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }

        // Mirror the loading sequence from Ghostty's own Ghostty.Config.loadConfig():
        //   1. load default files (~/.config/ghostty/config, etc.)
        //   2. load CLI args (skipped — we don't forward CLI args to Ghostty)
        //   3. load recursively-referenced files
        //   4. finalize — populates internal defaults; MUST be called before
        //      ghostty_app_new / ghostty_surface_new, otherwise surface creation
        //      reads uninitialized config fields and crashes.
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        app = ghostty_app_new(&runtimeConfig, config)
    }

    static func scheduleTickIfInitialized() {
        guard shouldScheduleTickOnMain() else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                tickScheduleObserver()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    tickScheduleObserver()
                }
            }
        }

        initializedShared?.enqueueTick()
    }

    // MARK: - Runtime callbacks

    /// Internal so integration tests can invoke the exact libghostty action callback seam.
    static func handleAction(_ app: ghostty_app_t?,
                             target: ghostty_target_s,
                             action: ghostty_action_s) -> Bool {
        _ = app

        // These are emitted during surface creation and can be safely ignored
        // in this embedding.
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE:
            return true

        // QUIT_TIMER fires when libghostty thinks all surfaces have closed and
        // wants to terminate the app. In our embedded design the host app
        // controls lifecycle, so we consume this action and do nothing.
        // Without this, libghostty falls back to NSApp.terminate() -> SIGTERM.
        //
        // SET_TITLE is also consumed. The host window hides the title text and uses
        // workspace tabs as the user-facing title surface, so terminal OSC/tmux
        // titles must never mutate NSWindow chrome.
        case GHOSTTY_ACTION_QUIT_TIMER:
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            return true
        case GHOSTTY_ACTION_RENDER:
            return handleRender(target: target)
        case GHOSTTY_ACTION_CUSTOM_OSC:
            return handleCustomOSC(target: target, action: action)

        default:
            break
        }

        return false
    }

    private static func handleCustomOSC(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        let runOnMain = {
            MainActor.assumeIsolated {
                bridgeMainActorObserver()

                do {
                    let result = try bridgeActionDispatcher(target, action)
                    return result != nil
                } catch {
                    bridgeFailureReporter(error)
                    return true
                }
            }
        }

        if Thread.isMainThread {
            return runOnMain()
        }

        return DispatchQueue.main.sync(execute: runOnMain)
    }

    private static func handleRender(target: ghostty_target_s) -> Bool {
        let runOnMain = {
            MainActor.assumeIsolated {
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let rawSurface = target.target.surface else { return true }
                SurfacePool.shared.markDirty(
                    surfaceHandle: GhosttySurfaceHandle(surface: rawSurface)
                )
                return true
            }
        }

        if Thread.isMainThread {
            return runOnMain()
        }

        return DispatchQueue.main.sync(execute: runOnMain)
    }

    /// Integration-test seam for the real action callback path.
    @MainActor
    static func withTestBridgeHooks<T>(
        dispatcher: @escaping BridgeActionDispatcher,
        failureReporter: @escaping BridgeFailureReporter,
        mainActorObserver: @escaping BridgeMainActorObserver = {},
        _ body: () async throws -> T
    ) async rethrows -> T {
        let originalDispatcher = bridgeActionDispatcher
        let originalFailureReporter = bridgeFailureReporter
        let originalMainActorObserver = bridgeMainActorObserver

        bridgeActionDispatcher = dispatcher
        bridgeFailureReporter = failureReporter
        bridgeMainActorObserver = mainActorObserver

        defer {
            bridgeActionDispatcher = originalDispatcher
            bridgeFailureReporter = originalFailureReporter
            bridgeMainActorObserver = originalMainActorObserver
        }

        return try await body()
    }

    @MainActor
    private static func reportBridgeFailure(_ error: Error) {
        let message = "AgtmuxTerm CLI bridge failure: \(error)"
        fputs(message + "\n", stderr)
        assertionFailure(message)
    }

    @MainActor
    private static var tickScheduleObserver: @MainActor () -> Void = {}

    @MainActor
    private static var tickExecutionOverrideForTesting: Bool?

    @MainActor
    static func withTestTickScheduleObserver<T>(
        _ observer: @escaping @MainActor () -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        let originalObserver = tickScheduleObserver
        tickScheduleObserver = observer
        defer { tickScheduleObserver = originalObserver }
        return try body()
    }

    @MainActor
    static func withTestTickExecutionState<T>(
        _ isExecuting: Bool,
        _ body: () throws -> T
    ) rethrows -> T {
        let originalOverride = tickExecutionOverrideForTesting
        tickExecutionOverrideForTesting = isExecuting
        defer { tickExecutionOverrideForTesting = originalOverride }
        return try body()
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }

    // MARK: - Tick

    @MainActor
    private func tick() {
        guard let app else { return }
        let tickID = AgtmuxSignpost.ghosttyTick.makeSignpostID()
        let tickState = AgtmuxSignpost.ghosttyTick.beginInterval("tick", id: tickID)
        defer { AgtmuxSignpost.ghosttyTick.endInterval("tick", tickState) }
        wakeupLock.lock()
        wakeupPending = false
        wakeupLock.unlock()
        tickExecutionDepth += 1
        defer { tickExecutionDepth -= 1 }
        ghostty_app_tick(app)
        Self.runDirtyDrawPass()
    }

    @MainActor
    static func runDirtyDrawPassForTesting() {
        runDirtyDrawPass()
    }

    // MARK: - Surface Management

    /// Create a new ghostty surface for the given view and register it.
    ///
    /// - Parameters:
    ///   - view: The GhosttyTerminalView that will host this surface.
    ///   - command: Shell command string (e.g. "tmux attach-session -t main").
    ///              nil = default shell ($SHELL).
    /// - Returns: The new surface, or nil if ghostty_surface_new failed.
    func newSurface(for view: GhosttyTerminalView,
                    command: String? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }

        // Inner builder; uses withCString scope for safe C-string lifetime.
        func build(_ cmd: UnsafePointer<CChar>?) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_s()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                )
            )
            cfg.scale_factor = Double(
                view.window?.backingScaleFactor
                    ?? view.window?.screen?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 1.0
            )
            cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
            cfg.command = cmd       // nil → default shell
            cfg.font_size = 0       // 0 = use Ghostty config default
            cfg.working_directory = nil
            cfg.env_vars = nil
            cfg.env_var_count = 0
            cfg.initial_input = nil
            cfg.wait_after_command = false
            return ghostty_surface_new(app, &cfg)
        }

        let surface: ghostty_surface_t?
        if let command {
            surface = command.withCString { build($0) }
        } else {
            surface = build(nil)
        }

        return surface
    }

    private func enqueueTick() {
        wakeupLock.lock()
        let shouldSchedule = !wakeupPending
        wakeupPending = true
        wakeupLock.unlock()
        guard shouldSchedule else { return }

        if Self.schedulerExperimentDisabled {
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
            return
        }

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                GhosttyApp.shared.tick()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    @MainActor
    private static func runDirtyDrawPass() {
        let dirtyViews = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        guard dirtyViews.isEmpty == false else {
            SurfacePool.shared.recordDrawPassCount(0)
            return
        }

        var drawnSurfaceCount = 0
        for view in dirtyViews {
            let drawID = AgtmuxSignpost.surfaceDraw.makeSignpostID()
            let drawState = AgtmuxSignpost.surfaceDraw.beginInterval("draw", id: drawID)
            view.triggerDraw()
            AgtmuxSignpost.surfaceDraw.endInterval("draw", drawState)
            drawnSurfaceCount += 1
        }
        SurfacePool.shared.recordDrawPassCount(drawnSurfaceCount)
    }

    private static func shouldScheduleTickOnMain() -> Bool {
        let runOnMain = {
            MainActor.assumeIsolated {
                if let override = tickExecutionOverrideForTesting {
                    return override == false
                }
                return (initializedShared?.tickExecutionDepth ?? 0) == 0
            }
        }

        if Thread.isMainThread {
            return runOnMain()
        }

        return DispatchQueue.main.sync(execute: runOnMain)
    }
}
