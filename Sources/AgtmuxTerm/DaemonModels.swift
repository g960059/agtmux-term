import Foundation

// MARK: - AgtmuxPane

/// A single tmux pane tracked by the agtmux daemon or discovered via SSH.
///
/// `source` is NOT decoded from JSON — it is injected by the client after decoding.
struct AgtmuxPane: Identifiable {
    /// Unique across all sources: "\(source):\(paneId)", e.g. "local:%42" or "vm1.example.com:%3"
    var id: String { "\(source):\(paneId)" }

    let source: String          // "local" or remote hostname
    let paneId: String          // "%42" format — tmux pane id
    let sessionName: String
    let windowId: String
    let activityState: ActivityState
    let presence: String?       // "claude" if managed, nil if plain shell
    let conversationTitle: String?
    let cwd: String?

    /// Memberwise init (defined here to provide defaults and suppress the synthesized one).
    init(source: String,
         paneId: String,
         sessionName: String,
         windowId: String,
         activityState: ActivityState = .unknown,
         presence: String? = nil,
         conversationTitle: String? = nil,
         cwd: String? = nil) {
        self.source            = source
        self.paneId            = paneId
        self.sessionName       = sessionName
        self.windowId          = windowId
        self.activityState     = activityState
        self.presence          = presence
        self.conversationTitle = conversationTitle
        self.cwd               = cwd
    }

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
}

// MARK: - AgtmuxPane factories

extension AgtmuxPane {
    /// Returns a copy of this pane with the given source tag applied.
    func tagged(source: String) -> AgtmuxPane {
        AgtmuxPane(source: source,
                   paneId: paneId,
                   sessionName: sessionName,
                   windowId: windowId,
                   activityState: activityState,
                   presence: presence,
                   conversationTitle: conversationTitle,
                   cwd: cwd)
    }
}

// MARK: - AgtmuxSnapshot

/// Top-level result type returned by daemon clients.
struct AgtmuxSnapshot {
    let version: Int
    let panes: [AgtmuxPane]

    /// Decode from `agtmux json` output, tagging all panes with the given source identifier.
    ///
    /// Parsing is handled via private `RawSnapshot` DTO to keep `AgtmuxPane` clean of
    /// JSON decoding concerns (source is injected, not from JSON).
    static func decode(from data: Data, source: String) throws -> AgtmuxSnapshot {
        let raw = try JSONDecoder().decode(RawSnapshot.self, from: data)
        let panes = raw.panes.map { dto in
            AgtmuxPane(source: source,
                       paneId: dto.paneId,
                       sessionName: dto.sessionName,
                       windowId: dto.windowId,
                       activityState: dto.activityState ?? .unknown,
                       presence: dto.presence,
                       conversationTitle: dto.conversationTitle,
                       cwd: dto.cwd)
        }
        return AgtmuxSnapshot(version: raw.version, panes: panes)
    }
}

// MARK: - Private JSON DTOs

private struct RawSnapshot: Decodable {
    let version: Int
    let panes: [RawPane]
}

private struct RawPane: Decodable {
    let paneId: String
    let sessionName: String
    let windowId: String
    let activityState: AgtmuxPane.ActivityState?
    let presence: String?
    let conversationTitle: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case paneId            = "pane_id"
        case sessionName       = "session_name"
        case windowId          = "window_id"
        case activityState     = "activity_state"
        case presence
        case conversationTitle = "conversation_title"
        case cwd
    }
}

// MARK: - StatusFilter

/// Filter for the sidebar pane list.
enum StatusFilter: String, CaseIterable {
    case all
    case managed
    case attention
    case pinned
}
