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

    private struct BootstrapV3Step {
        let delayMs: UInt64
        let result: Result<AgtmuxSyncV3Bootstrap, Error>
    }

    private struct ChangesStep {
        let delayMs: UInt64
        let result: Result<AgtmuxSyncV2ChangesResponse, Error>
    }

    private struct ChangesV3Step {
        let delayMs: UInt64
        let result: Result<AgtmuxSyncV3ChangesResponse, Error>
    }

    private struct HealthStep {
        let delayMs: UInt64
        let result: Result<AgtmuxUIHealthV1, Error>
    }

    private actor StubMetadataClient: LocalMetadataClient, LocalHealthClient {
        private var bootstrapV3Steps: [BootstrapV3Step]
        private var bootstrapSteps: [BootstrapStep]
        private var changesV3Steps: [ChangesV3Step]
        private var changesSteps: [ChangesStep]
        private var healthSteps: [HealthStep]
        private(set) var resetCount = 0
        private(set) var healthFetchCount = 0

        init(bootstrapV3Steps: [BootstrapV3Step] = [],
             bootstrapSteps: [BootstrapStep],
             changesV3Steps: [ChangesV3Step] = [],
             changesSteps: [ChangesStep] = [],
             healthSteps: [HealthStep] = []) {
            self.bootstrapV3Steps = bootstrapV3Steps
            self.bootstrapSteps = bootstrapSteps
            self.changesV3Steps = changesV3Steps
            self.changesSteps = changesSteps
            self.healthSteps = healthSteps
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.unexpectedSnapshotCall
        }

        func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
            guard !bootstrapV3Steps.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3")
            }
            let step = bootstrapV3Steps.removeFirst()
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

        func fetchUIChangesV3(limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
            guard !changesV3Steps.isEmpty else {
                throw LocalMetadataClientError.unsupportedMethod("ui.changes.v3")
            }
            let step = changesV3Steps.removeFirst()
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

        func resetUIChangesV3() async {
            resetCount += 1
        }

        func resets() -> Int {
            resetCount
        }

        func healthFetches() -> Int {
            healthFetchCount
        }
    }

    private actor DecodingMetadataClient: LocalMetadataClient {
        private let bootstrapJSON: String
        private(set) var resetCount = 0

        init(bootstrapJSON: String) {
            self.bootstrapJSON = bootstrapJSON
        }

        func fetchSnapshot() async throws -> AgtmuxSnapshot {
            throw StubError.unexpectedSnapshotCall
        }

        func fetchUIBootstrapV2() async throws -> AgtmuxSyncV2Bootstrap {
            let data = Data(bootstrapJSON.utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(AgtmuxSyncV2Bootstrap.self, from: data)
            } catch {
                throw DaemonError.parseError("RPC ui.bootstrap.v2 parse failed: \(error.localizedDescription)")
            }
        }

        func fetchUIChangesV2(limit: Int) async throws -> AgtmuxSyncV2ChangesResponse {
            throw StubError.exhausted
        }

        func resetUIChangesV2() async {
            resetCount += 1
        }

        func resets() -> Int {
            resetCount
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

    private func makeInventoryPane(
        paneId: String = "%101",
        sessionName: String = "dev",
        sessionGroup: String? = nil,
        windowId: String = "@11",
        windowIndex: Int? = nil,
        windowName: String? = nil,
        activityState: ActivityState = .unknown,
        presence: PanePresence = .unmanaged,
        currentCmd: String? = "zsh"
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: paneId,
            sessionName: sessionName,
            sessionGroup: sessionGroup,
            windowId: windowId,
            windowIndex: windowIndex,
            windowName: windowName,
            activityState: activityState,
            presence: presence,
            evidenceMode: .none,
            currentCmd: currentCmd
        )
    }

    private func makeManagedMetadataPane(
        paneId: String = "%101",
        sessionName: String = "dev",
        sessionGroup: String? = nil,
        windowId: String = "@11",
        windowIndex: Int? = nil,
        windowName: String? = nil,
        provider: Provider = .codex,
        activityState: ActivityState = .running,
        conversationTitle: String = "Implement A0",
        metadataSessionKey: String? = nil,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: paneId,
            sessionName: sessionName,
            sessionGroup: sessionGroup,
            windowId: windowId,
            windowIndex: windowIndex,
            windowName: windowName,
            activityState: activityState,
            presence: .managed,
            provider: provider,
            evidenceMode: .deterministic,
            conversationTitle: conversationTitle,
            currentCmd: "node",
            metadataSessionKey: metadataSessionKey ?? sessionName,
            paneInstanceID: paneInstanceID
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

    private func makePaneState(
        paneId: String = "%101",
        sessionKey: String = "dev",
        generation: UInt64? = nil,
        birthTs: Date? = nil,
        presence: PanePresence = .managed,
        evidenceMode: EvidenceMode = .deterministic,
        activityState: ActivityState = .running,
        provider: Provider? = .codex,
        updatedAt: Date = Date(timeIntervalSince1970: 1_778_822_260)
    ) -> AgtmuxSyncV2PaneState {
        AgtmuxSyncV2PaneState(
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneId,
                generation: generation,
                birthTs: birthTs
            ),
            presence: presence,
            evidenceMode: evidenceMode,
            activityState: activityState,
            provider: provider,
            sessionKey: sessionKey,
            updatedAt: updatedAt
        )
    }

    private func makeChangesResponse(
        paneState: AgtmuxSyncV2PaneState,
        seq: UInt64 = 2
    ) -> AgtmuxSyncV2ChangesResponse {
        .changes(
            AgtmuxSyncV2Changes(
                epoch: 1,
                changes: [
                    AgtmuxSyncV2ChangeRef(
                        seq: seq,
                        sessionKey: paneState.sessionKey,
                        paneId: paneState.paneId,
                        timestamp: paneState.updatedAt,
                        pane: paneState
                    )
                ],
                fromSeq: seq,
                toSeq: seq,
                nextCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: seq + 1)
            )
        )
    }

    private func makeChangesV3Response(
        pane: AgtmuxSyncV3PaneSnapshot,
        kind: AgtmuxSyncV3ChangeKind = .upsert,
        seq: UInt64 = 2,
        fieldGroups: [AgtmuxSyncV3FieldGroup] = [.thread, .pendingRequests, .attention]
    ) -> AgtmuxSyncV3ChangesResponse {
        .changes(
            AgtmuxSyncV3Changes(
                fromSeq: seq,
                toSeq: seq,
                nextCursor: AgtmuxSyncV3Cursor(seq: seq),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: seq,
                        at: pane.updatedAt,
                        kind: kind,
                        paneID: pane.paneID,
                        sessionName: pane.sessionName,
                        windowID: pane.windowID,
                        sessionKey: pane.sessionKey,
                        paneInstanceID: pane.paneInstanceID,
                        fieldGroups: fieldGroups,
                        pane: kind == .upsert ? pane : nil
                    )
                ]
            )
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

    private func makeMissingExactIdentitySyncV2Error() -> Error {
        DaemonError.parseError(
            "AGTMUX_UI_BOOTSTRAP_V2_JSON parse failed: " +
            "sync-v2 bootstrap pane missing required exact identity field 'session_key'"
        )
    }

    private func makeLegacyDaemonBootstrapPayload() -> String {
        #"""
        {
          "epoch": 1,
          "snapshot_seq": 2296,
          "generated_at": "2026-03-07T16:57:36Z",
          "replay_cursor": { "epoch": 1, "seq": 2296 },
          "sessions": [],
          "panes": [
            {
              "pane_id": "%1",
              "session_name": "vm agtmux",
              "window_id": "@1",
              "window_name": "zsh",
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "heuristic",
              "current_cmd": "zsh",
              "current_path": "/Users/virtualmachine/ghq/github.com/g960059/agtmux",
              "updated_at": "2026-03-07T12:46:08Z",
              "session_id": "$1"
            },
            {
              "pane_id": "%2",
              "session_name": "vm agtmux-term",
              "window_id": "@2",
              "window_name": "node",
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "deterministic",
              "current_cmd": "node",
              "current_path": "/Users/virtualmachine/ghq/github.com/g960059/agtmux-term",
              "updated_at": "2026-03-07T15:36:18Z",
              "session_id": "$2"
            }
          ]
        }
        """#
    }

    private func makeMixedEraBootstrapPayloadWithLegacySessionID() -> String {
        #"""
        {
          "epoch": 1,
          "snapshot_seq": 2296,
          "generated_at": "2026-03-07T16:57:36Z",
          "replay_cursor": { "epoch": 1, "seq": 2296 },
          "sessions": [],
          "panes": [
            {
              "pane_id": "%1",
              "session_id": "$1",
              "session_name": "vm agtmux",
              "session_key": "vm agtmux",
              "window_id": "@1",
              "window_name": "zsh",
              "pane_instance_id": {
                "pane_id": "%1",
                "generation": 1,
                "birth_ts": "2026-03-07T16:45:00Z"
              },
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "heuristic",
              "current_cmd": "zsh",
              "current_path": "/Users/virtualmachine/ghq/github.com/g960059/agtmux",
              "updated_at": "2026-03-07T12:46:08Z"
            }
          ]
        }
        """#
    }

    private func makeLiveMarch7MixedEraBootstrapPayloadWithOrphanManagedRows() -> String {
        #"""
        {
          "epoch": 1,
          "snapshot_seq": 2296,
          "generated_at": "2026-03-07T16:57:36Z",
          "replay_cursor": { "epoch": 1, "seq": 2296 },
          "sessions": [],
          "panes": [
            {
              "pane_id": "%1",
              "session_id": "$1",
              "session_name": "vm agtmux",
              "session_key": "vm agtmux",
              "window_id": "@1",
              "window_name": "zsh",
              "pane_instance_id": {
                "pane_id": "%1",
                "generation": 1,
                "birth_ts": "2026-03-07T16:45:00Z"
              },
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "heuristic",
              "current_cmd": "zsh",
              "current_path": "/Users/virtualmachine/ghq/github.com/g960059/agtmux",
              "updated_at": "2026-03-07T12:46:08Z"
            },
            {
              "pane_id": "%999",
              "session_id": "$999",
              "session_name": null,
              "window_id": null,
              "window_name": "ghost",
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "deterministic",
              "current_cmd": "node",
              "current_path": "/tmp/orphan",
              "updated_at": "2026-03-07T15:36:18Z"
            }
          ]
        }
        """#
    }

    private func makeLiveMarch8BootstrapPayloadWithNullExactLocationFields() -> String {
        #"""
        {
          "epoch": 1,
          "snapshot_seq": 4332,
          "generated_at": "2026-03-08T16:05:06Z",
          "replay_cursor": { "epoch": 1, "seq": 4332 },
          "sessions": [
            {
              "session_key": "59bafe97-9f5b-410b-ba6a-6d21b2d4b8ab",
              "presence": "managed",
              "evidence_mode": "deterministic",
              "activity_state": "idle",
              "updated_at": "2026-03-08T14:09:32.967Z"
            }
          ],
          "panes": [
            {
              "pane_id": "%1",
              "session_name": "vm agtmux",
              "session_key": "59bafe97-9f5b-410b-ba6a-6d21b2d4b8ab",
              "window_id": "@1",
              "window_name": "node",
              "pane_instance_id": {
                "pane_id": "%1",
                "generation": 0,
                "birth_ts": "2026-03-07T23:23:32.320609Z"
              },
              "activity_state": "Idle",
              "presence": "managed",
              "provider": "claude",
              "evidence_mode": "deterministic",
              "current_cmd": "node",
              "current_path": "/Users/virtualmachine/ghq/github.com/g960059/agtmux",
              "updated_at": "2026-03-08T14:09:32.967Z"
            },
            {
              "pane_id": "%14",
              "session_name": null,
              "session_key": "rollout-2026-03-08T07-23-09-019ccdd4-9ff1-7e41-9f13-87a9a7034644",
              "window_id": null,
              "window_name": null,
              "pane_instance_id": {
                "pane_id": "%14",
                "generation": 0,
                "birth_ts": "2026-03-08T14:22:11.039338Z"
              },
              "activity_state": "WaitingInput",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "heuristic",
              "conversation_title": "orphan managed row",
              "updated_at": "2026-03-08T14:23:49.043883Z"
            }
          ]
        }
        """#
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
    func testFetchAllKeepsLinkedPrefixedSessionsVisibleAsExactSessions() async {
        let linkedSession = "agtmux-linked-ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345"
        let realSession = "agtmux-ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345"
        let panes = [
            AgtmuxPane(
                source: "local",
                paneId: "%101",
                sessionName: realSession,
                windowId: "@11",
                activityState: .unknown,
                presence: .unmanaged,
                evidenceMode: .none,
                currentCmd: "zsh"
            ),
            AgtmuxPane(
                source: "local",
                paneId: "%101",
                sessionName: linkedSession,
                windowId: "@11",
                activityState: .unknown,
                presence: .unmanaged,
                evidenceMode: .none,
                currentCmd: "zsh"
            )
        ]

        let model = AppViewModel(
            localClient: StubMetadataClient(bootstrapSteps: []),
            localInventoryClient: StubInventoryClient(panes: panes),
            hostsConfig: .empty
        )

        await model.fetchAll()

        XCTAssertEqual(
            Set(model.panes.map(\.sessionName)),
            Set([realSession, linkedSession]),
            "linked-looking session names must remain visible when they are real tmux sessions"
        )
        XCTAssertEqual(model.panes.count, 2)
    }

    @MainActor
    func testFetchAllKeepsSessionGroupAliasesAsDistinctSessions() async {
        let paneID = "%199"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"
        let panes = [
            AgtmuxPane(
                source: "local",
                paneId: paneID,
                sessionName: sessionA,
                sessionGroup: groupName,
                windowId: "@5",
                windowIndex: 1,
                windowName: "AgtmuxTerm",
                activityState: .running,
                presence: .managed,
                provider: .claude,
                evidenceMode: .deterministic,
                conversationTitle: "A",
                currentCmd: "node"
            ),
            AgtmuxPane(
                source: "local",
                paneId: paneID,
                sessionName: sessionB,
                sessionGroup: groupName,
                windowId: "@5",
                windowIndex: 1,
                windowName: "AgtmuxTerm",
                activityState: .running,
                presence: .managed,
                provider: .claude,
                evidenceMode: .deterministic,
                conversationTitle: "B",
                currentCmd: "node"
            )
        ]

        let model = AppViewModel(
            localClient: StubMetadataClient(bootstrapSteps: []),
            localInventoryClient: StubInventoryClient(panes: panes),
            hostsConfig: .empty
        )

        await model.fetchAll()

        XCTAssertEqual(
            Set(model.panes.map(\.sessionName)),
            Set([sessionA, sessionB]),
            "session_group metadata must not collapse exact sessions in the normal sidebar path"
        )
        XCTAssertEqual(model.panes.count, 2)
        XCTAssertEqual(model.panesBySession.first?.sessions.count, 2)
    }

    @MainActor
    func testBootstrapMetadataDoesNotRelabelPlainZshPaneFromDifferentSessionWithSamePaneID() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%77",
            sessionName: "utm-main",
            windowId: "@7",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let staleManagedPane = makeManagedMetadataPane(
            paneId: "%77",
            sessionName: "agtmux-term",
            windowId: "@7",
            provider: .codex,
            activityState: .running,
            conversationTitle: "Old Codex",
            metadataSessionKey: "agtmux-term",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%77",
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )

        let model = AppViewModel(
            localClient: StubMetadataClient(
                bootstrapSteps: [BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [staleManagedPane])))]
            ),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.sessionName, "utm-main")
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .idle)
        XCTAssertEqual(model.panes.first?.currentCmd, "zsh")
        if let pane = model.panes.first {
            XCTAssertEqual(model.paneDisplayTitle(for: pane), "zsh")
        }
    }

    @MainActor
    func testBootstrapMetadataDoesNotLeakProviderAcrossExactSessionAliases() async {
        let paneID = "%88"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"
        let inventoryA = makeInventoryPane(
            paneId: paneID,
            sessionName: sessionA,
            sessionGroup: groupName,
            windowId: "@8",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let inventoryB = makeInventoryPane(
            paneId: paneID,
            sessionName: sessionB,
            sessionGroup: groupName,
            windowId: "@8",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let metadataA = makeManagedMetadataPane(
            paneId: paneID,
            sessionName: sessionA,
            sessionGroup: groupName,
            windowId: "@8",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Session A",
            metadataSessionKey: sessionA,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneID,
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )

        let model = AppViewModel(
            localClient: StubMetadataClient(
                bootstrapSteps: [BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataA])))]
            ),
            localInventoryClient: StubInventoryClient(panes: [inventoryA, inventoryB]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        let panesBySession = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.sessionName, $0) })
        XCTAssertEqual(panesBySession[sessionA]?.presence, .managed)
        XCTAssertEqual(panesBySession[sessionA]?.provider, .codex)
        XCTAssertEqual(panesBySession[sessionA]?.activityState, .idle)
        XCTAssertEqual(panesBySession[sessionB]?.presence, .unmanaged)
        XCTAssertNil(panesBySession[sessionB]?.provider)
        XCTAssertEqual(panesBySession[sessionB]?.activityState, .idle)
        if let paneB = panesBySession[sessionB] {
            XCTAssertEqual(model.paneDisplayTitle(for: paneB), "zsh")
        }
    }

    @MainActor
    func testBootstrapMetadataDropsAmbiguousExactIdentityCollisionAtSamePaneLocation() async {
        let paneID = "%77"
        let sessionName = "dev"
        let inventoryPane = makeInventoryPane(
            paneId: paneID,
            sessionName: sessionName,
            windowId: "@7",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let staleMetadata = makeManagedMetadataPane(
            paneId: paneID,
            sessionName: sessionName,
            windowId: "@7",
            provider: .claude,
            activityState: .running,
            conversationTitle: "Stale",
            metadataSessionKey: sessionName,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneID,
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )
        let currentMetadata = makeManagedMetadataPane(
            paneId: paneID,
            sessionName: sessionName,
            windowId: "@7",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Current",
            metadataSessionKey: sessionName,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneID,
                generation: 2,
                birthTs: Date(timeIntervalSince1970: 1_778_822_260)
            )
        )
        let model = AppViewModel(
            localClient: StubMetadataClient(
                bootstrapSteps: [
                    BootstrapStep(
                        delayMs: 20,
                        result: .success(makeBootstrap(panes: [staleMetadata, currentMetadata]))
                    )
                ]
            ),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .idle)
        XCTAssertNil(
            model.panes.first?.paneInstanceID,
            "ambiguous bootstrap location must fail closed to inventory-only rather than surfacing either exact identity"
        )
    }

    @MainActor
    func testFetchAllRetainsSelectionForExactSessionGroupAliasAcrossRefresh() async {
        let paneID = "%199"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"
        let paneA = AgtmuxPane(
            source: "local",
            paneId: paneID,
            sessionName: sessionA,
            sessionGroup: groupName,
            windowId: "@5",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .running,
            presence: .managed,
            provider: .claude,
            evidenceMode: .deterministic,
            conversationTitle: "A",
            currentCmd: "node"
        )
        let paneB = AgtmuxPane(
            source: "local",
            paneId: paneID,
            sessionName: sessionB,
            sessionGroup: groupName,
            windowId: "@5",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .running,
            presence: .managed,
            provider: .claude,
            evidenceMode: .deterministic,
            conversationTitle: "B",
            currentCmd: "node"
        )

        let model = AppViewModel(
            localClient: StubMetadataClient(bootstrapSteps: []),
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([paneA, paneB]),
                    .success([paneB, paneA]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        guard let selectedAlias = model.panes.first(where: { $0.sessionName == sessionA }) else {
            return XCTFail("expected session-group alias pane to be present after first fetch")
        }
        model.selectPane(selectedAlias)

        await model.fetchAll()

        XCTAssertEqual(
            model.selectedPane?.sessionName,
            sessionA,
            "refresh must retain the exact selected session-group alias instead of collapsing to a sibling alias"
        )
        XCTAssertEqual(model.selectedPane?.id, selectedAlias.id)
    }

    @MainActor
    func testMetadataChangesKeepSiblingAliasIdleWhenExactSessionTurnsRunning() async {
        let paneID = "%99"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"
        let birthDate = Date(timeIntervalSince1970: 1_778_822_200)
        let inventoryA = makeInventoryPane(
            paneId: paneID,
            sessionName: sessionA,
            sessionGroup: groupName,
            windowId: "@9",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let inventoryB = makeInventoryPane(
            paneId: paneID,
            sessionName: sessionB,
            sessionGroup: groupName,
            windowId: "@9",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let bootstrapA = makeManagedMetadataPane(
            paneId: paneID,
            sessionName: sessionA,
            sessionGroup: groupName,
            windowId: "@9",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Session A",
            metadataSessionKey: sessionA,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneID,
                generation: 1,
                birthTs: birthDate
            )
        )
        let bootstrapB = makeManagedMetadataPane(
            paneId: paneID,
            sessionName: sessionB,
            sessionGroup: groupName,
            windowId: "@9",
            windowIndex: 1,
            windowName: "AgtmuxTerm",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Session B",
            metadataSessionKey: sessionB,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: paneID,
                generation: 2,
                birthTs: birthDate.addingTimeInterval(1)
            )
        )
        let runningChangeA = makePaneState(
            paneId: paneID,
            sessionKey: sessionA,
            generation: 1,
            birthTs: birthDate,
            activityState: .running,
            provider: .codex
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [bootstrapA, bootstrapB], cursorSeq: 1))),
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: runningChangeA, seq: 2))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryA, inventoryB]),
                    .success([inventoryA, inventoryB]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let bootstrapApplied = await waitUntil {
            let panesBySession = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.sessionName, $0) })
            return panesBySession[sessionA]?.activityState == .idle
                && panesBySession[sessionB]?.activityState == .idle
                && panesBySession[sessionA]?.presence == .managed
                && panesBySession[sessionB]?.presence == .managed
        }
        XCTAssertTrue(bootstrapApplied)

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        let changeApplied = await waitUntil {
            let panesBySession = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.sessionName, $0) })
            return panesBySession[sessionA]?.activityState == .running
                && panesBySession[sessionB]?.activityState == .idle
        }
        XCTAssertTrue(changeApplied, "running change should only affect the exact session alias row")

        let panesBySession = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.sessionName, $0) })
        XCTAssertEqual(panesBySession[sessionA]?.provider, .codex)
        XCTAssertEqual(panesBySession[sessionB]?.provider, .codex)
        XCTAssertEqual(panesBySession[sessionB]?.activityState, .idle)
        XCTAssertEqual(panesBySession[sessionB]?.presence, .managed)
    }

    @MainActor
    func testMetadataChangesUseBootstrapSessionNameMappingWhenSessionKeyIsOpaque() async {
        let sessionName = "vm agtmux"
        let metadataSessionKey = "rollout-opaque-1"
        let birthDate = Date(timeIntervalSince1970: 1_778_822_200)
        let inventoryBootstrapPane = makeInventoryPane(
            paneId: "%70",
            sessionName: sessionName,
            windowId: "@7",
            windowName: "editor",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let inventoryChangedPane = makeInventoryPane(
            paneId: "%71",
            sessionName: sessionName,
            windowId: "@7",
            windowName: "editor",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let bootstrapPane = makeManagedMetadataPane(
            paneId: "%70",
            sessionName: sessionName,
            windowId: "@7",
            windowName: "editor",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Known pane",
            metadataSessionKey: metadataSessionKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%70",
                generation: 1,
                birthTs: birthDate
            )
        )
        let changePaneState = makePaneState(
            paneId: "%71",
            sessionKey: metadataSessionKey,
            generation: 3,
            birthTs: birthDate.addingTimeInterval(5),
            activityState: .running,
            provider: .codex
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [bootstrapPane], cursorSeq: 1))),
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: changePaneState, seq: 2))),
            ]
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryBootstrapPane, inventoryChangedPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let bootstrapApplied = await waitUntil {
            model.panes.first(where: { $0.paneId == "%70" })?.presence == .managed
        }
        XCTAssertTrue(bootstrapApplied, "sanity check: bootstrap pane should resolve before change replay")

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        let changeApplied = await waitUntil {
            guard let changedPane = model.panes.first(where: { $0.paneId == "%71" }) else { return false }
            return changedPane.presence == .managed
                && changedPane.provider == .codex
                && changedPane.activityState == .running
                && changedPane.metadataSessionKey == metadataSessionKey
        }
        XCTAssertTrue(
            changeApplied,
            "change replay must use bootstrap-derived session-name mapping instead of comparing opaque session_key to visible tmux session name"
        )
        XCTAssertEqual(model.panes.first(where: { $0.paneId == "%71" })?.sessionName, sessionName)
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
    func testMissingExactIdentityLocalDaemonIsSurfacedWhileInventoryPanesStillRender() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeMissingExactIdentitySyncV2Error())),
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
        XCTAssertTrue(surfaced, "missing exact identity must be surfaced in UI state")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue")
        }
        XCTAssertTrue(detail.contains("session_key"))

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testMissingExactIdentityInSyncV2BootstrapIsSurfacedAsIncompatible() async {
        let inventoryPane = makeInventoryPane()
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeMissingExactIdentitySyncV2Error())),
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
        XCTAssertNil(model.panes.first?.provider)

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "missing exact sync-v2 identity must surface as incompatible")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for missing exact identity")
        }
        XCTAssertTrue(
            detail.contains("ui.bootstrap.v2") || detail.contains("AGTMUX_UI_BOOTSTRAP_V2_JSON"),
            "detail must identify the sync-v2 bootstrap contract that failed"
        )
        XCTAssertTrue(detail.contains("session_key"))
    }

    @MainActor
    func testLegacyDaemonBootstrapSampleFallsBackToInventoryOnly() async {
        let inventoryA = makeInventoryPane(
            paneId: "%1",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let inventoryB = makeInventoryPane(
            paneId: "%2",
            sessionName: "vm agtmux-term",
            windowId: "@2",
            windowName: "node",
            activityState: .unknown,
            currentCmd: "node"
        )
        let client = DecodingMetadataClient(
            bootstrapJSON: makeLegacyDaemonBootstrapPayload()
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryA, inventoryB]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "legacy daemon bootstrap payload must surface incompatibility")

        let panesBySession = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.sessionName, $0) })
        XCTAssertEqual(panesBySession["vm agtmux"]?.presence, .unmanaged)
        XCTAssertNil(panesBySession["vm agtmux"]?.provider)
        XCTAssertEqual(panesBySession["vm agtmux"]?.activityState, .unknown)
        XCTAssertEqual(panesBySession["vm agtmux"]?.currentCmd, "zsh")

        XCTAssertEqual(panesBySession["vm agtmux-term"]?.presence, .unmanaged)
        XCTAssertNil(panesBySession["vm agtmux-term"]?.provider)
        XCTAssertEqual(panesBySession["vm agtmux-term"]?.activityState, .unknown)
        XCTAssertEqual(panesBySession["vm agtmux-term"]?.currentCmd, "node")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for legacy bootstrap sample")
        }
        XCTAssertTrue(detail.contains("ui.bootstrap.v2"))
        XCTAssertTrue(detail.contains("session_id"))
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
    func testHealthyBootstrapAfterIncompatibleStateRestoresManagedOverlayWithoutRelaunch() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%71",
            sessionName: "vm agtmux-term",
            windowId: "@2",
            windowName: "zsh",
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%71",
            sessionName: "vm agtmux-term",
            windowId: "@2",
            windowName: "zsh",
            provider: .codex,
            activityState: .running,
            conversationTitle: "managed recovery",
            metadataSessionKey: "vm agtmux-term",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%71",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_100)
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .failure(makeIncompatibleSyncV2Error())),
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 2))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let incompatibleSurfaced = await waitUntil {
            guard case .incompatibleSyncV2? = model.localDaemonIssue else { return false }
            return model.panes.first?.presence == .unmanaged
        }
        XCTAssertTrue(incompatibleSurfaced, "initial incompatible bootstrap must fail closed to inventory-only")

        let recovered = await waitUntilAsync(timeout: 5.0, intervalMs: 100) {
            await model.fetchAll()
            guard model.localDaemonIssue == nil else { return false }
            guard let pane = model.panes.first else { return false }
            return pane.presence == .managed
                && pane.provider == .codex
                && pane.activityState == .running
                && pane.conversationTitle == "managed recovery"
        }
        XCTAssertTrue(recovered, "a later healthy bootstrap must restore managed overlay without app relaunch")

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testEmptyBootstrapWithLiveInventoryDoesNotPrimeSyncOwnershipAndLaterHealthyBootstrapRecovers() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%71",
            sessionName: "vm agtmux-term",
            windowId: "@2",
            windowName: "zsh",
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%71",
            sessionName: "vm agtmux-term",
            windowId: "@2",
            windowName: "zsh",
            provider: .codex,
            activityState: .running,
            conversationTitle: "bootstrap ready",
            metadataSessionKey: "vm agtmux-term",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%71",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_101)
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [], cursorSeq: 0))),
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 2))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let stayedInventoryOnly = await waitUntil {
            guard model.localDaemonIssue == nil else { return false }
            guard let pane = model.panes.first else { return false }
            return pane.presence == .unmanaged && pane.provider == nil
        }
        XCTAssertTrue(
            stayedInventoryOnly,
            "inventory-present empty bootstrap must stay inventory-only instead of priming an unrecoverable sync-v2 epoch"
        )

        let recovered = await waitUntilAsync(timeout: 5.0, intervalMs: 100) {
            await model.fetchAll()
            guard model.localDaemonIssue == nil else { return false }
            guard let pane = model.panes.first else { return false }
            return pane.presence == .managed
                && pane.provider == .codex
                && pane.activityState == .running
                && pane.conversationTitle == "bootstrap ready"
        }
        XCTAssertTrue(
            recovered,
            "a later non-empty bootstrap must recover managed overlay after the transient empty bootstrap"
        )

        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1, "transient empty bootstrap should reset sync-v2 cursor ownership once")
    }

    @MainActor
    func testSlowRemoteFetchCannotOverwriteNewerLocalManagedOverlay() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%72",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%72",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            provider: .claude,
            activityState: .idle,
            conversationTitle: "newer overlay wins",
            metadataSessionKey: "vm agtmux",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%72",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_200)
            )
        )
        let remotePane = AgtmuxPane(
            source: "slow-host",
            paneId: "%501",
            sessionName: "remote-dev",
            windowId: "@50",
            windowName: "shell",
            activityState: .unknown,
            presence: .unmanaged,
            evidenceMode: .none,
            currentCmd: "zsh"
        )
        let remoteSource = RemotePaneInventorySource(
            source: "slow-host",
            fetchPanes: {
                try? await Task.sleep(for: .milliseconds(250))
                return [remotePane]
            }
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty,
            remotePaneSources: [remoteSource]
        )

        await model.fetchAll()

        let localPane = model.panes.first { $0.source == "local" }
        XCTAssertEqual(localPane?.presence, .managed, "slow remote fetch must not overwrite the newer local metadata overlay with stale inventory-only rows")
        XCTAssertEqual(localPane?.provider, .claude)
        XCTAssertEqual(localPane?.activityState, .idle)
        XCTAssertEqual(localPane?.conversationTitle, "newer overlay wins")

        let surfacedRemotePane = model.panes.first {
            $0.source == "slow-host" && $0.paneId == "%501"
        }
        XCTAssertNotNil(surfacedRemotePane, "remote rows should still publish after the slow fetch completes")
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
    func testMetadataFailureClearsPreviousOverlayInsteadOfKeepingStaleManagedState() async {
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
            .unmanaged,
            "metadata timeout/failure must clear stale overlay rather than keep potentially reused managed state"
        )
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .unknown)
        XCTAssertNil(model.localDaemonIssue)
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testIncompatibleBootstrapAfterResyncClearsPreviouslyValidOverlayBeforeNextPublish() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%7",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%7",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            provider: .codex,
            activityState: .running,
            conversationTitle: "stale managed row",
            metadataSessionKey: "vm agtmux",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%7",
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1))),
                BootstrapStep(
                    delayMs: 20,
                    result: .failure(
                        DaemonError.parseError(
                            "RPC ui.bootstrap.v2 parse failed: " +
                            "sync-v2 pane payload contains legacy identity field 'session_id'"
                        )
                    )
                ),
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
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryPane]),
                    .success([inventoryPane]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let firstOverlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
                && model.panes.first?.provider == .codex
                && model.panes.first?.activityState == .running
        }
        XCTAssertTrue(firstOverlayApplied, "sanity check: valid bootstrap should publish managed overlay first")

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        let inventoryOnly = await waitUntil(timeout: 5.0, intervalMs: 50) {
            guard let pane = model.panes.first else { return false }
            guard case .incompatibleSyncV2? = model.localDaemonIssue else { return false }
            return pane.presence == .unmanaged
                && pane.provider == nil
                && pane.activityState == .unknown
                && pane.currentCmd == "zsh"
        }
        XCTAssertTrue(
            inventoryOnly,
            "an incompatible resync bootstrap must clear stale managed overlay before the next published sidebar truth"
        )

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue after invalid resync bootstrap")
        }
        XCTAssertTrue(detail.contains("session_id"))
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 2, "resync + incompatible bootstrap should reset cursor ownership twice")
    }

    @MainActor
    func testMixedEraBootstrapPayloadWithLegacySessionIDIsRejectedEvenWhenExactIdentityIsPresent() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%1",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = DecodingMetadataClient(
            bootstrapJSON: makeMixedEraBootstrapPayloadWithLegacySessionID()
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "mixed-era bootstrap payload must surface incompatibility")

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .unknown)
        XCTAssertEqual(model.panes.first?.currentCmd, "zsh")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for mixed-era bootstrap sample")
        }
        XCTAssertTrue(detail.contains("ui.bootstrap.v2"))
        XCTAssertTrue(detail.contains("session_id"))
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testLiveMarch7MixedEraBootstrapSampleWithOrphanRowsFailsClosedToInventoryOnly() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%1",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "zsh",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = DecodingMetadataClient(
            bootstrapJSON: makeLiveMarch7MixedEraBootstrapPayloadWithOrphanManagedRows()
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "live March 7 mixed-era sample must surface incompatibility")

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .unknown)
        XCTAssertEqual(model.panes.first?.currentCmd, "zsh")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for live March 7 mixed-era sample")
        }
        XCTAssertTrue(detail.contains("session_id"))
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testLiveMarch8BootstrapSampleWithNullExactLocationFieldsFailsClosedAndSurfacesIncompatibleDaemon() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%1",
            sessionName: "vm agtmux",
            windowId: "@1",
            windowName: "node",
            activityState: .unknown,
            currentCmd: "node"
        )
        let client = DecodingMetadataClient(
            bootstrapJSON: makeLiveMarch8BootstrapPayloadWithNullExactLocationFields()
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "live March 8 bootstrap sample must surface incompatibility")

        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .unknown)
        XCTAssertEqual(model.panes.first?.currentCmd, "node")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for null exact-location bootstrap sample")
        }
        XCTAssertTrue(detail.contains("ui.bootstrap.v2"))
        XCTAssertTrue(
            detail.contains("session_name") || detail.contains("window_id"),
            "detail must identify the missing exact-location field instead of surfacing only a generic decode failure"
        )
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testBootstrapLocationCollisionFailsClosedForWholeLocalMetadataEpoch() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1",
            windowName: "zsh",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let metadataA = makeManagedMetadataPane(
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1",
            provider: .codex,
            activityState: .running,
            conversationTitle: "A",
            metadataSessionKey: "shared",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%1",
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )
        let metadataB = makeManagedMetadataPane(
            paneId: "%1",
            sessionName: "shared",
            windowId: "@1",
            provider: .claude,
            activityState: .idle,
            conversationTitle: "B",
            metadataSessionKey: "shared",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%1",
                generation: 2,
                birthTs: Date(timeIntervalSince1970: 1_778_822_260)
            )
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(
                    delayMs: 20,
                    result: .success(makeBootstrap(panes: [metadataA, metadataB], cursorSeq: 1))
                ),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let surfaced = await waitUntil {
            model.localDaemonIssue != nil
        }
        XCTAssertTrue(surfaced, "bootstrap location collisions must surface an incompatible local metadata epoch")
        XCTAssertEqual(model.panes.count, 1)
        XCTAssertEqual(model.panes.first?.presence, .unmanaged)
        XCTAssertNil(model.panes.first?.provider)
        XCTAssertEqual(model.panes.first?.activityState, .unknown)
        XCTAssertEqual(model.panes.first?.currentCmd, "zsh")

        guard case let .incompatibleSyncV2(detail)? = model.localDaemonIssue else {
            return XCTFail("expected incompatible local daemon issue for bootstrap location collision")
        }
        XCTAssertTrue(detail.contains("ui.bootstrap.v2"))
        XCTAssertTrue(detail.contains("ambiguous exact pane location"))
        let resetCount = await client.resets()
        XCTAssertEqual(resetCount, 1)
    }

    @MainActor
    func testMetadataChangeWithMismatchedPaneInstanceIDDoesNotRetargetCurrentExactPane() async {
        let birthA = Date(timeIntervalSince1970: 1_778_822_200)
        let birthB = birthA.addingTimeInterval(10)
        let inventoryPane = makeInventoryPane(
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let currentMetadata = makeManagedMetadataPane(
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Current",
            metadataSessionKey: "dev",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%101",
                generation: 2,
                birthTs: birthB
            )
        )
        let staleChange = makePaneState(
            paneId: "%101",
            sessionKey: "dev",
            generation: 1,
            birthTs: birthA,
            activityState: .running,
            provider: .claude
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [currentMetadata], cursorSeq: 1))),
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: staleChange, seq: 2))),
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryPane]),
                    .success([inventoryPane]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let bootstrapApplied = await waitUntil {
            model.panes.first?.provider == .codex && model.panes.first?.activityState == .idle
        }
        XCTAssertTrue(bootstrapApplied)

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            model.panes.first?.provider,
            .codex,
            "stale pane-state changes must not overwrite the current pane when pane_instance_id mismatches"
        )
        XCTAssertEqual(model.panes.first?.activityState, .idle)
        XCTAssertEqual(model.panes.first?.conversationTitle, "Current")
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

    // MARK: - T-108 regressions: opaque session_key vs session_name

    /// Bootstrap overlay must be applied even when the daemon's opaque session_key differs
    /// from the visible tmux session_name.  Regression for Bug 1 in mergeLocalInventory where
    /// `metadataSessionKey == sessionName` was incorrectly required before applying the overlay.
    @MainActor
    func testBootstrapOverlayAppliesWhenOpaqueSessionKeyDiffersFromSessionName() async {
        let opaqueKey = "sk-opaque-uuid-42"   // deliberately != sessionName "dev"
        let inventoryPane = makeInventoryPane(
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%101",
            sessionName: "dev",
            windowId: "@11",
            provider: .codex,
            activityState: .running,
            conversationTitle: "Opaque Key Work",
            metadataSessionKey: opaqueKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%101",
                generation: 1,
                birthTs: Date(timeIntervalSince1970: 1_778_822_200)
            )
        )

        let model = AppViewModel(
            localClient: StubMetadataClient(
                bootstrapSteps: [BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane])))]
            ),
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let overlayApplied = await waitUntil {
            model.panes.first?.presence == .managed
        }

        XCTAssertTrue(
            overlayApplied,
            "bootstrap overlay must apply when opaque session_key ('\\(opaqueKey)') differs from session_name ('dev')"
        )
        XCTAssertEqual(model.panes.first?.provider, .codex)
        XCTAssertEqual(model.panes.first?.activityState, .running)
        XCTAssertEqual(model.panes.first?.sessionName, "dev",
                       "inventory session_name must not be replaced by the opaque session_key")
        XCTAssertEqual(model.panes.first?.metadataSessionKey, opaqueKey)
        XCTAssertNil(model.localDaemonIssue)
    }

    /// Changes overlay must be applied after bootstrap when session_key is opaque.
    /// The cache-path in metadataBasePane correlates by metadataSessionKey (opaque key),
    /// not by sessionName, so the change must reach the right pane.
    @MainActor
    func testChangesOverlayAppliesAfterBootstrapWithOpaqueSessionKey() async {
        let opaqueKey = "sk-opaque-uuid-77"
        let birthTs = Date(timeIntervalSince1970: 1_778_822_100)
        let inventoryPane = makeInventoryPane(
            paneId: "%202",
            sessionName: "work",
            windowId: "@22",
            activityState: .idle,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%202",
            sessionName: "work",
            windowId: "@22",
            provider: .claude,
            activityState: .idle,
            conversationTitle: "Bootstrap Title",
            metadataSessionKey: opaqueKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%202",
                generation: 3,
                birthTs: birthTs
            )
        )
        let runningChange = makePaneState(
            paneId: "%202",
            sessionKey: opaqueKey,   // same opaque key as bootstrap
            generation: 3,
            birthTs: birthTs,
            activityState: .running,
            provider: .claude
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1)))
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: runningChange, seq: 2)))
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryPane]),
                    .success([inventoryPane]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let bootstrapApplied = await waitUntil {
            model.panes.first?.presence == .managed && model.panes.first?.activityState == .idle
        }
        XCTAssertTrue(bootstrapApplied, "bootstrap overlay must have applied before changes test")

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        let changeApplied = await waitUntil {
            model.panes.first?.activityState == .running
        }
        XCTAssertTrue(
            changeApplied,
            "change must be applied via opaque session_key cache lookup, not session_name comparison"
        )
        XCTAssertEqual(model.panes.first?.provider, .claude)
        XCTAssertEqual(model.panes.first?.presence, .managed)
        XCTAssertEqual(model.panes.first?.sessionName, "work")
        XCTAssertNil(model.localDaemonIssue)
    }

    /// When daemon truth clears a managed pane back to an unmanaged shell, the next publish
    /// must not keep stale provider/activity/title decorations alive on that exact row.
    @MainActor
    func testManagedExitChangeClearsStaleProviderActivityAndTitleOnNextPublish() async {
        let sessionKey = "opaque-managed-exit"
        let birthTs = Date(timeIntervalSince1970: 1_778_822_300)
        let inventoryPane = makeInventoryPane(
            paneId: "%303",
            sessionName: "work",
            windowId: "@33",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%303",
            sessionName: "work",
            windowId: "@33",
            provider: .codex,
            activityState: .running,
            conversationTitle: "Managed work",
            metadataSessionKey: sessionKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%303",
                generation: 7,
                birthTs: birthTs
            )
        )
        let exitChange = makePaneState(
            paneId: "%303",
            sessionKey: sessionKey,
            generation: 7,
            birthTs: birthTs,
            presence: .unmanaged,
            evidenceMode: .none,
            activityState: .unknown,
            provider: nil,
            updatedAt: Date(timeIntervalSince1970: 1_778_822_360)
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1)))
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: exitChange, seq: 2)))
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryPane]),
                    .success([inventoryPane]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let managedApplied = await waitUntil {
            model.panes.first?.presence == .managed
                && model.panes.first?.provider == .codex
                && model.panes.first?.conversationTitle == "Managed work"
        }
        XCTAssertTrue(managedApplied, "sanity check: managed overlay must apply before exit-change regression")

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        let cleared = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.presence == .unmanaged
                && pane.provider == nil
                && pane.activityState == .unknown
                && pane.conversationTitle == nil
                && pane.currentCmd == "zsh"
        }
        XCTAssertTrue(
            cleared,
            "managed exit changes must clear stale provider/activity/title and restore shell truth on the next publish"
        )
        XCTAssertNil(model.localDaemonIssue)
    }

    /// A change whose session_key happens to equal the visible session_name of an inventory
    /// pane must NOT be applied when the bootstrap cache uses a different opaque session_key.
    /// Regression for Bug 2 in metadataBasePane where the inventory fallback incorrectly
    /// compared sessionName to sessionKey.
    @MainActor
    func testChangesWithSessionNameAsKeyDoNotMatchCachedPaneWithOpaqueKey() async {
        let opaqueKey = "sk-opaque-uuid-99"
        let sessionName = "prod"              // same as rogue change's sessionKey below
        let birthTs = Date(timeIntervalSince1970: 1_778_822_100)
        let inventoryPane = makeInventoryPane(
            paneId: "%303",
            sessionName: sessionName,
            windowId: "@33",
            activityState: .idle,
            currentCmd: "zsh"
        )
        // Bootstrap uses opaque key, not session_name
        let metadataPane = makeManagedMetadataPane(
            paneId: "%303",
            sessionName: sessionName,
            windowId: "@33",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Stable Title",
            metadataSessionKey: opaqueKey,
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%303",
                generation: 5,
                birthTs: birthTs
            )
        )
        // Rogue change: sessionKey == session_name (not the opaque key in the cache)
        let rogueChange = makePaneState(
            paneId: "%303",
            sessionKey: sessionName,   // "prod", not "sk-opaque-uuid-99"
            generation: 5,
            birthTs: birthTs,
            activityState: .running,
            provider: .codex
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1)))
            ],
            changesSteps: [
                ChangesStep(delayMs: 20, result: .success(makeChangesResponse(paneState: rogueChange, seq: 2)))
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(
                steps: [
                    .success([inventoryPane]),
                    .success([inventoryPane]),
                ]
            ),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let bootstrapApplied = await waitUntil {
            model.panes.first?.presence == .managed && model.panes.first?.activityState == .idle
        }
        XCTAssertTrue(bootstrapApplied, "bootstrap overlay must have applied before rogue-change test")

        try? await Task.sleep(for: .milliseconds(1_100))
        await model.fetchAll()

        // Wait long enough for any async change application that would be wrong
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            model.panes.first?.activityState, .idle,
            "rogue change with sessionKey==sessionName must be dropped when cache uses opaque key '\(opaqueKey)'"
        )
        XCTAssertEqual(model.panes.first?.presence, .managed)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testLiveOpaqueSessionKeyBootstrapDoesNotLeakManagedOverlayOntoUnrelatedLocalRows() async {
        let inventory = [
            makeInventoryPane(
                paneId: "%0",
                sessionName: "utm-main",
                windowId: "@0",
                windowName: "zsh",
                currentCmd: "zsh"
            ),
            makeInventoryPane(
                paneId: "%1",
                sessionName: "vm agtmux",
                windowId: "@1",
                windowName: "node",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%2",
                sessionName: "vm agtmux-term",
                windowId: "@2",
                windowName: "node",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%4",
                sessionName: "vm agtmux-term",
                windowId: "@2",
                windowName: "node",
                currentCmd: "AgtmuxTerm"
            ),
            makeInventoryPane(
                paneId: "%5",
                sessionName: "vm agtmux-term",
                windowId: "@2",
                windowName: "node",
                currentCmd: "zsh"
            ),
            makeInventoryPane(
                paneId: "%6",
                sessionName: "vm agtmux-term",
                windowId: "@3",
                windowName: "zsh",
                currentCmd: "zsh"
            ),
        ]
        let bootstrap = makeBootstrap(
            panes: [
                makeManagedMetadataPane(
                    paneId: "%1",
                    sessionName: "vm agtmux",
                    windowId: "@1",
                    windowName: "node",
                    provider: .claude,
                    activityState: .idle,
                    conversationTitle: "/tmp/agtmux-v2-a3-exact-identity-handover-20260307.md",
                    metadataSessionKey: "59bafe97-9f5b-410b-ba6a-6d21b2d4b8ab",
                    paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                        paneId: "%1",
                        generation: 0,
                        birthTs: Date(timeIntervalSince1970: 1_778_229_012.320609)
                    )
                ),
                makeManagedMetadataPane(
                    paneId: "%2",
                    sessionName: "vm agtmux-term",
                    windowId: "@2",
                    windowName: "node",
                    provider: .codex,
                    activityState: .running,
                    conversationTitle: "/tmp/agtmux-cockpit-workspace-design-20260306/07-implementation-handover.md",
                    metadataSessionKey: "rollout-2026-03-06T02-21-55-019cc2ab-0b97-7a93-803e-c4a064cf67f7",
                    paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                        paneId: "%2",
                        generation: 0,
                        birthTs: Date(timeIntervalSince1970: 1_778_229_012.320609)
                    )
                ),
            ],
            cursorSeq: 1_245
        )
        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(bootstrap))
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: inventory),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            model.panes.count == inventory.count
                && model.panes.contains(where: {
                    $0.sessionName == "vm agtmux"
                        && $0.paneId == "%1"
                        && $0.provider == .claude
                        && $0.activityState == .idle
                })
                && model.panes.contains(where: {
                    $0.sessionName == "vm agtmux-term"
                        && $0.paneId == "%2"
                        && $0.provider == .codex
                        && $0.activityState == .running
                })
        }
        XCTAssertTrue(overlayApplied, "managed rows from the live opaque-session-key sample must still enrich their exact inventory rows")

        let panesByID = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.id, $0) })

        let utmMain = panesByID["local:utm-main:%0"]
        XCTAssertEqual(utmMain?.presence, .unmanaged)
        XCTAssertNil(utmMain?.provider)
        XCTAssertEqual(utmMain?.activityState, .unknown)
        XCTAssertEqual(utmMain?.currentCmd, "zsh")
        XCTAssertEqual(utmMain?.windowName, "zsh")

        let vmAgtmux = panesByID["local:vm agtmux:%1"]
        XCTAssertEqual(vmAgtmux?.presence, .managed)
        XCTAssertEqual(vmAgtmux?.provider, .claude)
        XCTAssertEqual(vmAgtmux?.activityState, .idle)
        XCTAssertEqual(vmAgtmux?.metadataSessionKey, "59bafe97-9f5b-410b-ba6a-6d21b2d4b8ab")

        let vmAgtmuxTermManaged = panesByID["local:vm agtmux-term:%2"]
        XCTAssertEqual(vmAgtmuxTermManaged?.presence, .managed)
        XCTAssertEqual(vmAgtmuxTermManaged?.provider, .codex)
        XCTAssertEqual(vmAgtmuxTermManaged?.activityState, .running)
        XCTAssertEqual(
            vmAgtmuxTermManaged?.metadataSessionKey,
            "rollout-2026-03-06T02-21-55-019cc2ab-0b97-7a93-803e-c4a064cf67f7"
        )

        let vmAgtmuxTermApp = panesByID["local:vm agtmux-term:%4"]
        XCTAssertEqual(vmAgtmuxTermApp?.presence, .unmanaged)
        XCTAssertNil(vmAgtmuxTermApp?.provider)
        XCTAssertEqual(vmAgtmuxTermApp?.activityState, .unknown)
        XCTAssertEqual(vmAgtmuxTermApp?.currentCmd, "AgtmuxTerm")
        XCTAssertEqual(vmAgtmuxTermApp?.windowName, "node")

        let vmAgtmuxTermShell = panesByID["local:vm agtmux-term:%5"]
        XCTAssertEqual(vmAgtmuxTermShell?.presence, .unmanaged)
        XCTAssertNil(vmAgtmuxTermShell?.provider)
        XCTAssertEqual(vmAgtmuxTermShell?.activityState, .unknown)
        XCTAssertEqual(vmAgtmuxTermShell?.currentCmd, "zsh")

        let vmAgtmuxTermWindowTwo = panesByID["local:vm agtmux-term:%6"]
        XCTAssertEqual(vmAgtmuxTermWindowTwo?.presence, .unmanaged)
        XCTAssertNil(vmAgtmuxTermWindowTwo?.provider)
        XCTAssertEqual(vmAgtmuxTermWindowTwo?.activityState, .unknown)
        XCTAssertEqual(vmAgtmuxTermWindowTwo?.currentCmd, "zsh")
        XCTAssertEqual(vmAgtmuxTermWindowTwo?.windowName, "zsh")
    }

    @MainActor
    func testWaitingApprovalManagedRowSurfacesAttentionCountAndFilterWithoutBleed() async {
        let inventory = [
            makeInventoryPane(
                paneId: "%50",
                sessionName: "approval-session",
                windowId: "@5",
                windowIndex: 1,
                windowName: "claude",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%51",
                sessionName: "approval-session",
                windowId: "@5",
                windowIndex: 1,
                windowName: "codex",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%52",
                sessionName: "approval-session",
                windowId: "@6",
                windowIndex: 2,
                windowName: "zsh",
                currentCmd: "zsh"
            ),
        ]

        let waitingApprovalPane = makeManagedMetadataPane(
            paneId: "%50",
            sessionName: "approval-session",
            windowId: "@5",
            windowIndex: 1,
            windowName: "claude",
            provider: .claude,
            activityState: .waitingApproval,
            conversationTitle: "Approve tool call",
            metadataSessionKey: "approval-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%50",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_000)
            )
        )
        let idleManagedPane = makeManagedMetadataPane(
            paneId: "%51",
            sessionName: "approval-session",
            windowId: "@5",
            windowIndex: 1,
            windowName: "codex",
            provider: .codex,
            activityState: .idle,
            conversationTitle: "Idle sibling",
            metadataSessionKey: "idle-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%51",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_001)
            )
        )

        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(
                    delayMs: 20,
                    result: .success(makeBootstrap(panes: [waitingApprovalPane, idleManagedPane], cursorSeq: 5))
                )
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: inventory),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            model.panes.count == inventory.count
                && model.panes.contains(where: {
                    $0.paneId == "%50"
                        && $0.provider == .claude
                        && $0.activityState == .waitingApproval
                        && $0.needsAttention
                })
                && model.panes.contains(where: {
                    $0.paneId == "%51"
                        && $0.provider == .codex
                        && $0.activityState == .idle
                        && !$0.needsAttention
                })
        }
        XCTAssertTrue(overlayApplied, "waiting_approval and idle sibling rows must both reflect exact metadata truth")

        XCTAssertEqual(model.attentionCount, 1, "only the waiting_approval row must contribute to attention count")

        model.statusFilter = .attention
        let filteredPaneIDs = Set(model.filteredPanes.map(\.paneId))
        XCTAssertEqual(filteredPaneIDs, Set(["%50"]), "attention filter must keep only the waiting_approval row")

        let panesByID = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.paneId, $0) })
        XCTAssertEqual(panesByID["%50"]?.activityState, .waitingApproval)
        XCTAssertTrue(panesByID["%50"]?.needsAttention ?? false)
        XCTAssertEqual(panesByID["%51"]?.activityState, .idle)
        XCTAssertFalse(panesByID["%51"]?.needsAttention ?? true)
        XCTAssertEqual(panesByID["%52"]?.presence, .unmanaged)
        XCTAssertFalse(panesByID["%52"]?.needsAttention ?? true)
    }

    @MainActor
    func testWaitingInputManagedRowSurfacesAttentionCountAndFilterWithoutBleed() async {
        let inventory = [
            makeInventoryPane(
                paneId: "%60",
                sessionName: "waiting-input-session",
                windowId: "@7",
                windowIndex: 1,
                windowName: "codex",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%61",
                sessionName: "waiting-input-session",
                windowId: "@7",
                windowIndex: 1,
                windowName: "claude",
                currentCmd: "node"
            ),
            makeInventoryPane(
                paneId: "%62",
                sessionName: "waiting-input-session",
                windowId: "@8",
                windowIndex: 2,
                windowName: "zsh",
                currentCmd: "zsh"
            ),
        ]

        let waitingInputPane = makeManagedMetadataPane(
            paneId: "%60",
            sessionName: "waiting-input-session",
            windowId: "@7",
            windowIndex: 1,
            windowName: "codex",
            provider: .codex,
            activityState: .waitingInput,
            conversationTitle: "Need more input",
            metadataSessionKey: "waiting-input-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%60",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_100)
            )
        )
        let idleSiblingPane = makeManagedMetadataPane(
            paneId: "%61",
            sessionName: "waiting-input-session",
            windowId: "@7",
            windowIndex: 1,
            windowName: "claude",
            provider: .claude,
            activityState: .idle,
            conversationTitle: "Idle sibling",
            metadataSessionKey: "idle-sibling-key",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%61",
                generation: 0,
                birthTs: Date(timeIntervalSince1970: 1_778_900_101)
            )
        )

        let client = StubMetadataClient(
            bootstrapSteps: [
                BootstrapStep(
                    delayMs: 20,
                    result: .success(makeBootstrap(panes: [waitingInputPane, idleSiblingPane], cursorSeq: 6))
                )
            ]
        )

        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: inventory),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            model.panes.count == inventory.count
                && model.panes.contains(where: {
                    $0.paneId == "%60"
                        && $0.provider == .codex
                        && $0.activityState == .waitingInput
                        && $0.needsAttention
                })
                && model.panes.contains(where: {
                    $0.paneId == "%61"
                        && $0.provider == .claude
                        && $0.activityState == .idle
                        && !$0.needsAttention
                })
        }
        XCTAssertTrue(overlayApplied, "waiting_input and idle sibling rows must both reflect exact metadata truth")

        XCTAssertEqual(model.attentionCount, 1, "only the waiting_input row must contribute to attention count")

        model.statusFilter = .attention
        let filteredPaneIDs = Set(model.filteredPanes.map(\.paneId))
        XCTAssertEqual(filteredPaneIDs, Set(["%60"]), "attention filter must keep only the waiting_input row")

        let panesByID = Dictionary(uniqueKeysWithValues: model.panes.map { ($0.paneId, $0) })
        XCTAssertEqual(panesByID["%60"]?.activityState, .waitingInput)
        XCTAssertTrue(panesByID["%60"]?.needsAttention ?? false)
        XCTAssertEqual(panesByID["%61"]?.activityState, .idle)
        XCTAssertFalse(panesByID["%61"]?.needsAttention ?? true)
        XCTAssertEqual(panesByID["%62"]?.presence, .unmanaged)
        XCTAssertFalse(panesByID["%62"]?.needsAttention ?? true)
    }

    private func loadSyncV3Fixture(named name: String) throws -> AgtmuxSyncV3Bootstrap {
        let fixtureRoot: URL
        if let override = ProcessInfo.processInfo.environment["AGTMUX_SYNC_V3_FIXTURES_ROOT"],
           !override.isEmpty {
            fixtureRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            fixtureRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("agtmux", isDirectory: true)
                .appendingPathComponent("fixtures", isDirectory: true)
                .appendingPathComponent("sync-v3", isDirectory: true)
        }
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("\(name).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgtmuxSyncV3Bootstrap.self, from: data)
    }

    @MainActor
    func testBootstrapV3ManagedFixtureOverlaysExactRowAndRetainsOpaqueSessionKey() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-running")
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: []
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.paneId == "%12"
                && pane.sessionName == "workbench"
                && pane.windowId == "@5"
                && pane.provider == .codex
                && pane.presence == .managed
                && pane.activityState == .running
                && pane.metadataSessionKey == "codex:%12"
                && pane.paneInstanceID?.generation == 7
                && pane.currentCmd == "zsh"
        }
        XCTAssertTrue(overlayApplied, "bootstrap-v3 must overlay the exact local row and preserve the opaque session_key for later delta correlation")
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testBootstrapV3WaitingApprovalMapsToLegacyAttentionOnExactRow() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-waiting-approval")
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: []
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let approvalApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.provider == .codex
                && pane.presence == .managed
                && pane.activityState == .waitingApproval
                && pane.needsAttention
        }
        XCTAssertTrue(approvalApplied, "bootstrap-v3 waiting_approval truth must bridge to the exact local row and preserve legacy attention semantics until full v3 presentation cutover")
        XCTAssertEqual(model.attentionCount, 1)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testBootstrapV3CompletedIdleFeedsPresentationWithoutAttention() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-completed-idle")
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: []
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let presentationApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return model.panePresentation(for: pane)?.primaryState == .completedIdle
                && model.panePrimaryState(for: pane) == .completedIdle
                && model.paneNeedsAttention(pane) == false
        }

        XCTAssertTrue(presentationApplied, "bootstrap-v3 completed+idle truth must remain in local presentation state without inflating attention")
        XCTAssertEqual(model.attentionCount, 0)
        model.statusFilter = .attention
        XCTAssertTrue(model.filteredPanes.isEmpty)
        model.statusFilter = .managed
        XCTAssertEqual(model.filteredPanes.count, 1)
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testBootstrapV3MethodNotFoundFallsBackToSyncV2BootstrapWithoutBreakingOverlay() async {
        let inventoryPane = makeInventoryPane(
            paneId: "%303",
            sessionName: "work",
            windowId: "@33",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%303",
            sessionName: "work",
            windowId: "@33",
            provider: .codex,
            activityState: .running,
            conversationTitle: "Fallback to v2",
            metadataSessionKey: "opaque-v2-fallback",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%303",
                generation: 9,
                birthTs: Date(timeIntervalSince1970: 1_778_930_000)
            )
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(
                    delayMs: 20,
                    result: .failure(LocalMetadataClientError.unsupportedMethod("ui.bootstrap.v3"))
                )
            ],
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 1)))
            ]
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()

        let overlayApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.provider == .codex
                && pane.presence == .managed
                && pane.activityState == .running
                && pane.metadataSessionKey == "opaque-v2-fallback"
        }
        XCTAssertTrue(overlayApplied, "bootstrap-v3 method-not-found must fall back to the intact sync-v2 bootstrap path")
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testBootstrapV3ChangesV3UpsertUpdatesExactRowWithoutWeakeningIdentity() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-running")
        let updated = try loadSyncV3Fixture(named: "codex-waiting-approval")
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: [],
            changesV3Steps: [
                ChangesV3Step(delayMs: 20, result: .success(makeChangesV3Response(
                    pane: try XCTUnwrap(updated.panes.first),
                    seq: 41
                )))
            ]
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialOverlayApplied = await waitUntil {
            model.panes.first?.activityState == .running
        }
        XCTAssertTrue(initialOverlayApplied)

        try? await Task.sleep(for: .milliseconds(1100))
        await model.fetchAll()

        let updateApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.paneId == "%12"
                && pane.sessionName == "workbench"
                && pane.windowId == "@5"
                && pane.metadataSessionKey == "codex:%12"
                && pane.paneInstanceID?.generation == 7
                && pane.provider == .codex
                && pane.activityState == .waitingApproval
                && pane.needsAttention
                && model.panePresentation(for: pane)?.primaryState == .waitingApproval
        }

        XCTAssertTrue(updateApplied, "changes-v3 upsert must update the existing exact row without weakening identity requirements")
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testBootstrapV3ChangesV3RemoveClearsOverlayAndReturnsToInventoryTruth() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-running")
        let pane = try XCTUnwrap(bootstrap.panes.first)
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: [],
            changesV3Steps: [
                ChangesV3Step(delayMs: 20, result: .success(makeChangesV3Response(
                    pane: pane,
                    kind: .remove,
                    seq: 42,
                    fieldGroups: [.presence]
                )))
            ]
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialManagedOverlayApplied = await waitUntil {
            model.panes.first?.provider == .codex
        }
        XCTAssertTrue(initialManagedOverlayApplied)

        try? await Task.sleep(for: .milliseconds(1100))
        await model.fetchAll()

        let overlayCleared = await waitUntil {
            guard let visiblePane = model.panes.first else { return false }
            return visiblePane.paneId == "%12"
                && visiblePane.provider == nil
                && visiblePane.presence == .unmanaged
                && visiblePane.activityState == .unknown
                && visiblePane.metadataSessionKey == nil
                && visiblePane.currentCmd == "zsh"
                && model.panePresentation(for: visiblePane) == nil
        }

        XCTAssertTrue(overlayCleared, "changes-v3 remove must drop the cached overlay and return to inventory-only truth")
        XCTAssertNil(model.localDaemonIssue)
    }

    @MainActor
    func testChangesV3MethodNotFoundFallsBackToSyncV2AfterBootstrapV3() async throws {
        let bootstrap = try loadSyncV3Fixture(named: "codex-running")
        let inventoryPane = makeInventoryPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .unknown,
            currentCmd: "zsh"
        )
        let metadataPane = makeManagedMetadataPane(
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            provider: .codex,
            activityState: .waitingApproval,
            conversationTitle: "sync-v2 fallback",
            metadataSessionKey: "opaque-v2-after-v3",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%12",
                generation: 7,
                birthTs: Date(timeIntervalSince1970: 1_778_822_994)
            )
        )
        let client = StubMetadataClient(
            bootstrapV3Steps: [
                BootstrapV3Step(delayMs: 20, result: .success(bootstrap))
            ],
            bootstrapSteps: [
                BootstrapStep(delayMs: 20, result: .success(makeBootstrap(panes: [metadataPane], cursorSeq: 9)))
            ],
            changesV3Steps: [
                ChangesV3Step(
                    delayMs: 20,
                    result: .failure(LocalMetadataClientError.unsupportedMethod("ui.changes.v3"))
                )
            ]
        )
        let model = AppViewModel(
            localClient: client,
            localInventoryClient: StubInventoryClient(panes: [inventoryPane]),
            hostsConfig: .empty
        )

        await model.fetchAll()
        let initialV3OverlayApplied = await waitUntil {
            model.panes.first?.metadataSessionKey == "codex:%12"
        }
        XCTAssertTrue(initialV3OverlayApplied)

        try? await Task.sleep(for: .milliseconds(1100))
        await model.fetchAll()

        let fallbackApplied = await waitUntil {
            guard let pane = model.panes.first else { return false }
            return pane.provider == .codex
                && pane.activityState == .waitingApproval
                && pane.metadataSessionKey == "opaque-v2-after-v3"
                && model.panePresentation(for: pane) == nil
        }

        let resetCount = await client.resets()

        XCTAssertTrue(fallbackApplied, "unsupported ui.changes.v3 must drop back to the intact sync-v2 live path")
        XCTAssertEqual(resetCount, 1)
        XCTAssertNil(model.localDaemonIssue)
    }
}
