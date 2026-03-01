import Foundation

// MARK: - AgtmuxPane

/// A single tmux pane tracked by the agtmux daemon.
///
/// JSON field mapping follows the agtmux daemon schema (snake_case → camelCase).
struct AgtmuxPane: Codable, Identifiable {
    var id: String { paneId }

    let paneId: String          // "%42" format — tmux pane id
    let sessionName: String
    let windowIndex: Int
    let paneIndex: Int
    let activityState: ActivityState
    let presence: String?       // "claude" if managed, nil if plain shell
    let conversationTitle: String?
    let cwd: String?

    // MARK: Post-MVP stubs

    /// Post-MVP: user-defined pin. Always false until FR-012 is implemented.
    var isPinned: Bool { false }

    // MARK: Derived properties

    /// True when the pane requires user attention (approval, input, or error).
    var needsAttention: Bool {
        activityState == .waitingApproval
            || activityState == .waitingInput
            || activityState == .error
    }

    // MARK: ActivityState

    enum ActivityState: String, Codable {
        case running          = "running"
        case idle             = "idle"
        case waitingApproval  = "waiting_approval"
        case waitingInput     = "waiting_input"
        case error            = "error"
        case unknown          = "unknown"
    }

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case paneId            = "pane_id"
        case sessionName       = "session_name"
        case windowIndex       = "window_index"
        case paneIndex         = "pane_index"
        case activityState     = "activity_state"
        case presence
        case conversationTitle = "conversation_title"
        case cwd
    }
}

// MARK: - AgtmuxSnapshot

/// Top-level JSON payload returned by `agtmux json`.
struct AgtmuxSnapshot: Codable {
    let version: Int
    let panes: [AgtmuxPane]
}

// MARK: - StatusFilter

/// Filter for the sidebar pane list.
enum StatusFilter: String, CaseIterable {
    case all
    case managed
    case attention
    case pinned
}
