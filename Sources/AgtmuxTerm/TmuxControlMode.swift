import Foundation
import AgtmuxTermCore

private func tmuxControlModeDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AGTMUX_NAV_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[tmux-control] " + message() + "\n").utf8))
}

// MARK: - ControlModeEvent

/// Events produced by tmux control mode (`tmux -C attach-session`).
///
/// Based on the formats observed in Spike C (T-029, tmux 3.6a):
///   `%layout-change @WNDID LAYOUT VISIBLE_LAYOUT [*]`
///   `%window-pane-changed @WNDID %PANEID`
///   `%window-add @WNDID`
///   `%unlinked-window-close @WNDID`
///   `%session-changed $SESSID SESSNAME`
///   `%session-window-changed $SESSID @WNDID`
///   `%output %PANEID TEXT`
///   `%begin TIMESTAMP CMDID FLAG` ... `%end TIMESTAMP CMDID FLAG`
enum ControlModeEvent: Sendable {
    case layoutChange(windowId: String, layout: String, isCurrent: Bool)
    case windowPaneChanged(windowId: String, paneId: String)
    case windowAdd(windowId: String)
    case windowClose(windowId: String)
    case sessionChanged(sessionId: String, sessionName: String)
    case sessionWindowChanged(sessionId: String, windowId: String)
    case output(paneId: String, text: String)
    /// Accumulated lines between %begin / %end for a given command ID.
    case commandResponse(cmdId: Int, lines: [String])
}

struct TmuxControlModeParser {
    private static let newline: UInt8 = 0x0A

    private let emitsPaneOutput: Bool
    private var bufferedBytes = Data()
    private var inBlock = false
    private var blockCmdId = 0
    private var blockLines: [String] = []

    init(emitsPaneOutput: Bool) {
        self.emitsPaneOutput = emitsPaneOutput
    }

    mutating func append(_ data: Data) -> [ControlModeEvent] {
        guard data.isEmpty == false else { return [] }
        bufferedBytes.append(data)
        return drainCompleteLines()
    }

    mutating func finish() -> [ControlModeEvent] {
        guard bufferedBytes.isEmpty == false else { return [] }
        let trailing = bufferedBytes
        bufferedBytes.removeAll(keepingCapacity: false)
        return consumeLineData(trailing)
    }

    private mutating func drainCompleteLines() -> [ControlModeEvent] {
        var events: [ControlModeEvent] = []

        while let newlineIndex = bufferedBytes.firstIndex(of: Self.newline) {
            let lineData = Data(bufferedBytes[..<newlineIndex])
            bufferedBytes.removeSubrange(...newlineIndex)
            events.append(contentsOf: consumeLineData(lineData))
        }

        return events
    }

    private mutating func consumeLineData(_ lineData: Data) -> [ControlModeEvent] {
        guard let decoded = String(data: lineData, encoding: .utf8) else { return [] }
        let line = decoded.trimmingCharacters(in: .controlCharacters)
        guard line.isEmpty == false else { return [] }
        return parseLine(line)
    }

    private mutating func parseLine(_ line: String) -> [ControlModeEvent] {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard let tag = parts.first else { return [] }

        switch tag {
        case "%begin":
            inBlock = true
            blockCmdId = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
            blockLines = []
            return []

        case "%end":
            guard inBlock else {
                blockLines = []
                return []
            }

            let cmdId = parts.count >= 3 ? (Int(parts[2]) ?? blockCmdId) : blockCmdId
            let event = ControlModeEvent.commandResponse(cmdId: cmdId, lines: blockLines)
            inBlock = false
            blockLines = []
            return [event]

        case "%error":
            inBlock = false
            blockLines = []
            return []

        case "%layout-change":
            guard parts.count >= 3 else { return [] }
            let event = ControlModeEvent.layoutChange(
                windowId: String(parts[1]),
                layout: String(parts[2]),
                isCurrent: parts.last == "*"
            )
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%window-pane-changed":
            guard parts.count >= 3 else { return [] }
            let event = ControlModeEvent.windowPaneChanged(
                windowId: String(parts[1]),
                paneId: String(parts[2])
            )
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%window-add":
            guard parts.count >= 2 else { return [] }
            let event = ControlModeEvent.windowAdd(windowId: String(parts[1]))
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%unlinked-window-close":
            guard parts.count >= 2 else { return [] }
            let event = ControlModeEvent.windowClose(windowId: String(parts[1]))
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%session-changed":
            guard parts.count >= 3 else { return [] }
            let event = ControlModeEvent.sessionChanged(
                sessionId: String(parts[1]),
                sessionName: String(parts[2])
            )
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%session-window-changed":
            guard parts.count >= 3 else { return [] }
            let event = ControlModeEvent.sessionWindowChanged(
                sessionId: String(parts[1]),
                windowId: String(parts[2])
            )
            if inBlock {
                blockLines.append(line)
                return []
            }
            return [event]

        case "%output":
            if inBlock {
                blockLines.append(line)
                return []
            }
            guard emitsPaneOutput, parts.count >= 3 else { return [] }
            let paneId = String(parts[1])
            let text = parts[2...].joined(separator: " ")
            return [.output(paneId: paneId, text: text)]

        default:
            if inBlock {
                blockLines.append(line)
            }
            return []
        }
    }
}

// MARK: - TmuxControlMode

/// Maintains a persistent `tmux -C attach-session` subprocess for a named session.
///
/// Produces `ControlModeEvent` values via `events: AsyncStream<ControlModeEvent>`.
/// Reconnects automatically with exponential backoff on unexpected disconnection.
///
/// Reconnect schedule: 1 s → 2 s → 4 s → 8 s → 16 s (max 5 attempts),
/// then transitions to `.degraded`.
actor TmuxControlMode {
    // MARK: - Types

    enum ConnectionState: Sendable, Equatable {
        case connected
        case reconnecting(attempt: Int)
        case degraded
        case stopped

        var debugLabel: String {
            switch self {
            case .connected:
                return "connected"
            case .reconnecting(let attempt):
                return "reconnecting:\(attempt)"
            case .degraded:
                return "degraded"
            case .stopped:
                return "stopped"
            }
        }
    }

    // MARK: - Public state

    let sessionName: String
    let source: String
    let emitsPaneOutput: Bool
    private(set) var connectionState: ConnectionState = .stopped

    // MARK: - AsyncStream plumbing

    private let eventContinuation: AsyncStream<ControlModeEvent>.Continuation
    let events: AsyncStream<ControlModeEvent>

    // MARK: - Process state

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - Backoff

    private static let backoffDelays: [TimeInterval] = [1, 2, 4, 8, 16]
    private var retryCount = 0

    // MARK: - Init

    init(
        sessionName: String,
        source: String = "local",
        emitsPaneOutput: Bool = false
    ) {
        let (stream, continuation) = AsyncStream<ControlModeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1024)
        )
        self.events = stream
        self.eventContinuation = continuation
        self.sessionName = sessionName
        self.source = source
        self.emitsPaneOutput = emitsPaneOutput
    }

    // MARK: - Lifecycle

    /// Start the control mode connection.
    func start() async {
        guard connectionState == .stopped else { return }
        stopped = false
        retryCount = 0
        await connect()
    }

    /// Stop the connection and finish the AsyncStream continuation.
    func stop() async {
        stopped = true
        connectionState = .stopped
        await terminateProcess()
        readerTask?.cancel()
        readerTask = nil
        eventContinuation.finish()
    }

    /// Send a command string to the tmux control mode stdin.
    /// The response arrives asynchronously as a `.commandResponse` event.
    func send(command: String) throws {
        guard let handle = stdinHandle else {
            throw TmuxCommandError.failed(args: [command], code: -1,
                                          stderr: "control mode not connected")
        }
        let data = (command + "\n").data(using: .utf8)!
        let signpostID = AgtmuxSignpost.navigationSync.makeSignpostID()
        let signpostState = AgtmuxSignpost.navigationSync.beginInterval("controlModeSend", id: signpostID)
        defer { AgtmuxSignpost.navigationSync.endInterval("controlModeSend", signpostState) }
        try handle.write(contentsOf: data)
    }

    // MARK: - Private

    private func yield(_ event: ControlModeEvent) {
        recordEventSignpost(for: event)
        tmuxControlModeDebugLog("event session=\(sessionName) source=\(source) event=\(String(describing: event))")
        eventContinuation.yield(event)
    }

    private func connect() async {
        guard !stopped else { return }
        tmuxControlModeDebugLog("connect start session=\(sessionName) source=\(source)")

        let process = Process()

        if source == "local" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let env = ProcessInfo.processInfo.environment
            process.arguments = Self.localProcessArguments(
                sessionName: sessionName,
                env: env
            )
            var finalEnv = env
            finalEnv["TMUX"] = nil
            finalEnv["TMUX_PANE"] = nil
            process.environment = finalEnv
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                source,
                "tmux", "-C", "attach-session", "-t", sessionName,
            ]
        }

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(status: proc.terminationStatus) }
        }

        do {
            try runProcessWithSignpost(process)
        } catch {
            scheduleReconnect()
            return
        }

        self.process     = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        connectionState  = .connected
        retryCount       = 0
        tmuxControlModeDebugLog("connect ok session=\(sessionName) source=\(source) pid=\(process.processIdentifier)")
        if process.processIdentifier > 0 {
            await TmuxControlModeProcessRegistry.shared.register(process.processIdentifier)
        }

        // Start async reader
        let stdoutFH = stdoutPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.readLoop(fileHandle: stdoutFH)
        }
    }

    private func readLoop(fileHandle: FileHandle) async {
        await Self.streamEvents(
            fileHandle: fileHandle,
            emitsPaneOutput: emitsPaneOutput
        ) { [weak self] event in
            await self?.yield(event)
        }
    }

    private nonisolated static func streamEvents(
        fileHandle: FileHandle,
        emitsPaneOutput: Bool,
        emit: @escaping @Sendable (ControlModeEvent) async -> Void
    ) async {
        var parser = TmuxControlModeParser(emitsPaneOutput: emitsPaneOutput)

        while !Task.isCancelled {
            let chunk: Data
            do {
                guard let data = try fileHandle.read(upToCount: 4096), data.isEmpty == false else {
                    break
                }
                chunk = data
            } catch {
                break
            }

            for event in parser.append(chunk) {
                guard !Task.isCancelled else { return }
                await emit(event)
            }
        }

        guard !Task.isCancelled else { return }
        for event in parser.finish() {
            await emit(event)
        }
    }

    private func handleTermination(status: Int32) async {
        tmuxControlModeDebugLog("terminated session=\(sessionName) source=\(source) status=\(status)")
        readerTask?.cancel()
        readerTask = nil
        await terminateProcess()

        guard !stopped else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, retryCount < Self.backoffDelays.count else {
            connectionState = .degraded
            return
        }
        let delay = Self.backoffDelays[retryCount]
        retryCount += 1
        connectionState = .reconnecting(attempt: retryCount)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.connect()
        }
    }

    private func runProcessWithSignpost(_ process: Process) throws {
        guard source != "local" else {
            try process.run()
            return
        }
        let signpostID = AgtmuxSignpost.remoteSSH.makeSignpostID()
        let signpostState = AgtmuxSignpost.remoteSSH.beginInterval("sshControlConnect", id: signpostID)
        defer { AgtmuxSignpost.remoteSSH.endInterval("sshControlConnect", signpostState) }
        try process.run()
    }

    private func recordEventSignpost(for event: ControlModeEvent) {
        switch event {
        case .layoutChange:
            recordNavigationSignpost("layoutChange")
        case .windowPaneChanged:
            recordNavigationSignpost("windowPaneChanged")
        case .windowAdd:
            recordNavigationSignpost("windowAdd")
        case .windowClose:
            recordNavigationSignpost("windowClose")
        case .sessionChanged:
            recordNavigationSignpost("sessionChanged")
        case .sessionWindowChanged:
            recordNavigationSignpost("sessionWindowChanged")
        case .commandResponse:
            recordNavigationSignpost("commandResponse")
        case .output:
            break
        }
    }

    private func recordNavigationSignpost(_ name: StaticString) {
        let signpostID = AgtmuxSignpost.navigationSync.makeSignpostID()
        let signpostState = AgtmuxSignpost.navigationSync.beginInterval(name, id: signpostID)
        AgtmuxSignpost.navigationSync.endInterval(name, signpostState)
    }

    private func terminateProcess() async {
        let pid = process?.processIdentifier ?? 0
        if process?.isRunning == true { process?.terminate() }
        process     = nil
        stdinHandle = nil
        if pid > 0 {
            await TmuxControlModeProcessRegistry.shared.unregister(pid)
        }
    }

    nonisolated static func localProcessArguments(
        sessionName: String,
        env: [String: String]
    ) -> [String] {
        let configArgs = LocalTmuxTarget.configArguments(from: env)
        let socketArgs = LocalTmuxTarget.socketArguments(from: env)
        return ["tmux"] + configArgs + socketArgs + ["-C", "attach-session", "-t", sessionName]
    }
}
