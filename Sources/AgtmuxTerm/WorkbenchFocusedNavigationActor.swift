import Foundation
import AgtmuxTermCore

private func workbenchNavigationDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AGTMUX_NAV_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[nav] " + message() + "\n").utf8))
}

struct WorkbenchFocusedNavigationSnapshot {
    let taskIdentity: String
    let shouldRun: Bool
    let workbenchID: UUID
    let tileID: UUID
    let sessionRef: SessionRef
    let controlModeKey: WorkbenchFocusedNavigationControlModeKey?
    let hostsConfig: HostsConfig
    let desiredPaneRef: ActivePaneRef?
    let observedPaneRef: ActivePaneRef?
}

struct WorkbenchFocusedNavigationControlModeKey: Equatable {
    let sessionName: String
    let source: String
    let isRemote: Bool

    var identity: String {
        let scope = isRemote ? "remote" : "local"
        return "\(scope):\(source):\(sessionName)"
    }

    static func make(
        sessionRef: SessionRef,
        hostsConfig: HostsConfig
    ) -> Self? {
        switch sessionRef.target {
        case .local:
            return Self(
                sessionName: sessionRef.sessionName,
                source: "local",
                isRemote: false
            )
        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else { return nil }
            return Self(
                sessionName: sessionRef.sessionName,
                source: host.sshTarget,
                isRemote: true
            )
        }
    }
}

enum WorkbenchFocusedNavigationIdentity {
    static func make(
        tileID: UUID,
        isFocused: Bool,
        isReady: Bool,
        sessionRef: SessionRef,
        controlModeKey: WorkbenchFocusedNavigationControlModeKey?,
        desiredPaneRef: ActivePaneRef?,
        observedPaneRef: ActivePaneRef?
    ) -> String {
        let focused = isFocused ? "1" : "0"
        let ready = isReady ? "1" : "0"
        return [
            tileID.uuidString,
            focused,
            ready,
            sessionRef.target.label,
            sessionRef.sessionName,
            "control:\(controlModeKey?.identity ?? "")",
            paneRefIdentity(desiredPaneRef, label: "desired"),
            paneRefIdentity(observedPaneRef, label: "observed"),
        ].joined(separator: "|")
    }

    private static func paneRefIdentity(_ paneRef: ActivePaneRef?, label: String) -> String {
        guard let paneRef else { return "\(label):" }
        return [
            label,
            paneRef.sessionName,
            paneRef.windowID,
            paneRef.paneID,
            paneInstanceIdentity(paneRef.paneInstanceID),
        ].joined(separator: ":")
    }

    private static func paneInstanceIdentity(
        _ paneInstanceID: AgtmuxSyncV2PaneInstanceID?
    ) -> String {
        guard let paneInstanceID else { return "" }
        let generation = paneInstanceID.generation.map(String.init) ?? ""
        let birthTimestamp = paneInstanceID.birthTs.map {
            String($0.timeIntervalSince1970)
        } ?? ""
        return [
            paneInstanceID.paneId,
            generation,
            birthTimestamp,
        ].joined(separator: "@")
    }
}

struct WorkbenchFocusedNavigationControlModeHandle {
    let events: AsyncStream<ControlModeEvent>
    let send: (String) async throws -> Void
}

struct WorkbenchFocusedNavigationActorDependencies {
    var renderedState: @MainActor (UUID) -> GhosttyRenderedTerminalSurfaceState?
    var resolveControlMode: @MainActor (WorkbenchFocusedNavigationControlModeKey?) async -> WorkbenchFocusedNavigationControlModeHandle?
    var liveTarget: @MainActor (String, TargetRef, HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget
    var applyNavigationIntent: @MainActor (ActivePaneRef, String, HostsConfig) async throws -> Void
    var scheduleControlModeStop: @MainActor (WorkbenchFocusedNavigationControlModeKey?) -> Void
    var cancelControlModeStop: @MainActor (WorkbenchFocusedNavigationControlModeKey?) -> Void
    var sleep: (Duration) async throws -> Void

    init(
        renderedState: @escaping @MainActor (UUID) -> GhosttyRenderedTerminalSurfaceState?,
        resolveControlMode: @escaping @MainActor (WorkbenchFocusedNavigationControlModeKey?) async -> WorkbenchFocusedNavigationControlModeHandle?,
        liveTarget: @escaping @MainActor (String, TargetRef, HostsConfig) async throws -> WorkbenchV2TerminalLiveTarget,
        applyNavigationIntent: @escaping @MainActor (ActivePaneRef, String, HostsConfig) async throws -> Void,
        scheduleControlModeStop: @escaping @MainActor (WorkbenchFocusedNavigationControlModeKey?) -> Void = { _ in },
        cancelControlModeStop: @escaping @MainActor (WorkbenchFocusedNavigationControlModeKey?) -> Void = { _ in },
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.renderedState = renderedState
        self.resolveControlMode = resolveControlMode
        self.liveTarget = liveTarget
        self.applyNavigationIntent = applyNavigationIntent
        self.scheduleControlModeStop = scheduleControlModeStop
        self.cancelControlModeStop = cancelControlModeStop
        self.sleep = sleep
    }

    @MainActor
    static func live() -> Self {
        Self(
            renderedState: { tileID in
                GhosttyTerminalSurfaceRegistry.shared.renderedState(forTileID: tileID)
            },
            resolveControlMode: { controlModeKey in
                guard let controlModeKey else { return nil }
                TmuxControlModeRegistry.shared.startMonitoring(
                    sessionName: controlModeKey.sessionName,
                    source: controlModeKey.source
                )
                let mode = TmuxControlModeRegistry.shared.mode(
                    for: controlModeKey.sessionName,
                    source: controlModeKey.source
                )
                return WorkbenchFocusedNavigationControlModeHandle(
                    events: mode.events,
                    send: { command in
                        try await mode.send(command: command)
                    }
                )
            },
            liveTarget: { renderedClientTTY, target, hostsConfig in
                try await WorkbenchV2TerminalNavigationResolver.liveTarget(
                    renderedClientTTY: renderedClientTTY,
                    target: target,
                    hostsConfig: hostsConfig
                )
            },
            applyNavigationIntent: { activePaneRef, renderedClientTTY, hostsConfig in
                try await WorkbenchV2TerminalNavigationResolver.applyNavigationIntent(
                    activePaneRef: activePaneRef,
                    renderedClientTTY: renderedClientTTY,
                    hostsConfig: hostsConfig
                )
            },
            scheduleControlModeStop: { controlModeKey in
                guard let controlModeKey, controlModeKey.isRemote else { return }
                TmuxControlModeRegistry.shared.scheduleStop(
                    sessionName: controlModeKey.sessionName,
                    source: controlModeKey.source
                )
            },
            cancelControlModeStop: { controlModeKey in
                guard let controlModeKey, controlModeKey.isRemote else { return }
                TmuxControlModeRegistry.shared.cancelScheduledStop(
                    sessionName: controlModeKey.sessionName,
                    source: controlModeKey.source
                )
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }
}

@MainActor
final class WorkbenchFocusedNavigationActor {
    private static let controlModeTruthProbeInterval: Duration = .milliseconds(100)

    private let dependencies: WorkbenchFocusedNavigationActorDependencies
    private var store: WorkbenchStoreV2?
    private var runtimeStore: TerminalRuntimeStore?
    private var errorSink: ((String?) -> Void)?
    private var snapshot: WorkbenchFocusedNavigationSnapshot?
    private var runTask: Task<Void, Never>?
    private var runID: UInt64 = 0
    private var runningTaskIdentity: String?

    init() {
        self.dependencies = .live()
    }

    init(
        dependencies: WorkbenchFocusedNavigationActorDependencies
    ) {
        self.dependencies = dependencies
    }

    func update(
        snapshot: WorkbenchFocusedNavigationSnapshot,
        store: WorkbenchStoreV2,
        runtimeStore: TerminalRuntimeStore,
        onErrorChange: @escaping (String?) -> Void
    ) {
        let previousControlModeKey = self.snapshot?.controlModeKey
        self.store = store
        self.runtimeStore = runtimeStore
        self.errorSink = onErrorChange
        self.snapshot = snapshot
        workbenchNavigationDebugLog(
            "update task=\(snapshot.taskIdentity) shouldRun=\(snapshot.shouldRun) desired=\(snapshot.desiredPaneRef?.paneID ?? "nil") observed=\(snapshot.observedPaneRef?.paneID ?? "nil") control=\(snapshot.controlModeKey?.identity ?? "nil")"
        )
        reconcileControlModeLifecycle(
            previous: previousControlModeKey,
            current: snapshot.controlModeKey,
            shouldRun: snapshot.shouldRun
        )

        guard snapshot.shouldRun else {
            stop(clearError: true, scheduleControlModeStop: false)
            return
        }

        guard runningTaskIdentity != snapshot.taskIdentity || runTask == nil else { return }
        restart(for: snapshot)
    }

    func stop(
        clearError: Bool = true,
        scheduleControlModeStop: Bool = true
    ) {
        if scheduleControlModeStop {
            dependencies.scheduleControlModeStop(snapshot?.controlModeKey)
        }
        runID &+= 1
        runningTaskIdentity = nil
        runTask?.cancel()
        runTask = nil
        if clearError {
            errorSink?(nil)
        }
    }

    private func restart(for snapshot: WorkbenchFocusedNavigationSnapshot) {
        runTask?.cancel()
        runID &+= 1
        let currentRunID = runID
        let taskIdentity = snapshot.taskIdentity
        runningTaskIdentity = taskIdentity
        errorSink?(nil)
        runTask = Task { @MainActor [weak self] in
            await self?.run(runID: currentRunID, taskIdentity: taskIdentity)
        }
    }

    private func reconcileControlModeLifecycle(
        previous: WorkbenchFocusedNavigationControlModeKey?,
        current: WorkbenchFocusedNavigationControlModeKey?,
        shouldRun: Bool
    ) {
        if previous != current {
            dependencies.scheduleControlModeStop(previous)
        }
        if shouldRun {
            dependencies.cancelControlModeStop(current)
            return
        }
        dependencies.scheduleControlModeStop(current)
    }

    private func run(runID: UInt64, taskIdentity: String) async {
        guard let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else { return }
        workbenchNavigationDebugLog(
            "run start task=\(taskIdentity) desired=\(snapshot.desiredPaneRef?.paneID ?? "nil") observed=\(snapshot.observedPaneRef?.paneID ?? "nil")"
        )

        do {
            if let controlMode = await dependencies.resolveControlMode(snapshot.controlModeKey) {
                workbenchNavigationDebugLog("run control-mode task=\(taskIdentity)")
                try await runControlModeLoop(
                    controlMode: controlMode,
                    runID: runID,
                    taskIdentity: taskIdentity
                )
                return
            }

            workbenchNavigationDebugLog("run polling task=\(taskIdentity)")
            try await runPollingLoop(
                runID: runID,
                taskIdentity: taskIdentity
            )
        } catch is CancellationError {
            return
        } catch let error as WorkbenchV2TerminalNavigationError {
            setError(error.localizedDescription, runID: runID, taskIdentity: taskIdentity)
        } catch {
            setError(error.localizedDescription, runID: runID, taskIdentity: taskIdentity)
        }
    }

    private func runPollingLoop(runID: UInt64, taskIdentity: String) async throws {
        while !Task.isCancelled {
            guard let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else { return }
            guard let renderedClientTTY = dependencies.renderedState(snapshot.tileID)?.clientTTY else {
                try await dependencies.sleep(.milliseconds(100))
                continue
            }

            let liveTarget: WorkbenchV2TerminalLiveTarget
            do {
                liveTarget = try await dependencies.liveTarget(
                    renderedClientTTY,
                    snapshot.sessionRef.target,
                    snapshot.hostsConfig
                )
            } catch let error as WorkbenchV2TerminalNavigationError {
                switch error {
                case .renderedClientUnavailable:
                    try await dependencies.sleep(.milliseconds(100))
                    continue
                case .missingRemoteHostKey, .activePaneUnavailable:
                    throw error
                }
            }

            guard let currentSnapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else {
                return
            }

            if liveTarget.sessionName != currentSnapshot.sessionRef.sessionName {
                let didChange = try requireStore().syncTerminalObservation(
                    tileID: currentSnapshot.tileID,
                    observedSessionName: liveTarget.sessionName,
                    preferredWindowID: liveTarget.windowID,
                    preferredPaneID: liveTarget.paneID,
                    paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot)
                )
                clearError(runID: runID, taskIdentity: taskIdentity)
                try await dependencies.sleep(.milliseconds(didChange ? 100 : 1500))
                continue
            }

            requireStore().syncTerminalNavigation(
                tileID: currentSnapshot.tileID,
                preferredWindowID: liveTarget.windowID,
                preferredPaneID: liveTarget.paneID,
                paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot),
                authoritativeRenderedClientTruth: true
            )

            let refreshedSnapshot = snapshotAfterStoreSync(from: currentSnapshot)

            if WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
                desiredPaneRef: refreshedSnapshot.desiredPaneRef,
                observedPaneRef: refreshedSnapshot.observedPaneRef,
                liveTarget: liveTarget
            ),
               let desiredPaneRef = refreshedSnapshot.desiredPaneRef {
                try await dependencies.applyNavigationIntent(
                    desiredPaneRef,
                    renderedClientTTY,
                    refreshedSnapshot.hostsConfig
                )
                try await dependencies.sleep(.milliseconds(100))
                continue
            }

            clearError(runID: runID, taskIdentity: taskIdentity)
            try await dependencies.sleep(.milliseconds(1500))
        }
    }

    private func runControlModeLoop(
        controlMode: WorkbenchFocusedNavigationControlModeHandle,
        runID: UInt64,
        taskIdentity: String
    ) async throws {
        workbenchNavigationDebugLog("control-mode loop start task=\(taskIdentity)")
        let truthProbeTask = Task { @MainActor [weak self] in
            await self?.runControlModeTruthProbeLoop(
                controlMode: controlMode,
                runID: runID,
                taskIdentity: taskIdentity
            )
        }
        defer { truthProbeTask.cancel() }

        if let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity),
           let desiredPaneRef = snapshot.desiredPaneRef,
           desiredPaneRef.paneID != snapshot.observedPaneRef?.paneID {
            try await reconcileRenderedClientAfterControlModeEvent(
                controlMode: controlMode,
                event: nil,
                runID: runID,
                taskIdentity: taskIdentity
            )
        }

        for await event in controlMode.events {
            guard !Task.isCancelled else { return }
            if case .output = event { continue }
            workbenchNavigationDebugLog("control-mode event task=\(taskIdentity) event=\(String(describing: event))")
            await Task.yield()
            guard !Task.isCancelled else { return }
            try await reconcileRenderedClientAfterControlModeEvent(
                controlMode: controlMode,
                event: event,
                runID: runID,
                taskIdentity: taskIdentity
            )
        }
    }

    private func runControlModeTruthProbeLoop(
        controlMode: WorkbenchFocusedNavigationControlModeHandle,
        runID: UInt64,
        taskIdentity: String
    ) async {
        while !Task.isCancelled {
            do {
                try await dependencies.sleep(Self.controlModeTruthProbeInterval)
            } catch is CancellationError {
                return
            } catch {
                continue
            }

            guard let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else {
                workbenchNavigationDebugLog("truth probe stop task=\(taskIdentity) snapshot stale")
                return
            }
            guard dependencies.renderedState(snapshot.tileID)?.clientTTY != nil else {
                workbenchNavigationDebugLog("truth probe task=\(taskIdentity) rendered tty unavailable")
                continue
            }

            do {
                workbenchNavigationDebugLog("truth probe send task=\(taskIdentity)")
                try await controlMode.send("list-clients -F '#{client_tty}|#{session_name}|#{window_id}|#{pane_id}'")
            } catch let error as TmuxCommandError where isTransientControlModeSendRace(error) {
                workbenchNavigationDebugLog("truth probe transient send race task=\(taskIdentity) error=\(error)")
                continue
            } catch {
                workbenchNavigationDebugLog("truth probe send failed task=\(taskIdentity) error=\(error)")
            }
        }
    }

    private func reconcileRenderedClientAfterControlModeEvent(
        controlMode: WorkbenchFocusedNavigationControlModeHandle,
        event: ControlModeEvent?,
        runID: UInt64,
        taskIdentity: String
    ) async throws {
        guard let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else { return }
        guard let renderedClientTTY = dependencies.renderedState(snapshot.tileID)?.clientTTY else {
            workbenchNavigationDebugLog("reconcile task=\(taskIdentity) rendered tty missing; desired=\(snapshot.desiredPaneRef?.paneID ?? "nil") observed=\(snapshot.observedPaneRef?.paneID ?? "nil")")
            try await sendDesiredPaneIfStillPending(
                snapshot: snapshot,
                controlMode: controlMode,
                runID: runID,
                taskIdentity: taskIdentity
            )
            return
        }

        let liveTarget: WorkbenchV2TerminalLiveTarget
        if let liveTargetFromEvent = liveTargetFromEvent(from: event, renderedClientTTY: renderedClientTTY) {
            liveTarget = liveTargetFromEvent
        } else {
            do {
                liveTarget = try await dependencies.liveTarget(
                    renderedClientTTY,
                    snapshot.sessionRef.target,
                    snapshot.hostsConfig
                )
            } catch let error as WorkbenchV2TerminalNavigationError {
                switch error {
                case .renderedClientUnavailable:
                    try await sendDesiredPaneIfStillPending(
                        snapshot: snapshot,
                        controlMode: controlMode,
                        runID: runID,
                        taskIdentity: taskIdentity
                    )
                    return
                case .missingRemoteHostKey, .activePaneUnavailable:
                    throw error
                }
            }
        }

        guard let currentSnapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else {
            return
        }
        workbenchNavigationDebugLog(
            "reconcile task=\(taskIdentity) live session=\(liveTarget.sessionName) pane=\(liveTarget.paneID) desired=\(currentSnapshot.desiredPaneRef?.paneID ?? "nil") observed=\(currentSnapshot.observedPaneRef?.paneID ?? "nil")"
        )

        if liveTarget.sessionName != currentSnapshot.sessionRef.sessionName {
            clearError(runID: runID, taskIdentity: taskIdentity)
            _ = try requireStore().syncTerminalObservation(
                tileID: currentSnapshot.tileID,
                observedSessionName: liveTarget.sessionName,
                preferredWindowID: liveTarget.windowID,
                preferredPaneID: liveTarget.paneID,
                paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot)
            )
            return
        }

        requireStore().syncTerminalNavigation(
            tileID: currentSnapshot.tileID,
            preferredWindowID: liveTarget.windowID,
            preferredPaneID: liveTarget.paneID,
            paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot),
            authoritativeRenderedClientTruth: true
        )

        let refreshedSnapshot = snapshotAfterStoreSync(from: currentSnapshot)

        if WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
            desiredPaneRef: refreshedSnapshot.desiredPaneRef,
            observedPaneRef: refreshedSnapshot.observedPaneRef,
            liveTarget: liveTarget
        ),
           let desiredPaneRef = refreshedSnapshot.desiredPaneRef {
            try await sendNavigationCommand(
                paneID: desiredPaneRef.paneID,
                tileID: refreshedSnapshot.tileID,
                controlMode: controlMode,
                runID: runID,
                taskIdentity: taskIdentity
            )
            try await dependencies.sleep(.milliseconds(100))
            do {
                try await syncObservedPaneFromRenderedClientTruthWithRetry(
                    runID: runID,
                    taskIdentity: taskIdentity
                )
            } catch let error as WorkbenchV2TerminalNavigationError {
                switch error {
                case .renderedClientUnavailable:
                    break
                case .missingRemoteHostKey, .activePaneUnavailable:
                    throw error
                }
            }
            return
        }

        clearError(runID: runID, taskIdentity: taskIdentity)
        workbenchNavigationDebugLog("sync navigation task=\(taskIdentity) pane=\(liveTarget.paneID)")
    }

    private func syncObservedPaneFromRenderedClientTruthWithRetry(
        runID: UInt64,
        taskIdentity: String,
        maxAttempts: Int = 3
    ) async throws {
        let attempts = max(1, maxAttempts)
        var attempt = 0

        while true {
            do {
                try await syncObservedPaneFromRenderedClientTruth(
                    runID: runID,
                    taskIdentity: taskIdentity
                )
                return
            } catch let error as WorkbenchV2TerminalNavigationError {
                guard case .renderedClientUnavailable = error else {
                    throw error
                }
                attempt += 1
                if attempt >= attempts {
                    throw error
                }
                try await dependencies.sleep(.milliseconds(100))
            }
        }
    }

    private func syncObservedPaneFromRenderedClientTruth(
        runID: UInt64,
        taskIdentity: String
    ) async throws {
        guard let snapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else { return }
        guard let renderedClientTTY = dependencies.renderedState(snapshot.tileID)?.clientTTY else {
            throw WorkbenchV2TerminalNavigationError.renderedClientUnavailable(
                sessionName: snapshot.sessionRef.sessionName,
                clientTTY: "",
                output: "rendered client tty unavailable"
            )
        }

        let liveTarget = try await dependencies.liveTarget(
            renderedClientTTY,
            snapshot.sessionRef.target,
            snapshot.hostsConfig
        )

        guard let currentSnapshot = currentSnapshot(runID: runID, taskIdentity: taskIdentity) else {
            return
        }

        if liveTarget.sessionName != currentSnapshot.sessionRef.sessionName {
            clearError(runID: runID, taskIdentity: taskIdentity)
            _ = try requireStore().syncTerminalObservation(
                tileID: currentSnapshot.tileID,
                observedSessionName: liveTarget.sessionName,
                preferredWindowID: liveTarget.windowID,
                preferredPaneID: liveTarget.paneID,
                paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot)
            )
            return
        }

        clearError(runID: runID, taskIdentity: taskIdentity)
        requireStore().syncTerminalNavigation(
            tileID: currentSnapshot.tileID,
            preferredWindowID: liveTarget.windowID,
            preferredPaneID: liveTarget.paneID,
            paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: currentSnapshot),
            authoritativeRenderedClientTruth: true
        )
    }

    private func liveTargetFromEvent(
        from event: ControlModeEvent?,
        renderedClientTTY: String
    ) -> WorkbenchV2TerminalLiveTarget? {
        guard case .commandResponse(_, let lines) = event else { return nil }
        let output = lines.joined(separator: "\n")
        return try? WorkbenchV2TerminalNavigationResolver.parseLiveTarget(
            output: output,
            expectedClientTTY: renderedClientTTY
        )
    }

    private func sendDesiredPaneIfStillPending(
        snapshot: WorkbenchFocusedNavigationSnapshot,
        controlMode: WorkbenchFocusedNavigationControlModeHandle,
        runID: UInt64,
        taskIdentity: String
    ) async throws {
        guard let desiredPaneRef = snapshot.desiredPaneRef else { return }
        if let observedPaneRef = snapshot.observedPaneRef,
           desiredPaneRef.sessionName == observedPaneRef.sessionName,
           desiredPaneRef.windowID == observedPaneRef.windowID,
           desiredPaneRef.paneID == observedPaneRef.paneID {
            return
        }
        try await sendNavigationCommand(
            paneID: desiredPaneRef.paneID,
            tileID: snapshot.tileID,
            controlMode: controlMode,
            runID: runID,
            taskIdentity: taskIdentity
        )
    }

    private func snapshotAfterStoreSync(
        from snapshot: WorkbenchFocusedNavigationSnapshot
    ) -> WorkbenchFocusedNavigationSnapshot {
        guard let store else { return snapshot }
        guard let runtimeContext = store.activePaneRuntimeContext,
              runtimeContext.workbenchID == snapshot.workbenchID,
              runtimeContext.tileID == snapshot.tileID else {
            return snapshot
        }

        return WorkbenchFocusedNavigationSnapshot(
            taskIdentity: snapshot.taskIdentity,
            shouldRun: snapshot.shouldRun,
            workbenchID: snapshot.workbenchID,
            tileID: snapshot.tileID,
            sessionRef: snapshot.sessionRef,
            controlModeKey: snapshot.controlModeKey,
            hostsConfig: snapshot.hostsConfig,
            desiredPaneRef: runtimeContext.desiredPaneRef,
            observedPaneRef: runtimeContext.observedPaneRef
        )
    }

    private func currentSnapshot(
        runID: UInt64,
        taskIdentity: String
    ) -> WorkbenchFocusedNavigationSnapshot? {
        guard self.runID == runID else { return nil }
        guard let snapshot else { return nil }
        guard snapshot.shouldRun else { return nil }
        guard runningTaskIdentity == taskIdentity else { return nil }
        guard snapshot.taskIdentity == taskIdentity else { return nil }
        guard navigationTaskSnapshotIsCurrent(snapshot) else { return nil }
        return snapshot
    }

    private func navigationTaskSnapshotIsCurrent(
        _ snapshot: WorkbenchFocusedNavigationSnapshot
    ) -> Bool {
        guard let store else { return false }
        guard let context = store.focusedTerminalTileContext else { return false }
        guard context.workbenchID == snapshot.workbenchID else { return false }
        guard context.tileID == snapshot.tileID else { return false }
        guard context.sessionRef.target == snapshot.sessionRef.target else { return false }
        guard context.sessionRef.sessionName == snapshot.sessionRef.sessionName else { return false }

        guard let runtimeContext = store.activePaneRuntimeContext else {
            return snapshot.desiredPaneRef == nil && snapshot.observedPaneRef == nil
        }

        guard runtimeContext.workbenchID == snapshot.workbenchID else { return false }
        guard runtimeContext.tileID == snapshot.tileID else { return false }
        return runtimeContext.desiredPaneRef == snapshot.desiredPaneRef
            && runtimeContext.observedPaneRef == snapshot.observedPaneRef
    }

    private func navCommand(to paneID: String, tileID: UUID) -> String {
        if let renderedClientTTY = dependencies.renderedState(tileID)?.clientTTY {
            return "switch-client -c \(renderedClientTTY) -t \(paneID)"
        }
        return "select-pane -t \(paneID)"
    }

    private func sendNavigationCommand(
        paneID: String,
        tileID: UUID,
        controlMode: WorkbenchFocusedNavigationControlModeHandle,
        runID: UInt64,
        taskIdentity: String
    ) async throws {
        while isCurrentRun(runID: runID, taskIdentity: taskIdentity) {
            do {
                try await controlMode.send(navCommand(to: paneID, tileID: tileID))
                return
            } catch let error as TmuxCommandError where isTransientControlModeSendRace(error) {
                try await dependencies.sleep(.milliseconds(100))
                continue
            }
        }
    }

    private func isTransientControlModeSendRace(_ error: TmuxCommandError) -> Bool {
        guard case .failed(_, let code, let stderr) = error else { return false }
        return code == -1 && stderr == "control mode not connected"
    }

    private func isCurrentRun(runID: UInt64, taskIdentity: String) -> Bool {
        self.runID == runID && runningTaskIdentity == taskIdentity
    }

    private func selectionSource(for snapshot: WorkbenchFocusedNavigationSnapshot) -> String {
        switch snapshot.sessionRef.target {
        case .local:
            return "local"
        case .remote(let hostKey):
            return snapshot.hostsConfig.host(id: hostKey)?.hostname ?? hostKey
        }
    }

    private func livePaneInstanceID(
        for liveTarget: WorkbenchV2TerminalLiveTarget,
        snapshot: WorkbenchFocusedNavigationSnapshot
    ) -> AgtmuxSyncV2PaneInstanceID? {
        guard let runtimeStore else { return nil }
        let key = "\(selectionSource(for: snapshot)):\(liveTarget.sessionName):\(liveTarget.windowID):\(liveTarget.paneID)"
        return runtimeStore.paneIdentityIndex[key]
    }

    private func liveObservedPaneRef(
        from liveTarget: WorkbenchV2TerminalLiveTarget,
        snapshot: WorkbenchFocusedNavigationSnapshot
    ) -> ActivePaneRef {
        ActivePaneRef(
            target: snapshot.sessionRef.target,
            sessionName: liveTarget.sessionName,
            windowID: liveTarget.windowID,
            paneID: liveTarget.paneID,
            paneInstanceID: livePaneInstanceID(for: liveTarget, snapshot: snapshot)
        )
    }

    private func requireStore() -> WorkbenchStoreV2 {
        guard let store else {
            fatalError("WorkbenchFocusedNavigationActor.store missing during active navigation run")
        }
        return store
    }

    private func clearError(runID: UInt64, taskIdentity: String) {
        guard currentSnapshot(runID: runID, taskIdentity: taskIdentity) != nil else { return }
        errorSink?(nil)
    }

    private func setError(_ message: String?, runID: UInt64, taskIdentity: String) {
        guard self.runID == runID else { return }
        guard runningTaskIdentity == taskIdentity else { return }
        errorSink?(message)
    }
}
