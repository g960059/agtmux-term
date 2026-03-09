import Foundation

/// Product-facing display adapter for one pane row.
///
/// This keeps legacy `AgtmuxPane` fallback collapse in one place while the
/// product-facing UI moves toward `PanePresentationState`.
package struct PaneDisplayState: Equatable, Sendable {
    package let provider: Provider?
    package let presence: PanePresence
    package let primaryState: PanePresentationPrimaryState
    package let freshnessText: String?
    package let isManaged: Bool
    package let needsAttention: Bool

    package init(pane: AgtmuxPane, presentation: PanePresentationState?) {
        if let presentation {
            self.provider = presentation.provider
            self.presence = presentation.presence == .managed ? .managed : .unmanaged
            self.primaryState = Self.primaryState(from: pane, presentation: presentation)
            self.freshnessText = Self.freshnessText(ageSecs: pane.ageSecs, pane: pane, presentation: presentation)
            self.isManaged = presentation.presence == .managed
            self.needsAttention = Self.needsAttention(from: presentation)
            return
        }

        let legacyPrimary = PaneDisplayCompatFallback.primaryState(for: pane)
        self.provider = pane.provider
        self.presence = pane.presence
        self.primaryState = legacyPrimary
        self.freshnessText = PaneDisplayCompatFallback.freshnessText(for: pane)
        self.isManaged = pane.isManaged
        self.needsAttention = pane.needsAttention
    }

    private static func primaryState(from pane: AgtmuxPane, presentation: PanePresentationState) -> PanePresentationPrimaryState {
        switch presentation.primaryState {
        case .completedIdle:
            // Keep current low-risk UI behavior: completed idle still renders through
            // the existing idle visual state until the broader cutover lands.
            return .completedIdle
        default:
            return presentation.primaryState
        }
    }

    private static func needsAttention(from presentation: PanePresentationState) -> Bool {
        switch presentation.primaryState {
        case .waitingApproval, .waitingUserInput, .error:
            return true
        case .running, .completedIdle, .idle, .inactive:
            return false
        }
    }

    private static func freshnessText(
        ageSecs: Int?,
        pane: AgtmuxPane,
        presentation: PanePresentationState
    ) -> String? {
        switch presentation.freshnessState {
        case .down:
            return "down"
        case .degraded:
            return "degraded"
        case .fresh:
            break
        }

        if presentation.primaryState == .running {
            return nil
        }
        return PaneDisplayCompatFallback.freshnessText(ageSecs: ageSecs, activityState: pane.activityState)
    }
}
