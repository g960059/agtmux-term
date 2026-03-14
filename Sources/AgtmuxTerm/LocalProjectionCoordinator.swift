import Foundation
import AgtmuxTermCore

enum LocalHealthRefreshDisposition: Equatable {
    case unsupportedMethod
    case transientFailure
}

enum LocalHealthCacheAction: Equatable {
    case preserve
    case set(AgtmuxUIHealthV1?)
}

struct LocalHealthRefreshInput {
    let successInterval: TimeInterval
    let failureBackoff: TimeInterval
    let unsupportedBackoff: TimeInterval
}

struct LocalHealthRefreshExecution: Equatable {
    let cacheAction: LocalHealthCacheAction
    let nextRefreshAt: Date
}

struct LocalProjectionMetadataInput {
    let context: LocalMetadataRefreshContext
    let overlayStore: LocalMetadataOverlayStore
}

struct LocalProjectionState {
    let uiTestMetadataModeEnabled: Bool
    let localInventoryKnown: Bool
    let localInventoryAvailable: Bool
    let nextMetadataRefreshAt: Date
    let nextHealthRefreshAt: Date
    let metadataRefreshContext: LocalMetadataRefreshContext
    let overlayStore: LocalMetadataOverlayStore
    let healthSuccessInterval: TimeInterval
    let healthFailureBackoff: TimeInterval
    let healthUnsupportedBackoff: TimeInterval
}

struct LocalProjectionPlan {
    let inventoryResult: Result<[AgtmuxPane], Error>
    let metadataRefreshInput: LocalProjectionMetadataInput?
    let healthRefreshInput: LocalHealthRefreshInput?
}

struct LocalProjectionSteadyStateRuntime {
    let captureState: @MainActor () async -> LocalProjectionState?
    let applyMetadataExecution: @MainActor (LocalMetadataRefreshExecution) async -> Void
    let applyHealthExecution: @MainActor (LocalHealthRefreshExecution) async -> Void
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let idlePollInterval: TimeInterval

    init(
        captureState: @escaping @MainActor () async -> LocalProjectionState?,
        applyMetadataExecution: @escaping @MainActor (LocalMetadataRefreshExecution) async -> Void,
        applyHealthExecution: @escaping @MainActor (LocalHealthRefreshExecution) async -> Void,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = Self.defaultSleep,
        idlePollInterval: TimeInterval = 0.25
    ) {
        self.captureState = captureState
        self.applyMetadataExecution = applyMetadataExecution
        self.applyHealthExecution = applyHealthExecution
        self.sleep = sleep
        self.idlePollInterval = idlePollInterval
    }

    static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded(.up))
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

@MainActor
final class LocalProjectionCoordinator {
    private enum ProjectionMode {
        case snapshotFixture
        case inventoryOnlyUITest
        case live
    }

    private let localClient: any ProductLocalMetadataClient
    private let localHealthClient: (any LocalHealthClient)?
    private let localInventoryClient: any LocalPaneInventoryClient
    private let transportBridge: LocalMetadataTransportBridge
    private let environment: () -> [String: String]
    private let now: () -> Date
    private var metadataRefreshTask: Task<Void, Never>?
    private var healthRefreshTask: Task<Void, Never>?
    private var metadataSteadyStateTask: Task<Void, Never>?
    private var healthSteadyStateTask: Task<Void, Never>?

    init(
        localClient: any ProductLocalMetadataClient,
        localHealthClient: (any LocalHealthClient)?,
        localInventoryClient: any LocalPaneInventoryClient,
        transportBridge: LocalMetadataTransportBridge,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        now: @escaping () -> Date = Date.init
    ) {
        self.localClient = localClient
        self.localHealthClient = localHealthClient
        self.localInventoryClient = localInventoryClient
        self.transportBridge = transportBridge
        self.environment = environment
        self.now = now
    }

    deinit {
        metadataRefreshTask?.cancel()
        healthRefreshTask?.cancel()
        metadataSteadyStateTask?.cancel()
        healthSteadyStateTask?.cancel()
    }

    func refreshOnce(
        state: LocalProjectionState,
        runtime: LocalProjectionSteadyStateRuntime,
        classifyLocalDaemonIssue: @escaping @MainActor (any Error) -> LocalDaemonIssue?,
        classifyHealthFailure: @escaping @MainActor (any Error) -> LocalHealthRefreshDisposition
    ) async throws -> [AgtmuxPane] {
        let projectionMode = projectionMode(uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled)
        guard projectionMode == .live else {
            return try await fetchInventory(state: state)
        }

        if healthSteadyStateTask == nil,
           let input = makeHealthRefreshInputIfDue(state: state) {
            startHealthRefreshIfNeeded(
                input: input,
                runtime: runtime,
                classifyFailure: classifyHealthFailure
            )
        }

        let inventory = try await fetchInventory(state: state)

        if metadataSteadyStateTask == nil,
           let input = makeMetadataRefreshInputIfDue(
            inventory: inventory,
            state: state
           ) {
            startMetadataRefreshIfNeeded(
                input: input,
                runtime: runtime,
                classifyLocalDaemonIssue: classifyLocalDaemonIssue
            )
        }

        return inventory
    }

    func fetchInventory(state: LocalProjectionState) async throws -> [AgtmuxPane] {
        switch projectionMode(uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled) {
        case .snapshotFixture:
            let snapshot = try await localClient.fetchSnapshot()
            return snapshot.panes
        case .inventoryOnlyUITest:
            return try await localInventoryClient.fetchPanes()
        case .live:
            return try await localInventoryClient.fetchPanes()
        }
    }

    func startSteadyState(
        runtime: LocalProjectionSteadyStateRuntime,
        classifyLocalDaemonIssue: @escaping @MainActor (any Error) -> LocalDaemonIssue?,
        classifyHealthFailure: @escaping @MainActor (any Error) -> LocalHealthRefreshDisposition
    ) {
        if metadataSteadyStateTask == nil {
            let clearTask: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.metadataSteadyStateTask = nil
                }
            }

            metadataSteadyStateTask = Task { [weak self] in
                defer { clearTask() }
                await self?.runMetadataSteadyState(
                    runtime: runtime,
                    classifyLocalDaemonIssue: classifyLocalDaemonIssue
                )
            }
        }

        guard localHealthClient != nil else { return }
        guard healthSteadyStateTask == nil else { return }

        let clearTask: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthSteadyStateTask = nil
            }
        }

        healthSteadyStateTask = Task { [weak self] in
            defer { clearTask() }
            await self?.runHealthSteadyState(
                runtime: runtime,
                classifyFailure: classifyHealthFailure
            )
        }
    }

    func stop() {
        metadataSteadyStateTask?.cancel()
        metadataSteadyStateTask = nil
        healthSteadyStateTask?.cancel()
        healthSteadyStateTask = nil
        stopMetadataSteadyState()
        healthRefreshTask?.cancel()
        healthRefreshTask = nil
    }

    func stopMetadataSteadyState() {
        metadataSteadyStateTask?.cancel()
        metadataSteadyStateTask = nil
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
    }

    func planStep(state: LocalProjectionState) async -> LocalProjectionPlan {
        switch projectionMode(uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled) {
        case .snapshotFixture:
            return LocalProjectionPlan(
                inventoryResult: await snapshotInventoryResult(),
                metadataRefreshInput: nil,
                healthRefreshInput: nil
            )
        case .inventoryOnlyUITest:
            return LocalProjectionPlan(
                inventoryResult: await inventoryResult(),
                metadataRefreshInput: nil,
                healthRefreshInput: nil
            )
        case .live:
            let healthRefreshInput = makeHealthRefreshInputIfDue(state: state)
            let inventoryResult = await inventoryResult()

            switch inventoryResult {
            case .success(let inventory):
                return LocalProjectionPlan(
                    inventoryResult: .success(inventory),
                    metadataRefreshInput: makeMetadataRefreshInputIfDue(
                        inventory: inventory,
                        state: state
                    ),
                    healthRefreshInput: healthRefreshInput
                )
            case .failure(let error):
                return LocalProjectionPlan(
                    inventoryResult: .failure(error),
                    metadataRefreshInput: nil,
                    healthRefreshInput: healthRefreshInput
                )
            }
        }
    }

    func runMetadataSteadyState(
        runtime: LocalProjectionSteadyStateRuntime,
        classifyLocalDaemonIssue: @escaping @MainActor (any Error) -> LocalDaemonIssue?
    ) async {
        while !Task.isCancelled {
            guard let state = await runtime.captureState() else { return }

            guard projectionMode(uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled) == .live else {
                do {
                    try await runtime.sleep(runtime.idlePollInterval)
                } catch {
                    return
                }
                continue
            }

            if let input = makeSteadyStateMetadataRefreshInputIfDue(state: state) {
                startMetadataRefreshIfNeeded(
                    input: input,
                    runtime: runtime,
                    classifyLocalDaemonIssue: classifyLocalDaemonIssue
                )
            }

            do {
                try await runtime.sleep(
                    metadataSleepInterval(state: state, idlePollInterval: runtime.idlePollInterval)
                )
            } catch {
                return
            }
        }
    }

    func runHealthSteadyState(
        runtime: LocalProjectionSteadyStateRuntime,
        classifyFailure: @escaping @MainActor (any Error) -> LocalHealthRefreshDisposition
    ) async {
        guard localHealthClient != nil else { return }

        while !Task.isCancelled {
            guard let state = await runtime.captureState() else { return }

            guard projectionMode(uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled) == .live else {
                do {
                    try await runtime.sleep(runtime.idlePollInterval)
                } catch {
                    return
                }
                continue
            }

            if let input = makeHealthRefreshInputIfDue(state: state) {
                startHealthRefreshIfNeeded(
                    input: input,
                    runtime: runtime,
                    classifyFailure: classifyFailure
                )
            }

            do {
                try await runtime.sleep(
                    healthSleepInterval(state: state, idlePollInterval: runtime.idlePollInterval)
                )
            } catch {
                return
            }
        }
    }

    func runMetadataRefresh(
        input: LocalProjectionMetadataInput,
        classifyLocalDaemonIssue: @MainActor (any Error) -> LocalDaemonIssue?
    ) async throws -> LocalMetadataRefreshExecution {
        let coordinator = makeMetadataRefreshCoordinator()

        do {
            return try await coordinator.runStep(
                context: input.context,
                overlayStore: input.overlayStore
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return coordinator.failureExecution(
                context: input.context,
                error: error,
                classifyLocalDaemonIssue: classifyLocalDaemonIssue
            )
        }
    }

    func runHealthRefresh(
        input: LocalHealthRefreshInput,
        classifyFailure: @MainActor (any Error) -> LocalHealthRefreshDisposition
    ) async throws -> LocalHealthRefreshExecution {
        guard let localHealthClient else {
            preconditionFailure("LocalHealthRefreshInput must not exist without a health client")
        }

        do {
            let health = try await localHealthClient.fetchUIHealthV1()
            return LocalHealthRefreshExecution(
                cacheAction: .set(health),
                nextRefreshAt: now().addingTimeInterval(input.successInterval)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch classifyFailure(error) {
            case .unsupportedMethod:
                return LocalHealthRefreshExecution(
                    cacheAction: .set(nil),
                    nextRefreshAt: now().addingTimeInterval(input.unsupportedBackoff)
                )
            case .transientFailure:
                return LocalHealthRefreshExecution(
                    cacheAction: .preserve,
                    nextRefreshAt: now().addingTimeInterval(input.failureBackoff)
                )
            }
        }
    }

    private func makeMetadataRefreshCoordinator() -> LocalMetadataRefreshCoordinator {
        LocalMetadataRefreshCoordinator(
            client: localClient,
            transportBridge: transportBridge,
            now: now
        )
    }

    private func snapshotInventoryResult() async -> Result<[AgtmuxPane], Error> {
        do {
            let snapshot = try await localClient.fetchSnapshot()
            return .success(snapshot.panes)
        } catch {
            return .failure(error)
        }
    }

    private func inventoryResult() async -> Result<[AgtmuxPane], Error> {
        do {
            return .success(try await localInventoryClient.fetchPanes())
        } catch {
            return .failure(error)
        }
    }

    private func projectionMode(uiTestMetadataModeEnabled: Bool) -> ProjectionMode {
        let env = environment()

        if env["AGTMUX_JSON"] != nil {
            return .snapshotFixture
        }

        if env["AGTMUX_UITEST"] == "1",
           env["AGTMUX_UITEST_INVENTORY_ONLY"] == "1",
           !uiTestMetadataModeEnabled {
            return .inventoryOnlyUITest
        }

        return .live
    }

    private func makeHealthRefreshInputIfDue(state: LocalProjectionState) -> LocalHealthRefreshInput? {
        guard localHealthClient != nil else { return nil }
        guard healthRefreshTask == nil else { return nil }
        guard now() >= state.nextHealthRefreshAt else { return nil }

        return LocalHealthRefreshInput(
            successInterval: state.healthSuccessInterval,
            failureBackoff: state.healthFailureBackoff,
            unsupportedBackoff: state.healthUnsupportedBackoff
        )
    }

    private func makeMetadataRefreshInputIfDue(
        inventory: [AgtmuxPane],
        state: LocalProjectionState
    ) -> LocalProjectionMetadataInput? {
        guard metadataRefreshTask == nil else { return nil }
        guard now() >= state.nextMetadataRefreshAt else { return nil }

        return LocalProjectionMetadataInput(
            context: LocalMetadataRefreshContext(
                syncPrimed: state.metadataRefreshContext.syncPrimed,
                transportVersion: state.metadataRefreshContext.transportVersion,
                inventoryCount: inventory.count,
                successInterval: state.metadataRefreshContext.successInterval,
                failureBackoff: state.metadataRefreshContext.failureBackoff,
                bootstrapNotReadyBackoff: state.metadataRefreshContext.bootstrapNotReadyBackoff,
                changeLimit: state.metadataRefreshContext.changeLimit,
                useLongPoll: state.metadataRefreshContext.useLongPoll,
                longPollTimeoutMs: state.metadataRefreshContext.longPollTimeoutMs
            ),
            overlayStore: LocalMetadataOverlayStore(
                inventory: inventory,
                metadataByPaneKey: state.overlayStore.metadataByPaneKey,
                presentationByPaneKey: state.overlayStore.presentationByPaneKey,
                log: state.overlayStore.log
            )
        )
    }

    private func makeSteadyStateMetadataRefreshInputIfDue(
        state: LocalProjectionState
    ) -> LocalProjectionMetadataInput? {
        guard state.localInventoryKnown else { return nil }
        guard state.localInventoryAvailable else { return nil }

        return makeMetadataRefreshInputIfDue(
            inventory: state.overlayStore.inventory,
            state: state
        )
    }

    private func metadataSleepInterval(
        state: LocalProjectionState,
        idlePollInterval: TimeInterval
    ) -> TimeInterval {
        guard metadataRefreshTask == nil else { return idlePollInterval }
        guard state.localInventoryKnown else { return idlePollInterval }
        guard state.localInventoryAvailable else { return idlePollInterval }
        return max(0, state.nextMetadataRefreshAt.timeIntervalSince(now()))
    }

    private func healthSleepInterval(
        state: LocalProjectionState,
        idlePollInterval: TimeInterval
    ) -> TimeInterval {
        guard healthRefreshTask == nil else { return idlePollInterval }
        guard localHealthClient != nil else { return idlePollInterval }
        return max(0, state.nextHealthRefreshAt.timeIntervalSince(now()))
    }

    private func startMetadataRefreshIfNeeded(
        input: LocalProjectionMetadataInput,
        runtime: LocalProjectionSteadyStateRuntime,
        classifyLocalDaemonIssue: @escaping @MainActor (any Error) -> LocalDaemonIssue?
    ) {
        guard metadataRefreshTask == nil else { return }

        let clearTask: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.metadataRefreshTask = nil
            }
        }

        metadataRefreshTask = Task { [weak self] in
            defer { clearTask() }
            guard let self else { return }

            do {
                let syncID = AgtmuxSignpost.metadataSync.makeSignpostID()
                let syncState = AgtmuxSignpost.metadataSync.beginInterval("runStep", id: syncID)
                defer { AgtmuxSignpost.metadataSync.endInterval("runStep", syncState) }

                let execution = try await self.runMetadataRefresh(
                    input: input,
                    classifyLocalDaemonIssue: classifyLocalDaemonIssue
                )
                try Task.checkCancellation()
                await runtime.applyMetadataExecution(execution)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Local metadata refresh raised unexpected error: \(error)")
            }
        }
    }

    private func startHealthRefreshIfNeeded(
        input: LocalHealthRefreshInput,
        runtime: LocalProjectionSteadyStateRuntime,
        classifyFailure: @escaping @MainActor (any Error) -> LocalHealthRefreshDisposition
    ) {
        guard healthRefreshTask == nil else { return }

        let clearTask: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthRefreshTask = nil
            }
        }

        healthRefreshTask = Task { [weak self] in
            defer { clearTask() }
            guard let self else { return }

            do {
                let execution = try await self.runHealthRefresh(
                    input: input,
                    classifyFailure: classifyFailure
                )
                try Task.checkCancellation()
                await runtime.applyHealthExecution(execution)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Local health refresh raised unexpected error: \(error)")
            }
        }
    }
}
