import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalMetadataOverlayStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBootstrapCachesBuildExactV3MetadataAndPresentation() throws {
        let snapshot = makeV3Snapshot(
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneID: "%1",
            paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 7),
            provider: .codex,
            presence: .managed,
            threadLifecycle: .active,
            blocking: .waitingApproval,
            execution: .toolRunning,
            attentionKinds: [.approval],
            unresolvedCount: 1
        )
        let store = makeStore()

        let cache = try store.bootstrapCaches(
            from: AgtmuxSyncV3Bootstrap(
                version: 3,
                panes: [snapshot],
                generatedAt: now,
                replayCursor: AgtmuxSyncV3Cursor(seq: 12)
            )
        )

        let key = "local:visible-session:@1:%1"
        XCTAssertEqual(cache.metadataByPaneKey[key]?.metadataSessionKey, "opaque-session-key")
        XCTAssertEqual(cache.metadataByPaneKey[key]?.paneInstanceID, makeV2PaneInstanceID(paneID: "%1", generation: 7))
        XCTAssertEqual(cache.presentationByPaneKey[key]?.primaryState, .waitingApproval)
        XCTAssertEqual(cache.presentationByPaneKey[key]?.freshnessState, .fresh)
    }

    func testApplyV2ChangesUsesCachedExactBaseWhenAvailable() {
        let cachedBase = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 2),
            conversationTitle: "Keep Me",
            currentPath: "/cached",
            gitBranch: "main",
            currentCmd: "zsh"
        )
        let inventoryBase = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            currentPath: "/inventory",
            currentCmd: "tmux"
        )
        let store = makeStore(
            inventory: [inventoryBase],
            metadataByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedBase): cachedBase]
        )
        let payload = AgtmuxSyncV2Changes(
            epoch: 1,
            changes: [
                AgtmuxSyncV2ChangeRef(
                    seq: 10,
                    sessionKey: "opaque-session-key",
                    paneId: "%1",
                    timestamp: now,
                    pane: AgtmuxSyncV2PaneState(
                        paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 2),
                        presence: .managed,
                        evidenceMode: .deterministic,
                        activityState: .running,
                        provider: .codex,
                        sessionKey: "opaque-session-key",
                        updatedAt: now
                    )
                )
            ],
            fromSeq: 10,
            toSeq: 10,
            nextCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 10)
        )

        let nextCache = store.apply(payload)
        let key = "local:visible-session:@1:%1"

        XCTAssertEqual(nextCache[key]?.currentPath, "/cached")
        XCTAssertEqual(nextCache[key]?.conversationTitle, "Keep Me")
        XCTAssertEqual(nextCache[key]?.provider, .codex)
        XCTAssertEqual(nextCache[key]?.activityState, .running)
    }

    func testApplyV2ChangesUnmanagedPrefersInventoryBaseResolvedFromVisibleSessionKey() {
        let cachedBase = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 1),
            currentPath: "/cached",
            currentCmd: "codex"
        )
        let inventoryBase = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            currentPath: "/inventory",
            currentCmd: "zsh"
        )
        let store = makeStore(
            inventory: [inventoryBase],
            metadataByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedBase): cachedBase]
        )
        let payload = AgtmuxSyncV2Changes(
            epoch: 1,
            changes: [
                AgtmuxSyncV2ChangeRef(
                    seq: 11,
                    sessionKey: "opaque-session-key",
                    paneId: "%1",
                    timestamp: now,
                    pane: AgtmuxSyncV2PaneState(
                        paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 3),
                        presence: .unmanaged,
                        evidenceMode: .none,
                        activityState: .idle,
                        provider: nil,
                        sessionKey: "opaque-session-key",
                        updatedAt: now
                    )
                )
            ],
            fromSeq: 11,
            toSeq: 11,
            nextCursor: AgtmuxSyncV2Cursor(epoch: 1, seq: 11)
        )

        let nextCache = store.apply(payload)
        let key = "local:visible-session:@1:%1"

        XCTAssertEqual(nextCache[key]?.currentPath, "/inventory")
        XCTAssertEqual(nextCache[key]?.currentCmd, "zsh")
        XCTAssertEqual(nextCache[key]?.presence, .unmanaged)
        XCTAssertNil(nextCache[key]?.provider)
    }

    func testApplyV3ChangesUpsertAndRemoveMaintainExactRowPresentationCache() {
        let cachedPane = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 1),
            provider: .codex,
            activityState: .idle
        )
        let cachedPresentation = PanePresentationState(
            snapshot: makeV3Snapshot(
                sessionName: "visible-session",
                windowID: "@1",
                sessionKey: "opaque-session-key",
                paneID: "%1",
                paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
                provider: .codex,
                presence: .managed,
                threadLifecycle: .idle,
                blocking: .none,
                execution: .none
            )
        )
        let store = makeStore(
            metadataByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPane],
            presentationByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPresentation]
        )
        let upsertSnapshot = makeV3Snapshot(
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneID: "%1",
            paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
            provider: .codex,
            presence: .managed,
            threadLifecycle: .active,
            blocking: .waitingUserInput,
            execution: .streaming,
            attentionKinds: [.question],
            unresolvedCount: 1
        )
        let upserted = store.apply(
            AgtmuxSyncV3Changes(
                fromSeq: 5,
                toSeq: 5,
                nextCursor: AgtmuxSyncV3Cursor(seq: 5),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: 5,
                        at: now,
                        kind: .upsert,
                        paneID: "%1",
                        sessionName: "visible-session",
                        windowID: "@1",
                        sessionKey: "opaque-session-key",
                        paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
                        fieldGroups: [.thread, .attention],
                        pane: upsertSnapshot
                    )
                ]
            )
        )

        let key = "local:visible-session:@1:%1"
        XCTAssertEqual(upserted.metadataByPaneKey[key]?.activityState, .waitingInput)
        XCTAssertEqual(upserted.presentationByPaneKey[key]?.primaryState, .waitingUserInput)

        let removed = makeStore(
            metadataByPaneKey: upserted.metadataByPaneKey,
            presentationByPaneKey: upserted.presentationByPaneKey
        ).apply(
            AgtmuxSyncV3Changes(
                fromSeq: 6,
                toSeq: 6,
                nextCursor: AgtmuxSyncV3Cursor(seq: 6),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: 6,
                        at: now,
                        kind: .remove,
                        paneID: "%1",
                        sessionName: "visible-session",
                        windowID: "@1",
                        sessionKey: "opaque-session-key",
                        paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
                        fieldGroups: [.presence],
                        pane: nil
                    )
                ]
            )
        )

        XCTAssertNil(removed.metadataByPaneKey[key])
        XCTAssertNil(removed.presentationByPaneKey[key])
    }

    func testApplyV3ChangesDropsConflictingUpsertAtSameLocationWhenPaneInstanceDiffers() {
        let cachedPane = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 2),
            provider: .codex,
            activityState: .idle
        )
        let cachedPresentation = PanePresentationState(
            snapshot: makeV3Snapshot(
                sessionName: "visible-session",
                windowID: "@1",
                sessionKey: "opaque-session-key",
                paneID: "%1",
                paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 2),
                provider: .codex,
                presence: .managed,
                threadLifecycle: .idle,
                blocking: .none,
                execution: .none
            )
        )
        let store = makeStore(
            metadataByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPane],
            presentationByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPresentation]
        )
        let conflictingSnapshot = makeV3Snapshot(
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "opaque-session-key",
            paneID: "%1",
            paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
            provider: .claude,
            presence: .managed,
            threadLifecycle: .active,
            blocking: .none,
            execution: .thinking
        )

        let nextCache = store.apply(
            AgtmuxSyncV3Changes(
                fromSeq: 7,
                toSeq: 7,
                nextCursor: AgtmuxSyncV3Cursor(seq: 7),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: 7,
                        at: now,
                        kind: .upsert,
                        paneID: "%1",
                        sessionName: "visible-session",
                        windowID: "@1",
                        sessionKey: "opaque-session-key",
                        paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 1),
                        fieldGroups: [.identity, .provider, .thread],
                        pane: conflictingSnapshot
                    )
                ]
            )
        )

        let key = "local:visible-session:@1:%1"
        XCTAssertEqual(nextCache.metadataByPaneKey[key]?.provider, .codex)
        XCTAssertEqual(nextCache.metadataByPaneKey[key]?.activityState, .idle)
        XCTAssertEqual(nextCache.presentationByPaneKey[key]?.primaryState, .completedIdle)
    }

    func testApplyV3ChangesAllowsShellDemotionToReplaceManagedExactIdentityAtSameVisibleLocation() {
        let cachedPane = makePane(
            paneID: "%1",
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "codex:%1",
            paneInstanceID: makeV2PaneInstanceID(paneID: "%1", generation: 2),
            provider: .codex,
            activityState: .running
        )
        let cachedPresentation = PanePresentationState(
            snapshot: makeV3Snapshot(
                sessionName: "visible-session",
                windowID: "@1",
                sessionKey: "codex:%1",
                paneID: "%1",
                paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 2),
                provider: .codex,
                presence: .managed,
                threadLifecycle: .active,
                blocking: .none,
                execution: .streaming
            )
        )
        let store = makeStore(
            metadataByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPane],
            presentationByPaneKey: [LocalMetadataOverlayStore.paneMetadataKey(for: cachedPane): cachedPresentation]
        )
        let demotedSnapshot = makeV3Snapshot(
            sessionName: "visible-session",
            windowID: "@1",
            sessionKey: "shell:%1",
            paneID: "%1",
            paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 2),
            provider: nil,
            presence: .unmanaged,
            threadLifecycle: .idle,
            blocking: .none,
            execution: .none
        )

        let nextCache = store.apply(
            AgtmuxSyncV3Changes(
                fromSeq: 8,
                toSeq: 8,
                nextCursor: AgtmuxSyncV3Cursor(seq: 8),
                changes: [
                    AgtmuxSyncV3PaneChange(
                        seq: 8,
                        at: now,
                        kind: .upsert,
                        paneID: "%1",
                        sessionName: "visible-session",
                        windowID: "@1",
                        sessionKey: "shell:%1",
                        paneInstanceID: makeV3PaneInstanceID(paneID: "%1", generation: 2),
                        fieldGroups: [.identity, .presence, .thread],
                        pane: demotedSnapshot
                    )
                ]
            )
        )

        let key = "local:visible-session:@1:%1"
        XCTAssertEqual(nextCache.metadataByPaneKey[key]?.presence, .unmanaged)
        XCTAssertNil(nextCache.metadataByPaneKey[key]?.provider)
        XCTAssertEqual(nextCache.metadataByPaneKey[key]?.metadataSessionKey, "shell:%1")
        XCTAssertEqual(nextCache.presentationByPaneKey[key], PanePresentationState(snapshot: demotedSnapshot))
    }

    private func makeStore(
        inventory: [AgtmuxPane] = [],
        metadataByPaneKey: [String: AgtmuxPane] = [:],
        presentationByPaneKey: [String: PanePresentationState] = [:]
    ) -> LocalMetadataOverlayStore {
        LocalMetadataOverlayStore(
            inventory: inventory,
            metadataByPaneKey: metadataByPaneKey,
            presentationByPaneKey: presentationByPaneKey
        )
    }

    private func makePane(
        paneID: String,
        sessionName: String,
        windowID: String,
        sessionKey: String? = nil,
        paneInstanceID: AgtmuxSyncV2PaneInstanceID? = nil,
        provider: Provider? = nil,
        activityState: ActivityState = .unknown,
        conversationTitle: String? = nil,
        currentPath: String? = nil,
        gitBranch: String? = nil,
        currentCmd: String? = nil
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: "local",
            paneId: paneID,
            sessionName: sessionName,
            windowId: windowID,
            activityState: activityState,
            presence: provider == nil ? .unmanaged : .managed,
            provider: provider,
            evidenceMode: provider == nil ? .none : .deterministic,
            conversationTitle: conversationTitle,
            currentPath: currentPath,
            gitBranch: gitBranch,
            currentCmd: currentCmd,
            updatedAt: now,
            metadataSessionKey: sessionKey,
            paneInstanceID: paneInstanceID
        )
    }

    private func makeV2PaneInstanceID(paneID: String, generation: UInt64?) -> AgtmuxSyncV2PaneInstanceID {
        AgtmuxSyncV2PaneInstanceID(
            paneId: paneID,
            generation: generation,
            birthTs: now
        )
    }

    private func makeV3PaneInstanceID(paneID: String, generation: UInt64?) -> AgtmuxSyncV3PaneInstanceID {
        AgtmuxSyncV3PaneInstanceID(
            paneId: paneID,
            generation: generation,
            birthTs: now
        )
    }

    private func makeV3Snapshot(
        sessionName: String,
        windowID: String,
        sessionKey: String,
        paneID: String,
        paneInstanceID: AgtmuxSyncV3PaneInstanceID,
        provider: Provider?,
        presence: AgtmuxSyncV3Presence,
        threadLifecycle: AgtmuxSyncV3ThreadLifecycle,
        blocking: AgtmuxSyncV3BlockingState,
        execution: AgtmuxSyncV3ExecutionState,
        attentionKinds: [AgtmuxSyncV3AttentionKind] = [],
        unresolvedCount: UInt32 = 0
    ) -> AgtmuxSyncV3PaneSnapshot {
        AgtmuxSyncV3PaneSnapshot(
            sessionName: sessionName,
            windowID: windowID,
            sessionKey: sessionKey,
            paneID: paneID,
            paneInstanceID: paneInstanceID,
            provider: provider,
            presence: presence,
            agent: AgtmuxSyncV3AgentState(lifecycle: provider == nil ? .unknown : .running),
            thread: AgtmuxSyncV3ThreadState(
                lifecycle: threadLifecycle,
                blocking: blocking,
                execution: execution,
                flags: AgtmuxSyncV3ThreadFlags(reviewMode: false, subagentActive: false),
                turn: AgtmuxSyncV3TurnState(
                    outcome: threadLifecycle == .idle ? .completed : .none,
                    sequence: 1,
                    startedAt: now,
                    completedAt: threadLifecycle == .idle ? now : nil
                )
            ),
            pendingRequests: [],
            attention: AgtmuxSyncV3AttentionSummary(
                activeKinds: attentionKinds,
                highestPriority: attentionKinds.isEmpty ? .none : .approval,
                unresolvedCount: unresolvedCount,
                generation: 1,
                latestAt: attentionKinds.isEmpty ? nil : now
            ),
            freshness: AgtmuxSyncV3FreshnessSummary(
                snapshot: .fresh,
                blocking: .fresh,
                execution: .fresh
            ),
            providerRaw: nil,
            updatedAt: now
        )
    }
}
