import Foundation

// MARK: - AppViewModel

/// Central state holder for the agtmux-term UI.
///
/// Polls the agtmux daemon every 1 second via AgtmuxDaemonClient.
/// All @Published properties are mutated on the main actor.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var panes: [AgtmuxPane] = []
    @Published var selectedPane: AgtmuxPane?
    @Published var isOffline: Bool = false
    @Published var statusFilter: StatusFilter = .all

    private let daemonClient = AgtmuxDaemonClient()
    private var pollingTask: Task<Void, Never>?

    // MARK: - Filtered panes

    var filteredPanes: [AgtmuxPane] {
        switch statusFilter {
        case .all:
            return panes
        case .managed:
            return panes.filter { $0.presence != nil }
        case .attention:
            return panes.filter { $0.needsAttention }
        case .pinned:
            return panes.filter { $0.isPinned }
        }
    }

    // MARK: - Selection

    func selectPane(_ pane: AgtmuxPane) {
        selectedPane = pane
    }

    // MARK: - Polling

    /// Start the 1-second polling loop.
    ///
    /// Guarded against double-start: calling startPolling() while already running is a no-op.
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await daemonClient.fetchSnapshot()
                    panes = snapshot.panes
                    isOffline = false
                } catch is CancellationError {
                    break
                } catch {
                    // Daemon unavailable or parse error — go offline, keep retrying.
                    isOffline = true
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Sleep was cancelled — exit cleanly.
                    break
                }
            }
        }
    }

    /// Cancel the polling loop and reset so startPolling() can be called again.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
