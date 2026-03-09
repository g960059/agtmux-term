import Foundation

/// Compatibility-only collapse from structured sync-v3 presentation into the
/// legacy `ActivityState` field still carried by `AgtmuxPane`.
package enum PaneMetadataCompatFallback {
    package static func activityState(from presentation: PanePresentationState) -> ActivityState {
        switch presentation.primaryState {
        case .running:
            return .running
        case .waitingApproval:
            return .waitingApproval
        case .waitingUserInput:
            return .waitingInput
        case .error:
            return .error
        case .completedIdle, .idle:
            return .idle
        case .inactive:
            return .unknown
        }
    }
}
