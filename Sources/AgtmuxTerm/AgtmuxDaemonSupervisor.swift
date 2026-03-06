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

    init(socketPath: String = AgtmuxBinaryResolver.defaultSocketPath) {
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
        if env["AGTMUX_UITEST"] == "1" { return }

        let candidates = AgtmuxBinaryResolver.candidateBinaryURLs()
        guard !candidates.isEmpty else { return }

        // Reuse an already-running daemon when available.
        if candidates.contains(where: { isDaemonReachable(via: $0) }) {
            return
        }
        guard ensureSocketParentDirectoryExists() else { return }

        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
            if launchDaemon(using: binary), isDaemonReachable(via: binary, retries: 20) {
                return
            }
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
    }

    private func launchDaemon(using binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--socket-path", socketPath, "daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

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
            return true
        } catch {
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
}
