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
    let presence: PanePresence  // "managed" | "unmanaged"
    let provider: Provider?     // which AI agent, if any
    let evidenceMode: EvidenceMode
    let conversationTitle: String?
    let currentPath: String?    // working directory (field: current_path)
    let gitBranch: String?      // git branch derived from currentPath
    let currentCmd: String?     // running process name
    let updatedAt: Date?        // last state update from daemon
    let ageSecs: Int?           // seconds since updatedAt

    /// Memberwise init.
    init(source: String,
         paneId: String,
         sessionName: String,
         windowId: String,
         activityState: ActivityState = .unknown,
         presence: PanePresence = .unmanaged,
         provider: Provider? = nil,
         evidenceMode: EvidenceMode = .none,
         conversationTitle: String? = nil,
         currentPath: String? = nil,
         gitBranch: String? = nil,
         currentCmd: String? = nil,
         updatedAt: Date? = nil,
         ageSecs: Int? = nil) {
        self.source            = source
        self.paneId            = paneId
        self.sessionName       = sessionName
        self.windowId          = windowId
        self.activityState     = activityState
        self.presence          = presence
        self.provider          = provider
        self.evidenceMode      = evidenceMode
        self.conversationTitle = conversationTitle
        self.currentPath       = currentPath
        self.gitBranch         = gitBranch
        self.currentCmd        = currentCmd
        self.updatedAt         = updatedAt
        self.ageSecs           = ageSecs
    }

    // MARK: Post-MVP stubs

    /// Post-MVP: user-defined pin. Always false until FR-012 is implemented.
    var isPinned: Bool { false }

    // MARK: Derived properties

    /// True when the pane is tracked by an agent (presence == .managed).
    var isManaged: Bool { presence == .managed }

    /// Display label for the sidebar row.
    ///
    /// - managed pane: `conversationTitle` → `provider.rawValue` ("claude"/"codex") → `paneId`
    ///   NOTE: `currentCmd` is intentionally skipped for managed panes because Claude Code
    ///   runs as a Node.js process, making `pane_current_command` = "node" (unhelpful).
    /// - unmanaged pane: `currentCmd` (e.g. "vim", "python", "bash") → `paneId`
    var primaryLabel: String {
        if isManaged {
            return conversationTitle ?? provider?.rawValue ?? paneId
        } else {
            return currentCmd ?? paneId
        }
    }

    /// True when the pane requires user attention (approval, input, or error).
    var needsAttention: Bool {
        activityState == .waitingApproval
            || activityState == .waitingInput
            || activityState == .error
    }

    // MARK: - ActivityState

    enum ActivityState: String, Codable {
        case running          = "running"
        case idle             = "idle"
        case waitingApproval  = "waiting_approval"
        case waitingInput     = "waiting_input"
        case error            = "error"
        case unknown          = "unknown"
    }

    // MARK: - PanePresence

    enum PanePresence: String, Codable {
        case managed   = "managed"
        case unmanaged = "unmanaged"
    }

    // MARK: - Provider

    enum Provider: String, Codable {
        case claude  = "claude"
        case codex   = "codex"
        case gemini  = "gemini"
        case copilot = "copilot"
    }

    // MARK: - EvidenceMode

    enum EvidenceMode: String, Codable {
        case deterministic = "deterministic"
        case heuristic     = "heuristic"
        case none          = "none"
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
                   provider: provider,
                   evidenceMode: evidenceMode,
                   conversationTitle: conversationTitle,
                   currentPath: currentPath,
                   gitBranch: gitBranch,
                   currentCmd: currentCmd,
                   updatedAt: updatedAt,
                   ageSecs: ageSecs)
    }
}

// MARK: - AgtmuxSnapshot

/// Top-level result type returned by daemon clients.
struct AgtmuxSnapshot {
    let version: Int
    let panes: [AgtmuxPane]

    /// Decode from `agtmux json` output, tagging all panes with the given source identifier.
    static func decode(from data: Data, source: String) throws -> AgtmuxSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(RawSnapshot.self, from: data)
        let panes = raw.panes.map { dto in
            AgtmuxPane(source: source,
                       paneId: dto.paneId,
                       sessionName: dto.sessionName,
                       windowId: dto.windowId,
                       activityState: dto.activityState ?? .unknown,
                       presence: dto.presence ?? .unmanaged,
                       provider: dto.provider,
                       evidenceMode: dto.evidenceMode ?? .none,
                       conversationTitle: dto.conversationTitle,
                       currentPath: dto.currentPath,
                       gitBranch: dto.gitBranch,
                       currentCmd: dto.currentCmd,
                       updatedAt: dto.updatedAt,
                       ageSecs: dto.ageSecs)
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
    let presence: AgtmuxPane.PanePresence?
    let provider: AgtmuxPane.Provider?
    let evidenceMode: AgtmuxPane.EvidenceMode?
    let conversationTitle: String?
    let currentPath: String?
    let gitBranch: String?
    let currentCmd: String?
    let updatedAt: Date?
    let ageSecs: Int?

    enum CodingKeys: String, CodingKey {
        case paneId            = "pane_id"
        case sessionName       = "session_name"
        case windowId          = "window_id"
        case activityState     = "activity_state"
        case presence
        case provider
        case evidenceMode      = "evidence_mode"
        case conversationTitle = "conversation_title"
        case currentPath       = "current_path"
        case gitBranch         = "git_branch"
        case currentCmd        = "current_cmd"
        case updatedAt         = "updated_at"
        case ageSecs           = "age_secs"
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
