import Foundation

// MARK: - TmuxControlModeRegistry

/// Manages the lifecycle of TmuxControlMode instances.
///
/// `safeKillSession()` ensures the TmuxControlMode for a session is stopped
/// before `kill-session` is issued, preventing SIGPIPE when tmux terminates
/// the PTY while the control mode process is still reading.
@MainActor
final class TmuxControlModeRegistry {
    static let shared = TmuxControlModeRegistry()

    private var modes: [String: TmuxControlMode] = [:]  // key: "source:sessionName"
    private var scheduledStops: [String: Task<Void, Never>] = [:]  // key: "source:sessionName"

    private init() {}

    // MARK: - Mode access

    /// Get or create a TmuxControlMode for the given session and source.
    func mode(for sessionName: String, source: String = "local") -> TmuxControlMode {
        let key = "\(source):\(sessionName)"
        if let existing = modes[key] { return existing }
        let mode = TmuxControlMode(sessionName: sessionName, source: source)
        modes[key] = mode
        return mode
    }

    /// Returns an existing TmuxControlMode only if already registered; never creates one.
    ///
    /// Use this when you want to subscribe to events only if monitoring is already underway
    /// (e.g. for remote sessions where you don't want to initiate a new SSH connection).
    func existingMode(for sessionName: String, source: String = "local") -> TmuxControlMode? {
        let key = "\(source):\(sessionName)"
        return modes[key]
    }

    /// Start monitoring a session (idempotent).
    func startMonitoring(sessionName: String, source: String = "local") {
        let m = mode(for: sessionName, source: source)
        Task { await m.start() }
    }

    /// Stop monitoring a session.
    func stopMonitoring(sessionName: String, source: String = "local") async {
        let key = "\(source):\(sessionName)"
        guard let m = modes[key] else { return }
        modes.removeValue(forKey: key)  // Remove first to prevent new start racing
        await m.stop()
    }

    // MARK: - Blur lifecycle

    /// Schedule a stop after a delay (for remote session blur lifecycle).
    /// Cancels any previously scheduled stop for the same key.
    func scheduleStop(sessionName: String, source: String, afterDelay: TimeInterval = 30) {
        let key = "\(source):\(sessionName)"
        scheduledStops[key]?.cancel()
        scheduledStops[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(afterDelay * 1_000_000_000))
            } catch {
                return  // cancelled
            }
            await self?.stopMonitoring(sessionName: sessionName, source: source)
            // Capture key by value to avoid capturing mutable self across actor boundary.
            let capturedKey = key
            Task { @MainActor [weak self] in self?.scheduledStops.removeValue(forKey: capturedKey) }
        }
    }

    /// Cancel a previously scheduled stop (called on re-focus).
    func cancelScheduledStop(sessionName: String, source: String) {
        let key = "\(source):\(sessionName)"
        scheduledStops[key]?.cancel()
        scheduledStops.removeValue(forKey: key)
    }

    // MARK: - Safe kill

    /// Stop the TmuxControlMode for `name` before issuing `kill-session`.
    ///
    /// Ordering matters: stop the control mode subprocess first so that
    /// tmux's SIGPIPE is not delivered to a process still reading from the PTY.
    func safeKillSession(_ name: String, source: String = "local") async throws {
        // 1. Stop the control mode (if any) inline — await guarantees stop() completes
        //    before we proceed to kill-session. Fire-and-forget stopMonitoring() was
        //    racy: the Task scheduling didn't guarantee completion within the 50ms sleep.
        let key = "\(source):\(name)"
        if let m = modes[key] {
            await m.stop()
            modes.removeValue(forKey: key)
        }

        // 2. Now kill the tmux session.
        _ = try await TmuxCommandRunner.shared.run(
            ["kill-session", "-t", name],
            source: source
        )
    }
}
