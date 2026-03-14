import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalProjectionCoordinatorTests: XCTestCase {
    private enum StubError: Error, Equatable {
        case exhausted
        case inventoryFailure
        case metadataFailure
        case healthFailure
    }

    private final class LocalProjectionStateBox: @unchecked Sendable {
        @MainActor var state: LocalProjectionState?

        @MainActor
        init(_ state: LocalProjectionState?) {
            self.state = state
        }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private actor StubProjectionClient: ProductLocalMetadataClient, LocalHealthClient {
        private var snapshotResults: [Result<AgtmuxSnapshot, Error>]
        private var bootstrapResults: [Result<AgtmuxSyncV3Bootstrap, Error>]
        private var changesResults: [Result<AgtmuxSyncV3ChangesResponse, Error>]
        private var waitResults: [Result<AgtmuxSyncV3ChangesResponse, Error>]
        private var healthResults: [Result<AgtmuxUIHealthV1, Error>]

        private(set) var snapshotCalls = 0
        private(set) var bootstrapCalls = 0
        private(set) var changesCalls = 0
        private(set) var waitCalls = 0
        private(set) var healthCalls = 0

        init(
            snapshotResults: [Result<AgtmuxSnapshot, Error>] = [],
            bootstrapResults: [Result<AgtmuxSyncV3Bootstrap, Error>] = [],
            changesResults: [Result<AgtmuxSyncV3ChangesResponse, Error>] = [],
            waitResults: [Result<AgtmuxSyncV3ChangesResponse, Error>] = [],
            healthResults: [Result<AgtmuxUIHealthV1, Error>] = []
        ) {
            self.snapshotResults = snapshotResults
            self.bootstrapResults = bootstrapResults
            self.changesResults = changesResults
            self.waitResults = waitResults
            self.healthResults = healthResults
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            snapshotCalls += 1
            guard !snapshotResults.isEmpty else { throw StubError.exhausted }
            switch snapshotResults.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            bootstrapCalls += 1
            guard !bootstrapResults.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3")
            }
            switch bootstrapResults.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            changesCalls += 1
            guard !changesResults.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.changes.v3")
            }
            switch changesResults.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func waitForUIChangesV1(timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
            waitCalls += 1
            guard !waitResults.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.wait_for_changes.v1")
            }
            switch waitResults.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
            healthCalls += 1
            guard !healthResults.isEmpty else { throw StubError.exhausted }
            switch healthResults.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func resetUIChangesV3() async {}

        func callCounts() -> (snapshot: Int, bootstrap: Int, changes: Int, wait: Int, health: Int) {
            (snapshotCalls, bootstrapCalls, changesCalls, waitCalls, healthCalls)
        }
    }

    private actor StubInventoryClient: LocalPaneInventoryClient {
        private var results: [Result<[AgtmuxPane], Error>]
        private(set) var calls = 0

        init(results: [Result<[AgtmuxPane], Error>]) {
            self.results = results
        }

        func fetchPanes() async throws -> [AgtmuxPane] {
            calls += 1
            guard !results.isEmpty else { throw StubError.exhausted }
            switch results.removeFirst() {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }

        func callCount() -> Int { calls }
    }

    @MainActor
    func testPlanStepUsesSnapshotFixtureMode() async {
        let pane = makeInventoryPane()
        let client = StubProjectionClient(
            snapshotResults: [.success(AgtmuxSnapshot(version: 1, panes: [pane]))]
        )
        let inventoryClient = StubInventoryClient(results: [.failure(StubError.inventoryFailure)])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { ["AGTMUX_JSON": "1"] }
        )

        let plan = await coordinator.planStep(state: makeState())

        switch plan.inventoryResult {
        case .success(let inventory):
            XCTAssertEqual(inventory, [pane])
        case .failure(let error):
            XCTFail("expected snapshot inventory, got \(error)")
        }
        XCTAssertNil(plan.metadataRefreshInput)
        XCTAssertNil(plan.healthRefreshInput)
        let counts = await client.callCounts()
        XCTAssertEqual(counts.snapshot, 1)
        XCTAssertEqual(counts.bootstrap, 0)
        XCTAssertEqual(counts.changes, 0)
        XCTAssertEqual(counts.wait, 0)
        XCTAssertEqual(counts.health, 0)
        let inventoryCalls = await inventoryClient.callCount()
        XCTAssertEqual(inventoryCalls, 0)
    }

    @MainActor
    func testPlanStepUsesInventoryOnlyUITestModeWithoutProjectionWork() async {
        let pane = makeInventoryPane()
        let client = StubProjectionClient(
            snapshotResults: [.failure(StubError.metadataFailure)],
            healthResults: [.failure(StubError.healthFailure)]
        )
        let inventoryClient = StubInventoryClient(results: [.success([pane])])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: {
                [
                    "AGTMUX_UITEST": "1",
                    "AGTMUX_UITEST_INVENTORY_ONLY": "1",
                ]
            }
        )

        let plan = await coordinator.planStep(state: makeState(uiTestMetadataModeEnabled: false))

        switch plan.inventoryResult {
        case .success(let inventory):
            XCTAssertEqual(inventory, [pane])
        case .failure(let error):
            XCTFail("expected inventory-only panes, got \(error)")
        }
        XCTAssertNil(plan.metadataRefreshInput)
        XCTAssertNil(plan.healthRefreshInput)
        let counts = await client.callCounts()
        XCTAssertEqual(counts.snapshot, 0)
        XCTAssertEqual(counts.bootstrap, 0)
        XCTAssertEqual(counts.changes, 0)
        XCTAssertEqual(counts.wait, 0)
        XCTAssertEqual(counts.health, 0)
        let inventoryCalls = await inventoryClient.callCount()
        XCTAssertEqual(inventoryCalls, 1)
    }

    @MainActor
    func testPlanStepProducesMetadataAndHealthWorkForLiveInventoryWhenDue() async {
        let inventory = [makeInventoryPane()]
        let client = StubProjectionClient()
        let inventoryClient = StubInventoryClient(results: [.success(inventory)])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        let plan = await coordinator.planStep(
            state: makeState(
                nextMetadataRefreshAt: now.addingTimeInterval(-1),
                nextHealthRefreshAt: now.addingTimeInterval(-1)
            )
        )

        switch plan.inventoryResult {
        case .success(let resolvedInventory):
            XCTAssertEqual(resolvedInventory, inventory)
        case .failure(let error):
            XCTFail("expected live inventory, got \(error)")
        }
        XCTAssertNotNil(plan.metadataRefreshInput)
        XCTAssertNotNil(plan.healthRefreshInput)
        XCTAssertEqual(plan.metadataRefreshInput?.context.inventoryCount, inventory.count)
        let inventoryCalls = await inventoryClient.callCount()
        XCTAssertEqual(inventoryCalls, 1)
    }

    @MainActor
    func testPlanStepPreservesHealthWorkWhenInventoryFails() async {
        let client = StubProjectionClient()
        let inventoryClient = StubInventoryClient(results: [.failure(StubError.inventoryFailure)])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        let plan = await coordinator.planStep(
            state: makeState(
                nextMetadataRefreshAt: now.addingTimeInterval(-1),
                nextHealthRefreshAt: now.addingTimeInterval(-1)
            )
        )

        switch plan.inventoryResult {
        case .success:
            XCTFail("expected inventory failure")
        case .failure(let error):
            XCTAssertEqual(error as? StubError, .inventoryFailure)
        }
        XCTAssertNil(plan.metadataRefreshInput)
        XCTAssertNotNil(plan.healthRefreshInput)
    }

    @MainActor
    func testRefreshOnceStartsHealthRefreshBeforeInventoryFailure() async {
        let expectedHealth = makeHealthSnapshot(detail: "inventory offline but daemon healthy")
        let client = StubProjectionClient(
            healthResults: [.success(expectedHealth)]
        )
        let inventoryClient = StubInventoryClient(results: [.failure(StubError.inventoryFailure)])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        let healthApplied = expectation(description: "health refresh applied")
        var publishedExecution: LocalHealthRefreshExecution?
        let runtime = LocalProjectionSteadyStateRuntime(
            captureState: { nil },
            applyMetadataExecution: { _ in
                XCTFail("inventory failure must not publish metadata execution")
            },
            applyHealthExecution: { execution in
                publishedExecution = execution
                healthApplied.fulfill()
            },
            sleep: { _ in }
        )

        do {
            _ = try await coordinator.refreshOnce(
                state: makeState(
                    nextMetadataRefreshAt: now.addingTimeInterval(-1),
                    nextHealthRefreshAt: now.addingTimeInterval(-1)
                ),
                runtime: runtime,
                classifyLocalDaemonIssue: { _ in nil },
                classifyHealthFailure: { _ in .transientFailure }
            )
            XCTFail("expected inventory failure")
        } catch let error as StubError {
            XCTAssertEqual(error, .inventoryFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await fulfillment(of: [healthApplied], timeout: 1.0)
        XCTAssertEqual(publishedExecution?.cacheAction, .set(expectedHealth))
        let counts = await client.callCounts()
        XCTAssertEqual(counts.health, 1)
        XCTAssertEqual(counts.bootstrap, 0)
        XCTAssertEqual(counts.changes, 0)
        XCTAssertEqual(counts.wait, 0)
    }

    @MainActor
    func testRunMetadataRefreshMapsFailureIntoFailureExecution() async throws {
        let client = StubProjectionClient(
            bootstrapResults: [.failure(StubError.metadataFailure)]
        )
        let inventoryClient = StubInventoryClient(results: [.success([makeInventoryPane()])])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        let plan = await coordinator.planStep(
            state: makeState(
                nextMetadataRefreshAt: now.addingTimeInterval(-1),
                nextHealthRefreshAt: now.addingTimeInterval(60)
            )
        )
        guard let metadataInput = plan.metadataRefreshInput else {
            return XCTFail("expected metadata refresh input")
        }

        let execution = try await coordinator.runMetadataRefresh(
            input: metadataInput,
            classifyLocalDaemonIssue: { _ in .incompatibleMetadataProtocol(detail: "metadata failure") }
        )

        XCTAssertEqual(execution.plan.cacheAction, .clear)
        XCTAssertEqual(execution.plan.state.syncPrimed, false)
        XCTAssertEqual(execution.plan.state.transportVersion, nil)
        XCTAssertEqual(
            execution.plan.state.daemonIssue,
            .incompatibleMetadataProtocol(detail: "metadata failure")
        )
        XCTAssertEqual(execution.postApplyLogMessages, ["sync metadata unavailable; cleared cached overlay: metadataFailure"])
    }

    @MainActor
    func testRunMetadataSteadyStateOwnsBootstrapThenWaitForChangesLoop() async {
        let client = StubProjectionClient(
            bootstrapResults: [.success(makeEmptyBootstrapV3(seq: 0))],
            waitResults: [.success(makeEmptyChangesV3(seq: 1))]
        )
        let inventoryClient = StubInventoryClient(results: [.success([])])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        var state: LocalProjectionState? = makeState(
            localInventoryAvailable: true,
            inventory: [],
            inventoryCount: 0,
            useLongPoll: true,
            successInterval: 0
        )
        var executions: [LocalMetadataRefreshExecution] = []
        let runtime = LocalProjectionSteadyStateRuntime(
            captureState: { state },
            applyMetadataExecution: { execution in
                executions.append(execution)
                guard let current = state else { return }
                state = self.applying(execution, to: current)
                if executions.count == 2 {
                    state = nil
                }
            },
            applyHealthExecution: { _ in
                XCTFail("metadata loop must not publish health execution")
            },
            sleep: { _ in await Task.yield() },
            idlePollInterval: 0
        )

        await coordinator.runMetadataSteadyState(
            runtime: runtime,
            classifyLocalDaemonIssue: { _ in nil }
        )

        XCTAssertEqual(executions.count, 2)
        XCTAssertTrue(executions[0].plan.state.syncPrimed, "bootstrap must prime sync ownership")
        XCTAssertTrue(executions[1].plan.state.syncPrimed, "wait-for-changes apply must keep sync primed")

        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrap, 1)
        XCTAssertEqual(counts.wait, 1, "steady-state ownership must call waitForUIChangesV1 after bootstrap")
        XCTAssertEqual(counts.changes, 0, "long-poll support must not fall back to fetchUIChangesV3")
    }

    @MainActor
    func testRunMetadataSteadyStateWaitsForLocalInventoryTruth() async {
        let client = StubProjectionClient(
            bootstrapResults: [.failure(StubError.metadataFailure)]
        )
        let inventoryClient = StubInventoryClient(results: [.success([])])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        let stateBox = LocalProjectionStateBox(makeState(
            localInventoryAvailable: false,
            inventory: [],
            inventoryCount: 0,
            useLongPoll: true,
            successInterval: 0
        ))
        let runtime = LocalProjectionSteadyStateRuntime(
            captureState: { stateBox.state },
            applyMetadataExecution: { _ in
                XCTFail("metadata loop must not publish without local inventory truth")
            },
            applyHealthExecution: { _ in
                XCTFail("metadata loop must not publish health execution")
            },
            sleep: { _ in
                await MainActor.run {
                    stateBox.state = nil
                }
                await Task.yield()
            },
            idlePollInterval: 0
        )

        await coordinator.runMetadataSteadyState(
            runtime: runtime,
            classifyLocalDaemonIssue: { _ in nil }
        )

        let counts = await client.callCounts()
        XCTAssertEqual(counts.bootstrap, 0)
        XCTAssertEqual(counts.wait, 0)
        XCTAssertEqual(counts.changes, 0)
    }

    @MainActor
    func testRunHealthSteadyStateOwnsHealthCadence() async {
        let healthA = makeHealthSnapshot(detail: "first")
        let healthB = makeHealthSnapshot(detail: "second")
        let client = StubProjectionClient(
            healthResults: [
                .success(healthA),
                .success(healthB),
            ]
        )
        let inventoryClient = StubInventoryClient(results: [.success([])])
        let coordinator = makeCoordinator(
            client: client,
            inventoryClient: inventoryClient,
            environment: { [:] }
        )

        var state: LocalProjectionState? = makeState(
            localInventoryAvailable: true,
            inventory: [],
            inventoryCount: 0,
            healthSuccessInterval: 0
        )
        var executions: [LocalHealthRefreshExecution] = []
        let runtime = LocalProjectionSteadyStateRuntime(
            captureState: { state },
            applyMetadataExecution: { _ in
                XCTFail("health loop must not publish metadata execution")
            },
            applyHealthExecution: { execution in
                executions.append(execution)
                guard let current = state else { return }
                state = self.applying(execution, to: current)
                if executions.count == 2 {
                    state = nil
                }
            },
            sleep: { _ in await Task.yield() },
            idlePollInterval: 0
        )

        await coordinator.runHealthSteadyState(
            runtime: runtime,
            classifyFailure: { _ in .transientFailure }
        )

        XCTAssertEqual(executions.map(\.cacheAction), [.set(healthA), .set(healthB)])
        let counts = await client.callCounts()
        XCTAssertEqual(counts.health, 2)
    }

    @MainActor
    private func makeCoordinator(
        client: StubProjectionClient,
        inventoryClient: StubInventoryClient,
        environment: @escaping () -> [String: String]
    ) -> LocalProjectionCoordinator {
        LocalProjectionCoordinator(
            localClient: client,
            localHealthClient: client,
            localInventoryClient: inventoryClient,
            transportBridge: LocalMetadataTransportBridge(),
            environment: environment,
            now: { self.now }
        )
    }

    @MainActor
    private func makeState(
        uiTestMetadataModeEnabled: Bool = false,
        localInventoryKnown: Bool = true,
        localInventoryAvailable: Bool = true,
        nextMetadataRefreshAt: Date? = nil,
        nextHealthRefreshAt: Date? = nil,
        inventory: [AgtmuxPane]? = nil,
        inventoryCount: Int? = nil,
        useLongPoll: Bool = false,
        successInterval: TimeInterval = 1.0,
        healthSuccessInterval: TimeInterval = 1.0
    ) -> LocalProjectionState {
        let resolvedInventory = inventory ?? [makeInventoryPane()]
        return LocalProjectionState(
            uiTestMetadataModeEnabled: uiTestMetadataModeEnabled,
            localInventoryKnown: localInventoryKnown,
            localInventoryAvailable: localInventoryAvailable,
            nextMetadataRefreshAt: nextMetadataRefreshAt ?? now.addingTimeInterval(-1),
            nextHealthRefreshAt: nextHealthRefreshAt ?? now.addingTimeInterval(-1),
            metadataRefreshContext: LocalMetadataRefreshContext(
                syncPrimed: false,
                transportVersion: nil,
                inventoryCount: inventoryCount ?? resolvedInventory.count,
                successInterval: successInterval,
                failureBackoff: 3.0,
                bootstrapNotReadyBackoff: 0.5,
                changeLimit: 256,
                useLongPoll: useLongPoll,
                longPollTimeoutMs: 3000
            ),
            overlayStore: LocalMetadataOverlayStore(
                inventory: resolvedInventory,
                metadataByPaneKey: [:],
                presentationByPaneKey: [:]
            ),
            healthSuccessInterval: healthSuccessInterval,
            healthFailureBackoff: 3.0,
            healthUnsupportedBackoff: 60.0
        )
    }

    private func applying(
        _ execution: LocalMetadataRefreshExecution,
        to state: LocalProjectionState
    ) -> LocalProjectionState {
        let cache: LocalMetadataOverlayCache
        switch execution.plan.cacheAction {
        case .replace(let updated):
            cache = updated
        case .clear:
            cache = LocalMetadataOverlayCache(
                metadataByPaneKey: [:],
                presentationByPaneKey: [:]
            )
        }

        return LocalProjectionState(
            uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled,
            localInventoryKnown: state.localInventoryKnown,
            localInventoryAvailable: state.localInventoryAvailable,
            nextMetadataRefreshAt: execution.plan.state.nextRefreshAt,
            nextHealthRefreshAt: state.nextHealthRefreshAt,
            metadataRefreshContext: LocalMetadataRefreshContext(
                syncPrimed: execution.plan.state.syncPrimed,
                transportVersion: execution.plan.state.transportVersion,
                inventoryCount: state.metadataRefreshContext.inventoryCount,
                successInterval: state.metadataRefreshContext.successInterval,
                failureBackoff: state.metadataRefreshContext.failureBackoff,
                bootstrapNotReadyBackoff: state.metadataRefreshContext.bootstrapNotReadyBackoff,
                changeLimit: state.metadataRefreshContext.changeLimit,
                useLongPoll: execution.plan.disableLongPoll ? false : state.metadataRefreshContext.useLongPoll,
                longPollTimeoutMs: state.metadataRefreshContext.longPollTimeoutMs
            ),
            overlayStore: LocalMetadataOverlayStore(
                inventory: state.overlayStore.inventory,
                metadataByPaneKey: cache.metadataByPaneKey,
                presentationByPaneKey: cache.presentationByPaneKey,
                log: state.overlayStore.log
            ),
            healthSuccessInterval: state.healthSuccessInterval,
            healthFailureBackoff: state.healthFailureBackoff,
            healthUnsupportedBackoff: state.healthUnsupportedBackoff
        )
    }

    private func applying(
        _ execution: LocalHealthRefreshExecution,
        to state: LocalProjectionState
    ) -> LocalProjectionState {
        LocalProjectionState(
            uiTestMetadataModeEnabled: state.uiTestMetadataModeEnabled,
            localInventoryKnown: state.localInventoryKnown,
            localInventoryAvailable: state.localInventoryAvailable,
            nextMetadataRefreshAt: state.nextMetadataRefreshAt,
            nextHealthRefreshAt: execution.nextRefreshAt,
            metadataRefreshContext: state.metadataRefreshContext,
            overlayStore: state.overlayStore,
            healthSuccessInterval: state.healthSuccessInterval,
            healthFailureBackoff: state.healthFailureBackoff,
            healthUnsupportedBackoff: state.healthUnsupportedBackoff
        )
    }

    private func makeEmptyBootstrapV3(seq: UInt64) -> AgtmuxSyncV3Bootstrap {
        AgtmuxSyncV3Bootstrap(
            version: 3,
            panes: [],
            generatedAt: now,
            replayCursor: AgtmuxSyncV3Cursor(seq: seq)
        )
    }

    private func makeEmptyChangesV3(seq: UInt64) -> AgtmuxSyncV3ChangesResponse {
        .changes(
            AgtmuxSyncV3Changes(
                fromSeq: seq,
                toSeq: seq,
                nextCursor: AgtmuxSyncV3Cursor(seq: seq),
                changes: []
            )
        )
    }

    private func makeHealthSnapshot(detail: String) -> AgtmuxUIHealthV1 {
        AgtmuxUIHealthV1(
            generatedAt: now,
            runtime: AgtmuxUIComponentHealth(
                status: .ok,
                detail: detail,
                lastUpdatedAt: now
            ),
            replay: AgtmuxUIReplayHealth(
                status: .ok,
                currentEpoch: 1,
                cursorSeq: 1,
                headSeq: 1,
                lag: 0,
                detail: "healthy"
            ),
            overlay: AgtmuxUIComponentHealth(
                status: .ok,
                detail: "healthy",
                lastUpdatedAt: now
            ),
            focus: AgtmuxUIFocusHealth(
                status: .ok,
                mismatchCount: 0,
                detail: "healthy"
            )
        )
    }

    private func makeInventoryPane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "visible-session",
            windowId: "@1",
            activityState: .unknown,
            presence: .unmanaged,
            evidenceMode: .none,
            currentCmd: "zsh"
        )
    }
}
