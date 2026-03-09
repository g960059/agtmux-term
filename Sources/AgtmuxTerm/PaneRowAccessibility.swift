import Foundation
import AgtmuxTermCore

enum PaneRowAccessibility {
    static func summary(for pane: AgtmuxPane, isSelected: Bool) -> String {
        summary(for: pane, presentation: nil, isSelected: isSelected)
    }

    static func summary(for pane: AgtmuxPane, presentation: PanePresentationState?, isSelected: Bool) -> String {
        let selection = isSelected ? "selected" : "unselected"
        let provider = presentation?.provider?.rawValue ?? pane.provider?.rawValue ?? "none"
        let presence = presentation?.presence.rawValue ?? pane.presence.rawValue
        let activity = presentation?.primaryState.rawValue ?? pane.activityState.rawValue
        let freshness = formattedFreshness(
            ageSecs: pane.ageSecs,
            activityState: pane.activityState,
            presentation: presentation
        )

        return [
            "selection=\(selection)",
            "presence=\(presence)",
            "provider=\(provider)",
            "activity=\(activity)",
            "freshness=\(freshness)",
        ].joined(separator: ", ")
    }

    static func formattedFreshness(ageSecs: Int?, activityState: ActivityState) -> String {
        formattedFreshness(ageSecs: ageSecs, activityState: activityState, presentation: nil)
    }

    static func formattedFreshness(
        ageSecs: Int?,
        activityState: ActivityState,
        presentation: PanePresentationState?
    ) -> String {
        if let presentation {
            switch presentation.freshnessState {
            case .down:
                return "down"
            case .degraded:
                return "degraded"
            case .fresh:
                break
            }
            if presentation.primaryState == .running {
                return "none"
            }
        }

        return formattedLegacyFreshness(ageSecs: ageSecs, activityState: activityState)
    }

    static func formattedLegacyFreshness(ageSecs: Int?, activityState: ActivityState) -> String {
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
