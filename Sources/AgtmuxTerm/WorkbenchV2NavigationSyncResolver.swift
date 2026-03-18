import Foundation
import AgtmuxTermCore

enum WorkbenchV2NavigationSyncResolver {
    static func shouldApplyNavigationIntent(
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        liveTarget: WorkbenchV2TerminalLiveTarget?
    ) -> Bool {
        guard let desiredPaneRef else { return false }
        guard let liveTarget else { return true }
        if let observedPaneRef,
           observedPaneRef.sessionName == desiredPaneRef.sessionName,
           observedPaneRef.windowID == desiredPaneRef.windowID,
           observedPaneRef.paneID == desiredPaneRef.paneID,
           (desiredPaneRef.sessionName != liveTarget.sessionName
                || desiredPaneRef.windowID != liveTarget.windowID
                || desiredPaneRef.paneID != liveTarget.paneID) {
            return false
        }
        return desiredPaneRef.sessionName != liveTarget.sessionName
            || desiredPaneRef.windowID != liveTarget.windowID
            || desiredPaneRef.paneID != liveTarget.paneID
    }
}
