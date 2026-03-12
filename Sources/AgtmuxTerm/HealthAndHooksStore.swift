import Foundation
import Observation
import AgtmuxTermCore

// MARK: - HealthAndHooksStore
//
// Owns daemon health and hook setup status that the settings/header UI consumes.
//
// T-PERF-P12: Properties are kept in sync with AppViewModel via sync helpers.
// Full migration of @Published storage to this store is deferred to a later phase.

@Observable
@MainActor
final class HealthAndHooksStore {
    // MARK: - Hook setup status
    var hookSetupStatus: HookSetupStatus = .unknown

    // MARK: - Local daemon health
    var localDaemonHealth: AgtmuxUIHealthV1?

    // MARK: - Local daemon issue
    var localDaemonIssue: LocalDaemonIssue?
}
