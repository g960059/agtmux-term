import Foundation
import Darwin
import AgtmuxTermCore

/// Daemon process owner for the XPC service process.
final class ServiceDaemonSupervisor {
    private let socketPath: String
    private let queue = DispatchQueue(label: "local.agtmux.term.daemon-service-supervisor")
    private var process: Process?

    init(socketPath: String = AgtmuxBinaryResolver.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func startIfNeeded() -> Bool {
        queue.sync {
            startIfNeededLocked()
        }
    }

    func stopIfOwned() {
        queue.sync {
            stopIfOwnedLocked()
        }
    }

    private func startIfNeededLocked() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["AGTMUX_JSON"] != nil { return true }

        let candidates = AgtmuxBinaryResolver.candidateBinaryURLs()
        guard !candidates.isEmpty else { return false }

        // Already running: don't spawn another daemon.
        if candidates.contains(where: { isDaemonReachable(via: $0) }) {
            return true
        }
        if env["AGTMUX_AUTOSTART"] == "0" { return false }

        for binary in candidates where FileManager.default.isExecutableFile(atPath: binary.path) {
            if launchDaemon(using: binary), isDaemonReachable(via: binary, retries: 20) {
                return true
            }
            stopIfOwnedLocked()
        }
        return false
    }

    private func stopIfOwnedLocked() {
        guard let proc = process else { return }

        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        process = nil
    }

    private func launchDaemon(using binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["--socket-path", socketPath, "daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] finished in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.process?.processIdentifier == finished.processIdentifier {
                    self.process = nil
                }
            }
        }

        do {
            try proc.run()
            process = proc
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

final class AgtmuxDaemonServiceEndpoint: NSObject, AgtmuxDaemonServiceXPCProtocol {
    private let supervisor = ServiceDaemonSupervisor()
    private let daemonClient = AgtmuxDaemonClient()

    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void) {
        let started = supervisor.startIfNeeded()
        if started {
            reply(true, nil)
        } else {
            reply(false, "agtmux daemon unavailable" as NSString)
        }
    }

    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void) {
        guard supervisor.startIfNeeded() else {
            reply(nil, "agtmux daemon unavailable" as NSString)
            return
        }
        Task {
            do {
                let snapshot = try await daemonClient.fetchSnapshot()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                reply(data as NSData, nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func stopManagedDaemon(_ reply: @escaping () -> Void) {
        supervisor.stopIfOwned()
        reply()
    }

    func stopOwnedDaemon() {
        supervisor.stopIfOwned()
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let endpoint = AgtmuxDaemonServiceEndpoint()
    private let queue = DispatchQueue(label: "local.agtmux.term.daemon-service.connections")
    private var activeConnectionIDs = Set<ObjectIdentifier>()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AgtmuxDaemonServiceXPCProtocol.self)
        newConnection.exportedObject = endpoint

        let connectionID = ObjectIdentifier(newConnection)
        queue.sync {
            _ = activeConnectionIDs.insert(connectionID)
        }

        newConnection.interruptionHandler = { [weak self] in
            self?.handleConnectionClosed(connectionID)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.handleConnectionClosed(connectionID)
        }
        newConnection.resume()
        return true
    }

    private func handleConnectionClosed(_ connectionID: ObjectIdentifier) {
        queue.sync {
            guard activeConnectionIDs.remove(connectionID) != nil else { return }
            if activeConnectionIDs.isEmpty {
                endpoint.stopOwnedDaemon()
            }
        }
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
