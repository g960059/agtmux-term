import Foundation
import Darwin

actor TmuxControlModeProcessRegistry {
    static let shared = TmuxControlModeProcessRegistry()

    private var trackedPIDs: Set<pid_t> = []

    func register(_ pid: pid_t) {
        guard pid > 0 else { return }
        trackedPIDs.insert(pid)
    }

    func unregister(_ pid: pid_t) {
        guard pid > 0 else { return }
        trackedPIDs.remove(pid)
    }

    func terminateTrackedProcesses() async {
        let livePIDs = trackedPIDs.filter(Self.processIsAlive)
        guard !livePIDs.isEmpty else {
            trackedPIDs.removeAll()
            return
        }

        for pid in livePIDs {
            _ = Darwin.kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            let remaining = livePIDs.filter(Self.processIsAlive)
            if remaining.isEmpty {
                trackedPIDs.subtract(livePIDs)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let stubborn = livePIDs.filter(Self.processIsAlive)
        stubborn.forEach { _ = Darwin.kill($0, SIGKILL) }
        trackedPIDs.subtract(livePIDs)
    }

    func trackedPIDsSnapshot() -> Set<pid_t> {
        trackedPIDs
    }

    nonisolated static func reapOrphanedLocalControlModeProcessesIfNeeded(
        processTable: () throws -> String = liveProcessTable,
        signalProcess: (pid_t, Int32) -> Int32 = Darwin.kill
    ) throws -> [pid_t] {
        let orphanedPIDs = orphanedLocalControlModePIDs(from: try processTable())
        orphanedPIDs.forEach { _ = signalProcess($0, SIGTERM) }
        return orphanedPIDs
    }

    nonisolated static func orphanedLocalControlModePIDs(from processTable: String) -> [pid_t] {
        processTable
            .split(whereSeparator: \.isNewline)
            .compactMap(ProcessRecord.init(rawLine:))
            .filter(\.isOrphanedLocalControlMode)
            .map(\.pid)
    }

    private struct ProcessRecord {
        let pid: pid_t
        let ppid: pid_t
        let command: String

        init?(rawLine: Substring) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else {
                return nil
            }

            self.pid = pid
            self.ppid = ppid
            self.command = String(parts[2])
        }

        var isOrphanedLocalControlMode: Bool {
            guard ppid == 1 else { return false }
            return command.range(
                of: #"^(\S+/)?tmux\s+-C\s+attach-session\s+-t\s+"#,
                options: .regularExpression
            ) != nil
        }
    }

    private nonisolated static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private nonisolated static func liveProcessTable() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,command="]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Drain stdout before waiting. `ps -Ao ...` can emit enough rows to fill the
        // pipe buffer; waiting first deadlocks startup because the child cannot exit.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TmuxCommandError.failed(
                args: process.arguments ?? [],
                code: process.terminationStatus,
                stderr: "ps process table query failed"
            )
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
