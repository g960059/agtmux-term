import Foundation

package enum AgtmuxUIHealthStatus: String, Codable, Equatable, Sendable {
    case ok
    case degraded
    case unavailable
}

package struct AgtmuxUIComponentHealth: Codable, Equatable, Sendable {
    package let status: AgtmuxUIHealthStatus
    package let detail: String?
    package let lastUpdatedAt: Date?

    package init(status: AgtmuxUIHealthStatus,
                 detail: String? = nil,
                 lastUpdatedAt: Date? = nil) {
        self.status = status
        self.detail = detail
        self.lastUpdatedAt = lastUpdatedAt
    }

    enum CodingKeys: String, CodingKey {
        case status
        case detail
        case lastUpdatedAt = "last_updated_at"
    }
}

package struct AgtmuxUIReplayHealth: Codable, Equatable, Sendable {
    package let status: AgtmuxUIHealthStatus
    package let currentEpoch: UInt64?
    package let cursorSeq: UInt64?
    package let headSeq: UInt64?
    package let lag: UInt64?
    package let lastResyncReason: String?
    package let lastResyncAt: Date?
    package let detail: String?

    package init(status: AgtmuxUIHealthStatus,
                 currentEpoch: UInt64? = nil,
                 cursorSeq: UInt64? = nil,
                 headSeq: UInt64? = nil,
                 lag: UInt64? = nil,
                 lastResyncReason: String? = nil,
                 lastResyncAt: Date? = nil,
                 detail: String? = nil) {
        self.status = status
        self.currentEpoch = currentEpoch
        self.cursorSeq = cursorSeq
        self.headSeq = headSeq
        self.lag = lag
        self.lastResyncReason = lastResyncReason
        self.lastResyncAt = lastResyncAt
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case status
        case currentEpoch = "current_epoch"
        case cursorSeq = "cursor_seq"
        case headSeq = "head_seq"
        case lag
        case lastResyncReason = "last_resync_reason"
        case lastResyncAt = "last_resync_at"
        case detail
    }
}

package struct AgtmuxUIFocusHealth: Codable, Equatable, Sendable {
    package let status: AgtmuxUIHealthStatus
    package let focusedPaneID: String?
    package let mismatchCount: UInt64?
    package let lastSyncAt: Date?
    package let detail: String?

    package init(status: AgtmuxUIHealthStatus,
                 focusedPaneID: String? = nil,
                 mismatchCount: UInt64? = nil,
                 lastSyncAt: Date? = nil,
                 detail: String? = nil) {
        self.status = status
        self.focusedPaneID = focusedPaneID
        self.mismatchCount = mismatchCount
        self.lastSyncAt = lastSyncAt
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case status
        case focusedPaneID = "focused_pane_id"
        case mismatchCount = "mismatch_count"
        case lastSyncAt = "last_sync_at"
        case detail
    }
}

package struct AgtmuxUIHealthV1: Codable, Equatable, Sendable {
    package let generatedAt: Date
    package let runtime: AgtmuxUIComponentHealth
    package let replay: AgtmuxUIReplayHealth
    package let overlay: AgtmuxUIComponentHealth
    package let focus: AgtmuxUIFocusHealth

    package init(generatedAt: Date,
                 runtime: AgtmuxUIComponentHealth,
                 replay: AgtmuxUIReplayHealth,
                 overlay: AgtmuxUIComponentHealth,
                 focus: AgtmuxUIFocusHealth) {
        self.generatedAt = generatedAt
        self.runtime = runtime
        self.replay = replay
        self.overlay = overlay
        self.focus = focus
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case runtime
        case replay
        case overlay
        case focus
    }
}
