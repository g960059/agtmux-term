import Foundation
import Observation
import AgtmuxTermCore

// MARK: - TerminalRuntimeStore
//
// Owns host configuration and per-tile routing state that the terminal subtree consumes.
//
// T-PERF-P12: Properties are kept in sync with AppViewModel via sync helpers.
// Full migration of @Published storage to this store is deferred to a later phase.

@Observable
@MainActor
final class TerminalRuntimeStore {
    // MARK: - Hosts
    var hostsConfig: HostsConfig = HostsConfig(hosts: [])

    // MARK: - Offline set
    var offlineHosts: Set<String> = []

    // MARK: - Fetch readiness
    var hasCompletedInitialFetch: Bool = false

    // MARK: - Live pane tracking
    var livePaneSessionKeys: Set<String> = []

    /// Identity index: "\(source):\(sessionName):\(windowId):\(paneId)" → paneInstanceID
    var paneIdentityIndex: [String: AgtmuxSyncV2PaneInstanceID] = [:]

    // MARK: - Refresh callback
    var onRefreshInventory: (@MainActor @Sendable () async -> Void)?
}
