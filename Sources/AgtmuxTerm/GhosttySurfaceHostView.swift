import SwiftUI

/// NSViewRepresentable that hosts a single Ghostty terminal surface.
///
/// - Creates / recreates the surface whenever `attachCommand` changes.
/// - Registers new surfaces with SurfacePool for lifecycle management.
/// - Occlusion is delegated to SurfacePool (ghostty_surface_set_occlusion).
/// - dismantleNSView schedules a 5-second grace-period GC via SurfacePool.
struct GhosttySurfaceHostView: NSViewRepresentable {
    let surfaceID: UUID
    let poolKey: String
    let attachCommand: String?
    let surfaceContext: GhosttyTerminalSurfaceContext?
    let isFocused: Bool
    let focusRestoreNonce: UInt64

    init(
        surfaceID: UUID,
        poolKey: String,
        attachCommand: String?,
        surfaceContext: GhosttyTerminalSurfaceContext? = nil,
        isFocused: Bool,
        focusRestoreNonce: UInt64 = 0
    ) {
        self.surfaceID = surfaceID
        self.poolKey = poolKey
        self.attachCommand = attachCommand
        self.surfaceContext = surfaceContext
        self.isFocused = isFocused
        self.focusRestoreNonce = focusRestoreNonce
    }

    @MainActor
    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView()
        context.coordinator.surfaceID = surfaceID
        return view
    }

    @MainActor
    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        let cmd = attachCommand
        let commandChanged = context.coordinator.currentCommand != cmd

        if commandChanged {
            context.coordinator.lastAppliedFocus = nil
            cancelPendingSurfaceRetry(for: context.coordinator)
            if let cmd {
                guard attachSurfaceIfPossible(
                    nsView,
                    coordinator: context.coordinator,
                    command: cmd
                ) else {
                    scheduleSurfaceRetry(
                        for: nsView,
                        coordinator: context.coordinator,
                        command: cmd
                    )
                    return
                }
            } else {
                context.coordinator.currentCommand = nil
            }
        }

        if let surfaceContext,
           let registeredSurfaceHandle = context.coordinator.registeredSurfaceHandle,
           context.coordinator.registeredSurfaceContext != surfaceContext {
            GhosttyTerminalSurfaceRegistry.shared.register(
                surfaceHandle: registeredSurfaceHandle,
                context: surfaceContext,
                attachCommand: cmd ?? context.coordinator.currentCommand ?? ""
            )
            context.coordinator.registeredSurfaceContext = surfaceContext
        }

        let focusStateChanged = context.coordinator.lastAppliedFocus != isFocused
        let focusRestoreChanged = context.coordinator.lastFocusRestoreNonce != focusRestoreNonce
        guard focusStateChanged || (isFocused && focusRestoreChanged) else { return }
        context.coordinator.lastAppliedFocus = isFocused
        context.coordinator.lastFocusRestoreNonce = focusRestoreNonce
        if isFocused {
            SurfacePool.shared.activate(leafID: surfaceID)
            nsView.window?.makeFirstResponder(nsView)
        } else {
            SurfacePool.shared.background(leafID: surfaceID)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: GhosttyTerminalView, coordinator: Coordinator) {
        coordinator.pendingAttachRetryWorkItem?.cancel()
        coordinator.pendingAttachRetryWorkItem = nil
        coordinator.pendingAttachRetryCommand = nil
        if let registeredSurfaceHandle = coordinator.registeredSurfaceHandle {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: registeredSurfaceHandle)
        } else if let surface = nsView.surface {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surface: surface)
        }
        coordinator.registeredSurfaceHandle = nil
        coordinator.registeredSurfaceContext = nil

        if let surfaceID = coordinator.surfaceID {
            let expectedViewID = ObjectIdentifier(nsView)
            Task { @MainActor in
                SurfacePool.shared.release(
                    leafID: surfaceID,
                    expectedViewID: expectedViewID
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    private func attachSurfaceIfPossible(
        _ nsView: GhosttyTerminalView,
        coordinator: Coordinator,
        command: String
    ) -> Bool {
        guard nsView.window != nil else { return false }

        guard let surface = GhosttyApp.shared.newSurface(for: nsView, command: command) else {
            return false
        }

        let previousSurfaceHandle = coordinator.registeredSurfaceHandle
        let surfaceHandle = GhosttySurfaceHandle(surface: surface)

        if let previousSurfaceHandle {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: previousSurfaceHandle)
        } else if let existingSurface = nsView.surface {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surface: existingSurface)
        }

        nsView.attachSurface(surface)
        SurfacePool.shared.register(
            view: nsView,
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
            coordinator.registeredSurfaceHandle = surfaceHandle
            coordinator.registeredSurfaceContext = surfaceContext
        } else {
            coordinator.registeredSurfaceHandle = nil
            coordinator.registeredSurfaceContext = nil
        }
        coordinator.currentCommand = command
        cancelPendingSurfaceRetry(for: coordinator)
        return true
    }

    @MainActor
    private func scheduleSurfaceRetry(
        for nsView: GhosttyTerminalView,
        coordinator: Coordinator,
        command: String
    ) {
        guard coordinator.currentCommand != command else { return }
        guard coordinator.pendingAttachRetryCommand != command else { return }

        cancelPendingSurfaceRetry(for: coordinator)
        coordinator.pendingAttachRetryCommand = command

        let retry = DispatchWorkItem { [weak nsView, weak coordinator] in
            guard let nsView, let coordinator else { return }
            guard coordinator.currentCommand != command else { return }
            guard self.attachSurfaceIfPossible(nsView, coordinator: coordinator, command: command) == false else {
                return
            }
            self.scheduleSurfaceRetry(for: nsView, coordinator: coordinator, command: command)
        }

        coordinator.pendingAttachRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    @MainActor
    private func cancelPendingSurfaceRetry(for coordinator: Coordinator) {
        coordinator.pendingAttachRetryWorkItem?.cancel()
        coordinator.pendingAttachRetryWorkItem = nil
        coordinator.pendingAttachRetryCommand = nil
    }

    final class Coordinator {
        var currentCommand: String?
        var surfaceID: UUID?
        var registeredSurfaceHandle: GhosttySurfaceHandle?
        var registeredSurfaceContext: GhosttyTerminalSurfaceContext?
        var lastAppliedFocus: Bool? = nil
        var lastFocusRestoreNonce: UInt64? = nil
        var pendingAttachRetryCommand: String?
        var pendingAttachRetryWorkItem: DispatchWorkItem?
    }
}
