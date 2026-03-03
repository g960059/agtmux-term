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
