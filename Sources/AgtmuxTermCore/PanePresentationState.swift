import Foundation

package enum PanePresentationPrimaryState: String, Equatable, Sendable {
    case running
    case waitingApproval = "waiting_approval"
    case waitingUserInput = "waiting_user_input"
    case completedIdle = "completed_idle"
    case error
    case idle
    case inactive
}

package enum PanePresentationFreshnessState: String, Equatable, Sendable {
    case fresh
    case degraded
    case down
}

package struct PanePresentationIdentity: Equatable, Sendable {
    package let sessionName: String
    package let windowID: String
    package let sessionKey: String
    package let paneID: String
    package let paneInstanceID: AgtmuxSyncV3PaneInstanceID

    package init(sessionName: String,
                 windowID: String,
                 sessionKey: String,
                 paneID: String,
                 paneInstanceID: AgtmuxSyncV3PaneInstanceID) {
        self.sessionName = sessionName
        self.windowID = windowID
        self.sessionKey = sessionKey
        self.paneID = paneID
        self.paneInstanceID = paneInstanceID
    }
}

/// Term-local derivation from daemon truth to UI-friendly state.
///
/// This stays deliberately decoupled from raw wire structs so the sidebar and
/// title bar can evolve without rebinding directly to daemon field names.
/// `attention` is preserved as a summary, while request identity truth remains
/// in `pendingRequestIDs`.
package struct PanePresentationState: Equatable, Sendable {
    package let identity: PanePresentationIdentity
    package let presence: PanePresence
    package let provider: Provider?
    package let agentLifecycle: AgtmuxSyncV3AgentLifecycle
    package let threadLifecycle: AgtmuxSyncV3ThreadLifecycle
    package let blocking: AgtmuxSyncV3BlockingState
    package let execution: AgtmuxSyncV3ExecutionState
    package let reviewMode: Bool
    package let subagentActive: Bool
    package let turnOutcome: AgtmuxSyncV3TurnOutcome
    package let primaryState: PanePresentationPrimaryState
    package let freshnessState: PanePresentationFreshnessState
    package let pendingRequestIDs: [String]
    package let needsUserAction: Bool
    package let showsAttentionSummary: Bool
    package let attentionSummary: AgtmuxSyncV3AttentionSummary
    package let providerRaw: AgtmuxSyncV3ProviderRaw?

    package init(snapshot: AgtmuxSyncV3PaneSnapshot) {
        identity = PanePresentationIdentity(
            sessionName: snapshot.sessionName,
            windowID: snapshot.windowID,
            sessionKey: snapshot.sessionKey,
            paneID: snapshot.paneID,
            paneInstanceID: snapshot.paneInstanceID
        )
        presence = snapshot.presence
        provider = snapshot.provider
        agentLifecycle = snapshot.agent.lifecycle
        threadLifecycle = snapshot.thread.lifecycle
        blocking = snapshot.thread.blocking
        execution = snapshot.thread.execution
        reviewMode = snapshot.thread.flags.reviewMode
        subagentActive = snapshot.thread.flags.subagentActive
        turnOutcome = snapshot.thread.turn.outcome
        pendingRequestIDs = snapshot.pendingRequests.map(\.requestID)
        needsUserAction = snapshot.thread.blocking != .none
        showsAttentionSummary = !snapshot.attention.activeKinds.isEmpty || snapshot.attention.unresolvedCount > 0
        attentionSummary = snapshot.attention
        freshnessState = Self.deriveFreshnessState(from: snapshot.freshness)
        primaryState = Self.derivePrimaryState(from: snapshot)
        providerRaw = snapshot.providerRaw
    }

    private static func derivePrimaryState(from snapshot: AgtmuxSyncV3PaneSnapshot) -> PanePresentationPrimaryState {
        if snapshot.thread.lifecycle == .errored || snapshot.agent.lifecycle == .errored {
            return .error
        }
        switch snapshot.thread.blocking {
        case .waitingApproval:
            return .waitingApproval
        case .waitingUserInput:
            return .waitingUserInput
        case .none:
            break
        }
        if snapshot.thread.lifecycle == .active {
            return .running
        }
        if snapshot.thread.lifecycle == .idle && snapshot.thread.turn.outcome == .completed {
            return .completedIdle
        }
        if snapshot.thread.lifecycle == .idle || snapshot.agent.lifecycle == .completed {
            return .idle
        }
        return .inactive
    }

    private static func deriveFreshnessState(from summary: AgtmuxSyncV3FreshnessSummary) -> PanePresentationFreshnessState {
        let levels = [summary.snapshot, summary.blocking, summary.execution]
        if levels.contains(.down) {
            return .down
        }
        if levels.contains(.stale) {
            return .degraded
        }
        return .fresh
    }
}
