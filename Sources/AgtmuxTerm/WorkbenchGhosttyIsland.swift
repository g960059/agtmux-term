import SwiftUI
import AppKit
import AgtmuxTermCore

// MARK: - GhosttyIslandRepresentable

@MainActor
final class GhosttyIslandUpdateTelemetry {
    struct Snapshot: Codable, Equatable {
        let updateCount: Int
        let commandChangeCount: Int
        let surfaceContextChangeCount: Int
        let focusChangeCount: Int
        let focusRestoreChangeCount: Int
        let applyCommandCount: Int
        let paneRetargetRefreshCount: Int
        let retryCount: Int
    }

    private struct State {
        var updateCount = 0
        var commandChangeCount = 0
        var surfaceContextChangeCount = 0
        var focusChangeCount = 0
        var focusRestoreChangeCount = 0
        var applyCommandCount = 0
        var paneRetargetRefreshCount = 0
        var retryCount = 0
    }

    static let shared = GhosttyIslandUpdateTelemetry()

    private var statesByTileID: [UUID: State] = [:]

    func recordUpdate(
        tileID: UUID,
        commandChanged: Bool,
        surfaceContextChanged: Bool,
        focusStateChanged: Bool,
        focusRestoreChanged: Bool
    ) {
        var state = statesByTileID[tileID] ?? State()
        state.updateCount += 1
        if commandChanged { state.commandChangeCount += 1 }
        if surfaceContextChanged { state.surfaceContextChangeCount += 1 }
        if focusStateChanged { state.focusChangeCount += 1 }
        if focusRestoreChanged { state.focusRestoreChangeCount += 1 }
        statesByTileID[tileID] = state
    }

    func recordApplyCommand(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.applyCommandCount += 1
        statesByTileID[tileID] = state
    }

    func recordPaneRetargetRefresh(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.paneRetargetRefreshCount += 1
        statesByTileID[tileID] = state
    }

    func recordRetry(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.retryCount += 1
        statesByTileID[tileID] = state
    }

    func reset(tileID: UUID) {
        statesByTileID[tileID] = State()
    }

    func snapshot(tileID: UUID) -> Snapshot {
        let state = statesByTileID[tileID] ?? State()
        return Snapshot(
            updateCount: state.updateCount,
            commandChangeCount: state.commandChangeCount,
            surfaceContextChangeCount: state.surfaceContextChangeCount,
            focusChangeCount: state.focusChangeCount,
            focusRestoreChangeCount: state.focusRestoreChangeCount,
            applyCommandCount: state.applyCommandCount,
            paneRetargetRefreshCount: state.paneRetargetRefreshCount,
            retryCount: state.retryCount
        )
    }
}

/// AppKit island that hosts a GhosttyTerminalView inside an NSViewController.
///
/// SwiftUI recomposition does NOT propagate into the view controller's view hierarchy,
/// which prevents sidebar inventory updates from triggering Metal draw calls.
/// All communication happens through value-type parameters only — no @EnvironmentObject.
struct GhosttyIslandRepresentable: NSViewControllerRepresentable, Equatable {
    let surfaceID: UUID
    let poolKey: String
    let attachCommand: String?
    let surfaceContext: GhosttyTerminalSurfaceContext?
    let visiblePaneIdentity: String?
    let isFocused: Bool
    let focusRestoreNonce: UInt64

    func makeNSViewController(context: Context) -> GhosttyIslandViewController {
        GhosttyIslandViewController(
            surfaceID: surfaceID,
            poolKey: poolKey,
            attachCommand: attachCommand,
            surfaceContext: surfaceContext,
            visiblePaneIdentity: visiblePaneIdentity
        )
    }

    func updateNSViewController(_ controller: GhosttyIslandViewController, context: Context) {
        controller.update(
            attachCommand: attachCommand,
            surfaceContext: surfaceContext,
            visiblePaneIdentity: visiblePaneIdentity,
            isFocused: isFocused,
            focusRestoreNonce: focusRestoreNonce
        )
    }
}

// MARK: - GhosttyIslandViewController

@MainActor
final class GhosttyIslandViewController: NSViewController {
    nonisolated static func shouldSchedulePaneRetargetPresentationRefresh(
        previousVisiblePaneIdentity: String?,
        nextVisiblePaneIdentity: String?,
        commandChanged: Bool
    ) -> Bool {
        guard commandChanged == false else { return false }
        guard previousVisiblePaneIdentity != nextVisiblePaneIdentity else { return false }
        return nextVisiblePaneIdentity != nil
    }

    // MARK: Init params
    private let surfaceID: UUID
    private let poolKey: String
    private var pendingAttachCommand: String?
    private var pendingSurfaceContext: GhosttyTerminalSurfaceContext?
    private var visiblePaneIdentity: String?

    // MARK: Coordinator state (mirrors GhosttySurfaceHostView.Coordinator)
    private var currentCommand: String?
    private var registeredSurfaceHandle: GhosttySurfaceHandle?
    private var registeredSurfaceContext: GhosttyTerminalSurfaceContext?
    private var lastAppliedFocus: Bool?
    private var lastFocusRestoreNonce: UInt64?
    private var pendingAttachRetryCommand: String?
    private var pendingAttachRetryWorkItem: DispatchWorkItem?

    private var terminalView: GhosttyTerminalView?

    init(
        surfaceID: UUID,
        poolKey: String,
        attachCommand: String?,
        surfaceContext: GhosttyTerminalSurfaceContext?,
        visiblePaneIdentity: String?
    ) {
        self.surfaceID = surfaceID
        self.poolKey = poolKey
        self.pendingAttachCommand = attachCommand
        self.pendingSurfaceContext = surfaceContext
        self.visiblePaneIdentity = visiblePaneIdentity
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - NSViewController lifecycle

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.setAccessibilityElement(false)
        let tv = GhosttyTerminalView()
        if let pendingSurfaceContext {
            tv.configureAccessibility(
                identifier: AccessibilityID.workspaceTerminalHostPrefix + pendingSurfaceContext.tileID.uuidString,
                label: "Terminal \(pendingSurfaceContext.sessionRef.sessionName)"
            )
        }
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        view.setAccessibilityChildren([tv])
        tv.setAccessibilityParent(view)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.topAnchor.constraint(equalTo: view.topAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.terminalView = tv

        // Apply the first attach command if available
        if let cmd = pendingAttachCommand {
            applyCommandIfPossible(cmd, surfaceContext: pendingSurfaceContext)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Retry attach once the view is in a window (needed for surface creation)
        if let cmd = pendingAttachCommand, currentCommand != cmd {
            applyCommandIfPossible(cmd, surfaceContext: pendingSurfaceContext)
        }
    }

    func hostContainerDidAttachVisibleView() {
        guard let terminalView else { return }
        guard terminalView.surface == nil else { return }
        guard let command = pendingAttachCommand ?? currentCommand else { return }
        applyCommandIfPossible(
            command,
            surfaceContext: pendingSurfaceContext ?? registeredSurfaceContext
        )
    }

    // MARK: - Update from SwiftUI

    func update(
        attachCommand cmd: String?,
        surfaceContext: GhosttyTerminalSurfaceContext?,
        visiblePaneIdentity: String?,
        isFocused: Bool,
        focusRestoreNonce: UInt64
    ) {
        let commandChanged = currentCommand != cmd
        let previousVisiblePaneIdentity = self.visiblePaneIdentity

        if commandChanged {
            lastAppliedFocus = nil
            cancelPendingRetry()
            if let cmd {
                applyCommandIfPossible(cmd, surfaceContext: surfaceContext)
            } else {
                currentCommand = nil
            }
        }

        self.visiblePaneIdentity = visiblePaneIdentity
        if Self.shouldSchedulePaneRetargetPresentationRefresh(
            previousVisiblePaneIdentity: previousVisiblePaneIdentity,
            nextVisiblePaneIdentity: visiblePaneIdentity,
            commandChanged: commandChanged
        ) {
            terminalView?.schedulePaneRetargetPresentationRefreshIfNeeded()
            GhosttyIslandUpdateTelemetry.shared.recordPaneRetargetRefresh(tileID: surfaceID)
        }

        // Update surface context registration if it changed
        let surfaceContextChanged = registeredSurfaceContext != surfaceContext
        if surfaceContextChanged,
           let surfaceContext,
           let terminalView {
            terminalView.configureAccessibility(
                identifier: AccessibilityID.workspaceTerminalHostPrefix + surfaceContext.tileID.uuidString,
                label: "Terminal \(surfaceContext.sessionRef.sessionName)"
            )
        }
        if surfaceContextChanged,
           let surfaceContext,
           let registeredSurfaceHandle,
           registeredSurfaceContext != surfaceContext {
            GhosttyTerminalSurfaceRegistry.shared.register(
                surfaceHandle: registeredSurfaceHandle,
                context: surfaceContext,
                attachCommand: cmd ?? currentCommand ?? ""
            )
            registeredSurfaceContext = surfaceContext
        }

        // Apply focus changes
        let focusStateChanged = lastAppliedFocus != isFocused
        let focusRestoreChanged = lastFocusRestoreNonce != focusRestoreNonce
        GhosttyIslandUpdateTelemetry.shared.recordUpdate(
            tileID: surfaceID,
            commandChanged: commandChanged,
            surfaceContextChanged: surfaceContextChanged,
            focusStateChanged: focusStateChanged,
            focusRestoreChanged: focusRestoreChanged
        )
        guard focusStateChanged || (isFocused && focusRestoreChanged) else { return }
        lastAppliedFocus = isFocused
        lastFocusRestoreNonce = focusRestoreNonce
        if isFocused {
            SurfacePool.shared.activate(leafID: surfaceID)
            if let tv = terminalView { tv.window?.makeFirstResponder(tv) }
        } else {
            SurfacePool.shared.background(leafID: surfaceID)
        }
    }

    // MARK: - Teardown

    deinit {
        // Schedule cleanup on main actor since deinit may run on any thread
        let capturedSurfaceID = surfaceID
        let capturedHandle = registeredSurfaceHandle
        let capturedView = terminalView
        let capturedViewID = terminalView.map(ObjectIdentifier.init)
        let capturedWorkItem = pendingAttachRetryWorkItem

        capturedWorkItem?.cancel()

        Task { @MainActor in
            if let handle = capturedHandle {
                GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: handle)
            } else if let surface = capturedView?.surface {
                GhosttyTerminalSurfaceRegistry.shared.unregister(surface: surface)
            }
            SurfacePool.shared.release(
                leafID: capturedSurfaceID,
                expectedViewID: capturedViewID
            )
        }
    }

    // MARK: - Private helpers

    private func applyCommandIfPossible(_ command: String, surfaceContext: GhosttyTerminalSurfaceContext?) {
        guard let tv = terminalView else {
            // viewDidLoad hasn't run yet; store for later
            pendingAttachCommand = command
            pendingSurfaceContext = surfaceContext
            return
        }
        guard tv.window != nil else {
            scheduleRetry(for: command, surfaceContext: surfaceContext)
            return
        }

        guard let surface = GhosttyApp.shared.newSurface(for: tv, command: command) else {
            scheduleRetry(for: command, surfaceContext: surfaceContext)
            return
        }

        let previousHandle = registeredSurfaceHandle
        let surfaceHandle = GhosttySurfaceHandle(surface: surface)

        if let previousHandle {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: previousHandle)
        } else if let existingSurface = tv.surface {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surface: existingSurface)
        }

        tv.attachSurface(surface)
        SurfacePool.shared.register(
            view: tv,
            leafID: surfaceID,
            tmuxPaneID: poolKey,
            surfaceHandle: surfaceHandle
        )

        if let surfaceContext {
            GhosttyTerminalSurfaceRegistry.shared.register(
                surfaceHandle: surfaceHandle,
                context: surfaceContext,
                attachCommand: command
            )
            registeredSurfaceHandle = surfaceHandle
            registeredSurfaceContext = surfaceContext
        } else {
            registeredSurfaceHandle = nil
            registeredSurfaceContext = nil
        }

        currentCommand = command
        GhosttyIslandUpdateTelemetry.shared.recordApplyCommand(tileID: surfaceID)
        pendingAttachCommand = nil
        pendingSurfaceContext = nil
        cancelPendingRetry()
    }

    private func scheduleRetry(for command: String, surfaceContext: GhosttyTerminalSurfaceContext?) {
        guard currentCommand != command else { return }
        guard pendingAttachRetryCommand != command else { return }

        cancelPendingRetry()
        pendingAttachRetryCommand = command
        GhosttyIslandUpdateTelemetry.shared.recordRetry(tileID: surfaceID)

        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentCommand != command else { return }
            self.applyCommandIfPossible(command, surfaceContext: surfaceContext)
        }
        pendingAttachRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    private func cancelPendingRetry() {
        pendingAttachRetryWorkItem?.cancel()
        pendingAttachRetryWorkItem = nil
        pendingAttachRetryCommand = nil
    }
}
