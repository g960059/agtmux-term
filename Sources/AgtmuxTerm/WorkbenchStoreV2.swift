import Foundation
import Observation
import AgtmuxTermCore

enum WorkbenchStoreV2Error: Error, Equatable, LocalizedError {
    case invalidFixture(String)
    case observedSessionCollision(target: TargetRef, sessionName: String)

    var errorDescription: String? {
        switch self {
        case .invalidFixture(let message):
            return message
        case .observedSessionCollision(let target, let sessionName):
            return "Terminal session switch failed: \(target.label) session '\(sessionName)' is already visible in another tile"
        }
    }
}

enum WorkbenchStoreV2TerminalOpenResult: Equatable {
    case opened(workbenchID: UUID, tileID: UUID)
    case revealedExisting(workbenchID: UUID, tileID: UUID)

    var tileID: UUID {
        switch self {
        case .opened(_, let tileID), .revealedExisting(_, let tileID):
            return tileID
        }
    }
}

struct WorkbenchActivePaneRuntimeState: Equatable {
    let tileID: UUID
    var desiredPaneRef: ActivePaneRef?
    var observedPaneRef: ActivePaneRef?
    var focusRequestNonce: UInt64
    var desiredMatchObservationCount: UInt8
    var desiredObservationConfirmationTarget: UInt8

    var navigationPaneRef: ActivePaneRef? {
        desiredPaneRef ?? observedPaneRef
    }

    var resolvedPaneRef: ActivePaneRef? {
        observedPaneRef ?? desiredPaneRef
    }
}

@Observable
@MainActor
final class WorkbenchStoreV2 {
    static let featureFlagEnvironmentKey = "AGTMUX_COCKPIT_WORKBENCH_V2"
    static let fixtureEnvironmentKey = "AGTMUX_WORKBENCH_V2_FIXTURE_JSON"
    private static let initialAttachObservationConfirmationCount: UInt8 = 2
    private static let retargetObservationConfirmationCount: UInt8 = 1

    var workbenches: [Workbench]
    var activeWorkbenchIndex: Int
    private let persistence: WorkbenchStoreV2Persistence?
    private var activePaneRuntimeByWorkbenchID: [UUID: WorkbenchActivePaneRuntimeState]

    var activeWorkbench: Workbench? {
        guard workbenches.indices.contains(activeWorkbenchIndex) else { return nil }
        return workbenches[activeWorkbenchIndex]
    }

    var focusedTerminalTileContext: (workbenchID: UUID, tileID: UUID, sessionRef: SessionRef)? {
        guard let workbench = activeWorkbench else { return nil }
        guard let focusedTileID = workbench.focusedTileID else { return nil }
        guard let tile = workbench.tiles.first(where: { $0.id == focusedTileID }) else { return nil }
        guard case .terminal(let sessionRef) = tile.kind else { return nil }
        return (workbench.id, tile.id, sessionRef)
    }

    var activePaneContext: (workbenchID: UUID, activePaneRef: ActivePaneRef, focusRequestNonce: UInt64)? {
        guard let workbench = activeWorkbench else { return nil }
        guard let runtimeState = activePaneRuntime(for: workbench) else { return nil }
        guard let activePaneRef = runtimeState.navigationPaneRef else { return nil }
        return (workbench.id, activePaneRef, runtimeState.focusRequestNonce)
    }

    var activePaneRuntimeContext: (
        workbenchID: UUID,
        tileID: UUID,
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        focusRequestNonce: UInt64
    )? {
        guard let workbench = activeWorkbench else { return nil }
        guard let runtimeState = activePaneRuntime(for: workbench) else { return nil }
        return (
            workbench.id,
            runtimeState.tileID,
            runtimeState.desiredPaneRef,
            runtimeState.observedPaneRef,
            runtimeState.focusRequestNonce
        )
    }

    init(
        workbenches: [Workbench] = [.empty()],
        activeWorkbenchIndex: Int = 0,
        persistence: WorkbenchStoreV2Persistence? = nil
    ) {
        precondition(!workbenches.isEmpty, "WorkbenchStoreV2 requires at least one workbench")
        precondition(
            workbenches.indices.contains(activeWorkbenchIndex),
            "WorkbenchStoreV2 activeWorkbenchIndex is out of range"
        )
        self.workbenches = workbenches
        self.activeWorkbenchIndex = activeWorkbenchIndex
        self.persistence = persistence
        self.activePaneRuntimeByWorkbenchID = Self.seedActivePaneRuntimeState(from: workbenches)
    }

    convenience init(
        env: [String: String],
        persistence: WorkbenchStoreV2Persistence? = .live()
    ) throws {
        if let fixtureJSON = env[Self.fixtureEnvironmentKey] {
            self.init(
                workbenches: try Self.decodeFixtureJSON(fixtureJSON),
                persistence: nil
            )
        } else if let snapshot = try persistence?.load() {
            self.init(
                workbenches: snapshot.workbenches,
                activeWorkbenchIndex: snapshot.activeWorkbenchIndex,
                persistence: persistence
            )
        } else {
            self.init(persistence: persistence)
        }
    }

    static func isFeatureEnabled(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env[featureFlagEnvironmentKey] == "1"
    }

    static func decodeFixtureJSON(_ json: String) throws -> [Workbench] {
        guard let data = json.data(using: .utf8) else {
            throw WorkbenchStoreV2Error.invalidFixture(
                "\(fixtureEnvironmentKey) is not valid UTF-8"
            )
        }

        let decoded = try JSONDecoder().decode([Workbench].self, from: data)
        guard !decoded.isEmpty else {
            throw WorkbenchStoreV2Error.invalidFixture(
                "\(fixtureEnvironmentKey) must contain at least one workbench"
            )
        }
        return decoded
    }

    func save() throws {
        guard let persistence else {
            throw WorkbenchStoreV2PersistenceError.persistenceUnavailable
        }

        try persistence.save(
            .init(
                workbenches: workbenches,
                activeWorkbenchIndex: activeWorkbenchIndex
            )
        )
    }

    @discardableResult
    func createWorkbench(title: String = "") -> Workbench {
        let workbench = Workbench.empty(title: title)
        workbenches.append(workbench)
        activeWorkbenchIndex = workbenches.count - 1
        autosaveIfNeeded()
        return workbench
    }

    func closeWorkbench(id: UUID) {
        guard let index = workbenches.firstIndex(where: { $0.id == id }) else { return }

        activePaneRuntimeByWorkbenchID.removeValue(forKey: id)
        workbenches.remove(at: index)
        if workbenches.isEmpty {
            workbenches = [.empty()]
            activeWorkbenchIndex = 0
            autosaveIfNeeded()
            return
        }

        if index < activeWorkbenchIndex {
            activeWorkbenchIndex -= 1
        } else if activeWorkbenchIndex >= workbenches.count {
            activeWorkbenchIndex = workbenches.count - 1
        }
        autosaveIfNeeded()
    }

    func switchWorkbench(to id: UUID) {
        guard let index = workbenches.firstIndex(where: { $0.id == id }) else { return }
        guard activeWorkbenchIndex != index else { return }
        activeWorkbenchIndex = index
        _ = syncActivePaneRuntimeForFocusedTile(inWorkbenchAt: index)
        autosaveIfNeeded()
    }

    @discardableResult
    func openTerminal(sessionRef: SessionRef) -> WorkbenchStoreV2TerminalOpenResult {
        openTerminal(sessionRef: sessionRef, activePaneRef: nil)
    }

    @discardableResult
    func openTerminal(
        for pane: AgtmuxPane,
        hostsConfig: HostsConfig
    ) -> WorkbenchStoreV2TerminalOpenResult {
        openTerminal(
            sessionRef: SessionRef(
                target: Self.targetRef(for: pane.source, hostsConfig: hostsConfig),
                sessionName: pane.sessionName,
                lastSeenRepoRoot: pane.currentPath
            ),
            activePaneRef: Self.activePaneRef(for: pane, hostsConfig: hostsConfig)
        )
    }

    @discardableResult
    private func openTerminal(
        sessionRef: SessionRef,
        activePaneRef: ActivePaneRef?
    ) -> WorkbenchStoreV2TerminalOpenResult {
        if let existing = existingTerminalTile(for: sessionRef) {
            let didChangeWorkbench = activeWorkbenchIndex != existing.workbenchIndex
            activeWorkbenchIndex = existing.workbenchIndex
            let didChangeFocus = focusTile(id: existing.tile.id, inWorkbenchAt: existing.workbenchIndex)
            let didChangeNavigation = updateExistingTerminalTile(
                inWorkbenchAt: existing.workbenchIndex,
                tile: existing.tile,
                incomingRef: sessionRef
            )
            let didChangeActivePane = syncActivePaneRuntimeAfterTerminalOpen(
                sessionRef: sessionRef,
                activePaneRef: activePaneRef,
                tileID: existing.tile.id,
                inWorkbenchAt: existing.workbenchIndex
            )
            if didChangeWorkbench || didChangeFocus || didChangeNavigation || didChangeActivePane {
                autosaveIfNeeded()
            }
            return .revealedExisting(
                workbenchID: workbenches[existing.workbenchIndex].id,
                tileID: existing.tile.id
            )
        }

        let tileID = placeTile(
            WorkbenchTile(
                kind: .terminal(sessionRef: sessionRef)
            )
        )
        _ = syncActivePaneRuntimeAfterTerminalOpen(
            sessionRef: sessionRef,
            activePaneRef: activePaneRef,
            tileID: tileID,
            inWorkbenchAt: activeWorkbenchIndex
        )
        autosaveIfNeeded()
        return .opened(
            workbenchID: workbenches[activeWorkbenchIndex].id,
            tileID: tileID
        )
    }

    func activePaneSelection(
        panes: [AgtmuxPane],
        hostsConfig: HostsConfig
    ) -> WorkbenchV2ActivePaneSelection? {
        WorkbenchV2ActivePaneSelectionResolver.resolve(
            workbench: activeWorkbench,
            runtimeState: activeWorkbench.flatMap(activePaneRuntime(for:)),
            panes: panes,
            hostsConfig: hostsConfig
        )
    }

    @discardableResult
    func openBrowserPlaceholder(
        url: URL,
        sourceContext: String? = nil,
        placement: WorkbenchV2Placement = .replace,
        pinned: Bool = false
    ) -> UUID {
        let tileID = placeTile(
            WorkbenchTile(
                kind: .browser(url: url, sourceContext: sourceContext),
                pinned: pinned
            ),
            placement: placement
        )
        autosaveIfNeeded()
        return tileID
    }

    @discardableResult
    func openDocumentPlaceholder(
        ref: DocumentRef,
        placement: WorkbenchV2Placement = .replace,
        pinned: Bool = false
    ) -> UUID {
        let tileID = placeTile(
            WorkbenchTile(
                kind: .document(ref: ref),
                pinned: pinned
            ),
            placement: placement
        )
        autosaveIfNeeded()
        return tileID
    }

    func focusTile(id: UUID) {
        let didChangeFocus = focusTile(id: id, inWorkbenchAt: activeWorkbenchIndex)
        let didChangeActivePane = syncActivePaneRuntimeForFocusedTile(inWorkbenchAt: activeWorkbenchIndex)
        if didChangeFocus || didChangeActivePane {
            autosaveIfNeeded()
        }
    }

    private func placeTile(
        _ tile: WorkbenchTile,
        placement: WorkbenchV2Placement = .replace
    ) -> UUID {
        guard workbenches.indices.contains(activeWorkbenchIndex) else {
            preconditionFailure("WorkbenchStoreV2.activeWorkbenchIndex is out of range")
        }

        var workbench = workbenches[activeWorkbenchIndex]
        if workbench.root.isEmpty {
            workbench.root = .tile(tile)
        } else {
            let focusedTile = resolveFocusedTile(in: &workbench)
            let replacement = replacementNode(
                for: placement,
                replacing: focusedTile,
                with: tile
            )

            guard let updated = workbench.root.replacing(tileID: focusedTile.id, with: replacement) else {
                preconditionFailure(
                    "WorkbenchStoreV2.placeTile could not replace focused tile \(focusedTile.id)"
                )
            }
            workbench.root = updated
        }
        workbench.focusedTileID = tile.id
        workbenches[activeWorkbenchIndex] = workbench
        return tile.id
    }

    private func resolveFocusedTile(in workbench: inout Workbench) -> WorkbenchTile {
        if let focusedTileID = workbench.focusedTileID {
            return requireFocusedTile(id: focusedTileID, in: workbench)
        }

        guard let fallbackTile = workbench.tiles.first else {
            preconditionFailure(
                "WorkbenchStoreV2.placeTile requires at least one tile for a non-empty workbench"
            )
        }
        workbench.focusedTileID = fallbackTile.id
        return fallbackTile
    }

    private func requireFocusedTile(id: UUID, in workbench: Workbench) -> WorkbenchTile {
        guard let focusedTile = workbench.tiles.first(where: { $0.id == id }) else {
            preconditionFailure(
                "WorkbenchStoreV2.placeTile could not find focused tile \(id) in the active workbench"
            )
        }
        return focusedTile
    }

    private func replacementNode(
        for placement: WorkbenchV2Placement,
        replacing focusedTile: WorkbenchTile,
        with newTile: WorkbenchTile
    ) -> WorkbenchNode {
        switch placement {
        case .replace:
            return .tile(newTile)
        case .left:
            return splitNode(axis: .horizontal, first: newTile, second: focusedTile)
        case .right:
            return splitNode(axis: .horizontal, first: focusedTile, second: newTile)
        case .up:
            return splitNode(axis: .vertical, first: newTile, second: focusedTile)
        case .down:
            return splitNode(axis: .vertical, first: focusedTile, second: newTile)
        }
    }

    private func splitNode(
        axis: SplitAxis,
        first: WorkbenchTile,
        second: WorkbenchTile
    ) -> WorkbenchNode {
        .split(
            WorkbenchSplit(
                axis: axis,
                first: .tile(first),
                second: .tile(second)
            )
        )
    }

    private func existingTerminalTile(
        for sessionRef: SessionRef
    ) -> (workbenchIndex: Int, tile: WorkbenchTile)? {
        for (workbenchIndex, workbench) in workbenches.enumerated() {
            if let tile = workbench.tiles.first(where: { tile in
                guard case .terminal(let storedSessionRef) = tile.kind else {
                    return false
                }
                return storedSessionRef == sessionRef
            }) {
                return (workbenchIndex, tile)
            }
        }
        return nil
    }

    private func updateExistingTerminalTile(
        inWorkbenchAt index: Int,
        tile: WorkbenchTile,
        incomingRef: SessionRef
    ) -> Bool {
        guard workbenches.indices.contains(index) else { return false }
        guard case .terminal(let existingRef) = tile.kind else { return false }

        let mergedRef = existingRef.mergingStoredHints(from: incomingRef)
        guard hasDifferentStoredFields(lhs: existingRef, rhs: mergedRef) else {
            return false
        }

        let updatedTile = WorkbenchTile(id: tile.id, kind: .terminal(sessionRef: mergedRef))
        var workbench = workbenches[index]
        guard let updatedRoot = workbench.root.replacing(tileID: tile.id, with: .tile(updatedTile)) else {
            fatalError("WorkbenchStoreV2.updateExistingTerminalTile: tile \(tile.id) not found in tree")
        }
        workbench.root = updatedRoot
        workbenches[index] = workbench
        return true
    }

    private func hasDifferentStoredFields(lhs: SessionRef, rhs: SessionRef) -> Bool {
        lhs.target != rhs.target
            || lhs.sessionName != rhs.sessionName
            || lhs.lastSeenSessionID != rhs.lastSeenSessionID
            || lhs.lastSeenRepoRoot != rhs.lastSeenRepoRoot
    }

    private func rebindObservedTerminalTile(
        tileID: UUID,
        to observedRef: SessionRef,
        inWorkbenchAt index: Int
    ) -> Bool {
        guard workbenches.indices.contains(index) else { return false }
        guard let existingTile = workbenches[index].tiles.first(where: { $0.id == tileID }) else { return false }
        guard case .terminal(let existingRef) = existingTile.kind else { return false }
        guard existingRef != observedRef else { return false }

        let updatedTile = WorkbenchTile(
            id: tileID,
            kind: .terminal(sessionRef: observedRef),
            pinned: existingTile.pinned
        )
        guard let updatedRoot = workbenches[index].root.replacing(tileID: tileID, with: .tile(updatedTile)) else {
            fatalError("WorkbenchStoreV2.rebindObservedTerminalTile: tile \(tileID) not found in tree")
        }
        workbenches[index].root = updatedRoot
        return true
    }

    private func focusTile(id: UUID, inWorkbenchAt index: Int) -> Bool {
        guard workbenches.indices.contains(index) else { return false }
        guard workbenches[index].root.tileIDs.contains(id) else { return false }
        var workbench = workbenches[index]
        guard workbench.focusedTileID != id else { return false }
        workbench.focusedTileID = id
        workbenches[index] = workbench
        return true
    }

    // MARK: - Tile Mutations

    /// Removes the tile with the given id from whichever workbench contains it.
    /// The containing split is collapsed to its sibling. Focus is repaired when
    /// the removed tile was the focused one.
    func removeTile(id: UUID) {
        for index in workbenches.indices {
            guard workbenches[index].root.tileIDs.contains(id) else { continue }
            var workbench = workbenches[index]
            let removedTile = workbench.tiles.first(where: { $0.id == id })
            if let updatedRoot = workbench.root.removingTile(id: id) {
                workbench.root = updatedRoot
            } else {
                workbench.root = .empty(WorkbenchEmptyNode())
            }
            if workbench.focusedTileID == id {
                workbench.focusedTileID = workbench.root.tiles.first?.id
            }
            if let removedTile,
               case .terminal(let sessionRef) = removedTile.kind,
               let runtimeState = activePaneRuntimeByWorkbenchID[workbench.id],
               runtimeState.tileID == removedTile.id,
               runtimeState.resolvedPaneRef?.target == sessionRef.target,
               runtimeState.resolvedPaneRef?.sessionName == sessionRef.sessionName {
                activePaneRuntimeByWorkbenchID.removeValue(forKey: workbench.id)
            }
            workbenches[index] = workbench
            _ = syncActivePaneRuntimeForFocusedTile(inWorkbenchAt: index)
            autosaveIfNeeded()
            return
        }
    }

    /// Rebinds the terminal tile identified by `tileID` to `newRef`, preserving
    /// tile identity. If target or sessionName changes, stale hint fields
    /// (lastSeenSessionID, lastSeenRepoRoot) are cleared.
    func rebindTerminal(tileID: UUID, to newRef: SessionRef) {
        for index in workbenches.indices {
            guard let existingTile = workbenches[index].tiles.first(where: { $0.id == tileID }) else { continue }
            guard case .terminal(let existingRef) = existingTile.kind else { continue }
            var ref = newRef
            if ref.target != existingRef.target || ref.sessionName != existingRef.sessionName {
                ref.lastSeenSessionID = nil
                ref.lastSeenRepoRoot = nil
            }
            let updatedTile = WorkbenchTile(id: tileID, kind: .terminal(sessionRef: ref))
            guard let updatedRoot = workbenches[index].root.replacing(tileID: tileID, with: .tile(updatedTile)) else {
                fatalError("WorkbenchStoreV2.rebindTerminal: tile \(tileID) not found in tree")
            }
            workbenches[index].root = updatedRoot
            _ = syncActivePaneRuntimeAfterTerminalOpen(
                sessionRef: ref,
                activePaneRef: nil,
                tileID: tileID,
                inWorkbenchAt: index
            )
            autosaveIfNeeded()
            return
        }
    }

    /// Rebinds the document tile identified by `tileID` to `newRef`, preserving
    /// tile identity and existing pinning state.
    func rebindDocument(tileID: UUID, to newRef: DocumentRef) {
        for index in workbenches.indices {
            guard let existingTile = workbenches[index].tiles.first(where: { $0.id == tileID }) else { continue }
            guard case .document = existingTile.kind else { continue }
            let updatedTile = WorkbenchTile(id: tileID, kind: .document(ref: newRef), pinned: existingTile.pinned)
            guard let updatedRoot = workbenches[index].root.replacing(tileID: tileID, with: .tile(updatedTile)) else {
                fatalError("WorkbenchStoreV2.rebindDocument: tile \(tileID) not found in tree")
            }
            workbenches[index].root = updatedRoot
            autosaveIfNeeded()
            return
        }
    }

    @discardableResult
    func syncTerminalNavigation(
        tileID: UUID,
        preferredWindowID: String?,
        preferredPaneID: String?,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) -> Bool {
        for index in workbenches.indices {
            guard let existingTile = workbenches[index].tiles.first(where: { $0.id == tileID }) else { continue }
            guard case .terminal(let existingRef) = existingTile.kind else { continue }

            let normalizedWindowID = Self.normalizedNavigationField(preferredWindowID)
            let normalizedPaneID = Self.normalizedNavigationField(preferredPaneID)
            let didChangeActivePane = syncObservedPaneRuntime(
                tileID: tileID,
                sessionRef: existingRef,
                observedPaneRef: Self.activePaneRef(
                    target: existingRef.target,
                    sessionName: existingRef.sessionName,
                    windowID: normalizedWindowID,
                    paneID: normalizedPaneID,
                    paneInstanceID: paneInstanceID
                )
            )
            if didChangeActivePane {
                autosaveIfNeeded()
                return true
            }
            return false
        }
        return false
    }

    @discardableResult
    func syncTerminalObservation(
        tileID: UUID,
        observedSessionName: String,
        preferredWindowID: String?,
        preferredPaneID: String?,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) throws -> Bool {
        let normalizedSessionName = observedSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionName.isEmpty else { return false }

        for index in workbenches.indices {
            guard let existingTile = workbenches[index].tiles.first(where: { $0.id == tileID }) else { continue }
            guard case .terminal(let existingRef) = existingTile.kind else { continue }

            let observedRef = SessionRef(
                target: existingRef.target,
                sessionName: normalizedSessionName
            )
            let normalizedWindowID = Self.normalizedNavigationField(preferredWindowID)
            let normalizedPaneID = Self.normalizedNavigationField(preferredPaneID)
            let observedPaneRef = Self.activePaneRef(
                target: observedRef.target,
                sessionName: observedRef.sessionName,
                windowID: normalizedWindowID,
                paneID: normalizedPaneID,
                paneInstanceID: paneInstanceID
            )
            let workbenchID = workbenches[index].id
            let sessionChanged = existingRef.sessionName != observedRef.sessionName
            var didChange = false

            if sessionChanged {
                if let collision = existingTerminalTile(for: observedRef),
                   !(collision.workbenchIndex == index && collision.tile.id == tileID) {
                    throw WorkbenchStoreV2Error.observedSessionCollision(
                        target: observedRef.target,
                        sessionName: observedRef.sessionName
                    )
                }

                didChange = rebindObservedTerminalTile(
                    tileID: tileID,
                    to: observedRef,
                    inWorkbenchAt: index
                ) || didChange

                let focusRequestNonce = activePaneRuntimeByWorkbenchID[workbenchID]?.focusRequestNonce ?? 0
                let nextState = WorkbenchActivePaneRuntimeState(
                    tileID: tileID,
                    desiredPaneRef: nil,
                    observedPaneRef: observedPaneRef,
                    focusRequestNonce: focusRequestNonce,
                    desiredMatchObservationCount: 0,
                    desiredObservationConfirmationTarget: 0
                )
                if activePaneRuntimeByWorkbenchID[workbenchID] != nextState {
                    activePaneRuntimeByWorkbenchID[workbenchID] = nextState
                    didChange = true
                }
            } else {
                didChange = syncObservedPaneRuntime(
                    tileID: tileID,
                    sessionRef: observedRef,
                    observedPaneRef: observedPaneRef
                ) || didChange
            }

            if didChange {
                autosaveIfNeeded()
            }
            return didChange
        }
        return false
    }

    private func autosaveIfNeeded() {
        guard persistence != nil else { return }
        do {
            try save()
        } catch {
            fatalError("WorkbenchStoreV2 autosave failed: \(error)")
        }
    }

    private static func normalizedNavigationField(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func targetRef(for source: String, hostsConfig: HostsConfig) -> TargetRef {
        if source == "local" {
            return .local
        }
        return .remote(hostKey: hostsConfig.remoteHostKey(for: source))
    }

    private static func activePaneRef(for pane: AgtmuxPane, hostsConfig: HostsConfig) -> ActivePaneRef {
        ActivePaneRef(
            target: targetRef(for: pane.source, hostsConfig: hostsConfig),
            sessionName: pane.sessionName,
            windowID: pane.windowId,
            paneID: pane.paneId,
            paneInstanceID: pane.paneInstanceID
        )
    }

    private static func activePaneRef(
        target: TargetRef,
        sessionName: String,
        windowID: String?,
        paneID: String?,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) -> ActivePaneRef? {
        guard let windowID = normalizedNavigationField(windowID),
              let paneID = normalizedNavigationField(paneID) else {
            return nil
        }
        return ActivePaneRef(
            target: target,
            sessionName: sessionName,
            windowID: windowID,
            paneID: paneID,
            paneInstanceID: paneInstanceID
        )
    }

    private func syncActivePaneRuntimeAfterTerminalOpen(
        sessionRef: SessionRef,
        activePaneRef: ActivePaneRef?,
        tileID: UUID,
        inWorkbenchAt index: Int
    ) -> Bool {
        guard workbenches.indices.contains(index) else { return false }
        let workbenchID = workbenches[index].id
        if let activePaneRef {
            return setDesiredActivePaneRuntime(
                tileID: tileID,
                paneRef: activePaneRef,
                inWorkbenchID: workbenchID
            )
        }

        guard let current = activePaneRuntimeByWorkbenchID[workbenchID]?.resolvedPaneRef else { return false }
        guard current.target != sessionRef.target || current.sessionName != sessionRef.sessionName else {
            return false
        }
        activePaneRuntimeByWorkbenchID.removeValue(forKey: workbenchID)
        return true
    }

    private func syncActivePaneRuntimeForFocusedTile(inWorkbenchAt index: Int) -> Bool {
        guard workbenches.indices.contains(index) else { return false }
        guard let focusedTileID = workbenches[index].focusedTileID,
              let focusedTile = workbenches[index].tiles.first(where: { $0.id == focusedTileID }) else {
            return false
        }
        guard case .terminal(let sessionRef) = focusedTile.kind else {
            return false
        }
        let workbenchID = workbenches[index].id
        guard let currentState = activePaneRuntimeByWorkbenchID[workbenchID] else {
            activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
                tileID: focusedTileID,
                desiredPaneRef: nil,
                observedPaneRef: nil,
                focusRequestNonce: 0,
                desiredMatchObservationCount: 0,
                desiredObservationConfirmationTarget: 0
            )
            return true
        }
        guard currentState.tileID != focusedTileID
                || !(currentState.resolvedPaneRef?.matches(sessionRef: sessionRef) ?? true) else {
            return false
        }
        activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
            tileID: focusedTileID,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            focusRequestNonce: currentState.focusRequestNonce,
            desiredMatchObservationCount: 0,
            desiredObservationConfirmationTarget: 0
        )
        return true
    }

    private func setDesiredActivePaneRuntime(
        tileID: UUID,
        paneRef: ActivePaneRef,
        inWorkbenchID workbenchID: UUID
    ) -> Bool {
        let current = activePaneRuntimeByWorkbenchID[workbenchID]
        if let current,
           current.tileID == tileID,
           current.desiredPaneRef == paneRef {
            return false
        }

        var next = current ?? WorkbenchActivePaneRuntimeState(
            tileID: tileID,
            desiredPaneRef: nil,
            observedPaneRef: nil,
            focusRequestNonce: 0,
            desiredMatchObservationCount: 0,
            desiredObservationConfirmationTarget: 0
        )
        let confirmationTarget = desiredObservationConfirmationTarget(
            currentObservedPaneRef: current?.observedPaneRef,
            incomingPaneRef: paneRef
        )
        next = WorkbenchActivePaneRuntimeState(
            tileID: tileID,
            desiredPaneRef: paneRef,
            observedPaneRef: current?.observedPaneRef,
            focusRequestNonce: (current?.focusRequestNonce ?? 0) + 1,
            desiredMatchObservationCount: 0,
            desiredObservationConfirmationTarget: confirmationTarget
        )
        if let observed = next.observedPaneRef,
           Self.paneRefsMatchForRuntime(observed, paneRef) {
            if confirmationTarget <= 1 {
                next.desiredPaneRef = nil
                next.observedPaneRef = paneRef
                next.desiredMatchObservationCount = 0
                next.desiredObservationConfirmationTarget = 0
            } else {
                next.observedPaneRef = paneRef
                next.desiredMatchObservationCount = 1
            }
        }
        activePaneRuntimeByWorkbenchID[workbenchID] = next
        return true
    }

    private func syncObservedPaneRuntime(
        tileID: UUID,
        sessionRef: SessionRef,
        observedPaneRef: ActivePaneRef?
    ) -> Bool {
        guard let observedPaneRef else { return false }
        guard let workbenchIndex = workbenches.firstIndex(where: { $0.tiles.contains(where: { $0.id == tileID }) }) else {
            return false
        }
        let workbenchID = workbenches[workbenchIndex].id
        let current = activePaneRuntimeByWorkbenchID[workbenchID]
            ?? WorkbenchActivePaneRuntimeState(
                tileID: tileID,
                desiredPaneRef: nil,
                observedPaneRef: nil,
                focusRequestNonce: 0,
                desiredMatchObservationCount: 0,
                desiredObservationConfirmationTarget: 0
            )

        if current.tileID != tileID {
            return false
        }

        if let desiredPaneRef = current.desiredPaneRef {
            guard observedPaneRef.matches(sessionRef: sessionRef) else { return false }
            if Self.paneRefsMatchForRuntime(desiredPaneRef, observedPaneRef) {
                let nextMatchCount: UInt8
                if let currentObserved = current.observedPaneRef,
                   Self.paneRefsMatchForRuntime(currentObserved, observedPaneRef) {
                    nextMatchCount = min(
                        current.desiredMatchObservationCount + 1,
                        current.desiredObservationConfirmationTarget
                    )
                } else {
                    nextMatchCount = 1
                }
                if nextMatchCount < current.desiredObservationConfirmationTarget {
                    activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
                        tileID: tileID,
                        desiredPaneRef: desiredPaneRef,
                        observedPaneRef: observedPaneRef,
                        focusRequestNonce: current.focusRequestNonce,
                        desiredMatchObservationCount: nextMatchCount,
                        desiredObservationConfirmationTarget: current.desiredObservationConfirmationTarget
                    )
                    return current.observedPaneRef != observedPaneRef
                        || current.desiredMatchObservationCount != nextMatchCount
                }
                activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
                    tileID: tileID,
                    desiredPaneRef: nil,
                    observedPaneRef: observedPaneRef,
                    focusRequestNonce: current.focusRequestNonce,
                    desiredMatchObservationCount: 0,
                    desiredObservationConfirmationTarget: 0
                )
                return current.observedPaneRef != observedPaneRef || current.desiredPaneRef != nil
            }
            guard current.observedPaneRef != observedPaneRef else { return false }
            activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
                tileID: tileID,
                desiredPaneRef: desiredPaneRef,
                observedPaneRef: observedPaneRef,
                focusRequestNonce: current.focusRequestNonce,
                desiredMatchObservationCount: 0,
                desiredObservationConfirmationTarget: current.desiredObservationConfirmationTarget
            )
            return true
        }

        guard observedPaneRef.matches(sessionRef: sessionRef) else { return false }
        guard current.observedPaneRef != observedPaneRef else { return false }
        activePaneRuntimeByWorkbenchID[workbenchID] = WorkbenchActivePaneRuntimeState(
            tileID: tileID,
            desiredPaneRef: nil,
            observedPaneRef: observedPaneRef,
            focusRequestNonce: current.focusRequestNonce,
            desiredMatchObservationCount: 0,
            desiredObservationConfirmationTarget: 0
        )
        return true
    }

    private func activePaneRuntime(for workbench: Workbench) -> WorkbenchActivePaneRuntimeState? {
        guard let state = activePaneRuntimeByWorkbenchID[workbench.id] else { return nil }
        guard workbench.tiles.contains(where: { $0.id == state.tileID }) else { return nil }
        return state
    }

    private static func seedActivePaneRuntimeState(
        from workbenches: [Workbench]
    ) -> [UUID: WorkbenchActivePaneRuntimeState] {
        Dictionary(uniqueKeysWithValues: workbenches.compactMap { workbench in
            guard let activePaneRef = workbench.activePaneRef else { return nil }
            guard let tileID = workbench.tiles.first(where: { tile in
                guard case .terminal(let sessionRef) = tile.kind else { return false }
                return activePaneRef.matches(sessionRef: sessionRef)
            })?.id else {
                return nil
            }
            return (
                workbench.id,
                WorkbenchActivePaneRuntimeState(
                    tileID: tileID,
                    desiredPaneRef: nil,
                    observedPaneRef: activePaneRef,
                    focusRequestNonce: 0,
                    desiredMatchObservationCount: 0,
                    desiredObservationConfirmationTarget: 0
                )
            )
        })
    }

    private static func paneRefsMatchForRuntime(
        _ lhs: ActivePaneRef,
        _ rhs: ActivePaneRef
    ) -> Bool {
        guard lhs.target == rhs.target,
              lhs.sessionName == rhs.sessionName,
              lhs.windowID == rhs.windowID,
              lhs.paneID == rhs.paneID else {
            return false
        }
        switch (lhs.paneInstanceID, rhs.paneInstanceID) {
        case let (.some(left), .some(right)):
            return left == right
        default:
            return true
        }
    }

    private func desiredObservationConfirmationTarget(
        currentObservedPaneRef: ActivePaneRef?,
        incomingPaneRef: ActivePaneRef
    ) -> UInt8 {
        guard let currentObservedPaneRef else {
            return Self.initialAttachObservationConfirmationCount
        }
        guard currentObservedPaneRef.target == incomingPaneRef.target,
              currentObservedPaneRef.sessionName == incomingPaneRef.sessionName else {
            return Self.initialAttachObservationConfirmationCount
        }
        return Self.retargetObservationConfirmationCount
    }
}

// MARK: - WorkbenchNode removal

private extension WorkbenchNode {
    /// Returns this node with the tile `id` removed, collapsing the containing
    /// split to its sibling. Returns `nil` if this node itself is the target tile.
    func removingTile(id: UUID, depth: Int = 0) -> WorkbenchNode? {
        guard depth < 256 else { return self }
        switch self {
        case .empty:
            return self
        case .tile(let tile):
            return tile.id == id ? nil : self
        case .split(var split):
            if split.first.tileIDs.contains(id) {
                if let updated = split.first.removingTile(id: id, depth: depth + 1) {
                    split.first = updated
                    return .split(split)
                }
                // First collapsed to nothing — promote second
                return split.second
            }
            if split.second.tileIDs.contains(id) {
                if let updated = split.second.removingTile(id: id, depth: depth + 1) {
                    split.second = updated
                    return .split(split)
                }
                // Second collapsed to nothing — promote first
                return split.first
            }
            return self
        }
    }
}
