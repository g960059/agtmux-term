import Foundation
import Observation
import AgtmuxTermCore

// MARK: - SidebarInventoryStore
//
// Owns all pane-list state that SidebarView consumes.
// Isolated to the main actor so @Observable mutations remain thread-safe.
//
// T-PERF-P12: Properties are kept in sync with AppViewModel via sync helpers.
// Full migration of @Published storage to this store is deferred to a later phase.

@Observable
@MainActor
final class SidebarInventoryStore {
    // MARK: - Pane inventory
    var panes: [AgtmuxPane] = []

    // MARK: - Grouped views
    var panesBySession: [(source: String, sessions: [SessionGroup])] = []

    // MARK: - Session order (DnD)
    var sessionOrderBySource: [String: [String]] = [:]

    // MARK: - Filters
    var statusFilter: StatusFilter = .all

    var showAgentsOnly: Bool = false

    var showPinnedOnly: Bool = false

    // MARK: - Pinning
    var pinnedPaneKeys: Set<String> = []

    var paneDisplayTitleOverrides: [String: String] = [:]

    // MARK: - Attention count
    var attentionCount: Int = 0
}
