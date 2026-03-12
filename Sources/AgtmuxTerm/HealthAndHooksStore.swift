import Foundation
import Observation
import AgtmuxTermCore

// MARK: - HealthAndHooksStore
//
// Owns daemon health and hook setup status that the settings/header UI consumes.
//
// TODO (T-PERF-P4 follow-up): migrate the corresponding @Published properties
// out of AppViewModel and update SettingsView / hook-status banners to consume
// this store directly.

@Observable
@MainActor
final class HealthAndHooksStore {
    // MARK: - Hook setup status
    // TODO: migrate from AppViewModel.hookSetupStatus
    var hookSetupStatus: HookSetupStatus = .unknown

    // MARK: - Local daemon health
    // TODO: migrate from AppViewModel.localDaemonHealth
    var localDaemonHealth: AgtmuxUIHealthV1?

    // MARK: - Local daemon issue
    // TODO: migrate from AppViewModel.localDaemonIssue
    var localDaemonIssue: LocalDaemonIssue?
}
