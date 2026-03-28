import AppKit
import CoreFoundation
import GhosttyKit
import os

/// Singleton that owns the ghostty_app_t lifecycle.
///
/// Design constraints:
/// - wakeup_cb must be a @convention(c) function pointer (no captures).
///   We reference GhosttyApp.shared which is a static property and thus
///   not a closure capture in the C-function-pointer sense.
final class GhosttyApp {
    struct MetricSummary: Codable, Equatable {
        let count: Int
        let p50Ms: Double?
        let p95Ms: Double?
        let maxMs: Double?
    }

    struct SurfaceDrawTelemetrySnapshot: Codable, Equatable {
        let renderCallbackCount: Int
        let rendererFrameCompletedCount: Int
        let scheduledDirectDrawPassCount: Int
        let immediateDirectDrawPassCount: Int
        let dirtyDrawPassCount: Int
        let dirtyDrawnSurfaceCount: Int
        let ghosttyAppTickDuration: MetricSummary
        let dirtyDrawPassDuration: MetricSummary
    }

    static let shared = GhosttyApp()
    private static var initializedShared: GhosttyApp?
    @MainActor
    private static var runtimeBootstrapped = false
    private static let hostSignpostsEnabled =
        ProcessInfo.processInfo.environment["AGTMUX_HOST_SIGNPOSTS_ENABLED"] == "1"
    private static let surfaceDrawTelemetryStateLock = NSLock()
    private static var _surfaceDrawTelemetryEnabled =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["AGTMUX_SCROLL_TELEMETRY_ENABLED"] == "1"
    private static let rendererObservationStateLock = NSLock()
    private static var rendererFrameCompletedObservedSurfaces: Set<GhosttySurfaceHandle> = []
    private static var rendererFrameRequestedObservedSurfaces: Set<GhosttySurfaceHandle> = []

    typealias BridgeActionDispatcher = @MainActor (
        ghostty_target_s,
        ghostty_action_s
    ) throws -> GhosttyCLIOSCBridgeResult?
    typealias BridgeFailureReporter = @MainActor (Error) -> Void
    typealias BridgeMainActorObserver = @MainActor () -> Void

    private enum BridgeDispatchTarget: Sendable {
        case app
        case surface(GhosttySurfaceHandle)
        case unsupported(ghostty_target_tag_e)

        init(target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                self = .app
            case GHOSTTY_TARGET_SURFACE:
                if let rawSurface = target.target.surface {
                    self = .surface(GhosttySurfaceHandle(surface: rawSurface))
                } else {
                    self = .unsupported(target.tag)
                }
            default:
                self = .unsupported(target.tag)
            }
        }

        func ghosttyTarget() -> ghostty_target_s {
            switch self {
            case .app:
                return ghostty_target_s(
                    tag: GHOSTTY_TARGET_APP,
                    target: ghostty_target_u(surface: nil)
                )
            case .surface(let surfaceHandle):
                return ghostty_target_s(
                    tag: GHOSTTY_TARGET_SURFACE,
                    target: ghostty_target_u(
                        surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)
                    )
                )
            case .unsupported(let tag):
                return ghostty_target_s(
                    tag: tag,
                    target: ghostty_target_u(surface: nil)
                )
            }
        }
    }

    private struct OwnedCustomOSCDispatch: Sendable {
        let target: BridgeDispatchTarget
        let payload: Data
    }

    @MainActor
    private static var bridgeActionDispatcher: BridgeActionDispatcher = { target, action in
        try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
            target: target,
            action: action,
            registry: .shared
        )
    }

    @MainActor
    private static var bridgeFailureReporter: BridgeFailureReporter = { error in
        reportBridgeFailure(error)
    }

    @MainActor
    private static var bridgeMainActorObserver: BridgeMainActorObserver = {}
    @MainActor
    private static var directDrawScheduleObserver: @MainActor () -> Void = {}
    @MainActor
    private static var directDrawPassPending = false
    @MainActor
    private static var pendingSurfaceDrawGapState: OSSignpostIntervalState?
    @MainActor
    private static var renderCallbackCount = 0
    @MainActor
    private static var rendererFrameCompletedCount = 0
    @MainActor
    private static var scheduledDirectDrawPassCount = 0
    @MainActor
    private static var immediateDirectDrawPassCount = 0
    @MainActor
    private static var dirtyDrawPassCount = 0
    @MainActor
    private static var dirtyDrawnSurfaceCount = 0
    @MainActor
    private static var ghosttyAppTickDurationSamplesMs: [Double] = []
    @MainActor
    private static var dirtyDrawPassDurationSamplesMs: [Double] = []

    private(set) var app: ghostty_app_t?
    private var notificationObserverTokens: [NSObjectProtocol] = []
    private lazy var tickScheduler = GhosttyTickScheduler(
        scheduleOnMainRunLoop: Self.scheduleOnMainRunLoopCommonModes
    ) { [weak self] in
        self?.tick()
    }

    static var sharedIfInitialized: GhosttyApp? {
        initializedShared
    }

    @MainActor
    @discardableResult
    static func ensureSharedInitialized() -> GhosttyApp {
        if runtimeBootstrapped == false {
            let ghosttyInitResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard ghosttyInitResult == 0 else {
                fatalError("ghostty_init failed with code \(ghosttyInitResult)")
            }
            ghostty_cli_try_action()
            runtimeBootstrapped = true
        }
        return shared
    }

    private static func scheduleOnMainRunLoopCommonModes(
        _ action: @escaping @MainActor () -> Void
    ) {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                action()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private static func surfaceDrawTelemetryEnabledSnapshot() -> Bool {
        surfaceDrawTelemetryStateLock.lock()
        defer { surfaceDrawTelemetryStateLock.unlock() }
        return _surfaceDrawTelemetryEnabled
    }

    @MainActor
    private static func setSurfaceDrawTelemetryEnabled(_ enabled: Bool) {
        surfaceDrawTelemetryStateLock.lock()
        _surfaceDrawTelemetryEnabled = enabled
        surfaceDrawTelemetryStateLock.unlock()
    }

    static func setRendererFrameCompletedObservationEnabled(
        _ enabled: Bool,
        for surfaceHandle: GhosttySurfaceHandle
    ) {
        rendererObservationStateLock.lock()
        if enabled {
            rendererFrameCompletedObservedSurfaces.insert(surfaceHandle)
        } else {
            rendererFrameCompletedObservedSurfaces.remove(surfaceHandle)
        }
        rendererObservationStateLock.unlock()
    }

    static func setRendererFrameRequestedObservationEnabled(
        _ enabled: Bool,
        for surfaceHandle: GhosttySurfaceHandle
    ) {
        rendererObservationStateLock.lock()
        if enabled {
            rendererFrameRequestedObservedSurfaces.insert(surfaceHandle)
        } else {
            rendererFrameRequestedObservedSurfaces.remove(surfaceHandle)
        }
        rendererObservationStateLock.unlock()
    }

    private static func rendererFrameCompletedObservationEnabled(
        for surfaceHandle: GhosttySurfaceHandle
    ) -> Bool {
        rendererObservationStateLock.lock()
        defer { rendererObservationStateLock.unlock() }
        return rendererFrameCompletedObservedSurfaces.contains(surfaceHandle)
    }

    private static func rendererFrameRequestedObservationEnabled(
        for surfaceHandle: GhosttySurfaceHandle
    ) -> Bool {
        rendererObservationStateLock.lock()
        defer { rendererObservationStateLock.unlock() }
        return rendererFrameRequestedObservedSurfaces.contains(surfaceHandle)
    }

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
        let readClipboard: ghostty_runtime_read_clipboard_cb = { _, _, _ in false }
        let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }
        let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, _, _, _ in }
        let closeSurface: ghostty_runtime_close_surface_cb = { _, _ in }
        runtimeConfig.read_clipboard_cb = readClipboard
        runtimeConfig.confirm_read_clipboard_cb = confirmReadClipboard
        runtimeConfig.write_clipboard_cb = writeClipboard
        runtimeConfig.close_surface_cb = closeSurface
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

        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
            let center = NotificationCenter.default
            notificationObserverTokens = [
                center.addObserver(
                    forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard let app = self?.app else { return }
                    ghostty_app_keyboard_changed(app)
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard let app = self?.app else { return }
                    ghostty_app_set_focus(app, true)
                },
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard let app = self?.app else { return }
                    ghostty_app_set_focus(app, false)
                }
            ]
        }
    }

    @MainActor
    static func scheduleTickIfInitialized() {
        tickScheduleObserver()
        initializedShared?.enqueueTick()
    }

    @MainActor
    static func scheduleCoalescedTickIfInitialized() {
        tickScheduleObserver()
        _ = initializedShared?.tickScheduler.enqueueTickIfNeeded()
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
        case GHOSTTY_ACTION_RENDERER_FRAME_COMPLETED:
            return handleRendererFrameCompleted(target: target)
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
        let bridgeID = AgtmuxSignpost.ghosttyBridge.makeSignpostID()
        let bridgeState = AgtmuxSignpost.ghosttyBridge.beginInterval("customOSC", id: bridgeID)
        defer { AgtmuxSignpost.ghosttyBridge.endInterval("customOSC", bridgeState) }

        guard let dispatch = makeOwnedCustomOSCDispatch(target: target, action: action) else {
            return false
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                dispatchOwnedCustomOSC(dispatch)
            }
        }

        DispatchQueue.main.async {
            _ = dispatchOwnedCustomOSC(dispatch)
        }
        return true
    }

    private static func handleRender(target: ghostty_target_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let rawSurface = target.target.surface else { return true }
        let surfaceHandle = GhosttySurfaceHandle(surface: rawSurface)

        @MainActor
        func applyRenderCallback() {
            if surfaceDrawTelemetryEnabledSnapshot(),
               rendererFrameRequestedObservationEnabled(for: surfaceHandle) {
                renderCallbackCount += 1
                resolvedTerminalView(forSurfaceHandle: surfaceHandle)?
                    .noteRenderRequestTelemetry()
            }
            let resolvedView = resolvedTerminalView(forSurfaceHandle: surfaceHandle)
            let didMarkDirty: Bool
            if let resolvedView {
                didMarkDirty = SurfacePool.shared.markDirtyForDirectDraw(view: resolvedView)
            } else {
                didMarkDirty = SurfacePool.shared.markDirtyForDirectDraw(surfaceHandle: surfaceHandle)
            }
            guard didMarkDirty else {
                return
            }
            if runDirectDrawPassImmediatelyIfPossible() == false {
                scheduleDirectDrawPassIfNeeded()
            }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                applyRenderCallback()
            }
            return true
        }

        scheduleOnMainRunLoopCommonModes {
            applyRenderCallback()
        }
        return true
    }

    private static func handleRendererFrameCompleted(target: ghostty_target_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let rawSurface = target.target.surface else { return true }
        let surfaceHandle = GhosttySurfaceHandle(surface: rawSurface)
        guard rendererFrameCompletedObservationEnabled(for: surfaceHandle)
        else {
            return true
        }

        @MainActor
        func applyRendererFrameCompleted() {
            if surfaceDrawTelemetryEnabledSnapshot() {
                rendererFrameCompletedCount += 1
            }
            resolvedTerminalView(forSurfaceHandle: surfaceHandle)?
                .noteRendererFrameCompletedTelemetry()
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                applyRendererFrameCompleted()
            }
            return true
        }

        scheduleOnMainRunLoopCommonModes {
            applyRendererFrameCompleted()
        }
        return true
    }

    @MainActor
    private static func resolvedTerminalView(
        forSurfaceHandle surfaceHandle: GhosttySurfaceHandle
    ) -> GhosttyTerminalView? {
        if let context = GhosttyTerminalSurfaceRegistry.shared.context(forSurfaceHandle: surfaceHandle) {
            if let activeLeafID = TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forSurfaceID: context.surfaceID),
               let activeView = SurfacePool.shared.view(leafID: activeLeafID),
               SurfacePool.shared.isActive(view: activeView) {
                return activeView
            }

            if let activeSurfaceView = SurfacePool.shared.view(leafID: context.surfaceID),
               SurfacePool.shared.isActive(view: activeSurfaceView) {
                return activeSurfaceView
            }

            if let handleMappedView = SurfacePool.shared.view(forSurfaceHandle: surfaceHandle),
               SurfacePool.shared.isActive(view: handleMappedView) {
                return handleMappedView
            }

            if let activeLeafID = TerminalHostActiveSurfaceRegistry.shared.activeLeafID(forSurfaceID: context.surfaceID),
               let activeView = SurfacePool.shared.view(leafID: activeLeafID) {
                return activeView
            }

            if let surfaceView = SurfacePool.shared.view(leafID: context.surfaceID) {
                return surfaceView
            }

            return SurfacePool.shared.view(forSurfaceHandle: surfaceHandle)
        }

        if let handleMappedView = SurfacePool.shared.view(forSurfaceHandle: surfaceHandle),
           SurfacePool.shared.isActive(view: handleMappedView) {
            return handleMappedView
        }

        if let singleActiveView = SurfacePool.shared.singleActiveView() {
            return singleActiveView
        }

        return SurfacePool.shared.view(forSurfaceHandle: surfaceHandle)
    }

    @MainActor
    static func resolvedTerminalViewForTesting(
        surfaceHandle: GhosttySurfaceHandle
    ) -> GhosttyTerminalView? {
        resolvedTerminalView(forSurfaceHandle: surfaceHandle)
    }

    @MainActor
    @discardableResult
    static func dispatchRenderActionForTesting(
        surfaceHandle: GhosttySurfaceHandle
    ) -> Bool {
        handleRender(
            target: ghostty_target_s(
                tag: GHOSTTY_TARGET_SURFACE,
                target: ghostty_target_u(
                    surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)
                )
            )
        )
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
    static func withTestTickScheduleObserver<T>(
        _ observer: @escaping @MainActor () -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let originalObserver = tickScheduleObserver
        tickScheduleObserver = observer
        defer { tickScheduleObserver = originalObserver }
        return try await body()
    }

    @MainActor
    static func withTestDirectDrawScheduleObserver<T>(
        _ observer: @escaping @MainActor () -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        let originalObserver = directDrawScheduleObserver
        directDrawScheduleObserver = observer
        defer { directDrawScheduleObserver = originalObserver }
        return try body()
    }

    @MainActor
    static func withTestDirectDrawScheduleObserver<T>(
        _ observer: @escaping @MainActor () -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let originalObserver = directDrawScheduleObserver
        directDrawScheduleObserver = observer
        defer { directDrawScheduleObserver = originalObserver }
        return try await body()
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

    @MainActor
    static func resetSurfaceDrawTelemetryForTesting() {
        resetSurfaceDrawTelemetry(enableCollection: true)
    }

    @MainActor
    static func setSurfaceDrawTelemetryEnabledForTesting(_ enabled: Bool) {
        resetSurfaceDrawTelemetry(enableCollection: enabled)
    }

    @MainActor
    private static func resetSurfaceDrawTelemetry(enableCollection: Bool) {
        setSurfaceDrawTelemetryEnabled(enableCollection)
        pendingSurfaceDrawGapState = nil
        directDrawPassPending = false
        renderCallbackCount = 0
        rendererFrameCompletedCount = 0
        scheduledDirectDrawPassCount = 0
        immediateDirectDrawPassCount = 0
        dirtyDrawPassCount = 0
        dirtyDrawnSurfaceCount = 0
        ghosttyAppTickDurationSamplesMs = []
        dirtyDrawPassDurationSamplesMs = []
        rendererObservationStateLock.lock()
        rendererFrameCompletedObservedSurfaces.removeAll(keepingCapacity: false)
        rendererFrameRequestedObservedSurfaces.removeAll(keepingCapacity: false)
        rendererObservationStateLock.unlock()
    }

    @MainActor
    static func surfaceDrawTelemetrySnapshotForTesting() -> SurfaceDrawTelemetrySnapshot {
        SurfaceDrawTelemetrySnapshot(
            renderCallbackCount: renderCallbackCount,
            rendererFrameCompletedCount: rendererFrameCompletedCount,
            scheduledDirectDrawPassCount: scheduledDirectDrawPassCount,
            immediateDirectDrawPassCount: immediateDirectDrawPassCount,
            dirtyDrawPassCount: dirtyDrawPassCount,
            dirtyDrawnSurfaceCount: dirtyDrawnSurfaceCount,
            ghosttyAppTickDuration: summary(for: ghosttyAppTickDurationSamplesMs),
            dirtyDrawPassDuration: summary(for: dirtyDrawPassDurationSamplesMs)
        )
    }

    deinit {
        let center = NotificationCenter.default
        for token in notificationObserverTokens {
            center.removeObserver(token)
        }
        notificationObserverTokens.removeAll()
        if let app { ghostty_app_free(app) }
    }

    // MARK: - Tick

    @MainActor
    private func tick() {
        guard let app else { return }
        let tickState = Self.hostSignpostsEnabled
            ? AgtmuxSignpost.ghosttyTick.beginInterval(
                "tick",
                id: AgtmuxSignpost.ghosttyTick.makeSignpostID()
            )
            : nil
        defer {
            if let tickState {
                AgtmuxSignpost.ghosttyTick.endInterval("tick", tickState)
            }
        }
        tickExecutionDepth += 1
        defer { tickExecutionDepth -= 1 }
        let tickStart = ProcessInfo.processInfo.systemUptime
        ghostty_app_tick(app)
        let tickEnd = ProcessInfo.processInfo.systemUptime
        if Self.surfaceDrawTelemetryEnabledSnapshot() {
            Self.ghosttyAppTickDurationSamplesMs.append((tickEnd - tickStart) * 1000.0)
        }
        Self.runDirtyDrawPass()
    }

    @MainActor
    static func runDirtyDrawPassForTesting() {
        runDirtyDrawPass()
    }

    @MainActor
    private static func scheduleDirectDrawPassIfNeeded() {
        guard shouldScheduleTickOnMain() else { return }
        guard directDrawPassPending == false else { return }
        directDrawPassPending = true
        if surfaceDrawTelemetryEnabledSnapshot() {
            scheduledDirectDrawPassCount += 1
        }
        directDrawScheduleObserver()

        scheduleOnMainRunLoopCommonModes {
            directDrawPassPending = false
            runDirtyDrawPass()
        }
    }

    @MainActor
    @discardableResult
    private static func runDirectDrawPassImmediatelyIfPossible() -> Bool {
        guard shouldScheduleTickOnMain() else { return false }
        guard directDrawPassPending == false else { return false }
        if surfaceDrawTelemetryEnabledSnapshot() {
            immediateDirectDrawPassCount += 1
        }
        runDirtyDrawPass()
        return true
    }

    // MARK: - Surface Management

    /// Create a new ghostty surface for the given view and register it.
    ///
    /// - Parameters:
    ///   - view: The GhosttyTerminalView that will host this surface.
    ///   - command: Shell command string (e.g. "tmux attach-session -t main").
    ///              nil = default shell ($SHELL).
    /// - Returns: The new surface, or nil if ghostty_surface_new failed.
    @MainActor
    func newSurface(for view: GhosttyTerminalView,
                    command: String? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }
        guard let attachmentContext = view.surfaceAttachmentContext() else {
            return nil
        }

        // Inner builder; uses withCString scope for safe C-string lifetime.
        func build(_ cmd: UnsafePointer<CChar>?) -> ghostty_surface_t? {
            var cfg = ghostty_surface_config_s()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                )
            )
            cfg.scale_factor = attachmentContext.scaleFactor
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

        if let surface {
            ghostty_surface_set_display_id(surface, attachmentContext.displayID)
        }

        return surface
    }

    private func enqueueTick() {
        tickScheduler.enqueueTick()
    }

    @MainActor
    private static func runDirtyDrawPass() {
        let passStart = ProcessInfo.processInfo.systemUptime
        if surfaceDrawTelemetryEnabledSnapshot() {
            dirtyDrawPassCount += 1
        }
        let dirtyViews = SurfacePool.shared.consumeDirtyActiveSurfaceViews()
        defer {
            if surfaceDrawTelemetryEnabledSnapshot() {
                let passEnd = ProcessInfo.processInfo.systemUptime
                dirtyDrawPassDurationSamplesMs.append((passEnd - passStart) * 1000.0)
            }
        }

        guard dirtyViews.isEmpty == false else {
            SurfacePool.shared.recordDrawPassCount(0)
            return
        }

        var drawnSurfaceCount = 0
        for view in dirtyViews {
            let drawNow = ProcessInfo.processInfo.systemUptime
            recordSurfaceDrawGap()
            let drawState = Self.hostSignpostsEnabled
                ? AgtmuxSignpost.surfaceDraw.beginInterval(
                    "draw",
                    id: AgtmuxSignpost.surfaceDraw.makeSignpostID()
                )
                : nil
            view.triggerDirtyDrawForRenderCallback(now: drawNow)
            if let drawState {
                AgtmuxSignpost.surfaceDraw.endInterval("draw", drawState)
            }
            drawnSurfaceCount += 1
        }
        if surfaceDrawTelemetryEnabledSnapshot() {
            dirtyDrawnSurfaceCount += drawnSurfaceCount
        }
        SurfacePool.shared.recordDrawPassCount(drawnSurfaceCount)
    }

    @MainActor
    private static func shouldScheduleTickOnMain() -> Bool {
        if let override = tickExecutionOverrideForTesting {
            return override == false
        }
        return (initializedShared?.tickExecutionDepth ?? 0) == 0
    }

    @MainActor
    private static func recordSurfaceDrawGap() {
        guard hostSignpostsEnabled else {
            pendingSurfaceDrawGapState = nil
            return
        }
        if let pendingSurfaceDrawGapState {
            AgtmuxSignpost.surfaceDraw.endInterval("drawGap", pendingSurfaceDrawGapState)
        }

        let gapID = AgtmuxSignpost.surfaceDraw.makeSignpostID()
        pendingSurfaceDrawGapState = AgtmuxSignpost.surfaceDraw.beginInterval(
            "drawGap",
            id: gapID
        )
    }

    @MainActor
    private static func summary(for samples: [Double]) -> MetricSummary {
        guard samples.isEmpty == false else {
            return MetricSummary(count: 0, p50Ms: nil, p95Ms: nil, maxMs: nil)
        }

        let sorted = samples.sorted()
        return MetricSummary(
            count: sorted.count,
            p50Ms: percentile(50, sortedSamples: sorted),
            p95Ms: percentile(95, sortedSamples: sorted),
            maxMs: sorted.last
        )
    }

    @MainActor
    private static func percentile(_ percentile: Double, sortedSamples: [Double]) -> Double {
        guard sortedSamples.isEmpty == false else { return .zero }
        let index = Int(ceil((percentile / 100.0) * Double(sortedSamples.count)) - 1.0)
        let boundedIndex = max(0, min(sortedSamples.count - 1, index))
        return sortedSamples[boundedIndex]
    }

    private static func makeOwnedCustomOSCDispatch(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> OwnedCustomOSCDispatch? {
        guard action.tag == GHOSTTY_ACTION_CUSTOM_OSC else { return nil }
        let customOSC = action.action.custom_osc
        guard customOSC.osc == GhosttyCLIOSCBridge.command else { return nil }

        let payload: Data
        if customOSC.len == 0 {
            payload = Data()
        } else if let pointer = customOSC.payload {
            payload = Data(bytes: pointer, count: Int(customOSC.len))
        } else {
            payload = Data()
        }

        return OwnedCustomOSCDispatch(
            target: BridgeDispatchTarget(target: target),
            payload: payload
        )
    }

    @MainActor
    @discardableResult
    private static func dispatchOwnedCustomOSC(_ dispatch: OwnedCustomOSCDispatch) -> Bool {
        bridgeMainActorObserver()
        let target = dispatch.target.ghosttyTarget()
        let consumed = dispatch.payload.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            let customOSC = ghostty_action_custom_osc_s(
                osc: GhosttyCLIOSCBridge.command,
                payload: pointer,
                len: UInt(dispatch.payload.count)
            )
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_CUSTOM_OSC,
                action: ghostty_action_u(custom_osc: customOSC)
            )

            do {
                return try bridgeActionDispatcher(target, action) != nil
            } catch {
                bridgeFailureReporter(error)
                return true
            }
        }
        return consumed
    }
}
