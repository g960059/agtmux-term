import Foundation
import AgtmuxTermCore

struct WorkbenchV2ActivePaneSelection: Equatable {
    let workbenchID: UUID
    let tileID: UUID
    let source: String
    let sessionName: String
    let windowID: String
    let paneID: String
    let paneInstanceID: AgtmuxSyncV2PaneInstanceID?
    let paneInventoryID: String?
}

enum WorkbenchV2ActivePaneSelectionResolver {
    static func resolve(
        workbench: Workbench?,
        runtimeState: WorkbenchActivePaneRuntimeState?,
        panes: [AgtmuxPane],
        hostsConfig: HostsConfig
    ) -> WorkbenchV2ActivePaneSelection? {
        guard let workbench,
              let runtimeState,
              let activePaneRef = runtimeState.resolvedPaneRef else { return nil }
        guard let tile = workbench.tiles.first(where: { $0.id == runtimeState.tileID }),
              case .terminal(let sessionRef) = tile.kind,
              activePaneRef.matches(sessionRef: sessionRef) else {
            return nil
        }

        let source = source(for: activePaneRef.target, hostsConfig: hostsConfig)
        let paneInventoryID = resolvePaneInventoryID(
            source: source,
            activePaneRef: activePaneRef,
            panes: panes
        )

        return WorkbenchV2ActivePaneSelection(
            workbenchID: workbench.id,
            tileID: runtimeState.tileID,
            source: source,
            sessionName: activePaneRef.sessionName,
            windowID: activePaneRef.windowID,
            paneID: activePaneRef.paneID,
            paneInstanceID: activePaneRef.paneInstanceID,
            paneInventoryID: paneInventoryID
        )
    }

    static func resolvePaneInventoryID(
        source: String,
        activePaneRef: ActivePaneRef,
        panes: [AgtmuxPane]
    ) -> String? {
        let sessionPanes = panes.filter { pane in
            pane.source == source && pane.sessionName == activePaneRef.sessionName
        }

        if let paneInstanceID = activePaneRef.paneInstanceID {
            let exactMatches = sessionPanes.filter { $0.paneInstanceID == paneInstanceID }
            guard exactMatches.count == 1 else {
                return nil
            }
            return exactMatches[0].id
        }

        let locationMatches = sessionPanes.filter { pane in
            pane.windowId == activePaneRef.windowID && pane.paneId == activePaneRef.paneID
        }
        guard locationMatches.count == 1 else {
            return nil
        }
        return locationMatches[0].id
    }

    private static func source(
        for target: TargetRef,
        hostsConfig: HostsConfig
    ) -> String {
        switch target {
        case .local:
            return "local"
        case .remote(let hostKey):
            return hostsConfig.host(id: hostKey)?.hostname ?? hostKey
        }
    }
}
