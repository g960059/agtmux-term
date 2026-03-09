import Foundation
import AgtmuxTermCore

enum LocalMetadataOverlayError: LocalizedError {
    case ambiguousBootstrapLocation(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousBootstrapLocation(let metadataKey):
            return "Local metadata protocol parse failed: metadata bootstrap ambiguous exact pane location \(metadataKey)"
        }
    }
}

struct LocalMetadataOverlayCache: Equatable {
    let metadataByPaneKey: [String: AgtmuxPane]
    let presentationByPaneKey: [String: PanePresentationState]
}

struct LocalMetadataOverlayStore {
    private struct BootstrapMetadataIdentity: Hashable {
        let sessionKey: String
        let paneInstanceID: AgtmuxSyncV2PaneInstanceID
    }

    private struct LocalV3MetadataOverlay {
        let pane: AgtmuxPane
        let presentation: PanePresentationState
    }

    let inventory: [AgtmuxPane]
    let metadataByPaneKey: [String: AgtmuxPane]
    let presentationByPaneKey: [String: PanePresentationState]
    let log: (String) -> Void

    init(
        inventory: [AgtmuxPane],
        metadataByPaneKey: [String: AgtmuxPane],
        presentationByPaneKey: [String: PanePresentationState],
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.inventory = inventory
        self.metadataByPaneKey = metadataByPaneKey
        self.presentationByPaneKey = presentationByPaneKey
        self.log = log
    }

    static func paneMetadataKey(for pane: AgtmuxPane) -> String {
        "\(pane.source):\(pane.sessionName):\(pane.windowId):\(pane.paneId)"
    }

    static func metadataSessionKey(for pane: AgtmuxPane) -> String {
        pane.metadataSessionKey ?? pane.sessionName
    }

    func bootstrapMetadataMap(from metadata: [AgtmuxPane]) throws -> [String: AgtmuxPane] {
        let grouped = Dictionary(grouping: metadata.filter { $0.source == "local" }) {
            Self.paneMetadataKey(for: $0)
        }
        var resolved: [String: AgtmuxPane] = [:]
        for (metadataKey, panes) in grouped {
            resolved[metadataKey] = try resolveBootstrapMetadataPane(
                candidates: panes,
                metadataKey: metadataKey
            )
        }
        return resolved
    }

    func bootstrapCaches(from bootstrap: AgtmuxSyncV3Bootstrap) throws -> LocalMetadataOverlayCache {
        let grouped = Dictionary(grouping: bootstrap.panes.map(localMetadataOverlay(from:))) {
            Self.paneMetadataKey(for: $0.pane)
        }
        var resolvedMetadata: [String: AgtmuxPane] = [:]
        var resolvedPresentation: [String: PanePresentationState] = [:]

        for (metadataKey, overlays) in grouped {
            let resolvedPane = try resolveBootstrapMetadataPane(
                candidates: overlays.map(\.pane),
                metadataKey: metadataKey
            )
            guard let overlay = overlays.first(where: {
                $0.pane.metadataSessionKey == resolvedPane.metadataSessionKey
                    && $0.pane.paneInstanceID == resolvedPane.paneInstanceID
            }) else {
                throw LocalMetadataOverlayError.ambiguousBootstrapLocation(metadataKey)
            }
            resolvedMetadata[metadataKey] = resolvedPane
            resolvedPresentation[metadataKey] = overlay.presentation
        }

        return LocalMetadataOverlayCache(
            metadataByPaneKey: resolvedMetadata,
            presentationByPaneKey: resolvedPresentation
        )
    }

    func apply(_ payload: AgtmuxSyncV2Changes) -> [String: AgtmuxPane] {
        var nextMetadataByPaneKey = metadataByPaneKey

        for change in payload.changes {
            guard let paneState = change.pane else { continue }
            guard let basePane = metadataBasePane(for: paneState) else {
                log(
                    "sync-v2 pane change dropped for unknown exact pane " +
                    "\(paneState.sessionKey)/\(paneState.paneId)"
                )
                continue
            }
            let key = Self.paneMetadataKey(for: basePane)
            nextMetadataByPaneKey[key] = overlayLocalMetadata(paneState, onto: basePane)
        }

        return nextMetadataByPaneKey
    }

    func apply(_ payload: AgtmuxSyncV3Changes) -> LocalMetadataOverlayCache {
        var nextMetadataByPaneKey = metadataByPaneKey
        var nextPresentationByPaneKey = presentationByPaneKey

        for change in payload.changes {
            let matchingKeys = nextMetadataByPaneKey.compactMap { key, pane in
                matchesV3ExactIdentity(
                    pane,
                    sessionKey: change.sessionKey,
                    paneInstanceID: change.paneInstanceID
                ) ? key : nil
            }
            for key in matchingKeys {
                nextMetadataByPaneKey.removeValue(forKey: key)
                nextPresentationByPaneKey.removeValue(forKey: key)
            }

            switch change.kind {
            case .remove:
                continue
            case .upsert:
                guard let paneSnapshot = change.pane else { continue }
                let overlay = localMetadataOverlay(from: paneSnapshot)
                let key = Self.paneMetadataKey(for: overlay.pane)
                if let existingPane = nextMetadataByPaneKey[key],
                   existingPane.source == "local",
                   (Self.metadataSessionKey(for: existingPane) != Self.metadataSessionKey(for: overlay.pane)
                    || existingPane.paneInstanceID != overlay.pane.paneInstanceID),
                   !allowsVisibleRowReplacement(existingPane: existingPane, incomingPane: overlay.pane) {
                    log(
                        "sync-v3 pane upsert dropped for conflicting exact pane " +
                        "\(change.sessionKey)/\(change.paneID)"
                    )
                    continue
                }
                nextMetadataByPaneKey[key] = overlay.pane
                nextPresentationByPaneKey[key] = overlay.presentation
            }
        }

        return LocalMetadataOverlayCache(
            metadataByPaneKey: nextMetadataByPaneKey,
            presentationByPaneKey: nextPresentationByPaneKey
        )
    }

    private func resolveBootstrapMetadataPane(
        candidates: [AgtmuxPane],
        metadataKey: String
    ) throws -> AgtmuxPane {
        guard let first = candidates.first else {
            throw LocalMetadataOverlayError.ambiguousBootstrapLocation(metadataKey)
        }

        let grouped = Dictionary(grouping: candidates) { pane in
            BootstrapMetadataIdentity(
                sessionKey: Self.metadataSessionKey(for: pane),
                paneInstanceID: pane.paneInstanceID ?? AgtmuxSyncV2PaneInstanceID(
                    paneId: pane.paneId,
                    generation: nil,
                    birthTs: nil
                )
            )
        }

        guard candidates.count == 1, grouped.count == 1 else {
            throw LocalMetadataOverlayError.ambiguousBootstrapLocation(metadataKey)
        }

        return first
    }

    private func localMetadataOverlay(from snapshot: AgtmuxSyncV3PaneSnapshot) -> LocalV3MetadataOverlay {
        let presentation = PanePresentationState(snapshot: snapshot)
        let pane = AgtmuxPane(
            source: "local",
            paneId: snapshot.paneID,
            sessionName: snapshot.sessionName,
            windowId: snapshot.windowID,
            activityState: PaneMetadataCompatFallback.activityState(from: presentation),
            presence: legacyPresence(from: snapshot.presence),
            provider: snapshot.provider,
            evidenceMode: legacyEvidenceMode(from: snapshot),
            updatedAt: snapshot.updatedAt,
            metadataSessionKey: snapshot.sessionKey,
            paneInstanceID: legacyPaneInstanceID(from: snapshot.paneInstanceID)
        )
        return LocalV3MetadataOverlay(pane: pane, presentation: presentation)
    }

    private func overlayLocalMetadata(_ paneState: AgtmuxSyncV2PaneState, onto basePane: AgtmuxPane) -> AgtmuxPane {
        let isManaged = paneState.presence == .managed
        return AgtmuxPane(
            source: basePane.source,
            paneId: basePane.paneId,
            sessionName: basePane.sessionName,
            sessionGroup: basePane.sessionGroup,
            windowId: basePane.windowId,
            windowIndex: basePane.windowIndex,
            windowName: basePane.windowName,
            activityState: paneState.activityState,
            presence: paneState.presence,
            provider: paneState.provider,
            evidenceMode: paneState.evidenceMode,
            conversationTitle: isManaged ? basePane.conversationTitle : nil,
            currentPath: basePane.currentPath,
            gitBranch: isManaged ? basePane.gitBranch : nil,
            currentCmd: basePane.currentCmd,
            updatedAt: paneState.updatedAt,
            ageSecs: basePane.ageSecs,
            metadataSessionKey: paneState.sessionKey,
            paneInstanceID: paneState.paneInstanceID
        )
    }

    private func resolveMetadataBaseCandidate(
        candidates: [AgtmuxPane],
        paneState: AgtmuxSyncV2PaneState,
        candidateSource: String
    ) -> AgtmuxPane? {
        guard !candidates.isEmpty else { return nil }

        let paneInstanceID = paneState.paneInstanceID
        let exactMatches = candidates.filter { $0.paneInstanceID == paneInstanceID }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            log(
                "sync-v2 pane change dropped for ambiguous exact \(candidateSource) pane " +
                "\(paneState.sessionKey)/\(paneState.paneId)"
            )
            return nil
        }

        if candidates.contains(where: { $0.paneInstanceID != nil }) {
            log(
                "sync-v2 pane change dropped for mismatched pane instance " +
                "\(paneState.sessionKey)/\(paneState.paneId)"
            )
            return nil
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        log(
            "sync-v2 pane change dropped for ambiguous \(candidateSource) pane " +
            "\(paneState.sessionKey)/\(paneState.paneId)"
        )
        return nil
    }

    private func cachedMetadataBasePane(for paneState: AgtmuxSyncV2PaneState) -> (hadCandidates: Bool, pane: AgtmuxPane?) {
        let cachedCandidates = metadataByPaneKey.values.filter { pane in
            pane.source == "local"
                && pane.paneId == paneState.paneId
                && Self.metadataSessionKey(for: pane) == paneState.sessionKey
        }
        if !cachedCandidates.isEmpty {
            return (
                true,
                resolveMetadataBaseCandidate(
                    candidates: cachedCandidates,
                    paneState: paneState,
                    candidateSource: "cached"
                )
            )
        }
        return (false, nil)
    }

    private func visibleSessionName(for sessionKey: String) -> String? {
        let visibleSessionNames = Set<String>(
            metadataByPaneKey.values.compactMap { pane in
                guard pane.source == "local" else { return nil }
                guard Self.metadataSessionKey(for: pane) == sessionKey else { return nil }
                return pane.sessionName
            }
        )
        if visibleSessionNames.count > 1 {
            log("sync-v2 pane change dropped for ambiguous session-key mapping \(sessionKey)")
            return nil
        }
        return visibleSessionNames.first
    }

    private func inventoryMetadataBasePane(
        for paneState: AgtmuxSyncV2PaneState,
        visibleSessionName: String
    ) -> AgtmuxPane? {
        let inventoryCandidates = inventory.filter { pane in
            pane.source == "local"
                && pane.paneId == paneState.paneId
                && pane.sessionName == visibleSessionName
        }
        return resolveMetadataBaseCandidate(
            candidates: inventoryCandidates,
            paneState: paneState,
            candidateSource: "inventory"
        )
    }

    private func metadataBasePane(for paneState: AgtmuxSyncV2PaneState) -> AgtmuxPane? {
        let cachedResolution = cachedMetadataBasePane(for: paneState)
        let cachedBase = cachedResolution.pane
        let inventoryBase = visibleSessionName(for: paneState.sessionKey).flatMap { visibleSessionName in
            inventoryMetadataBasePane(for: paneState, visibleSessionName: visibleSessionName)
        }

        if paneState.presence == .unmanaged {
            return inventoryBase ?? cachedBase
        }
        if cachedResolution.hadCandidates {
            return cachedBase
        }
        return cachedBase ?? inventoryBase
    }

    private func allowsVisibleRowReplacement(existingPane: AgtmuxPane, incomingPane: AgtmuxPane) -> Bool {
        existingPane.source == "local"
            && incomingPane.source == "local"
            && existingPane.paneId == incomingPane.paneId
            && existingPane.sessionName == incomingPane.sessionName
            && existingPane.windowId == incomingPane.windowId
            && incomingPane.presence == .unmanaged
            && incomingPane.provider == nil
    }

    private func matchesV3ExactIdentity(
        _ pane: AgtmuxPane,
        sessionKey: String,
        paneInstanceID: AgtmuxSyncV3PaneInstanceID
    ) -> Bool {
        pane.source == "local"
            && Self.metadataSessionKey(for: pane) == sessionKey
            && pane.paneInstanceID == legacyPaneInstanceID(from: paneInstanceID)
    }

    private func legacyPaneInstanceID(from paneInstanceID: AgtmuxSyncV3PaneInstanceID) -> AgtmuxSyncV2PaneInstanceID {
        AgtmuxSyncV2PaneInstanceID(
            paneId: paneInstanceID.paneId,
            generation: paneInstanceID.generation,
            birthTs: paneInstanceID.birthTs
        )
    }

    private func legacyPresence(from presence: AgtmuxSyncV3Presence) -> PanePresence {
        switch presence {
        case .managed:
            return .managed
        case .unmanaged, .missing:
            return .unmanaged
        }
    }

    private func legacyEvidenceMode(from snapshot: AgtmuxSyncV3PaneSnapshot) -> EvidenceMode {
        guard snapshot.presence == .managed else { return .none }
        let levels = [
            snapshot.freshness.snapshot,
            snapshot.freshness.blocking,
            snapshot.freshness.execution,
        ]
        return levels.contains(where: { $0 != .fresh }) ? .heuristic : .deterministic
    }
}
