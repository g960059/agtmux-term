import Foundation

package enum AgtmuxSyncV3ProtocolError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case missingBootstrapPaneField(String)

    package var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "sync-v3 bootstrap version \(version) is unsupported"
        case .missingBootstrapPaneField(let field):
            return "sync-v3 bootstrap pane missing required exact identity field '\(field)'"
        }
    }
}

package struct AgtmuxSyncV3Cursor: Codable, Equatable, Sendable {
    package let epoch: UInt64
    package let seq: UInt64

    package init(epoch: UInt64, seq: UInt64) {
        self.epoch = epoch
        self.seq = seq
    }
}

package struct AgtmuxSyncV3PaneInstanceID: Codable, Equatable, Hashable, Sendable {
    package let paneId: String
    package let generation: UInt64?
    package let birthTs: Date?

    package init(paneId: String, generation: UInt64?, birthTs: Date?) {
        self.paneId = paneId
        self.generation = generation
        self.birthTs = birthTs
    }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case generation
        case birthTs = "birth_ts"
    }
}

package enum AgtmuxSyncV3AgentLifecycle: String, Codable, Equatable, Sendable {
    case unknown
    case pendingInit = "pending_init"
    case running
    case completed
    case errored
    case shutdown
    case notFound = "not_found"
}

package enum AgtmuxSyncV3ThreadLifecycle: String, Codable, Equatable, Sendable {
    case notLoaded = "not_loaded"
    case active
    case idle
    case interrupted
    case errored
    case shutdown
}

package enum AgtmuxSyncV3BlockingState: String, Codable, Equatable, Sendable {
    case none
    case waitingUserInput = "waiting_user_input"
    case waitingApproval = "waiting_approval"
}

package enum AgtmuxSyncV3ExecutionState: String, Codable, Equatable, Sendable {
    case none
    case thinking
    case streaming
    case toolRunning = "tool_running"
    case compacting
}

package enum AgtmuxSyncV3TurnOutcome: String, Codable, Equatable, Sendable {
    case none
    case completed
    case aborted
    case errored
}

package enum AgtmuxSyncV3PendingRequestKind: String, Codable, Equatable, Sendable {
    case approval
    case userInput = "user_input"
}

package enum AgtmuxSyncV3PendingRequestStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
    case dismissed
}

package enum AgtmuxSyncV3AttentionKind: String, Codable, Equatable, Sendable {
    case question
    case approval
    case error
    case completion
}

package enum AgtmuxSyncV3AttentionPriority: String, Codable, Equatable, Sendable {
    case none
    case question
    case approval
    case error
    case completion
}

package enum AgtmuxSyncV3FreshnessLevel: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case down
}

package struct AgtmuxSyncV3JSONValue: Codable, Equatable, Sendable {
    package enum Storage: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: AgtmuxSyncV3JSONValue])
        case array([AgtmuxSyncV3JSONValue])
        case null
    }

    package let storage: Storage

    package init(_ storage: Storage) {
        self.storage = storage
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.init(.null)
        } else if let value = try? container.decode(Bool.self) {
            self.init(.bool(value))
        } else if let value = try? container.decode(Double.self) {
            self.init(.number(value))
        } else if let value = try? container.decode(String.self) {
            self.init(.string(value))
        } else if let value = try? container.decode([String: AgtmuxSyncV3JSONValue].self) {
            self.init(.object(value))
        } else if let value = try? container.decode([AgtmuxSyncV3JSONValue].self) {
            self.init(.array(value))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in provider_raw"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

package struct AgtmuxSyncV3ProviderRaw: Codable, Equatable, Sendable {
    package let valuesByProvider: [String: AgtmuxSyncV3JSONValue]

    package init(valuesByProvider: [String: AgtmuxSyncV3JSONValue]) {
        self.valuesByProvider = valuesByProvider
    }

    package subscript(provider: Provider) -> AgtmuxSyncV3JSONValue? {
        valuesByProvider[provider.rawValue]
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        valuesByProvider = try container.decode([String: AgtmuxSyncV3JSONValue].self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(valuesByProvider)
    }
}

package struct AgtmuxSyncV3AgentState: Codable, Equatable, Sendable {
    package let lifecycle: AgtmuxSyncV3AgentLifecycle

    package init(lifecycle: AgtmuxSyncV3AgentLifecycle) {
        self.lifecycle = lifecycle
    }
}

package struct AgtmuxSyncV3ThreadFlags: Codable, Equatable, Sendable {
    package let reviewMode: Bool
    package let subagentActive: Bool

    package init(reviewMode: Bool, subagentActive: Bool) {
        self.reviewMode = reviewMode
        self.subagentActive = subagentActive
    }

    enum CodingKeys: String, CodingKey {
        case reviewMode = "review_mode"
        case subagentActive = "subagent_active"
    }
}

package struct AgtmuxSyncV3TurnState: Codable, Equatable, Sendable {
    package let outcome: AgtmuxSyncV3TurnOutcome
    package let sequence: UInt64?
    package let startedAt: Date?
    package let completedAt: Date?

    package init(outcome: AgtmuxSyncV3TurnOutcome,
                 sequence: UInt64?,
                 startedAt: Date?,
                 completedAt: Date?) {
        self.outcome = outcome
        self.sequence = sequence
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case outcome
        case sequence
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

package struct AgtmuxSyncV3ThreadState: Codable, Equatable, Sendable {
    package let lifecycle: AgtmuxSyncV3ThreadLifecycle
    package let blocking: AgtmuxSyncV3BlockingState
    package let execution: AgtmuxSyncV3ExecutionState
    package let flags: AgtmuxSyncV3ThreadFlags
    package let turn: AgtmuxSyncV3TurnState

    package init(lifecycle: AgtmuxSyncV3ThreadLifecycle,
                 blocking: AgtmuxSyncV3BlockingState,
                 execution: AgtmuxSyncV3ExecutionState,
                 flags: AgtmuxSyncV3ThreadFlags,
                 turn: AgtmuxSyncV3TurnState) {
        self.lifecycle = lifecycle
        self.blocking = blocking
        self.execution = execution
        self.flags = flags
        self.turn = turn
    }
}

package struct AgtmuxSyncV3PendingRequestSource: Codable, Equatable, Sendable {
    package let provider: Provider
    package let sourceKind: String

    package init(provider: Provider, sourceKind: String) {
        self.provider = provider
        self.sourceKind = sourceKind
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case sourceKind = "source_kind"
    }
}

package struct AgtmuxSyncV3PendingRequest: Codable, Equatable, Sendable {
    package let requestID: String
    package let kind: AgtmuxSyncV3PendingRequestKind
    package let title: String?
    package let detail: String?
    package let createdAt: Date
    package let updatedAt: Date
    package let status: AgtmuxSyncV3PendingRequestStatus
    package let source: AgtmuxSyncV3PendingRequestSource

    package init(requestID: String,
                 kind: AgtmuxSyncV3PendingRequestKind,
                 title: String?,
                 detail: String?,
                 createdAt: Date,
                 updatedAt: Date,
                 status: AgtmuxSyncV3PendingRequestStatus,
                 source: AgtmuxSyncV3PendingRequestSource) {
        self.requestID = requestID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case kind
        case title
        case detail
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case status
        case source
    }
}

package struct AgtmuxSyncV3AttentionSummary: Codable, Equatable, Sendable {
    package let activeKinds: [AgtmuxSyncV3AttentionKind]
    package let highestPriority: AgtmuxSyncV3AttentionPriority
    package let unresolvedCount: UInt32
    package let generation: UInt64
    package let latestAt: Date?

    package init(activeKinds: [AgtmuxSyncV3AttentionKind],
                 highestPriority: AgtmuxSyncV3AttentionPriority,
                 unresolvedCount: UInt32,
                 generation: UInt64,
                 latestAt: Date?) {
        self.activeKinds = activeKinds
        self.highestPriority = highestPriority
        self.unresolvedCount = unresolvedCount
        self.generation = generation
        self.latestAt = latestAt
    }

    enum CodingKeys: String, CodingKey {
        case activeKinds = "active_kinds"
        case highestPriority = "highest_priority"
        case unresolvedCount = "unresolved_count"
        case generation
        case latestAt = "latest_at"
    }
}

package struct AgtmuxSyncV3FreshnessSummary: Codable, Equatable, Sendable {
    package let snapshot: AgtmuxSyncV3FreshnessLevel
    package let blocking: AgtmuxSyncV3FreshnessLevel
    package let execution: AgtmuxSyncV3FreshnessLevel

    package init(snapshot: AgtmuxSyncV3FreshnessLevel,
                 blocking: AgtmuxSyncV3FreshnessLevel,
                 execution: AgtmuxSyncV3FreshnessLevel) {
        self.snapshot = snapshot
        self.blocking = blocking
        self.execution = execution
    }
}

/// Consumer-side v3 pane snapshot.
///
/// The exact identity fields remain strict because the term app still owns
/// exact-row correlation. Other semantic fields are intentionally modeled in a
/// richer structured form so views do not need to reverse-engineer daemon truth
/// from a collapsed `ActivityState`.
package struct AgtmuxSyncV3PaneSnapshot: Codable, Equatable, Sendable {
    package let sessionName: String
    package let windowID: String
    package let sessionKey: String
    package let paneID: String
    package let paneInstanceID: AgtmuxSyncV3PaneInstanceID
    package let provider: Provider?
    package let presence: PanePresence
    package let agent: AgtmuxSyncV3AgentState
    package let thread: AgtmuxSyncV3ThreadState
    package let pendingRequests: [AgtmuxSyncV3PendingRequest]
    package let attention: AgtmuxSyncV3AttentionSummary
    package let freshness: AgtmuxSyncV3FreshnessSummary
    package let providerRaw: AgtmuxSyncV3ProviderRaw?
    package let updatedAt: Date

    package init(sessionName: String,
                 windowID: String,
                 sessionKey: String,
                 paneID: String,
                 paneInstanceID: AgtmuxSyncV3PaneInstanceID,
                 provider: Provider?,
                 presence: PanePresence,
                 agent: AgtmuxSyncV3AgentState,
                 thread: AgtmuxSyncV3ThreadState,
                 pendingRequests: [AgtmuxSyncV3PendingRequest],
                 attention: AgtmuxSyncV3AttentionSummary,
                 freshness: AgtmuxSyncV3FreshnessSummary,
                 providerRaw: AgtmuxSyncV3ProviderRaw?,
                 updatedAt: Date) {
        self.sessionName = sessionName
        self.windowID = windowID
        self.sessionKey = sessionKey
        self.paneID = paneID
        self.paneInstanceID = paneInstanceID
        self.provider = provider
        self.presence = presence
        self.agent = agent
        self.thread = thread
        self.pendingRequests = pendingRequests
        self.attention = attention
        self.freshness = freshness
        self.providerRaw = providerRaw
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionName = "session_name"
        case windowID = "window_id"
        case sessionKey = "session_key"
        case paneID = "pane_id"
        case paneInstanceID = "pane_instance_id"
        case provider
        case presence
        case agent
        case thread
        case pendingRequests = "pending_requests"
        case attention
        case freshness
        case providerRaw = "provider_raw"
        case updatedAt = "updated_at"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionName = try Self.decodeRequired(String.self, from: container, forKey: .sessionName)
        windowID = try Self.decodeRequired(String.self, from: container, forKey: .windowID)
        sessionKey = try Self.decodeRequired(String.self, from: container, forKey: .sessionKey)
        paneID = try Self.decodeRequired(String.self, from: container, forKey: .paneID)
        paneInstanceID = try Self.decodeRequired(
            AgtmuxSyncV3PaneInstanceID.self,
            from: container,
            forKey: .paneInstanceID
        )
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
        presence = try container.decode(PanePresence.self, forKey: .presence)
        agent = try container.decode(AgtmuxSyncV3AgentState.self, forKey: .agent)
        thread = try container.decode(AgtmuxSyncV3ThreadState.self, forKey: .thread)
        pendingRequests = try container.decode([AgtmuxSyncV3PendingRequest].self, forKey: .pendingRequests)
        attention = try container.decode(AgtmuxSyncV3AttentionSummary.self, forKey: .attention)
        freshness = try container.decode(AgtmuxSyncV3FreshnessSummary.self, forKey: .freshness)
        providerRaw = try container.decodeIfPresent(AgtmuxSyncV3ProviderRaw.self, forKey: .providerRaw)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    private static func decodeRequired<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T {
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            throw AgtmuxSyncV3ProtocolError.missingBootstrapPaneField(key.rawValue)
        }
    }
}

package struct AgtmuxSyncV3Bootstrap: Codable, Equatable, Sendable {
    package let version: Int
    package let epoch: UInt64
    package let snapshotSeq: UInt64
    package let panes: [AgtmuxSyncV3PaneSnapshot]
    package let generatedAt: Date
    package let replayCursor: AgtmuxSyncV3Cursor

    package init(version: Int,
                 epoch: UInt64,
                 snapshotSeq: UInt64,
                 panes: [AgtmuxSyncV3PaneSnapshot],
                 generatedAt: Date,
                 replayCursor: AgtmuxSyncV3Cursor) {
        self.version = version
        self.epoch = epoch
        self.snapshotSeq = snapshotSeq
        self.panes = panes
        self.generatedAt = generatedAt
        self.replayCursor = replayCursor
    }

    enum CodingKeys: String, CodingKey {
        case version
        case epoch
        case snapshotSeq = "snapshot_seq"
        case panes
        case generatedAt = "generated_at"
        case replayCursor = "replay_cursor"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        if version != 3 {
            throw AgtmuxSyncV3ProtocolError.unsupportedVersion(version)
        }
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        snapshotSeq = try container.decode(UInt64.self, forKey: .snapshotSeq)
        panes = try container.decode([AgtmuxSyncV3PaneSnapshot].self, forKey: .panes)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        replayCursor = try container.decode(AgtmuxSyncV3Cursor.self, forKey: .replayCursor)
    }
}
