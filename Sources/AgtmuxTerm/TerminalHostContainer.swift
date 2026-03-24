import SwiftUI

@MainActor
final class TerminalHostActiveSurfaceRegistry {
    static let shared = TerminalHostActiveSurfaceRegistry()

    private var activeLeafIDsByTileID: [UUID: UUID] = [:]

    func setActiveLeafID(_ leafID: UUID, forTileID tileID: UUID) {
        activeLeafIDsByTileID[tileID] = leafID
    }

    func activeLeafID(forTileID tileID: UUID) -> UUID? {
        activeLeafIDsByTileID[tileID]
    }

    func clearActiveLeafID(forTileID tileID: UUID) {
        activeLeafIDsByTileID.removeValue(forKey: tileID)
    }

    func resetForTesting() {
        activeLeafIDsByTileID.removeAll()
    }
}

@MainActor
final class NextHostPaneControllerTelemetry {
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

    static let shared = NextHostPaneControllerTelemetry()

    private var statesByTileID: [UUID: State] = [:]

    func recordCreate(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.createCount += 1
        statesByTileID[tileID] = state
    }

    func recordPromote(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.promoteCount += 1
        statesByTileID[tileID] = state
    }

    func recordActivate(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.activateCount += 1
        statesByTileID[tileID] = state
    }

    func recordDeactivate(tileID: UUID) {
        var state = statesByTileID[tileID] ?? State()
        state.deactivateCount += 1
        statesByTileID[tileID] = state
    }

    func recordEvict(tileID: UUID, count: Int) {
        var state = statesByTileID[tileID] ?? State()
        state.evictCount += count
        statesByTileID[tileID] = state
    }

    func recordRetention(tileID: UUID, retainedCount: Int, retentionOrderCount: Int) {
        var state = statesByTileID[tileID] ?? State()
        state.retainedPaneControllerCount = retainedCount
        state.retentionOrderCount = retentionOrderCount
        state.maxRetainedPaneControllerCount = max(
            state.maxRetainedPaneControllerCount,
            retainedCount
        )
        statesByTileID[tileID] = state
    }

    func reset(tileID: UUID) {
        statesByTileID[tileID] = State()
    }

    func snapshot(tileID: UUID) -> Snapshot {
        let state = statesByTileID[tileID] ?? State()
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

struct TerminalHostContainer: View, Equatable {
    let mode: TerminalHostMode
    let model: TerminalHostRenderModel

    static func hostViewIdentity(surfaceID: UUID, mode: TerminalHostMode) -> String {
        "terminal-host:\(mode.rawValue):\(surfaceID.uuidString)"
    }

    @ViewBuilder
    var body: some View {
        switch mode {
        case .legacy:
            GhosttyIslandRepresentable(
                surfaceID: model.surfaceID,
                poolKey: model.poolKey,
                attachCommand: model.attachCommand,
                surfaceContext: model.surfaceContext,
                visiblePaneIdentity: model.visiblePaneIdentity,
                isFocused: model.isFocused,
                focusRestoreNonce: model.focusRestoreNonce
            )
            .equatable()

        case .next:
            NextGhosttyIslandRepresentable(model: model)
                .equatable()
        }
    }
}

/// Phase 1 boundary: the next host keeps legacy behavior while we split
/// ownership and cadence in later phases.
struct NextGhosttyIslandRepresentable: NSViewControllerRepresentable, Equatable {
    let model: TerminalHostRenderModel

    func makeNSViewController(context: Context) -> NextGhosttyIslandViewController {
        NextGhosttyIslandViewController(model: model)
    }

    func updateNSViewController(_ controller: NextGhosttyIslandViewController, context: Context) {
        controller.update(model: model)
    }
}

@MainActor
final class NextGhosttyIslandViewController: NSViewController {
    nonisolated static func paneCacheKey(
        visiblePaneIdentity: String?,
        fallbackSurfaceID: UUID
    ) -> String {
        visiblePaneIdentity ?? "__tile:\(fallbackSurfaceID.uuidString)"
    }

    nonisolated static func trimmedRetentionOrder(
        _ retentionOrder: [String],
        activePaneKey: String,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [activePaneKey] }
        var kept: [String] = []
        var inactiveKeptCount = 0
        for key in retentionOrder.reversed() {
            if key == activePaneKey {
                kept.append(key)
                continue
            }
            if inactiveKeptCount < (limit - 1) {
                kept.append(key)
                inactiveKeptCount += 1
            }
        }
        if kept.contains(activePaneKey) == false {
            kept.append(activePaneKey)
        }
        return kept.reversed()
    }

    nonisolated static func bootstrapPromotionSourcePaneKey(
        activePaneKey: String?,
        nextPaneKey: String,
        visiblePaneIdentity: String?,
        fallbackSurfaceID: UUID,
        existingPaneKeys: Set<String>
    ) -> String? {
        guard visiblePaneIdentity != nil else { return nil }
        let bootstrapKey = paneCacheKey(
            visiblePaneIdentity: nil,
            fallbackSurfaceID: fallbackSurfaceID
        )
        guard activePaneKey == bootstrapKey else { return nil }
        guard nextPaneKey != bootstrapKey else { return nil }
        guard existingPaneKeys.contains(bootstrapKey) else { return nil }
        guard existingPaneKeys.contains(nextPaneKey) == false else { return nil }
        return bootstrapKey
    }

    private let maxRetainedPaneControllers = 4
    private let tileID: UUID
    private var paneSurfaceIDs: [String: UUID] = [:]
    private var paneControllers: [String: GhosttyIslandViewController] = [:]
    private var paneModels: [String: TerminalHostRenderModel] = [:]
    private var paneRetentionOrder: [String] = []
    private var activePaneKey: String?

    init(model: TerminalHostRenderModel) {
        self.tileID = model.surfaceID
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
        update(model: model)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let activePaneKey,
              let controller = paneControllers[activePaneKey]
        else { return }
        controller.hostContainerDidAttachVisibleView()
    }

    func update(model: TerminalHostRenderModel) {
        let paneKey = Self.paneCacheKey(
            visiblePaneIdentity: model.visiblePaneIdentity,
            fallbackSurfaceID: model.surfaceID
        )
        let existingPaneKeys = Set(paneControllers.keys)
            .union(paneSurfaceIDs.keys)
            .union(paneModels.keys)
        if let bootstrapSourceKey = Self.bootstrapPromotionSourcePaneKey(
            activePaneKey: activePaneKey,
            nextPaneKey: paneKey,
            visiblePaneIdentity: model.visiblePaneIdentity,
            fallbackSurfaceID: tileID,
            existingPaneKeys: existingPaneKeys
        ) {
            promotePaneController(from: bootstrapSourceKey, to: paneKey)
        }
        let paneSurfaceID = paneSurfaceIDs[paneKey] ?? UUID()
        paneSurfaceIDs[paneKey] = paneSurfaceID

        let paneModel = TerminalHostRenderModel(
            surfaceID: paneSurfaceID,
            poolKey: model.poolKey,
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity,
            isFocused: model.isFocused,
            focusRestoreNonce: model.focusRestoreNonce
        )
        paneModels[paneKey] = paneModel

        let controller: GhosttyIslandViewController
        if let existingController = paneControllers[paneKey] {
            controller = existingController
        } else {
            NextHostPaneControllerTelemetry.shared.recordCreate(tileID: tileID)
            controller = makePaneController(model: paneModel)
        }
        paneControllers[paneKey] = controller
        controller.update(
            attachCommand: paneModel.attachCommand,
            surfaceContext: paneModel.surfaceContext,
            visiblePaneIdentity: paneModel.visiblePaneIdentity,
            isFocused: paneModel.isFocused,
            focusRestoreNonce: paneModel.focusRestoreNonce
        )

        if activePaneKey != paneKey {
            deactivateActivePaneIfNeeded()
            activatePaneController(controller, paneKey: paneKey)
            activePaneKey = paneKey
        } else {
            ensurePaneControllerIsVisible(controller)
        }

        paneRetentionOrder.removeAll { $0 == paneKey }
        paneRetentionOrder.append(paneKey)
        evictInactivePaneControllersIfNeeded(activePaneKey: paneKey)
        NextHostPaneControllerTelemetry.shared.recordRetention(
            tileID: tileID,
            retainedCount: paneControllers.count,
            retentionOrderCount: paneRetentionOrder.count
        )
    }

    private func promotePaneController(from sourceKey: String, to targetKey: String) {
        NextHostPaneControllerTelemetry.shared.recordPromote(tileID: tileID)
        if let surfaceID = paneSurfaceIDs.removeValue(forKey: sourceKey) {
            paneSurfaceIDs[targetKey] = surfaceID
        }
        if let controller = paneControllers.removeValue(forKey: sourceKey) {
            paneControllers[targetKey] = controller
        }
        if let model = paneModels.removeValue(forKey: sourceKey) {
            paneModels[targetKey] = model
        }
        paneRetentionOrder = paneRetentionOrder.map { $0 == sourceKey ? targetKey : $0 }
        if activePaneKey == sourceKey {
            activePaneKey = targetKey
            if let surfaceID = paneSurfaceIDs[targetKey] {
                TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(surfaceID, forTileID: tileID)
            }
        }
    }

    private func makePaneController(model: TerminalHostRenderModel) -> GhosttyIslandViewController {
        GhosttyIslandViewController(
            surfaceID: model.surfaceID,
            poolKey: model.poolKey,
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity
        )
    }

    private func deactivateActivePaneIfNeeded() {
        guard let activePaneKey,
              let controller = paneControllers[activePaneKey],
              var model = paneModels[activePaneKey]
        else { return }
        NextHostPaneControllerTelemetry.shared.recordDeactivate(tileID: tileID)
        model = TerminalHostRenderModel(
            surfaceID: model.surfaceID,
            poolKey: model.poolKey,
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity,
            isFocused: false,
            focusRestoreNonce: model.focusRestoreNonce
        )
        paneModels[activePaneKey] = model
        controller.update(
            attachCommand: model.attachCommand,
            surfaceContext: model.surfaceContext,
            visiblePaneIdentity: model.visiblePaneIdentity,
            isFocused: false,
            focusRestoreNonce: model.focusRestoreNonce
        )
        controller.view.removeFromSuperview()
    }

    private func activatePaneController(_ controller: GhosttyIslandViewController, paneKey: String) {
        NextHostPaneControllerTelemetry.shared.recordActivate(tileID: tileID)
        if children.contains(where: { $0 === controller }) == false {
            addChild(controller)
        }
        ensurePaneControllerIsVisible(controller)
        if let paneModel = paneModels[paneKey] {
            TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(
                paneModel.surfaceID,
                forTileID: tileID
            )
        }
        controller.hostContainerDidAttachVisibleView()
    }

    private func ensurePaneControllerIsVisible(_ controller: GhosttyIslandViewController) {
        let paneView = controller.view
        paneView.translatesAutoresizingMaskIntoConstraints = true
        paneView.autoresizingMask = [.width, .height]
        paneView.frame = view.bounds
        if paneView.superview !== view {
            view.addSubview(paneView)
        }
        view.setAccessibilityChildren([paneView])
    }

    private func evictInactivePaneControllersIfNeeded(activePaneKey: String) {
        let keptKeys = Set(
            Self.trimmedRetentionOrder(
                paneRetentionOrder,
                activePaneKey: activePaneKey,
                limit: maxRetainedPaneControllers
            )
        )
        let evictedKeys = paneControllers.keys.filter { keptKeys.contains($0) == false }
        NextHostPaneControllerTelemetry.shared.recordEvict(tileID: tileID, count: evictedKeys.count)
        for key in evictedKeys {
            guard let controller = paneControllers.removeValue(forKey: key) else { continue }
            paneModels.removeValue(forKey: key)
            paneSurfaceIDs.removeValue(forKey: key)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        paneRetentionOrder = paneRetentionOrder.filter { keptKeys.contains($0) }
    }

    deinit {
        let capturedTileID = tileID
        Task { @MainActor in
            TerminalHostActiveSurfaceRegistry.shared.clearActiveLeafID(forTileID: capturedTileID)
        }
    }
}
