import Foundation

/// Compatibility-only fallback for product UI that still has to derive display
/// state from legacy collapsed `AgtmuxPane.activityState`.
package enum PaneDisplayCompatFallback {
    package static func primaryState(for pane: AgtmuxPane) -> PanePresentationPrimaryState {
        primaryState(from: pane.activityState)
    }

    package static func needsAttention(for pane: AgtmuxPane) -> Bool {
        needsAttention(from: pane.activityState)
    }

    package static func primaryState(from activityState: ActivityState) -> PanePresentationPrimaryState {
        switch activityState {
        case .running:
            return .running
        case .waitingApproval:
            return .waitingApproval
        case .waitingInput:
            return .waitingUserInput
        case .error:
            return .error
        case .idle:
            return .idle
        case .unknown:
            return .inactive
        }
    }

    package static func needsAttention(from activityState: ActivityState) -> Bool {
        activityState == .waitingApproval
            || activityState == .waitingInput
            || activityState == .error
    }

    package static func freshnessText(for pane: AgtmuxPane) -> String? {
        guard pane.isManaged else { return nil }
        // Daemon does not send age_secs; compute from updatedAt when available.
        let ageSecs = pane.ageSecs ?? pane.updatedAt.map { max(0, Int(-$0.timeIntervalSinceNow)) }
        return freshnessText(ageSecs: ageSecs, activityState: pane.activityState)
    }

    package static func freshnessText(ageSecs: Int?, activityState _: ActivityState) -> String? {
        guard let ageSecs else { return nil }
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
