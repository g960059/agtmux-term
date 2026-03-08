import Foundation
import AgtmuxTermCore

enum WorkbenchV2NavigationSyncResolver {
    static func shouldApplyNavigationIntent(
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?,
        liveTarget: WorkbenchV2TerminalLiveTarget?
    ) -> Bool {
        _ = observedPaneRef
        guard let desiredPaneRef else { return false }
        guard let liveTarget else { return true }
        return desiredPaneRef.sessionName != liveTarget.sessionName
            || desiredPaneRef.windowID != liveTarget.windowID
            || desiredPaneRef.paneID != liveTarget.paneID
    }
}
