import Foundation
import AgtmuxTermCore

protocol LocalPaneInventoryClient: Sendable {
    func fetchPanes() async throws -> [AgtmuxPane]
}

@MainActor
protocol LocalPaneInventoryAuthorityProtocol: AnyObject {
    func start(
        seedInventory: [AgtmuxPane],
        applyInventory: @escaping @MainActor ([AgtmuxPane]) async -> Void,
        handleFailure: @escaping @MainActor () async -> Void
    )
    func updateSeedInventory(_ inventory: [AgtmuxPane])
    func stop()
}

struct LocalPaneInventoryMonitorHandle {
    let events: AsyncStream<ControlModeEvent>
    let start: @Sendable () async -> Void
    let stop: @Sendable () async -> Void
}

struct LocalPaneInventoryAuthorityDependencies {
    let fetchInventory: @Sendable () async throws -> [AgtmuxPane]
    let makeMonitor: @MainActor (String) -> LocalPaneInventoryMonitorHandle
    let fallbackPollInterval: TimeInterval

    @MainActor
    static func live(
        localInventoryClient: any LocalPaneInventoryClient,
        fallbackPollInterval: TimeInterval
    ) -> Self {
        Self(
            fetchInventory: {
                try await localInventoryClient.fetchPanes()
            },
            makeMonitor: { sessionName in
                let mode = TmuxControlMode(sessionName: sessionName, source: "local")
                return LocalPaneInventoryMonitorHandle(
                    events: mode.events,
                    start: { await mode.start() },
                    stop: { await mode.stop() }
                )
            },
            fallbackPollInterval: fallbackPollInterval
        )
    }
}

@MainActor
final class LocalPaneInventoryAuthority: LocalPaneInventoryAuthorityProtocol {
    private let dependencies: LocalPaneInventoryAuthorityDependencies
    private var applyInventory: (@MainActor ([AgtmuxPane]) async -> Void)?
    private var handleFailure: (@MainActor () async -> Void)?
    private var currentSessions: Set<String> = []
    private var monitors: [String: LocalPaneInventoryMonitorHandle] = [:]
    private var monitorTasks: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var fallbackPollTask: Task<Void, Never>?
    private var running = false

    init(dependencies: LocalPaneInventoryAuthorityDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        refreshTask?.cancel()
        fallbackPollTask?.cancel()
        for task in monitorTasks.values {
            task.cancel()
        }
    }

    func start(
        seedInventory: [AgtmuxPane],
        applyInventory: @escaping @MainActor ([AgtmuxPane]) async -> Void,
        handleFailure: @escaping @MainActor () async -> Void
    ) {
        self.applyInventory = applyInventory
        self.handleFailure = handleFailure

        guard !running else {
            synchronizeMonitors(with: seedInventory)
            return
        }

        running = true
        synchronizeMonitors(with: seedInventory)
        if seedInventory.isEmpty {
            startFallbackPollIfNeeded()
        }
    }

    func updateSeedInventory(_ inventory: [AgtmuxPane]) {
        guard running else { return }
        synchronizeMonitors(with: inventory)
    }

    func stop() {
        running = false
        applyInventory = nil
        handleFailure = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshQueued = false
        stopFallbackPoll()

        let sessions = Array(monitors.keys)
        for sessionName in sessions {
            stopMonitor(sessionName: sessionName)
        }
        currentSessions.removeAll()
    }

    private func synchronizeMonitors(with inventory: [AgtmuxPane]) {
        let nextSessions = Set(inventory.map(\.sessionName))
        let removedSessions = currentSessions.subtracting(nextSessions)
        let addedSessions = nextSessions.subtracting(currentSessions)
        currentSessions = nextSessions

        for sessionName in removedSessions {
            stopMonitor(sessionName: sessionName)
        }
        for sessionName in addedSessions {
            startMonitor(sessionName: sessionName)
        }

        if nextSessions.isEmpty {
            startFallbackPollIfNeeded()
        } else {
            stopFallbackPoll()
        }
    }

    private func startMonitor(sessionName: String) {
        guard monitors[sessionName] == nil else { return }

        let monitor = dependencies.makeMonitor(sessionName)
        monitors[sessionName] = monitor
        let events = monitor.events

        monitorTasks[sessionName] = Task { [weak self] in
            await monitor.start()

            for await event in events {
                if Task.isCancelled { break }
                if Self.shouldRefresh(for: event) {
                    await self?.requestRefresh()
                }
            }

            await self?.monitorDidEnd(
                sessionName: sessionName,
                wasCancelled: Task.isCancelled
            )
        }
    }

    private func stopMonitor(sessionName: String) {
        monitorTasks[sessionName]?.cancel()
        monitorTasks[sessionName] = nil

        guard let monitor = monitors.removeValue(forKey: sessionName) else { return }
        Task {
            await monitor.stop()
        }
    }

    private func monitorDidEnd(sessionName: String, wasCancelled: Bool) async {
        monitorTasks[sessionName] = nil

        guard running else { return }
        guard currentSessions.contains(sessionName) else { return }
        guard !wasCancelled else { return }

        if let monitor = monitors.removeValue(forKey: sessionName) {
            await monitor.stop()
        }
        await requestRefresh()
    }

    private func requestRefresh() async {
        guard running else { return }

        if refreshTask != nil {
            refreshQueued = true
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let inventory = try await self.dependencies.fetchInventory()
                    await self.refreshDidSucceed(inventory)
                } catch is CancellationError {
                    break
                } catch {
                    await self.refreshDidFail()
                }

                let shouldRunAgain = self.consumeQueuedRefresh()
                if !shouldRunAgain { break }
            }

            self.finishRefreshTask()
        }
    }

    private func refreshDidSucceed(_ inventory: [AgtmuxPane]) async {
        synchronizeMonitors(with: inventory)
        await applyInventory?(inventory)
    }

    private func refreshDidFail() async {
        startFallbackPollIfNeeded()
        await handleFailure?()
    }

    private func consumeQueuedRefresh() -> Bool {
        let shouldRunAgain = refreshQueued
        refreshQueued = false
        return shouldRunAgain
    }

    private func finishRefreshTask() {
        refreshTask = nil
    }

    private func startFallbackPollIfNeeded() {
        guard fallbackPollTask == nil else { return }

        fallbackPollTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let interval = self.dependencies.fallbackPollInterval
                    let nanoseconds = UInt64((interval * 1_000_000_000).rounded(.up))
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }

                await self.requestRefresh()
            }
        }
    }

    private func stopFallbackPoll() {
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
    }

    private static func shouldRefresh(for event: ControlModeEvent) -> Bool {
        switch event {
        case .layoutChange, .windowAdd, .windowClose, .sessionChanged:
            return true
        case .windowPaneChanged, .sessionWindowChanged, .output, .commandResponse:
            return false
        }
    }
}

/// Local tmux inventory client.
///
/// Unlike agtmux metadata (`agtmux json`), this client is authoritative for
/// local tmux object existence (session/window/pane).
actor LocalTmuxInventoryClient: LocalPaneInventoryClient {
    /// tmux format string using a stable printable separator token:
    /// pane_id, session_name, window_id, window_index, window_name,
    /// pane_current_path, pane_current_command, session_group
    ///
    /// Some environments sanitize control-character delimiters (e.g. `\t`) to `_`
    /// in `list-panes -F` output. A long alphanumeric token avoids that mutation.
    static let fieldSeparator = "AGTMUXFIELDSEP9F6F2D4D"
    static let formatString =
        [
            "#{pane_id}",
            "#{session_name}",
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{pane_current_path}",
            "#{pane_current_command}",
            "#{session_group}"
        ].joined(separator: fieldSeparator)

    func fetchPanes() async throws -> [AgtmuxPane] {
        let fetchID = AgtmuxSignpost.localInventory.makeSignpostID()
        let fetchState = AgtmuxSignpost.localInventory.beginInterval("fetchPanes", id: fetchID)
        defer { AgtmuxSignpost.localInventory.endInterval("fetchPanes", fetchState) }
        do {
            let output = try await TmuxCommandRunner.shared.run(
                ["list-panes", "-a", "-F", Self.formatString],
                source: "local"
            )
            let panes = try Self.parse(output: output, source: "local")
            return panes
        } catch let TmuxCommandError.failed(_, _, stderr) {
            // "no server running" means local tmux has no sessions.
            // Treat as empty inventory, not a hard fetch failure.
            if Self.isNoServer(stderr) {
                return []
            }
            throw DaemonError.processError(exitCode: 1, stderr: stderr)
        }
    }

    private static func isNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
    }

    static func parse(output: String, source: String) throws -> [AgtmuxPane] {
        var panes: [AgtmuxPane] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            let fields = line.components(separatedBy: fieldSeparator)
            guard fields.count == 8 else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: expected 8 fields " +
                    "separator=\(fieldSeparator) line='\(line)'"
                )
            }

            let paneId = fields[0]
            let sessionName = fields[1]
            let windowId = fields[2]
            let rawWindowIndex = fields[3]
            let windowName = fields[4].isEmpty ? nil : fields[4]
            let currentPath = fields[5].isEmpty ? nil : fields[5]
            let currentCmd = fields[6].isEmpty ? nil : fields[6]
            let sessionGroup = fields[7].isEmpty ? nil : fields[7]

            guard !paneId.isEmpty, !sessionName.isEmpty, !windowId.isEmpty else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: required field empty line='\(line)'"
                )
            }

            let windowIndex: Int?
            if rawWindowIndex.isEmpty {
                windowIndex = nil
            } else if let parsedIndex = Int(rawWindowIndex) {
                windowIndex = parsedIndex
            } else {
                throw DaemonError.parseError(
                    "local tmux inventory malformed: invalid window_index '\(rawWindowIndex)' line='\(line)'"
                )
            }

            panes.append(
                AgtmuxPane(
                    source: source,
                    paneId: paneId,
                    sessionName: sessionName,
                    sessionGroup: sessionGroup,
                    windowId: windowId,
                    windowIndex: windowIndex,
                    windowName: windowName,
                    activityState: .unknown,
                    presence: .unmanaged,
                    evidenceMode: .none,
                    currentPath: currentPath,
                    currentCmd: currentCmd
                )
            )
        }

        return panes
    }
}
