import Foundation
import AgtmuxTermCore

enum PaneRowAccessibility {
    static func summary(for pane: AgtmuxPane, presentation: PanePresentationState?, isSelected: Bool) -> String {
        summary(for: PaneDisplayState(pane: pane, presentation: presentation), isSelected: isSelected)
    }

    static func summary(for display: PaneDisplayState, isSelected: Bool) -> String {
        let selection = isSelected ? "selected" : "unselected"
        let trailingTimestampText = display.trailingTimestampText ?? "none"
        let trailingTimestampVisible = display.trailingTimestampText != nil ? "true" : "false"
        let badgeRing = badgeRingState(for: display.primaryState)

        return [
            "selection=\(selection)",
            "presence=\(display.presence.rawValue)",
            "provider=\(display.provider?.rawValue ?? "none")",
            "primary=\(display.primaryState.rawValue)",
            "badge_ring=\(badgeRing)",
            "freshness=\(display.freshnessText ?? "none")",
            "trailing_timestamp=\(trailingTimestampText)",
            "trailing_timestamp_visible=\(trailingTimestampVisible)",
        ].joined(separator: ", ")
    }

    private static func badgeRingState(for primaryState: PanePresentationPrimaryState) -> String {
        switch primaryState {
        case .running:
            return "running"
        case .waitingApproval:
            return "waiting_approval"
        case .waitingUserInput:
            return "waiting_user_input"
        case .error:
            return "error"
        case .completedIdle, .idle, .inactive:
            return "none"
        }
    }
}
