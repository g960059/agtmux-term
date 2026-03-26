import Foundation
import AgtmuxTermCore

enum PaneSelectionResolver {
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
            if exactMatches.count == 1 {
                return exactMatches[0].id
            }
            guard exactMatches.isEmpty else {
                return nil
            }

            let locationMatches = sessionPanes.filter { pane in
                pane.windowId == activePaneRef.windowID && pane.paneId == activePaneRef.paneID
            }
            guard locationMatches.count == 1 else {
                return nil
            }
            guard locationMatches[0].paneInstanceID == nil else {
                return nil
            }
            return locationMatches[0].id
        }

        let locationMatches = sessionPanes.filter { pane in
            pane.windowId == activePaneRef.windowID && pane.paneId == activePaneRef.paneID
        }
        guard locationMatches.count == 1 else {
            return nil
        }
        return locationMatches[0].id
    }
}
