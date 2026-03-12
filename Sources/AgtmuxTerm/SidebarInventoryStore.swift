import Foundation
import Observation
import AgtmuxTermCore

// MARK: - SidebarInventoryStore
//
// Owns all pane-list state that SidebarView consumes.
// Isolated to the main actor so @Published mutations remain thread-safe.
//
// TODO (T-PERF-P4 follow-up): migrate the corresponding @Published properties
// out of AppViewModel and into this store, then update SidebarView to consume
// this store directly instead of going through AppViewModel.

@Observable
@MainActor
final class SidebarInventoryStore {
    // MARK: - Pane inventory
    // TODO: migrate from AppViewModel.panes
    var panes: [AgtmuxPane] = []

    // MARK: - Grouped views
    // TODO: migrate from AppViewModel.panesBySession
    var panesBySession: [(source: String, sessions: [SessionGroup])] = []

    // MARK: - Session order (DnD)
    // TODO: migrate from AppViewModel.sessionOrderBySource
    var sessionOrderBySource: [String: [String]] = [:]

    // MARK: - Filters
    // TODO: migrate from AppViewModel.statusFilter
    var statusFilter: StatusFilter = .all

    // TODO: migrate from AppViewModel.showAgentsOnly
    var showAgentsOnly: Bool = false

    // TODO: migrate from AppViewModel.showPinnedOnly
    var showPinnedOnly: Bool = false

    // MARK: - Pinning
    // TODO: migrate from AppViewModel.pinnedPaneKeys
    var pinnedPaneKeys: Set<String> = []

    // TODO: migrate from AppViewModel.paneDisplayTitleOverrides
    var paneDisplayTitleOverrides: [String: String] = [:]

    // MARK: - Attention count
    // TODO: migrate from AppViewModel.attentionCount (computed)
    var attentionCount: Int = 0
}
