import Foundation
import AppKit
import Darwin
import AgtmuxTermCore

/// PID of the daemon process launched by this app instance (0 = none).
///
/// Accessed from a SIGTERM signal handler, so it must remain a simple global.
private var managedDaemonPID: pid_t = 0

/// SIGTERM handler used by main.swift.
///
/// XCUITest terminates the app with SIGTERM. We also terminate the managed daemon
/// before exiting immediately to avoid lingering child processes.
let agtmuxTermSIGTERMHandler: @convention(c) (Int32) -> Void = { signal in
    _ = signal
    let pid = managedDaemonPID
    if pid > 0 {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 {
            kill(pid, SIGTERM)
        }
    }
    _exit(0)
}

/// Starts/stops a local agtmux daemon process owned by this app instance.
///
/// Behavior:
/// - If a daemon is already reachable on the configured socket, no new daemon is spawned.
/// - If spawned by this instance, the daemon is terminated on app shutdown.
/// - Disabled when `AGTMUX_AUTOSTART=0`.
final class AgtmuxDaemonSupervisor {
    private let socketPath: String
    private let workQueue = DispatchQueue(label: "local.agtmux.term.daemon-supervisor")
    private var process: Process?
    private var terminationObserver: NSObjectProtocol?

    init(socketPath: String = AgtmuxBinaryResolver.resolvedSocketPath()) {
        self.socketPath = socketPath
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopIfOwned()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopIfOwned()
    }

    func startIfNeeded() {
        workQueue.sync {
            startIfNeededLocked()
        }
    }

    func startIfNeededAsync() {
        workQueue.async { [weak self] in
            self?.startIfNeededLocked()
        }
    }

    func stopIfOwned() {
        workQueue.sync {
            stopIfOwnedLocked()
        }
    }

    private func startIfNeededLocked() {
        let env = ProcessInfo.processInfo.environment
        if env["AGTMUX_AUTOSTART"] == "0" { return }
        if env["AGTMUX_UITEST"] == "1", env["AGTMUX_UITEST_ENABLE_MANAGED_DAEMON"] != "1" {
            return
        }

        let candidates = AgtmuxBinaryResolver.candidateBinaryURLs()
        guard !candidates.isEmpty else {
            fputs("AgtmuxTerm: no agtmux daemon binary candidates resolved for managed socket startup.\n", stderr)
            return
        }

        // Reuse an already-running daemon when available.
        if let reachableBinary = candidates.first(where: { isDaemonReachable(via: $0) }) {
            if !AgtmuxManagedDaemonRuntime.shouldRestartReachableDaemon(
                socketPath: socketPath,
                candidateBinaryURL: reachableBinary
            ) {
                let env = ProcessInfo.processInfo.environment
                var arguments = ["--socket-path", socketPath, "daemon"]
                arguments.append(contentsOf: LocalTmuxTarget.daemonCLIArguments(from: env))
                AgtmuxManagedDaemonRuntime.recordLaunch(
                    socketPath: socketPath,
                    binaryPath: reachableBinary.path,
                    arguments: arguments,
                    environment: env,
                    reusedExistingRuntime: true
                )
                return
            }

            fputs(
                "AgtmuxTerm: restarting stale app-managed daemon for \(socketPath) because \(reachableBinary.path) is newer than the current socket runtime.\n",
                stderr
            )
            stopIfOwnedLocked()
            AgtmuxManagedDaemonRuntime.terminateDaemonProcesses(socketPath: socketPath)
            removeStaleSocketIfPresent()
        }
        guard ensureSocketParentDirectoryExists() else { return }

        // Remove stale socket before launching: handles incompatible (old-generation)
        // daemons that answer the socket but don't speak our RPC protocol.
        removeStaleSocketIfPresent()

        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
            if launchDaemon(using: binary), isDaemonReachable(via: binary, retries: 50) {
                fputs("AgtmuxTerm: started managed daemon for \(socketPath) using \(binary.path).\n", stderr)
                return
            }
            fputs(
                "AgtmuxTerm: managed daemon launch or probe failed for \(socketPath) using \(binary.path).\n",
                stderr
            )
            stopIfOwnedLocked()
        }
    }

    private func ensureSocketParentDirectoryExists() -> Bool {
        do {
            try AgtmuxBinaryResolver.ensureSocketParentDirectoryExists(for: socketPath)
            return true
        } catch {
            fputs("Failed to create agtmux socket directory for \(socketPath): \(error)\n", stderr)
            return false
        }
    }

    private func removeStaleSocketIfPresent() {
        let socketURL = URL(fileURLWithPath: socketPath)
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: socketURL)
        } catch {
            fputs("AgtmuxTerm: failed to remove stale socket at \(socketPath): \(error)\n", stderr)
        }
    }

    private func stopIfOwnedLocked() {
        guard let proc = process else { return }

        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        process = nil
        managedDaemonPID = 0
        AgtmuxManagedDaemonRuntime.clearLaunchRecord(socketPath: socketPath)
    }

    private func launchDaemon(using binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = binaryURL
        let env = ManagedDaemonLaunchEnvironment.normalized(from: ProcessInfo.processInfo.environment)
        var arguments = ["--socket-path", socketPath, "daemon"]
        arguments.append(contentsOf: LocalTmuxTarget.daemonCLIArguments(from: env))
        proc.arguments = arguments
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let logHandle = managedDaemonLogHandle(env: env, key: "AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH")
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        proc.terminationHandler = { [weak self] finished in
            if managedDaemonPID == finished.processIdentifier {
                managedDaemonPID = 0
            }
            self?.workQueue.async { [weak self] in
                guard let self else { return }
                if self.process?.processIdentifier == finished.processIdentifier {
                    self.process = nil
                }
            }
        }

        do {
            try proc.run()
            process = proc
            managedDaemonPID = proc.processIdentifier
            AgtmuxManagedDaemonRuntime.recordLaunch(
                socketPath: socketPath,
                binaryPath: binaryURL.path,
                arguments: arguments,
                environment: env,
                reusedExistingRuntime: false
            )
            return true
        } catch {
            fputs(
                "AgtmuxTerm: failed to launch managed daemon \(binaryURL.path) for \(socketPath): \(error)\n",
                stderr
            )
            return false
        }
    }

    private func isDaemonReachable(via binaryURL: URL, retries: Int = 1) -> Bool {
        for attempt in 0..<retries {
            if probe(binaryURL: binaryURL) {
                return true
            }
            if attempt + 1 < retries {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return false
    }

    private func probe(binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--socket-path", socketPath, "json"]
        proc.environment = ManagedDaemonLaunchEnvironment.normalized(from: ProcessInfo.processInfo.environment)
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(1.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if proc.isRunning {
            proc.terminate()
            return false
        }

        return proc.terminationStatus == 0
    }

    private func managedDaemonLogHandle(env: [String: String], key: String) -> Any {
        // UI test: use the specified log path (or /dev/null if not set).
        if env["AGTMUX_UITEST"] == "1" {
            guard let path = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return FileHandle.nullDevice }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return FileHandle.nullDevice
            }
            try? handle.truncate(atOffset: 0)
            return handle
        }

        // Production: append to ~/Library/Logs/AgtmuxTerm/daemon.log.
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AgtmuxTerm")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return FileHandle.nullDevice
        }
        handle.seekToEndOfFile()
        return handle
    }
}
