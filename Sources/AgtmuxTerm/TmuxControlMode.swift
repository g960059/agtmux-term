import Foundation

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
    }

    // MARK: - Public state

    let sessionName: String
    let source: String
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

    init(sessionName: String, source: String = "local") {
        let (stream, continuation) = AsyncStream<ControlModeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.eventContinuation = continuation
        self.sessionName = sessionName
        self.source      = source
    }

    // MARK: - Lifecycle

    /// Start the control mode connection.
    func start() {
        guard connectionState == .stopped else { return }
        stopped = false
        retryCount = 0
        connect()
    }

    /// Stop the connection and finish the AsyncStream continuation.
    func stop() {
        stopped = true
        connectionState = .stopped
        terminateProcess()
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
        try handle.write(contentsOf: data)
    }

    // MARK: - Private

    private func yield(_ event: ControlModeEvent) {
        eventContinuation.yield(event)
    }

    private func connect() {
        guard !stopped else { return }

        let process = Process()

        if source == "local" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-C", "attach-session", "-t", sessionName]
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
            try process.run()
        } catch {
            scheduleReconnect()
            return
        }

        self.process     = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        connectionState  = .connected
        retryCount       = 0

        // Start async reader
        let stdoutFH = stdoutPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            await self?.readLoop(fileHandle: stdoutFH)
        }
    }

    private func readLoop(fileHandle: FileHandle) async {
        var inBlock = false
        var blockCmdId = 0
        var blockLines: [String] = []
        var lineBuffer = ""

        do {
            for try await byte in fileHandle.bytes {
                guard !Task.isCancelled else { break }
                let char = Character(UnicodeScalar(byte))
                if char == "\n" {
                    let line = lineBuffer.trimmingCharacters(in: .controlCharacters)
                    lineBuffer = ""
                    guard !line.isEmpty else { continue }
                    await parseLine(line, inBlock: &inBlock,
                                    blockCmdId: &blockCmdId, blockLines: &blockLines)
                } else {
                    lineBuffer.append(char)
                }
            }
        } catch {
            // EOF or read error — process terminated, handleTermination will reconnect
        }
    }

    private func parseLine(_ line: String,
                           inBlock: inout Bool,
                           blockCmdId: inout Int,
                           blockLines: inout [String]) async {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
                        .map(String.init)
        guard let tag = parts.first else { return }

        switch tag {
        case "%begin":
            inBlock    = true
            blockCmdId = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
            blockLines = []

        case "%end":
            if inBlock {
                let cmdId = parts.count >= 3 ? (Int(parts[2]) ?? blockCmdId) : blockCmdId
                yield(.commandResponse(cmdId: cmdId, lines: blockLines))
            }
            inBlock    = false
            blockLines = []

        case "%error":
            inBlock    = false
            blockLines = []

        case "%layout-change":
            // %layout-change @WNDID LAYOUT VISIBLE_LAYOUT [*]
            guard parts.count >= 3 else { return }
            let windowId = parts[1]
            let layout   = parts[2]
            let isCurrent = parts.last == "*"
            if inBlock { blockLines.append(line) }
            else { yield(.layoutChange(windowId: windowId, layout: layout, isCurrent: isCurrent)) }

        case "%window-pane-changed":
            guard parts.count >= 3 else { return }
            let event = ControlModeEvent.windowPaneChanged(windowId: parts[1], paneId: parts[2])
            if inBlock { blockLines.append(line) } else { yield(event) }

        case "%window-add":
            guard parts.count >= 2 else { return }
            let event = ControlModeEvent.windowAdd(windowId: parts[1])
            if inBlock { blockLines.append(line) } else { yield(event) }

        case "%unlinked-window-close":
            guard parts.count >= 2 else { return }
            let event = ControlModeEvent.windowClose(windowId: parts[1])
            if inBlock { blockLines.append(line) } else { yield(event) }

        case "%session-changed":
            guard parts.count >= 3 else { return }
            let event = ControlModeEvent.sessionChanged(sessionId: parts[1], sessionName: parts[2])
            if inBlock { blockLines.append(line) } else { yield(event) }

        case "%session-window-changed":
            guard parts.count >= 3 else { return }
            let event = ControlModeEvent.sessionWindowChanged(sessionId: parts[1], windowId: parts[2])
            if inBlock { blockLines.append(line) } else { yield(event) }

        case "%output":
            guard parts.count >= 3 else { return }
            // Text may contain spaces — rejoin from index 2
            let text  = parts[2...].joined(separator: " ")
            let event = ControlModeEvent.output(paneId: parts[1], text: text)
            if inBlock { blockLines.append(line) } else { yield(event) }

        default:
            if inBlock { blockLines.append(line) }
        }
    }

    private func handleTermination(status: Int32) {
        readerTask?.cancel()
        readerTask = nil
        terminateProcess()

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

    private func terminateProcess() {
        if process?.isRunning == true { process?.terminate() }
        process     = nil
        stdinHandle = nil
    }
}
