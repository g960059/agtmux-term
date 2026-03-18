import Foundation
import XCTest
import Darwin
@testable import AgtmuxTerm

final class TmuxControlModeProcessRegistryTests: XCTestCase {
    func testOrphanedLocalControlModePIDsFiltersToPPIDOneTmuxControlClients() {
        let table = """
          101     1 /opt/homebrew/bin/tmux -C attach-session -t alpha
          102    77 /opt/homebrew/bin/tmux -C attach-session -t beta
          103     1 /usr/bin/ssh host tmux -C attach-session -t gamma
          104     1 /opt/homebrew/bin/tmux attach-session -t delta
          105     1 tmux -C attach-session -t epsilon
        """

        let pids = TmuxControlModeProcessRegistry.orphanedLocalControlModePIDs(from: table)

        XCTAssertEqual(pids, [101, 105])
    }

    func testTerminateTrackedProcessesStopsRegisteredProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        await TmuxControlModeProcessRegistry.shared.register(process.processIdentifier)
        await TmuxControlModeProcessRegistry.shared.terminateTrackedProcesses()

        let exited = await waitUntil(timeout: 1.0) {
            !Self.processIsAlive(process.processIdentifier)
        }

        XCTAssertTrue(exited)
        let tracked = await TmuxControlModeProcessRegistry.shared.trackedPIDsSnapshot()
        XCTAssertFalse(tracked.contains(process.processIdentifier))
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        intervalMs: UInt64 = 20,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        return condition()
    }
}
