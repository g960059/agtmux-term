import Foundation
import AgtmuxTermCore

enum PaneRowAccessibility {
    static func summary(for pane: AgtmuxPane, isSelected: Bool) -> String {
        summary(for: PaneDisplayState(pane: pane, presentation: nil), isSelected: isSelected)
    }

    static func summary(for pane: AgtmuxPane, presentation: PanePresentationState?, isSelected: Bool) -> String {
        summary(for: PaneDisplayState(pane: pane, presentation: presentation), isSelected: isSelected)
    }

    static func summary(for display: PaneDisplayState, isSelected: Bool) -> String {
        let selection = isSelected ? "selected" : "unselected"

        return [
            "selection=\(selection)",
            "presence=\(display.presence.rawValue)",
            "provider=\(display.provider?.rawValue ?? "none")",
            "activity=\(display.primaryState.rawValue)",
            "freshness=\(display.freshnessText ?? "none")",
        ].joined(separator: ", ")
    }
}
