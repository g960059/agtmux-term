import Foundation
import AgtmuxTermCore

enum PaneRowAccessibility {
    static func summary(for pane: AgtmuxPane, isSelected: Bool) -> String {
        let selection = isSelected ? "selected" : "unselected"
        let provider = pane.provider?.rawValue ?? "none"
        let freshness = formattedFreshness(ageSecs: pane.ageSecs, activityState: pane.activityState)

        return [
            "selection=\(selection)",
            "presence=\(pane.presence.rawValue)",
            "provider=\(provider)",
            "activity=\(pane.activityState.rawValue)",
            "freshness=\(freshness)",
        ].joined(separator: ", ")
    }

    static func formattedFreshness(ageSecs: Int?, activityState: ActivityState) -> String {
        guard activityState != .running, let ageSecs else { return "none" }
        switch ageSecs {
        case 0..<60:
            return "\(ageSecs)s"
        case 60..<3600:
            return "\(ageSecs / 60)m"
        default:
            return "\(ageSecs / 3600)h"
        }
    }
}
