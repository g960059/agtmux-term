import Foundation

/// Legacy sync-v2 row/model types retained for pane identity and overlay compatibility.
package enum AgtmuxSyncV2ProtocolError: LocalizedError, Equatable, Sendable {
    case missingBootstrapPaneField(String)
    case legacyPaneField(String)

    package var errorDescription: String? {
        switch self {
        case .missingBootstrapPaneField(let field):
            return "sync-v2 bootstrap pane missing required exact identity field '\(field)'"
        case .legacyPaneField(let field):
            return "sync-v2 pane payload contains legacy identity field '\(field)'"
        }
    }
}

package struct AgtmuxSyncV2Cursor: Codable, Equatable, Sendable {
    package let epoch: UInt64
    package let seq: UInt64

    package init(epoch: UInt64, seq: UInt64) {
        self.epoch = epoch
        self.seq = seq
    }
}

package struct AgtmuxSyncV2SessionState: Codable, Equatable, Sendable {
    package let sessionKey: String
    package let presence: PanePresence
    package let evidenceMode: EvidenceMode
    package let activityState: ActivityState
    package let updatedAt: Date?

    package init(sessionKey: String,
                 presence: PanePresence,
                 evidenceMode: EvidenceMode,
                 activityState: ActivityState,
                 updatedAt: Date?) {
        self.sessionKey = sessionKey
        self.presence = presence
        self.evidenceMode = evidenceMode
        self.activityState = activityState
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key"
        case presence
        case evidenceMode = "evidence_mode"
        case activityState = "activity_state"
        case updatedAt = "updated_at"
    }
}

package struct AgtmuxSyncV2PaneInstanceID: Codable, Equatable, Hashable, Sendable {
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

package struct AgtmuxSyncV2PaneState: Codable, Equatable, Sendable {
    private enum LegacyCodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }

    package let paneInstanceID: AgtmuxSyncV2PaneInstanceID
    package let presence: PanePresence
    package let evidenceMode: EvidenceMode
    package let activityState: ActivityState
    package let provider: Provider?
    package let sessionKey: String
    package let updatedAt: Date

    package init(paneInstanceID: AgtmuxSyncV2PaneInstanceID,
                 presence: PanePresence,
                 evidenceMode: EvidenceMode,
                 activityState: ActivityState,
                 provider: Provider?,
                 sessionKey: String,
                 updatedAt: Date) {
        self.paneInstanceID = paneInstanceID
        self.presence = presence
        self.evidenceMode = evidenceMode
        self.activityState = activityState
        self.provider = provider
        self.sessionKey = sessionKey
        self.updatedAt = updatedAt
    }

    package var paneId: String { paneInstanceID.paneId }

    enum CodingKeys: String, CodingKey {
        case paneInstanceID = "pane_instance_id"
        case presence
        case evidenceMode = "evidence_mode"
        case activityState = "activity_state"
        case provider
        case sessionKey = "session_key"
        case updatedAt = "updated_at"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacyContainer.contains(.sessionID) {
            throw AgtmuxSyncV2ProtocolError.legacyPaneField(LegacyCodingKeys.sessionID.rawValue)
        }
        paneInstanceID = try container.decode(AgtmuxSyncV2PaneInstanceID.self, forKey: .paneInstanceID)
        presence = try container.decode(PanePresence.self, forKey: .presence)
        evidenceMode = try container.decode(EvidenceMode.self, forKey: .evidenceMode)
        activityState = try container.decode(ActivityState.self, forKey: .activityState)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneInstanceID, forKey: .paneInstanceID)
        try container.encode(presence, forKey: .presence)
        try container.encode(evidenceMode, forKey: .evidenceMode)
        try container.encode(activityState, forKey: .activityState)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

package struct AgtmuxSyncV2ChangeRef: Codable, Equatable, Sendable {
    package let seq: UInt64
    package let sessionKey: String
    package let paneId: String?
    package let timestamp: Date
    package let pane: AgtmuxSyncV2PaneState?
    package let session: AgtmuxSyncV2SessionState?

    package init(seq: UInt64,
                 sessionKey: String,
                 paneId: String?,
                 timestamp: Date,
                 pane: AgtmuxSyncV2PaneState? = nil,
                 session: AgtmuxSyncV2SessionState? = nil) {
        self.seq = seq
        self.sessionKey = sessionKey
        self.paneId = paneId
        self.timestamp = timestamp
        self.pane = pane
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionKey = "session_key"
        case paneId = "pane_id"
        case timestamp
        case pane
        case session
    }
}

package struct AgtmuxSyncV2Changes: Codable, Equatable, Sendable {
    package let epoch: UInt64
    package let changes: [AgtmuxSyncV2ChangeRef]
    package let fromSeq: UInt64
    package let toSeq: UInt64
    package let nextCursor: AgtmuxSyncV2Cursor

    package init(epoch: UInt64,
                 changes: [AgtmuxSyncV2ChangeRef],
                 fromSeq: UInt64,
                 toSeq: UInt64,
                 nextCursor: AgtmuxSyncV2Cursor) {
        self.epoch = epoch
        self.changes = changes
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case epoch
        case changes
        case fromSeq = "from_seq"
        case toSeq = "to_seq"
        case nextCursor = "next_cursor"
    }
}

package struct AgtmuxSyncV2ResyncRequired: Codable, Equatable, Sendable {
    package let currentEpoch: UInt64
    package let latestSnapshotSeq: UInt64
    package let reason: String

    package init(currentEpoch: UInt64,
                 latestSnapshotSeq: UInt64,
                 reason: String) {
        self.currentEpoch = currentEpoch
        self.latestSnapshotSeq = latestSnapshotSeq
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case currentEpoch = "current_epoch"
        case latestSnapshotSeq = "latest_snapshot_seq"
        case reason
    }
}

package enum AgtmuxSyncV2ChangesResponse: Codable, Equatable, Sendable {
    case changes(AgtmuxSyncV2Changes)
    case resyncRequired(AgtmuxSyncV2ResyncRequired)

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.resyncRequired) {
            self = .resyncRequired(try container.decode(AgtmuxSyncV2ResyncRequired.self, forKey: .resyncRequired))
            return
        }

        self = .changes(try AgtmuxSyncV2Changes(from: decoder))
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .changes(payload):
            try payload.encode(to: encoder)
        case let .resyncRequired(payload):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(payload, forKey: .resyncRequired)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case resyncRequired = "resync_required"
    }
}

package struct AgtmuxSyncV2Bootstrap: Codable, Equatable, Sendable {
    package let epoch: UInt64
    package let snapshotSeq: UInt64
    package let panes: [AgtmuxPane]
    package let sessions: [AgtmuxSyncV2SessionState]
    package let generatedAt: Date
    package let replayCursor: AgtmuxSyncV2Cursor

    package init(epoch: UInt64,
                 snapshotSeq: UInt64,
                 panes: [AgtmuxPane],
                 sessions: [AgtmuxSyncV2SessionState],
                 generatedAt: Date,
                 replayCursor: AgtmuxSyncV2Cursor) {
        self.epoch = epoch
        self.snapshotSeq = snapshotSeq
        self.panes = panes
        self.sessions = sessions
        self.generatedAt = generatedAt
        self.replayCursor = replayCursor
    }

    enum CodingKeys: String, CodingKey {
        case epoch
        case snapshotSeq = "snapshot_seq"
        case panes
        case sessions
        case generatedAt = "generated_at"
        case replayCursor = "replay_cursor"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        snapshotSeq = try container.decode(UInt64.self, forKey: .snapshotSeq)
        sessions = try container.decode([AgtmuxSyncV2SessionState].self, forKey: .sessions)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        replayCursor = try container.decode(AgtmuxSyncV2Cursor.self, forKey: .replayCursor)
        let rawPanes = try container.decode([AgtmuxSyncV2RawPane].self, forKey: .panes)
        panes = rawPanes.map { $0.makePane(source: "local") }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(snapshotSeq, forKey: .snapshotSeq)
        try container.encode(panes.map(AgtmuxSyncV2RawPane.init), forKey: .panes)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(replayCursor, forKey: .replayCursor)
    }
}

private struct AgtmuxSyncV2RawPane: Codable, Equatable, Sendable {
    private enum LegacyCodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }

    let paneId: String
    let sessionName: String
    let sessionKey: String
    let sessionGroup: String?
    let windowId: String
    let windowIndex: Int?
    let windowName: String?
    let paneInstanceID: AgtmuxSyncV2PaneInstanceID
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
        case paneId = "pane_id"
        case sessionName = "session_name"
        case sessionKey = "session_key"
        case sessionGroup = "session_group"
        case windowId = "window_id"
        case windowIndex = "window_index"
        case windowName = "window_name"
        case paneInstanceID = "pane_instance_id"
        case activityState = "activity_state"
        case presence
        case provider
        case evidenceMode = "evidence_mode"
        case conversationTitle = "conversation_title"
        case currentPath = "current_path"
        case gitBranch = "git_branch"
        case currentCmd = "current_cmd"
        case updatedAt = "updated_at"
        case ageSecs = "age_secs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacyContainer.contains(.sessionID) {
            throw AgtmuxSyncV2ProtocolError.legacyPaneField(LegacyCodingKeys.sessionID.rawValue)
        }
        paneId = try Self.decodeRequired(String.self, from: container, forKey: .paneId)
        sessionName = try Self.decodeRequired(String.self, from: container, forKey: .sessionName)
        sessionKey = try Self.decodeRequired(String.self, from: container, forKey: .sessionKey)
        sessionGroup = try container.decodeIfPresent(String.self, forKey: .sessionGroup)
        windowId = try Self.decodeRequired(String.self, from: container, forKey: .windowId)
        windowIndex = try container.decodeIfPresent(Int.self, forKey: .windowIndex)
        windowName = try container.decodeIfPresent(String.self, forKey: .windowName)
        paneInstanceID = try Self.decodeRequired(
            AgtmuxSyncV2PaneInstanceID.self,
            from: container,
            forKey: .paneInstanceID
        )
        activityState = try container.decodeIfPresent(ActivityState.self, forKey: .activityState)
        presence = try container.decodeIfPresent(PanePresence.self, forKey: .presence)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
        evidenceMode = try container.decodeIfPresent(EvidenceMode.self, forKey: .evidenceMode)
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
        currentPath = try container.decodeIfPresent(String.self, forKey: .currentPath)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        currentCmd = try container.decodeIfPresent(String.self, forKey: .currentCmd)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        ageSecs = try container.decodeIfPresent(Int.self, forKey: .ageSecs)
    }

    init(_ pane: AgtmuxPane) {
        precondition(
            pane.metadataSessionKey != nil,
            "AgtmuxSyncV2RawPane requires metadataSessionKey for sync-v2 bootstrap encoding"
        )
        precondition(
            pane.paneInstanceID != nil,
            "AgtmuxSyncV2RawPane requires paneInstanceID for sync-v2 bootstrap encoding"
        )
        paneId = pane.paneId
        sessionName = pane.sessionName
        sessionKey = pane.metadataSessionKey!
        sessionGroup = pane.sessionGroup
        windowId = pane.windowId
        windowIndex = pane.windowIndex
        windowName = pane.windowName
        paneInstanceID = pane.paneInstanceID!
        activityState = pane.activityState
        presence = pane.presence
        provider = pane.provider
        evidenceMode = pane.evidenceMode
        conversationTitle = pane.conversationTitle
        currentPath = pane.currentPath
        gitBranch = pane.gitBranch
        currentCmd = pane.currentCmd
        updatedAt = pane.updatedAt
        ageSecs = pane.ageSecs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneId, forKey: .paneId)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encodeIfPresent(sessionGroup, forKey: .sessionGroup)
        try container.encode(windowId, forKey: .windowId)
        try container.encodeIfPresent(windowIndex, forKey: .windowIndex)
        try container.encodeIfPresent(windowName, forKey: .windowName)
        try container.encode(paneInstanceID, forKey: .paneInstanceID)
        try container.encodeIfPresent(activityState, forKey: .activityState)
        try container.encodeIfPresent(presence, forKey: .presence)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(evidenceMode, forKey: .evidenceMode)
        try container.encodeIfPresent(conversationTitle, forKey: .conversationTitle)
        try container.encodeIfPresent(currentPath, forKey: .currentPath)
        try container.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try container.encodeIfPresent(currentCmd, forKey: .currentCmd)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(ageSecs, forKey: .ageSecs)
    }

    func makePane(source: String) -> AgtmuxPane {
        AgtmuxPane(
            source: source,
            paneId: paneId,
            sessionName: sessionName,
            sessionGroup: sessionGroup,
            windowId: windowId,
            windowIndex: windowIndex,
            windowName: windowName,
            activityState: activityState ?? .unknown,
            presence: presence ?? .unmanaged,
            provider: provider,
            evidenceMode: evidenceMode ?? .none,
            conversationTitle: conversationTitle,
            currentPath: currentPath,
            gitBranch: gitBranch,
            currentCmd: currentCmd,
            updatedAt: updatedAt,
            ageSecs: ageSecs,
            metadataSessionKey: sessionKey,
            paneInstanceID: paneInstanceID
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
            throw AgtmuxSyncV2ProtocolError.missingBootstrapPaneField(key.rawValue)
        }
    }

}
