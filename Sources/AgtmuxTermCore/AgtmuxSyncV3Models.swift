import Foundation

package enum AgtmuxSyncV3ProtocolError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case missingBootstrapPaneField(String)
    case paneInstanceIDMismatch(topLevelPaneID: String, paneInstancePaneID: String)
    case missingChangesField(String)
    case invalidChangesPayload(String)

    package var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "sync-v3 bootstrap version \(version) is unsupported"
        case .missingBootstrapPaneField(let field):
            return "sync-v3 bootstrap pane missing required exact identity field '\(field)'"
        case .paneInstanceIDMismatch(let topLevelPaneID, let paneInstancePaneID):
            return "sync-v3 bootstrap pane_instance_id.pane_id '\(paneInstancePaneID)' does not match pane_id '\(topLevelPaneID)'"
        case .missingChangesField(let field):
            return "ui.changes.v3 payload missing required field '\(field)'"
        case .invalidChangesPayload(let detail):
            return "ui.changes.v3 payload is invalid: \(detail)"
        }
    }
}

package struct AgtmuxSyncV3Cursor: Codable, Equatable, Sendable {
    package let seq: UInt64

    package init(seq: UInt64) {
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

package enum AgtmuxSyncV3Presence: String, Codable, Equatable, Sendable {
    case managed
    case unmanaged
    case missing
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
    package let conversationTitle: String?
    package let sessionSubtitle: String?
    package let presence: AgtmuxSyncV3Presence
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
                 conversationTitle: String? = nil,
                 sessionSubtitle: String? = nil,
                 presence: AgtmuxSyncV3Presence,
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
        self.conversationTitle = conversationTitle
        self.sessionSubtitle = sessionSubtitle
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
        case conversationTitle = "conversation_title"
        case sessionSubtitle = "session_subtitle"
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
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
        sessionSubtitle = try container.decodeIfPresent(String.self, forKey: .sessionSubtitle)
        presence = try container.decode(AgtmuxSyncV3Presence.self, forKey: .presence)
        agent = try container.decode(AgtmuxSyncV3AgentState.self, forKey: .agent)
        thread = try container.decode(AgtmuxSyncV3ThreadState.self, forKey: .thread)
        pendingRequests = try container.decode([AgtmuxSyncV3PendingRequest].self, forKey: .pendingRequests)
        attention = try container.decode(AgtmuxSyncV3AttentionSummary.self, forKey: .attention)
        freshness = try container.decode(AgtmuxSyncV3FreshnessSummary.self, forKey: .freshness)
        providerRaw = try container.decodeIfPresent(AgtmuxSyncV3ProviderRaw.self, forKey: .providerRaw)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if paneInstanceID.paneId != paneID {
            throw AgtmuxSyncV3ProtocolError.paneInstanceIDMismatch(
                topLevelPaneID: paneID,
                paneInstancePaneID: paneInstanceID.paneId
            )
        }
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
    package let panes: [AgtmuxSyncV3PaneSnapshot]
    package let generatedAt: Date
    package let replayCursor: AgtmuxSyncV3Cursor?

    package init(version: Int,
                 panes: [AgtmuxSyncV3PaneSnapshot],
                 generatedAt: Date,
                 replayCursor: AgtmuxSyncV3Cursor?) {
        self.version = version
        self.panes = panes
        self.generatedAt = generatedAt
        self.replayCursor = replayCursor
    }

    enum CodingKeys: String, CodingKey {
        case version
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
        panes = try container.decode([AgtmuxSyncV3PaneSnapshot].self, forKey: .panes)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        replayCursor = try container.decodeIfPresent(AgtmuxSyncV3Cursor.self, forKey: .replayCursor)
    }
}

package enum AgtmuxSyncV3FieldGroup: String, Codable, Equatable, Sendable {
    case identity
    case presence
    case provider
    case agent
    case thread
    case pendingRequests = "pending_requests"
    case attention
    case freshness
    case providerRaw = "provider_raw"
}

package enum AgtmuxSyncV3ChangeKind: String, Codable, Equatable, Sendable {
    case upsert
    case remove
}

package struct AgtmuxSyncV3PaneChange: Codable, Equatable, Sendable {
    package let seq: UInt64
    package let at: Date
    package let kind: AgtmuxSyncV3ChangeKind
    package let paneID: String
    package let sessionName: String
    package let windowID: String
    package let sessionKey: String
    package let paneInstanceID: AgtmuxSyncV3PaneInstanceID
    package let fieldGroups: [AgtmuxSyncV3FieldGroup]
    package let pane: AgtmuxSyncV3PaneSnapshot?

    package init(
        seq: UInt64,
        at: Date,
        kind: AgtmuxSyncV3ChangeKind,
        paneID: String,
        sessionName: String,
        windowID: String,
        sessionKey: String,
        paneInstanceID: AgtmuxSyncV3PaneInstanceID,
        fieldGroups: [AgtmuxSyncV3FieldGroup],
        pane: AgtmuxSyncV3PaneSnapshot?
    ) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.paneID = paneID
        self.sessionName = sessionName
        self.windowID = windowID
        self.sessionKey = sessionKey
        self.paneInstanceID = paneInstanceID
        self.fieldGroups = fieldGroups
        self.pane = pane
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case at
        case kind
        case paneID = "pane_id"
        case sessionName = "session_name"
        case windowID = "window_id"
        case sessionKey = "session_key"
        case paneInstanceID = "pane_instance_id"
        case fieldGroups = "field_groups"
        case pane
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(UInt64.self, forKey: .seq)
        at = try container.decode(Date.self, forKey: .at)
        kind = try container.decode(AgtmuxSyncV3ChangeKind.self, forKey: .kind)
        sessionName = try Self.decodeRequired(String.self, from: container, forKey: .sessionName)
        windowID = try Self.decodeRequired(String.self, from: container, forKey: .windowID)
        sessionKey = try Self.decodeRequired(String.self, from: container, forKey: .sessionKey)
        paneID = try Self.decodeRequired(String.self, from: container, forKey: .paneID)
        paneInstanceID = try Self.decodeRequired(AgtmuxSyncV3PaneInstanceID.self, from: container, forKey: .paneInstanceID)
        fieldGroups = try container.decode([AgtmuxSyncV3FieldGroup].self, forKey: .fieldGroups)
        pane = try container.decodeIfPresent(AgtmuxSyncV3PaneSnapshot.self, forKey: .pane)

        if paneInstanceID.paneId != paneID {
            throw AgtmuxSyncV3ProtocolError.paneInstanceIDMismatch(
                topLevelPaneID: paneID,
                paneInstancePaneID: paneInstanceID.paneId
            )
        }
        if fieldGroups.isEmpty {
            throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("field_groups must not be empty")
        }

        switch kind {
        case .upsert:
            guard let pane else {
                throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("upsert change requires pane payload")
            }
            guard pane.paneID == paneID,
                  pane.sessionName == sessionName,
                  pane.windowID == windowID,
                  pane.sessionKey == sessionKey,
                  pane.paneInstanceID == paneInstanceID else {
                throw AgtmuxSyncV3ProtocolError.invalidChangesPayload(
                    "upsert change identity fields must match nested pane payload"
                )
            }
        case .remove:
            if pane != nil {
                throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("remove change must not include pane payload")
            }
        }
    }

    private static func decodeRequired<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T {
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            throw AgtmuxSyncV3ProtocolError.missingChangesField(key.rawValue)
        }
    }
}

package struct AgtmuxSyncV3ResyncRequired: Codable, Equatable, Sendable {
    package let latestSnapshotSeq: UInt64
    package let reason: String

    enum CodingKeys: String, CodingKey {
        case latestSnapshotSeq = "latest_snapshot_seq"
        case reason
    }
}

package struct AgtmuxSyncV3Changes: Codable, Equatable, Sendable {
    package let fromSeq: UInt64
    package let toSeq: UInt64
    package let nextCursor: AgtmuxSyncV3Cursor
    package let changes: [AgtmuxSyncV3PaneChange]

    package init(
        fromSeq: UInt64,
        toSeq: UInt64,
        nextCursor: AgtmuxSyncV3Cursor,
        changes: [AgtmuxSyncV3PaneChange]
    ) {
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.nextCursor = nextCursor
        self.changes = changes
    }
}

package enum AgtmuxSyncV3ChangesResponse: Equatable, Sendable {
    case changes(AgtmuxSyncV3Changes)
    case resyncRequired(AgtmuxSyncV3ResyncRequired)
}

extension AgtmuxSyncV3ChangesResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case changes
        case fromSeq = "from_seq"
        case toSeq = "to_seq"
        case nextCursor = "next_cursor"
        case resyncRequired = "resync_required"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        if version != 3 {
            throw AgtmuxSyncV3ProtocolError.unsupportedVersion(version)
        }

        if let resync = try container.decodeIfPresent(AgtmuxSyncV3ResyncRequired.self, forKey: .resyncRequired) {
            let changes = try container.decodeIfPresent([AgtmuxSyncV3PaneChange].self, forKey: .changes) ?? []
            let fromSeq = try container.decodeIfPresent(UInt64.self, forKey: .fromSeq)
            let toSeq = try container.decodeIfPresent(UInt64.self, forKey: .toSeq)
            let nextCursor = try container.decodeIfPresent(AgtmuxSyncV3Cursor.self, forKey: .nextCursor)
            if !changes.isEmpty || fromSeq != nil || toSeq != nil || nextCursor != nil {
                throw AgtmuxSyncV3ProtocolError.invalidChangesPayload(
                    "resync_required response must not include batch cursors or changes"
                )
            }
            self = .resyncRequired(resync)
            return
        }

        let fromSeq = try Self.decodeRequired(UInt64.self, from: container, forKey: .fromSeq)
        let toSeq = try Self.decodeRequired(UInt64.self, from: container, forKey: .toSeq)
        let nextCursor = try Self.decodeRequired(AgtmuxSyncV3Cursor.self, from: container, forKey: .nextCursor)
        let changes = try container.decodeIfPresent([AgtmuxSyncV3PaneChange].self, forKey: .changes) ?? []

        let lowerBound = fromSeq == 0 ? 0 : fromSeq - 1
        if toSeq < lowerBound {
            throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("to_seq must be >= from_seq - 1")
        }
        if nextCursor.seq != toSeq {
            throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("next_cursor.seq must equal to_seq")
        }
        for change in changes where change.seq < fromSeq || change.seq > toSeq {
            throw AgtmuxSyncV3ProtocolError.invalidChangesPayload("change seq outside response window")
        }

        self = .changes(
            AgtmuxSyncV3Changes(
                fromSeq: fromSeq,
                toSeq: toSeq,
                nextCursor: nextCursor,
                changes: changes
            )
        )
    }

    private static func decodeRequired<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> T {
        do {
            return try container.decode(T.self, forKey: key)
        } catch {
            throw AgtmuxSyncV3ProtocolError.missingChangesField(key.rawValue)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(3, forKey: .version)
        switch self {
        case .changes(let payload):
            try container.encode(payload.changes, forKey: .changes)
            try container.encode(payload.fromSeq, forKey: .fromSeq)
            try container.encode(payload.toSeq, forKey: .toSeq)
            try container.encode(payload.nextCursor, forKey: .nextCursor)
        case .resyncRequired(let payload):
            try container.encode(payload, forKey: .resyncRequired)
        }
    }
}
