import Foundation

@MainActor
final class TerminalHostActiveSurfaceRegistry {
    static let shared = TerminalHostActiveSurfaceRegistry()

    private var activeLeafIDsBySurfaceID: [UUID: UUID] = [:]

    func setActiveLeafID(_ leafID: UUID, forSurfaceID surfaceID: UUID) {
        activeLeafIDsBySurfaceID[surfaceID] = leafID
    }

    func activeLeafID(forSurfaceID surfaceID: UUID) -> UUID? {
        activeLeafIDsBySurfaceID[surfaceID]
    }

    func clearActiveLeafID(forSurfaceID surfaceID: UUID) {
        activeLeafIDsBySurfaceID.removeValue(forKey: surfaceID)
    }

    func resetForTesting() {
        activeLeafIDsBySurfaceID.removeAll()
    }
}

// Retain the pane-controller telemetry surface so perf diagnostics can keep
// reading it while the app converges on the single-surface host model.
@MainActor
final class MainTerminalPaneControllerTelemetry {
    struct Snapshot: Codable, Equatable {
        let createCount: Int
        let promoteCount: Int
        let activateCount: Int
        let deactivateCount: Int
        let evictCount: Int
        let retainedPaneControllerCount: Int
        let maxRetainedPaneControllerCount: Int
        let retentionOrderCount: Int
    }

    private struct State {
        var createCount = 0
        var promoteCount = 0
        var activateCount = 0
        var deactivateCount = 0
        var evictCount = 0
        var retainedPaneControllerCount = 0
        var maxRetainedPaneControllerCount = 0
        var retentionOrderCount = 0
    }

    static let shared = MainTerminalPaneControllerTelemetry()

    private var statesBySurfaceID: [UUID: State] = [:]

    func recordCreate(surfaceID: UUID) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.createCount += 1
        statesBySurfaceID[surfaceID] = state
    }

    func recordPromote(surfaceID: UUID) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.promoteCount += 1
        statesBySurfaceID[surfaceID] = state
    }

    func recordActivate(surfaceID: UUID) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.activateCount += 1
        statesBySurfaceID[surfaceID] = state
    }

    func recordDeactivate(surfaceID: UUID) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.deactivateCount += 1
        statesBySurfaceID[surfaceID] = state
    }

    func recordEvict(surfaceID: UUID, count: Int) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.evictCount += count
        statesBySurfaceID[surfaceID] = state
    }

    func recordRetention(surfaceID: UUID, retainedCount: Int, retentionOrderCount: Int) {
        var state = statesBySurfaceID[surfaceID] ?? State()
        state.retainedPaneControllerCount = retainedCount
        state.retentionOrderCount = retentionOrderCount
        state.maxRetainedPaneControllerCount = max(
            state.maxRetainedPaneControllerCount,
            retainedCount
        )
        statesBySurfaceID[surfaceID] = state
    }

    func reset(surfaceID: UUID) {
        statesBySurfaceID[surfaceID] = State()
    }

    func snapshot(surfaceID: UUID) -> Snapshot {
        let state = statesBySurfaceID[surfaceID] ?? State()
        return Snapshot(
            createCount: state.createCount,
            promoteCount: state.promoteCount,
            activateCount: state.activateCount,
            deactivateCount: state.deactivateCount,
            evictCount: state.evictCount,
            retainedPaneControllerCount: state.retainedPaneControllerCount,
            maxRetainedPaneControllerCount: state.maxRetainedPaneControllerCount,
            retentionOrderCount: state.retentionOrderCount
        )
    }
}

struct TerminalHostRenderModel: Equatable {
    let surfaceID: UUID
    let poolKey: String
    let attachCommand: String?
    let surfaceContext: GhosttyTerminalSurfaceContext?
    let visiblePaneIdentity: String?
    let isFocused: Bool
    let focusRestoreNonce: UInt64
}
