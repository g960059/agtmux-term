import Foundation

// MARK: - ActivityState

package enum ActivityState: String, Codable, Equatable, Sendable {
    case running          = "running"
    case idle             = "idle"
    case waitingApproval  = "waiting_approval"
    case waitingInput     = "waiting_input"
    case error            = "error"
    case unknown          = "unknown"
}

extension ActivityState {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value.lowercased() {
        case "running":
            self = .running
        case "idle":
            self = .idle
        case "waitingapproval", "waiting_approval":
            self = .waitingApproval
        case "waitinginput", "waiting_input":
            self = .waitingInput
        case "error":
            self = .error
        case "unknown":
            self = .unknown
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ActivityState: \(value)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - PanePresence

package enum PanePresence: String, Codable, Equatable, Sendable {
    case managed   = "managed"
    case unmanaged = "unmanaged"
}

extension PanePresence {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value.lowercased() {
        case "managed":
            self = .managed
        case "unmanaged":
            self = .unmanaged
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported PanePresence: \(value)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Provider

package enum Provider: String, Codable, Equatable, Sendable {
    case claude  = "claude"
    case codex   = "codex"
    case gemini  = "gemini"
    case copilot = "copilot"
}

extension Provider {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value.lowercased() {
        case "claude":
            self = .claude
        case "codex":
            self = .codex
        case "gemini":
            self = .gemini
        case "copilot":
            self = .copilot
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Provider: \(value)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - EvidenceMode

package enum EvidenceMode: String, Codable, Equatable, Sendable {
    case deterministic = "deterministic"
    case heuristic     = "heuristic"
    case none          = "none"
}

extension EvidenceMode {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value.lowercased() {
        case "deterministic":
            self = .deterministic
        case "heuristic":
            self = .heuristic
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported EvidenceMode: \(value)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - AgtmuxPane

/// A single tmux pane tracked by the agtmux daemon or discovered via SSH.
///
/// `source` is NOT decoded from JSON — it is injected by the client after decoding.
package struct AgtmuxPane: Identifiable, Codable, Equatable, Sendable {
    /// Unique across all sources and sessions:
    /// "\(source):\(sessionName):\(paneId)".
    ///
    /// We intentionally include `sessionName` because session-linked topologies can
    /// expose the same `paneId` in multiple sessions.
    package var id: String { "\(source):\(sessionName):\(paneId)" }

    package let source: String          // "local" or remote hostname
    package let paneId: String          // "%42" format — tmux pane id
    package let sessionName: String
    package let sessionGroup: String?
    package let windowId: String        // "@42" format
    package let windowIndex: Int?       // tmux window index (1-based), nil when not available
    package let windowName: String?     // tmux window name, nil when not available
    package let activityState: ActivityState
    package let presence: PanePresence  // "managed" | "unmanaged"
    package let provider: Provider?     // which AI agent, if any
    package let evidenceMode: EvidenceMode
    package let conversationTitle: String?
    package let currentPath: String?    // working directory (field: current_path)
    package let gitBranch: String?      // git branch derived from currentPath
    package let currentCmd: String?     // running process name
    package let updatedAt: Date?        // last state update from daemon
    package let ageSecs: Int?           // seconds since updatedAt
    package let metadataSessionKey: String?
    package let paneInstanceID: AgtmuxSyncV2PaneInstanceID?

    /// Memberwise init.
    package init(source: String,
                 paneId: String,
                 sessionName: String,
                 sessionGroup: String? = nil,
                 windowId: String,
                 windowIndex: Int? = nil,
                 windowName: String? = nil,
                 activityState: ActivityState = .unknown,
                 presence: PanePresence = .unmanaged,
                 provider: Provider? = nil,
                 evidenceMode: EvidenceMode = .none,
                 conversationTitle: String? = nil,
                 currentPath: String? = nil,
                 gitBranch: String? = nil,
                 currentCmd: String? = nil,
                 updatedAt: Date? = nil,
                 ageSecs: Int? = nil,
                 metadataSessionKey: String? = nil,
                 paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil) {
        self.source            = source
        self.paneId            = paneId
        self.sessionName       = sessionName
        self.sessionGroup      = sessionGroup
        self.windowId          = windowId
        self.windowIndex       = windowIndex
        self.windowName        = windowName
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
        self.metadataSessionKey = metadataSessionKey
        self.paneInstanceID     = paneInstanceID
    }

    // MARK: Post-MVP stubs

    /// Post-MVP: user-defined pin. Always false until FR-012 is implemented.
    package var isPinned: Bool { false }

    // MARK: Derived properties

    /// True when the pane is tracked by an agent (presence == .managed).
    package var isManaged: Bool { presence == .managed }

    /// Display label for the sidebar row.
    ///
    /// - managed pane: `conversationTitle` → `provider.rawValue` ("claude"/"codex") → `paneId`
    ///   NOTE: `currentCmd` is intentionally skipped for managed panes because Claude Code
    ///   runs as a Node.js process, making `pane_current_command` = "node" (unhelpful).
    /// - unmanaged pane: `currentCmd` (e.g. "vim", "python", "bash") → `paneId`
    package var primaryLabel: String {
        if isManaged {
            return conversationTitle ?? provider?.rawValue ?? paneId
        } else {
            return currentCmd ?? paneId
        }
    }

    /// True when the pane requires user attention (approval, input, or error).
    package var needsAttention: Bool {
        activityState == .waitingApproval
            || activityState == .waitingInput
            || activityState == .error
    }
}

// MARK: - AgtmuxPane factories

extension AgtmuxPane {
    /// Returns a copy of this pane with the given source tag applied.
    package func tagged(source: String) -> AgtmuxPane {
        AgtmuxPane(source: source,
                   paneId: paneId,
                   sessionName: sessionName,
                   sessionGroup: sessionGroup,
                   windowId: windowId,
                   windowIndex: windowIndex,
                   windowName: windowName,
                   activityState: activityState,
                   presence: presence,
                   provider: provider,
                   evidenceMode: evidenceMode,
                   conversationTitle: conversationTitle,
                   currentPath: currentPath,
                   gitBranch: gitBranch,
                   currentCmd: currentCmd,
                   updatedAt: updatedAt,
                   ageSecs: ageSecs,
                   metadataSessionKey: metadataSessionKey,
                   paneInstanceID: paneInstanceID)
    }

    /// Returns a copy with a different session name (UI/session-group normalization).
    package func withSessionName(_ sessionName: String) -> AgtmuxPane {
        AgtmuxPane(source: source,
                   paneId: paneId,
                   sessionName: sessionName,
                   sessionGroup: sessionGroup,
                   windowId: windowId,
                   windowIndex: windowIndex,
                   windowName: windowName,
                   activityState: activityState,
                   presence: presence,
                   provider: provider,
                   evidenceMode: evidenceMode,
                   conversationTitle: conversationTitle,
                   currentPath: currentPath,
                   gitBranch: gitBranch,
                   currentCmd: currentCmd,
                   updatedAt: updatedAt,
                   ageSecs: ageSecs,
                   metadataSessionKey: metadataSessionKey,
                   paneInstanceID: paneInstanceID)
    }
}

// MARK: - WindowGroup

/// A group of panes sharing the same tmux window, within a session.
package struct WindowGroup: Identifiable, Codable, Equatable, Sendable {
    package var id: String { "\(source):\(sessionName):\(windowId)" }
    package let source: String
    package let sessionName: String
    package let windowId: String        // "@42" format
    package let windowIndex: Int?       // 1-based index, nil if unavailable
    package let windowName: String?
    package let panes: [AgtmuxPane]

    package init(source: String,
                 sessionName: String,
                 windowId: String,
                 windowIndex: Int? = nil,
                 windowName: String? = nil,
                 panes: [AgtmuxPane]) {
        self.source = source
        self.sessionName = sessionName
        self.windowId = windowId
        self.windowIndex = windowIndex
        self.windowName = windowName
        self.panes = panes
    }
}

// MARK: - AgtmuxSnapshot

/// Top-level result type returned by daemon clients.
package struct AgtmuxSnapshot: Codable, Equatable, Sendable {
    package let version: Int
    package let panes: [AgtmuxPane]

    package init(version: Int, panes: [AgtmuxPane]) {
        self.version = version
        self.panes = panes
    }

    /// Decode from `agtmux json` output, tagging all panes with the given source identifier.
    package static func decode(from data: Data, source: String) throws -> AgtmuxSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(RawSnapshot.self, from: data)
        let panes = raw.panes.map { dto in
            AgtmuxPane(source: source,
                       paneId: dto.paneId,
                       sessionName: dto.sessionName,
                       sessionGroup: dto.sessionGroup,
                       windowId: dto.windowId,
                       windowIndex: dto.windowIndex,
                       windowName: dto.windowName,
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
    let sessionGroup: String?
    let windowId: String
    let windowIndex: Int?
    let windowName: String?
    let activityState: ActivityState?
    let presence: PanePresence?
    let provider: Provider?
    let evidenceMode: EvidenceMode?
    let conversationTitle: String?
    let currentPath: String?
    let gitBranch: String?
    let currentCmd: String?
    let updatedAt: Date?
    let ageSecs: Int?

    enum CodingKeys: String, CodingKey {
        case paneId            = "pane_id"
        case sessionName       = "session_name"
        case sessionGroup      = "session_group"
        case windowId          = "window_id"
        case windowIndex       = "window_index"
        case windowName        = "window_name"
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
