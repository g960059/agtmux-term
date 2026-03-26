import Foundation
import GhosttyKit
import AgtmuxTermCore

struct GhosttyTerminalSurfaceContext: Equatable, Sendable {
    let viewportID: UUID
    let surfaceID: UUID
    let surfaceKey: String
    let sessionRef: SessionRef

    init(
        viewportID: UUID,
        surfaceID: UUID,
        surfaceKey: String,
        sessionRef: SessionRef
    ) {
        self.viewportID = viewportID
        self.surfaceID = surfaceID
        self.surfaceKey = surfaceKey
        self.sessionRef = sessionRef
    }

    var sourceTarget: TargetRef {
        sessionRef.target
    }

    var lastSeenRepoRoot: String? {
        sessionRef.lastSeenRepoRoot
    }
}

struct GhosttyRenderedTerminalSurfaceState: Equatable, Sendable {
    let context: GhosttyTerminalSurfaceContext
    let attachCommand: String
    let clientTTY: String?
    let generation: UInt64
}

enum GhosttyTerminalSurfaceRegistryError: Error, Equatable, CustomStringConvertible {
    case unsupportedTarget
    case unregisteredSurface(GhosttySurfaceHandle)

    var description: String {
        switch self {
        case .unsupportedTarget:
            return "CLI bridge target must resolve to a Ghostty surface"
        case .unregisteredSurface(let surfaceHandle):
            return "CLI bridge surface \(surfaceHandle.rawValue) is not registered"
        }
    }
}

struct GhosttySurfaceHandle: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt

    init(rawValue: UInt) {
        precondition(rawValue != 0, "Ghostty surface handle must be non-zero")
        self.rawValue = rawValue
    }

    init(surface: ghostty_surface_t) {
        self.rawValue = UInt(bitPattern: surface)
    }

    init?(target: ghostty_target_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        self.init(surface: target.target.surface)
    }
}

@MainActor
final class GhosttyTerminalSurfaceRegistry {
    static let shared = GhosttyTerminalSurfaceRegistry()

    private var statesBySurfaceHandle: [GhosttySurfaceHandle: GhosttyRenderedTerminalSurfaceState] = [:]
    private var surfaceHandlesBySurfaceID: [UUID: GhosttySurfaceHandle] = [:]
    private var latestGenerationBySurfaceID: [UUID: UInt64] = [:]
    private var stagedClientTTYBySurfaceHandle: [GhosttySurfaceHandle: String] = [:]

    func register(
        surfaceHandle: GhosttySurfaceHandle,
        context: GhosttyTerminalSurfaceContext,
        attachCommand: String
    ) {
        let previousTileState = surfaceHandlesBySurfaceID[context.surfaceID].flatMap { statesBySurfaceHandle[$0] }
        let stagedClientTTY = stagedClientTTYBySurfaceHandle.removeValue(forKey: surfaceHandle)

        if let previousHandle = surfaceHandlesBySurfaceID[context.surfaceID],
           previousHandle != surfaceHandle {
            statesBySurfaceHandle.removeValue(forKey: previousHandle)
        }

        if let previousState = statesBySurfaceHandle[surfaceHandle],
           previousState.context.surfaceID != context.surfaceID {
            surfaceHandlesBySurfaceID.removeValue(forKey: previousState.context.surfaceID)
        }

        let generation: UInt64
        if let existingState = statesBySurfaceHandle[surfaceHandle],
           existingState.context.surfaceID == context.surfaceID,
           existingState.attachCommand == attachCommand {
            generation = existingState.generation
        } else if let previousTileState,
           previousTileState.context.surfaceID == context.surfaceID,
           previousTileState.attachCommand == attachCommand {
            generation = previousTileState.generation
        } else {
            generation = (latestGenerationBySurfaceID[context.surfaceID] ?? 0) + 1
        }

        latestGenerationBySurfaceID[context.surfaceID] = generation
        let preservedClientTTY: String?
        if let stagedClientTTY {
            preservedClientTTY = stagedClientTTY
        } else if let existingState = statesBySurfaceHandle[surfaceHandle],
                  existingState.context.surfaceID == context.surfaceID,
                  existingState.attachCommand == attachCommand {
            preservedClientTTY = existingState.clientTTY
        } else if let previousTileState,
                  previousTileState.context.surfaceID == context.surfaceID,
                  previousTileState.attachCommand == attachCommand {
            preservedClientTTY = previousTileState.clientTTY
        } else {
            preservedClientTTY = nil
        }
        statesBySurfaceHandle[surfaceHandle] = GhosttyRenderedTerminalSurfaceState(
            context: context,
            attachCommand: attachCommand,
            clientTTY: preservedClientTTY,
            generation: generation
        )
        surfaceHandlesBySurfaceID[context.surfaceID] = surfaceHandle
    }

    func register(
        surface: ghostty_surface_t,
        context: GhosttyTerminalSurfaceContext,
        attachCommand: String
    ) {
        let surfaceHandle = GhosttySurfaceHandle(surface: surface)
        register(surfaceHandle: surfaceHandle, context: context, attachCommand: attachCommand)
    }

    func renderedState(
        forSurfaceHandle surfaceHandle: GhosttySurfaceHandle
    ) -> GhosttyRenderedTerminalSurfaceState? {
        statesBySurfaceHandle[surfaceHandle]
    }

    func renderedState(forSurfaceID surfaceID: UUID) -> GhosttyRenderedTerminalSurfaceState? {
        guard let surfaceHandle = surfaceHandlesBySurfaceID[surfaceID] else { return nil }
        return statesBySurfaceHandle[surfaceHandle]
    }

    func context(forSurfaceHandle surfaceHandle: GhosttySurfaceHandle) -> GhosttyTerminalSurfaceContext? {
        renderedState(forSurfaceHandle: surfaceHandle)?.context
    }

    func context(forSurface surface: ghostty_surface_t) -> GhosttyTerminalSurfaceContext? {
        context(forSurfaceHandle: GhosttySurfaceHandle(surface: surface))
    }

    func context(forTarget target: ghostty_target_s) -> GhosttyTerminalSurfaceContext? {
        guard let surfaceHandle = GhosttySurfaceHandle(target: target) else { return nil }
        return context(forSurfaceHandle: surfaceHandle)
    }

    func requireContext(forTarget target: ghostty_target_s) throws -> GhosttyTerminalSurfaceContext {
        guard let surfaceHandle = GhosttySurfaceHandle(target: target) else {
            throw GhosttyTerminalSurfaceRegistryError.unsupportedTarget
        }
        guard let context = context(forSurfaceHandle: surfaceHandle) else {
            throw GhosttyTerminalSurfaceRegistryError.unregisteredSurface(surfaceHandle)
        }
        return context
    }

    func surfaceHandle(forSurfaceID surfaceID: UUID) -> GhosttySurfaceHandle? {
        surfaceHandlesBySurfaceID[surfaceID]
    }

    func register(
        clientTTY: String,
        forSurfaceHandle surfaceHandle: GhosttySurfaceHandle
    ) throws {
        guard let existingState = statesBySurfaceHandle[surfaceHandle] else {
            stagedClientTTYBySurfaceHandle[surfaceHandle] = clientTTY
            return
        }
        statesBySurfaceHandle[surfaceHandle] = GhosttyRenderedTerminalSurfaceState(
            context: existingState.context,
            attachCommand: existingState.attachCommand,
            clientTTY: clientTTY,
            generation: existingState.generation
        )
    }

    func register(
        clientTTY: String,
        forTarget target: ghostty_target_s
    ) throws {
        guard let surfaceHandle = GhosttySurfaceHandle(target: target) else {
            throw GhosttyTerminalSurfaceRegistryError.unsupportedTarget
        }
        try register(clientTTY: clientTTY, forSurfaceHandle: surfaceHandle)
    }

    func unregister(surfaceHandle: GhosttySurfaceHandle) {
        stagedClientTTYBySurfaceHandle.removeValue(forKey: surfaceHandle)
        guard let removedState = statesBySurfaceHandle.removeValue(forKey: surfaceHandle) else { return }
        if surfaceHandlesBySurfaceID[removedState.context.surfaceID] == surfaceHandle {
            surfaceHandlesBySurfaceID.removeValue(forKey: removedState.context.surfaceID)
        }
    }

    func unregister(surface: ghostty_surface_t) {
        unregister(surfaceHandle: GhosttySurfaceHandle(surface: surface))
    }

    func resetForTesting() {
        statesBySurfaceHandle.removeAll()
        surfaceHandlesBySurfaceID.removeAll()
        latestGenerationBySurfaceID.removeAll()
        stagedClientTTYBySurfaceHandle.removeAll()
    }
}
