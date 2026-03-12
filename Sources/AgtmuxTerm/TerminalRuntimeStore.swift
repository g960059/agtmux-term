import Foundation
import Observation
import AgtmuxTermCore

// MARK: - TerminalRuntimeStore
//
// Owns host configuration and per-tile routing state that the terminal subtree consumes.
//
// TODO (T-PERF-P4 follow-up): migrate the corresponding @Published properties
// out of AppViewModel and pass this store to the terminal subtree environment
// instead of the full AppViewModel.

@Observable
@MainActor
final class TerminalRuntimeStore {
    // MARK: - Hosts
    // TODO: migrate from AppViewModel.hostsConfig
    var hostsConfig: HostsConfig = HostsConfig(hosts: [])

    // MARK: - Offline set
    // TODO: migrate from AppViewModel.offlineHosts
    var offlineHosts: Set<String> = []

    // MARK: - Fetch readiness
    // TODO: migrate from AppViewModel.hasCompletedInitialFetch
    var hasCompletedInitialFetch: Bool = false
}
