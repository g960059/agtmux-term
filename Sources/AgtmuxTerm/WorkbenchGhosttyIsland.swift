import SwiftUI
import AppKit

// MARK: - GhosttyIslandRepresentable

/// AppKit island that hosts a GhosttyTerminalView inside an NSViewController.
///
/// SwiftUI recomposition does NOT propagate into the view controller's view hierarchy,
/// which prevents sidebar inventory updates from triggering Metal draw calls.
/// All communication happens through value-type parameters only — no @EnvironmentObject.
struct GhosttyIslandRepresentable: NSViewControllerRepresentable {
    let surfaceID: UUID
    let poolKey: String
    let attachCommand: String?
    let surfaceContext: GhosttyTerminalSurfaceContext?
    let isFocused: Bool
    let focusRestoreNonce: UInt64

    func makeNSViewController(context: Context) -> GhosttyIslandViewController {
        GhosttyIslandViewController(
            surfaceID: surfaceID,
            poolKey: poolKey,
            attachCommand: attachCommand,
            surfaceContext: surfaceContext
        )
    }

    func updateNSViewController(_ controller: GhosttyIslandViewController, context: Context) {
        controller.update(
            attachCommand: attachCommand,
            surfaceContext: surfaceContext,
            isFocused: isFocused,
            focusRestoreNonce: focusRestoreNonce
        )
    }
}

// MARK: - GhosttyIslandViewController

@MainActor
final class GhosttyIslandViewController: NSViewController {
    // MARK: Init params
    private let surfaceID: UUID
    private let poolKey: String
    private var pendingAttachCommand: String?
    private var pendingSurfaceContext: GhosttyTerminalSurfaceContext?

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
        surfaceContext: GhosttyTerminalSurfaceContext?
    ) {
        self.surfaceID = surfaceID
        self.poolKey = poolKey
        self.pendingAttachCommand = attachCommand
        self.pendingSurfaceContext = surfaceContext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - NSViewController lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let tv = GhosttyTerminalView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
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

    // MARK: - Update from SwiftUI

    func update(
        attachCommand cmd: String?,
        surfaceContext: GhosttyTerminalSurfaceContext?,
        isFocused: Bool,
        focusRestoreNonce: UInt64
    ) {
        let commandChanged = currentCommand != cmd

        if commandChanged {
            lastAppliedFocus = nil
            cancelPendingRetry()
            if let cmd {
                applyCommandIfPossible(cmd, surfaceContext: surfaceContext)
            } else {
                currentCommand = nil
            }
        }

        // Update surface context registration if it changed
        if let surfaceContext,
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
        let capturedWorkItem = pendingAttachRetryWorkItem

        capturedWorkItem?.cancel()

        Task { @MainActor in
            if let handle = capturedHandle {
                GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: handle)
            } else if let surface = capturedView?.surface {
                GhosttyTerminalSurfaceRegistry.shared.unregister(surface: surface)
            }
            SurfacePool.shared.release(leafID: capturedSurfaceID)
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

        print("[GhosttyIsland] Creating surface for id \(surfaceID) cmd=\(command)")
        guard let surface = GhosttyApp.shared.newSurface(for: tv, command: command) else {
            print("[GhosttyIsland] Surface created: false")
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
            tmuxPaneID: poolKey
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
        pendingAttachCommand = nil
        pendingSurfaceContext = nil
        cancelPendingRetry()
        print("[GhosttyIsland] Surface created: true")
    }

    private func scheduleRetry(for command: String, surfaceContext: GhosttyTerminalSurfaceContext?) {
        guard currentCommand != command else { return }
        guard pendingAttachRetryCommand != command else { return }

        cancelPendingRetry()
        pendingAttachRetryCommand = command

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
