import Foundation
import Darwin

package enum AgtmuxManagedDaemonRuntime {
    private static let stateQueue = DispatchQueue(label: "local.agtmux.term.managed-daemon-runtime")
    private static var bootstrapResolvedTmuxSocketPathStorage: String?
    private static var launchRecordsBySocket: [String: LaunchRecord] = [:]

    package struct DaemonProcess: Equatable {
        package let pid: pid_t
        package let startedAt: Date?
        package let command: String
    }

    package struct LaunchRecord: Equatable {
        package let socketPath: String
        package let binaryPath: String
        package let arguments: [String]
        package let environment: [String: String]
        package let reusedExistingRuntime: Bool
        package let recordedAt: Date
    }

    package static func setBootstrapResolvedTmuxSocketPath(_ path: String?) {
        stateQueue.sync {
            bootstrapResolvedTmuxSocketPathStorage = normalizedSocketPath(path)
        }
    }

    package static func bootstrapResolvedTmuxSocketPath() -> String? {
        stateQueue.sync {
            bootstrapResolvedTmuxSocketPathStorage
        }
    }

    package static func recordLaunch(
        socketPath: String,
        binaryPath: String,
        arguments: [String],
        environment: [String: String],
        reusedExistingRuntime: Bool
    ) {
        stateQueue.sync {
            launchRecordsBySocket[socketPath] = LaunchRecord(
                socketPath: socketPath,
                binaryPath: binaryPath,
                arguments: arguments,
                environment: trackedEnvironment(from: environment),
                reusedExistingRuntime: reusedExistingRuntime,
                recordedAt: Date()
            )
        }
    }

    package static func launchRecord(socketPath: String) -> LaunchRecord? {
        stateQueue.sync {
            launchRecordsBySocket[socketPath]
        }
    }

    package static func clearLaunchRecord(socketPath: String) {
        _ = stateQueue.sync {
            launchRecordsBySocket.removeValue(forKey: socketPath)
        }
    }

    package static func shouldRestartReachableDaemon(
        socketPath: String,
        candidateBinaryURL: URL,
        appOwnedSocketPath: String = AgtmuxBinaryResolver.defaultSocketPath,
        fileManager: FileManager = .default,
        psOutput: String? = nil
    ) -> Bool {
        guard socketPath == appOwnedSocketPath else { return false }
        guard let binaryDate = modificationDate(for: candidateBinaryURL, fileManager: fileManager) else {
            return false
        }

        let processes = daemonProcesses(socketPath: socketPath, psOutput: psOutput)
        if let newestProcessStart = processes.compactMap(\.startedAt).max() {
            return newestProcessStart < binaryDate
        }

        guard let socketDate = modificationDate(
            for: URL(fileURLWithPath: socketPath),
            fileManager: fileManager
        ) else {
            return false
        }
        return socketDate < binaryDate
    }

    package static func daemonProcesses(socketPath: String) -> [DaemonProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,lstart=,command="]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return []
        }

        let output = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return daemonProcesses(socketPath: socketPath, psOutput: output)
    }

    package static func daemonProcesses(socketPath: String, psOutput: String?) -> [DaemonProcess] {
        guard let psOutput, !psOutput.isEmpty else {
            return daemonProcesses(socketPath: socketPath)
        }

        let marker = "--socket-path \(socketPath) daemon"
        return psOutput
            .split(separator: "\n")
            .compactMap { rawLine in
                parseDaemonProcess(line: String(rawLine), marker: marker)
            }
    }

    package static func daemonProcessIDs(socketPath: String) -> [pid_t] {
        daemonProcesses(socketPath: socketPath).map(\.pid)
    }

    package static func daemonProcessIDs(socketPath: String, psOutput: String) -> [pid_t] {
        let parsedProcesses = daemonProcesses(socketPath: socketPath, psOutput: psOutput)
        if !parsedProcesses.isEmpty {
            return parsedProcesses.map(\.pid)
        }

        let marker = "--socket-path \(socketPath) daemon"
        return psOutput
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                guard let splitIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    return nil
                }

                let pidText = line[..<splitIndex].trimmingCharacters(in: .whitespaces)
                let command = line[splitIndex...].trimmingCharacters(in: .whitespaces)
                guard
                    command.contains("agtmux"),
                    command.contains(marker),
                    let pidValue = Int32(pidText)
                else {
                    return nil
                }
                return pid_t(pidValue)
            }
    }

    package static func daemonProcessCommands(socketPath: String) -> [String] {
        daemonProcesses(socketPath: socketPath).map(\.command)
    }

    package static func daemonProcessCommands(socketPath: String, psOutput: String) -> [String] {
        let parsedProcesses = daemonProcesses(socketPath: socketPath, psOutput: psOutput)
        if !parsedProcesses.isEmpty {
            return parsedProcesses.map(\.command)
        }

        let marker = "--socket-path \(socketPath) daemon"
        return psOutput
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, line.contains(marker) else { return nil }
                guard let splitIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    return nil
                }
                return String(line[splitIndex...].trimmingCharacters(in: .whitespaces))
            }
    }

    package static func terminateDaemonProcesses(socketPath: String) {
        let pids = daemonProcessIDs(socketPath: socketPath).filter { $0 != getpid() }
        guard !pids.isEmpty else { return }

        pids.forEach { _ = kill($0, SIGTERM) }
        waitForProcessesToExit(pids, timeout: 1.0)

        let stubborn = pids.filter(processExists)
        stubborn.forEach { _ = kill($0, SIGKILL) }
        waitForProcessesToExit(stubborn, timeout: 0.5)

        let socketURL = URL(fileURLWithPath: socketPath)
        if FileManager.default.fileExists(atPath: socketURL.path) {
            try? FileManager.default.removeItem(at: socketURL)
        }
    }

    private static func modificationDate(for url: URL, fileManager: FileManager) -> Date? {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let date = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return date
    }

    private static func waitForProcessesToExit(_ pids: [pid_t], timeout: TimeInterval) {
        guard !pids.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ !processExists($0) }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func parseDaemonProcess(line: String, marker: String) -> DaemonProcess? {
        let parts = line.split(
            maxSplits: 6,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard
            parts.count == 7,
            let pidValue = Int32(String(parts[0]))
        else {
            return nil
        }

        let startedAtText = parts[1...5].joined(separator: " ")
        let command = String(parts[6])
        guard command.contains(marker) else { return nil }

        return DaemonProcess(
            pid: pid_t(pidValue),
            startedAt: daemonProcessDateFormatter.date(from: startedAtText),
            command: command
        )
    }

    private static let daemonProcessDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    private static func normalizedSocketPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trackedEnvironment(from env: [String: String]) -> [String: String] {
        let trackedKeys = [
            "TMUX_BIN",
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "XDG_CONFIG_HOME",
            "CODEX_HOME",
        ]
        return trackedKeys.reduce(into: [String: String]()) { result, key in
            if let value = env[key], !value.isEmpty {
                result[key] = value
            }
        }
    }
}
