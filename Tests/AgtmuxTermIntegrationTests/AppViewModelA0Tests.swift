import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class AppViewModelA0Tests: XCTestCase {
    private enum StubError: Error {
        case timedOut
        case exhausted
        case unexpectedSnapshotCall
    }

    private struct BootstrapStep {
        let delayMs: UInt64
        let result: Result<AgtmuxSyncV2Bootstrap, Error>
    }

    private struct ChangesStep {
        let delayMs: UInt64
        let result: Result<AgtmuxSyncV2ChangesResponse, Error>
    }

    private struct HealthStep {
        let delayMs: UInt64
        let result: Result<AgtmuxUIHealthV1, Error>
    }

    private actor StubMetadataClient: LocalMetadataClient, LocalHealthClient {
        private var bootstrapSteps: [BootstrapStep]
        private var changesSteps: [ChangesStep]
        private var healthSteps: [HealthStep]
        private(set) var resetCount = 0
        private(set) var healthFetchCount = 0

        init(bootstrapSteps: [BootstrapStep],
             changesSteps: [ChangesStep] = [],
             healthSteps: [HealthStep] = []) {
            self.bootstrapSteps = bootstrapSteps
            self.changesSteps = changesSteps
            self.healthSteps = healthSteps
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.unexpectedSnapshotCall
        }

        func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap {
            guard !bootstrapSteps.isEmpty else { throw StubError.exhausted }
            let step = bootstrapSteps.removeFirst()
            if step.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(step.delayMs))
            }
            switch step.result {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                throw error
            }
        }

        func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse {
            guard !changesSteps.isEmpty else { throw StubError.exhausted }
            let step = changesSteps.removeFirst()
            if step.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(step.delayMs))
            }
            switch step.result {
            case let .success(response):
                return response
            case let .failure(error):
                throw error
            }
        }

        func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
            healthFetchCount += 1
            guard !healthSteps.isEmpty else {
                throw LocalHealthClientError.unsupportedMethod("ui.health.v1")
            }

            let step = healthSteps.removeFirst()
            if step.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(step.delayMs))
            }
            switch step.result {
            case let .success(health):
                return health
            case let .failure(error):
                throw error
            }
        }

        func resetUIChangesV2() async {
            resetCount += 1
        }

        func resets() -> Int {
            resetCount
        }

        func healthFetches() -> Int {
            healthFetchCount
        }
    }

    private actor StubInventoryClient: LocalPaneInventoryClient {
        private var steps: [Result<[AgtmuxPane], Error>]
        private let repeatsLastStep: Bool

        init(panes: [AgtmuxPane]) {
            self.steps = [.success(panes)]
            self.repeatsLastStep = true
        }

        init(steps: [Result<[AgtmuxPane], Error>], repeatsLastStep: Bool = false) {
            self.steps = steps
            self.repeatsLastStep = repeatsLastStep
        }

        func fetchPanes() async throws -> [AgtmuxPane] {
            guard !steps.isEmpty else { throw StubError.exhausted }
            let step = steps.count == 1 && repeatsLastStep ? steps[0] : steps.removeFirst()
            switch step {
            case let .success(panes):
                return panes
            case let .failure(error):
                throw error
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 2.0,
                           intervalMs: UInt64 = 25,
                           condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return await condition()
    }

    private func waitUntilAsync(timeout: TimeInterval = 2.0,
                                intervalMs: UInt64 = 25,
                                condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return await condition()
    }

    private func makeInventoryPane() -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: .unknown,
            presence: .unmanaged,
            evidenceMode: .none,
            currentCmd: "zsh"
        )
    }

    private func makeManagedMetadataPane(provider: Provider = .codex,
                                         activityState: ActivityState = .running,
                                         conversationTitle: String = "Implement A0") -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: activityState,
            presence: .managed,
            provider: provider,
            evidenceMode: .deterministic,
            conversationTitle: conversationTitle,
            currentCmd: "node"
        )
    }

    private func makeBootstrap(panes: [AgtmuxPane], cursorSeq: UInt64 = 1) -> AgtmuxSyncV2Bootstrap {
        AgtmuxSyncV2Bootstrap(
            epoch: 1,
            snapshotSeq: cursorSeq,
            panes: panes,
            sessions: [],
            generatedAt: Date(timeIntervalSince1970: 1_778_822_260),
            replayCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: cursorSeq)
        )
    }

    private func makeIncompatibleSyncV2Error(
        method: String = "ui.bootstrap.v2"
    ) -> Error {
        DaemonError.processError(
            exitCode: -3,
            stderr: "RPC \(method) failed (-32601): method not found"
        )
    }

    private func makeDaemonUnavailableError() -> Error {
        DaemonError.daemonUnavailable
    }

    private func makeUnsupportedHealthError(
        method: String = "ui.health.v1"
    ) -> Error {
        DaemonError.processError(
            exitCode: -3,
            stderr: "RPC \(method) failed (-32601): method not found"
        )
    }

    private func makeStructuredUIErrorText(
        code: DaemonUIErrorCode,
        method: String,
        rpcCode: Int? = -32601,
        message: String
    ) throws -> String {
        let envelope = DaemonUIErrorEnvelope(
            code: code.rawValue,
            message: message,
            method: method,
            rpcCode: rpcCode
        )
        let data = try JSONEncoder().encode(envelope)
        return "\(DaemonError.uiErrorPrefix)\(String(decoding: data, as: UTF8.self))"
    }

    private func makeHealthSnapshot(
        runtime: AgtmuxUIComponentHealth = AgtmuxUIComponentHealth(
            status: .ok,
            detail: "runtime healthy",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_260)
        ),
        replay: AgtmuxUIReplayHealth = AgtmuxUIReplayHealth(
            status: .ok,
            currentEpoch: 1,
            cursorSeq: 4,
            headSeq: 4,
            lag: 0,
            detail: "replay caught up"
        ),
        overlay: AgtmuxUIComponentHealth = AgtmuxUIComponentHealth(
            status: .ok,
            detail: "overlay fresh",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_260)
        ),
        focus: AgtmuxUIFocusHealth = AgtmuxUIFocusHealth(
            status: .ok,
            focusedPaneID: "%101",
            mismatchCount: 0,
            lastSyncAt: Date(timeIntervalSince1970: 1_778_822_260),
            detail: "focus in sync"
        )
    ) -> AgtmuxUIHealthV1 {
        AgtmuxUIHealthV1(
            generatedAt: Date(timeIntervalSince1970: 1_778_822_261),
            runtime: runtime,
            replay: replay,
            overlay: overlay,
            focus: focus
        )
    }

    func testDefaultDirectLocalClientParticipatesInLocalHealthClient() {
        let client: any LocalMetadataClient = AgtmuxDaemonClient()
        XCTAssertNotNil(client as? any LocalHealthClient)
    }

    func testDefaultXPCClientParticipatesInLocalHealthClient() {
        let client: any LocalMetadataClient = AgtmuxDaemonXPCClient(serviceName: "test.agtmux.xpc")
        XCTAssertNotNil(client as? any LocalHealthClient)
    }

    @MainActor
    func testFetchAllReturnsInventoryWithoutWaitingMetadata() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let bootstrap = makeBootstrap(panes: [metadataPane])

        let model = AppViewModel(
            localClient: StubMetadataClient(bootstrapSteps: [
                BootstrapStep(delayMs: 700, result: .success(bootstrap)),
            ]),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        let started = Date()
        await model.fetchAll()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            0.35,
            "inventory-first path must not block on delayed metadata fetch"
        )
        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)

        let overlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(overlayApplied, "metadata overlay should apply asynchronously without next poll")
        XCTAssertEqual(model.panes.first?.provider, .codex)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testLocalDaemonHealthPublishesAvailableSnapshot() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let expectedHealth = makeHealthSnapshot()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            healthSteps: [
                HealthStep(delayMs: 20, result: .success(expectedHealth)),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let healthApplied = await waitUntilAsync {
            await client.healthFetches() == 1 && model.localDaemonHealth == expectedHealth
        }
        XCTAssertTrue(healthApplied, "health snapshot should publish asynchronously without blocking inventory")
        XCTAssertEqual(model.localDaemonHealth, expectedHealth)
        XCTAssertEqual(model.panes.first?.paneId, inventoryPane.paneId)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testLocalDaemonHealthPublishesEvenWhenInventoryFetchFails() async {
        let expectedHealth = makeHealthSnapshot(
            runtime: AgtmuxUIComponentHealth(
                status: .ok,
                detail: "inventory offline but daemon healthy",
                lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_270)
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [],
            healthSteps: [
                HealthStep(delayMs: 20, result: .success(expectedHealth)),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(steps: [
                .failure(StubError.timedOut),
            ]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let healthApplied = await waitUntilAsync {
            await client.healthFetches() == 1 && model.localDaemonHealth == expectedHealth
        }
        XCTAssertTrue(
            healthApplied,
            "ui.health.v1 refresh should not depend on a successful tmux inventory fetch"
        )
        XCTAssertTrue(model.offlineHosts.contains("local"))
        XCTAssertEqual(model.localDaemonHealth?.runtime.detail, "inventory offline but daemon healthy")
        XCTAssertNil(model.localDaemonIssue)
        XCTAssertTrue(model.panes.isEmpty)
    }

    @MainActor
    func testLocalInventoryOfflineDoesNotClearExistingHealthAndStillAllowsRefresh() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let firstHealth = makeHealthSnapshot(
            runtime: AgtmuxUIComponentHealth(
                status: .ok,
                detail: "runtime first poll",
                lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_270)
            )
        )
        let secondHealth = makeHealthSnapshot(
            runtime: AgtmuxUIComponentHealth(
                status: .degraded,
                detail: "runtime second poll",
                lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_275)
            ),
            replay: AgtmuxUIReplayHealth(
                status: .degraded,
                currentEpoch: 2,
                cursorSeq: 7,
                headSeq: 9,
                lag: 2,
                detail: "replay lagged while inventory stayed offline"
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            healthSteps: [
                HealthStep(delayMs: 20, result: .success(firstHealth)),
                HealthStep(delayMs: 20, result: .success(secondHealth)),
            ]
        )
        let inventoryClient = StubInventoryClient(steps: [
            .success([inventoryPane]),
            .failure(StubError.timedOut),
        ])

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: inventoryClient,
            hostsConfig: .empty
        )

        await model.fetchAll()
        let firstHealthApplied = await waitUntilAsync {
            await client.healthFetches() == 1 && model.localDaemonHealth == firstHealth
        }
        XCTAssertTrue(firstHealthApplied)
        XCTAssertFalse(model.offlineHosts.contains("local"))

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        XCTAssertEqual(
            model.localDaemonHealth,
            firstHealth,
            "local inventory offline must not automatically clear the last published health snapshot"
        )

        let secondHealthApplied = await waitUntilAsync {
            await client.healthFetches() == 2 && model.localDaemonHealth == secondHealth
        }
        XCTAssertTrue(
            secondHealthApplied,
            "ui.health.v1 refresh should keep running while local inventory is offline"
        )
        XCTAssertTrue(model.offlineHosts.contains("local"))
        XCTAssertEqual(model.localDaemonHealth?.runtime.detail, "runtime second poll")
        XCTAssertEqual(model.localDaemonHealth?.replay.lag, 2)
        XCTAssertEqual(model.panes.first?.paneId, inventoryPane.paneId)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testLocalDaemonHealthPublishesDegradedAndUnavailableComponents() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let degradedHealth = makeHealthSnapshot(
            runtime: AgtmuxUIComponentHealth(
                status: .unavailable,
                detail: "bundled runtime missing",
                lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_240)
            ),
            replay: AgtmuxUIReplayHealth(
                status: .degraded,
                currentEpoch: 4,
                cursorSeq: 180,
                headSeq: 192,
                lag: 12,
                lastResyncReason: "trimmed_cursor",
                lastResyncAt: Date(timeIntervalSince1970: 1_778_822_200),
                detail: "replay lag exceeded budget"
            ),
            overlay: AgtmuxUIComponentHealth(
                status: .degraded,
                detail: "overlay freshness stale",
                lastUpdatedAt: Date(timeIntervalSince1970: 1_778_822_180)
            ),
            focus: AgtmuxUIFocusHealth(
                status: .unavailable,
                focusedPaneID: "%404",
                mismatchCount: 3,
                lastSyncAt: Date(timeIntervalSince1970: 1_778_822_150),
                detail: "focus sync monitor offline"
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            healthSteps: [
                HealthStep(delayMs: 20, result: .success(degradedHealth)),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let healthApplied = await waitUntilAsync {
            await client.healthFetches() == 1 && model.localDaemonHealth == degradedHealth
        }
        XCTAssertTrue(healthApplied)
        XCTAssertEqual(model.localDaemonHealth?.runtime.status, .unavailable)
        XCTAssertEqual(model.localDaemonHealth?.runtime.detail, "bundled runtime missing")
        XCTAssertEqual(model.localDaemonHealth?.replay.status, .degraded)
        XCTAssertEqual(model.localDaemonHealth?.replay.lag, 12)
        XCTAssertEqual(model.localDaemonHealth?.replay.lastResyncReason, "trimmed_cursor")
        XCTAssertEqual(model.localDaemonHealth?.overlay.status, .degraded)
        XCTAssertEqual(model.localDaemonHealth?.focus.status, .unavailable)
        XCTAssertEqual(model.localDaemonHealth?.focus.mismatchCount, 3)
        XCTAssertEqual(model.panes.first?.paneId, inventoryPane.paneId)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testUnsupportedHealthMethodKeepsHealthUnsetAndOverlayBehaviorUnchanged() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            healthSteps: [
                HealthStep(delayMs: 20, result: .failure(makeUnsupportedHealthError())),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(overlayApplied)

        let healthAttempted = await waitUntilAsync {
            await client.healthFetches() == 1
        }
        XCTAssertTrue(healthAttempted)
        XCTAssertNil(model.localDaemonHealth, "missing ui.health.v1 should stay absent instead of surfacing noise")
        XCTAssertNil(model.localDaemonIssue)
        XCTAssertEqual(model.panes.first?.provider, .codex)
    }

    @MainActor
    func testStructuredUnsupportedHealthErrorFromXPCUsesUIErrorEnvelopeClassification() async throws {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let structuredRemoteError = try makeStructuredUIErrorText(
            code: .uiHealthMethodNotFound,
            method: "ui.health.v1",
            message: "structured ui.health.v1 method not found"
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            healthSteps: [
                HealthStep(delayMs: 20, result: .failure(XPCClientError.remote(structuredRemoteError))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(overlayApplied)

        let healthAttempted = await waitUntilAsync {
            await client.healthFetches() == 1
        }
        XCTAssertTrue(healthAttempted)
        XCTAssertNil(
            model.localDaemonHealth,
            "structured AGTMUX_UI_ERROR uiHealthMethodNotFound should classify as unsupported without surfacing noise"
        )
        XCTAssertNil(model.localDaemonIssue)
        XCTAssertEqual(model.panes.first?.provider, .codex)
    }

    @MainActor
    func testIncompatibleLocalDaemonIsSurfacedWhileInventoryPanesStillRender() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeIncompatibleSyncV2Error())),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.paneId, inventoryPane.paneId)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertFalse(model.offlineHosts.contains("local"))

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "explicit sync-v2 incompatibility should be surfaced in UI state")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue")
        }
        XCTAssertTrue(detail.contains("ui.bootstrap.v2"))
        XCTAssertTrue(detail.contains("-32601"))

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testLocalDaemonUnavailableIsSurfacedWhileInventoryPanesStillRender() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeDaemonUnavailableError())),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.paneId, inventoryPane.paneId)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertFalse(model.offlineHosts.contains("local"))

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "missing managed runtime should be surfaced in UI state")

        guard case let .localDaemonUnavailable(detail)? = model.localDaemonIssue else {
            return XCTFail("expected local daemon unavailable issue")
        }
        XCTAssertTrue(detail.contains("AGTMUX_BIN"))
        XCTAssertTrue(detail.contains(AgtmuxBinaryResolver.defaultSocketPath))

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testLocalDaemonIssueClearsAfterLaterNonCompatibilityFailure() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeIncompatibleSyncV2Error())),
                BootstrapStep(delayMs: 20, result: .failure(StubError.timedOut)),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialIssueSurfaced = await waitUntil {
            if case .incompatibleSyncV2? = model.localDaemonIssue {
                return true
            }
            return false
        }
        XCTAssertTrue(initialIssueSurfaced)

        let laterNonClassifiedFailureObserved = await waitUntilAsync(timeout: 5.0, intervalMs: 100) {
            await model.fetchAll()
            return await client.resets() == 2 && model.localDaemonIssue == nil
        }
        XCTAssertTrue(
            laterNonClassifiedFailureObserved,
            "the metadata refresh path must wait through failure backoff, attempt a second refresh, and clear stale incompatibility state on a later non-classified failure"
        )

        XCTAssertNil(
            model.localDaemonIssue,
            "a later non-classified metadata failure must clear stale incompatibility state"
        )
        XCTAssertFalse(model.offlineHosts.contains("local"))

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 2)
    }

    @MainActor
    func testLocalDaemonIssueClearsWhenLocalSourceTransitionsOffline() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeIncompatibleSyncV2Error())),
            ]
        )
        let inventoryClient = StubInventoryClient(
            steps: [
                .success([inventoryPane]),
                .failure(StubError.timedOut),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: inventoryClient,
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialIssueSurfaced = await waitUntil {
            if case .incompatibleSyncV2? = model.localDaemonIssue {
                return true
            }
            return false
        }
        XCTAssertTrue(initialIssueSurfaced)

        await model.fetchAll()

        XCTAssertTrue(model.offlineHosts.contains("local"))
        XCTAssertNil(
            model.localDaemonIssue,
            "local offline transitions must clear any stale daemon incompatibility banner"
        )
    }

    @MainActor
    func testMetadataFailureDoesNotClearPreviousOverlay() async {
        let inventoryPane = makeInventoryPane()
        let metadataPane = makeManagedMetadataPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane]))),
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .failure(StubError.timedOut)),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let firstOverlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }
        XCTAssertTrue(firstOverlayApplied)

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            model.panes.first?.presence,
            .managed,
            "metadata timeout/failure must not destructively clear cached overlay"
        )
        XCTAssertEqual(model.panes.first?.provider, .codex)
        XCTAssertNil(model.localDaemonIssue)
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testResyncRequiredTriggersExplicitBootstrapAndRefreshesOverlay() async {
        let inventoryPane = makeInventoryPane()
        let initialPane = makeManagedMetadataPane(provider: .codex, conversationTitle: "Initial A1")
        let resyncedPane = makeManagedMetadataPane(
            provider: .claude,
            activityState: .waitingInput,
            conversationTitle: "Resynced A1"
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [initialPane], cursorSeq: 1))),
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [resyncedPane], cursorSeq: 9))),
            ],
            changesSteps: [
                ChangesStep(
                    delayMs: 20,
                    result: .success(
                        .resyncRequired(
                            AgtmuxSyncV2ResyncRequired(
                                currentEpoch: 2,
                                latestSnapshotSeq: 9,
                                reason: "trimmed_cursor"
                            )
                        )
                    )
                ),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialOverlayApplied = await waitUntil {
            model.panes.first?.provider == .codex
        }
        XCTAssertTrue(initialOverlayApplied)

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()
        let resyncedOverlayApplied = await waitUntil {
            model.panes.first?.provider == .claude
                && model.panes.first?.activityState == .waitingInput
        }

        XCTAssertTrue(resyncedOverlayApplied, "resync_required should force an explicit bootstrap refresh")
        XCTAssertEqual(model.panes.first?.conversationTitle, "Resynced A1")
        XCTAssertNil(model.localDaemonIssue)
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }
}
