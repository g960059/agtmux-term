import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchFocusedNavigationActorTests: XCTestCase {
    @MainActor
    func testPollingRunExitsWithoutWritingWhenSnapshotBecomesStale() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        let originalContext = try XCTUnwrap(store.activePaneRuntimeContext)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        var errorMessages: [String?] = []
        let renderedState = GhosttyRenderedTerminalSurfaceState(
            context: makeSurfaceContext(
                workbenchID: workbenchID,
                tileID: openResult.tileID,
                sessionName: "shared"
            ),
            attachCommand: "tmux attach-session -t shared",
            clientTTY: "/dev/ttys001",
            generation: 1
        )
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { _ in renderedState },
                resolveControlMode: { _ in nil },
                liveTarget: { _, _, _ in
                    _ = store.openTerminal(
                        sessionRef: SessionRef(target: .local, sessionName: "other")
                    )
                    return WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@2",
                        paneID: "%9"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("stale polling run must exit before applying navigation intent")
                },
                sleep: { _ in await Task.yield() }
            )
        )

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { message in
            errorMessages.append(message)
        }

        await waitUntil {
            store.focusedTerminalTileContext?.sessionRef.sessionName == "other"
        }

        XCTAssertEqual(store.focusedTerminalTileContext?.sessionRef.sessionName, "other")
        XCTAssertEqual(store.focusedTerminalTileContext?.tileID, store.activeWorkbench?.focusedTileID)
        XCTAssertNil(store.activePaneRuntimeContext)
        XCTAssertNotEqual(store.activePaneRuntimeContext?.tileID, originalContext.tileID)
        XCTAssertEqual(errorMessages.last ?? nil, nil)
        actor.stop()
    }

    @MainActor
    func testControlModeSendReReadsLatestRenderedTTYOnEachRetry() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        let expectation = expectation(description: "two control-mode sends")
        expectation.expectedFulfillmentCount = 2
        var commands: [String] = []
        var renderedTTY = "/dev/ttys001"
        let (events, continuation) = AsyncStream<ControlModeEvent>.makeStream()
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: renderedTTY,
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: events,
                        send: { command in
                            commands.append(command)
                            expectation.fulfill()
                        }
                    )
                },
                liveTarget: { _, _, _ in
                    WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@1",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode path must not use polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer {
            continuation.finish()
            actor.stop()
        }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil { commands.count == 1 }
        renderedTTY = "/dev/ttys009"
        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty,
                taskIdentity: "run-refreshed"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(commands, [
            "switch-client -c /dev/ttys001 -t %9",
            "switch-client -c /dev/ttys009 -t %9",
        ])
    }

    @MainActor
    func testControlModeSendRetriesTransientNotConnectedRaceWithLatestTTY() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        let expectation = expectation(description: "retry succeeds after transient not connected")
        var attemptedCommands: [String] = []
        var renderedTTY = "/dev/ttys001"
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: renderedTTY,
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: AsyncStream { _ in },
                        send: { command in
                            attemptedCommands.append(command)
                            if attemptedCommands.count == 1 {
                                renderedTTY = "/dev/ttys011"
                                throw TmuxCommandError.failed(
                                    args: [command],
                                    code: -1,
                                    stderr: "control mode not connected"
                                )
                            }
                            expectation.fulfill()
                        }
                    )
                },
                liveTarget: { _, _, _ in
                    WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@1",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode path must not use polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop() }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(attemptedCommands, [
            "switch-client -c /dev/ttys001 -t %9",
            "switch-client -c /dev/ttys011 -t %9",
        ])
    }

    @MainActor
    func testControlModeFallsBackToSelectPaneOnlyWhileRenderedTTYIsUnavailable() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        let expectation = expectation(description: "fallback then exact-client send")
        expectation.expectedFulfillmentCount = 2
        var commands: [String] = []
        var renderedTTY: String?
        let (events, continuation) = AsyncStream<ControlModeEvent>.makeStream()
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: renderedTTY,
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: events,
                        send: { command in
                            commands.append(command)
                            expectation.fulfill()
                        }
                    )
                },
                liveTarget: { _, _, _ in
                    WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@1",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode path must not use polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer {
            continuation.finish()
            actor.stop()
        }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil { commands.count == 1 }
        renderedTTY = "/dev/ttys010"
        continuation.yield(.windowPaneChanged(windowId: "@1", paneId: "%1"))
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(commands, [
            "select-pane -t %9",
            "switch-client -c /dev/ttys010 -t %9",
        ])
    }

    @MainActor
    func testControlModeStartupSeedsObservedTruthWhenRenderedClientAlreadyReachedDesiredPane() async throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%0",
            sessionName: "shared",
            windowId: "@0"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@0"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: openResult.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        var commands: [String] = []
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys010",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: AsyncStream { _ in },
                        send: { command in
                            commands.append(command)
                        }
                    )
                },
                liveTarget: { renderedClientTTY, _, _ in
                    XCTAssertEqual(renderedClientTTY, "/dev/ttys010")
                    return WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@0",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode startup seed must not fall back to polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop() }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil {
            store.activePaneRuntimeContext?.desiredPaneRef == nil
                && store.activePaneRuntimeContext?.observedPaneRef?.paneID == secondPane.paneId
        }

        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.windowID, secondPane.windowId)
        XCTAssertTrue(
            commands.isEmpty,
            "rendered client already at desired pane must not send a redundant control-mode navigation command"
        )
    }

    @MainActor
    func testControlModeStartupReconcilesObservedTruthAfterSendWhenNoEventArrives() async throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%0",
            sessionName: "shared",
            windowId: "@0"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@0"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: openResult.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        var commands: [String] = []
        var liveTargets = [
            WorkbenchV2TerminalLiveTarget(
                sessionName: "shared",
                windowID: "@0",
                paneID: "%0"
            ),
            WorkbenchV2TerminalLiveTarget(
                sessionName: "shared",
                windowID: "@0",
                paneID: "%1"
            )
        ]
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys011",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: AsyncStream { _ in },
                        send: { command in
                            commands.append(command)
                        }
                    )
                },
                liveTarget: { renderedClientTTY, _, _ in
                    XCTAssertEqual(renderedClientTTY, "/dev/ttys011")
                    return liveTargets.isEmpty ? WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@0",
                        paneID: "%1"
                    ) : liveTargets.removeFirst()
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode startup reconcile must not fall back to polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop() }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil {
            store.activePaneRuntimeContext?.desiredPaneRef == nil
                && store.activePaneRuntimeContext?.observedPaneRef?.paneID == secondPane.paneId
        }

        XCTAssertEqual(commands, ["switch-client -c /dev/ttys011 -t %1"])
        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.windowID, secondPane.windowId)
    }

    @MainActor
    func testControlModeStartupRetriesTransientReadbackMissAfterSendWhenNoEventArrives() async throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%0",
            sessionName: "shared",
            windowId: "@0"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@0"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: openResult.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)

        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        var commands: [String] = []
        var liveTargetCallCount = 0
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys012",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: AsyncStream { _ in },
                        send: { command in
                            commands.append(command)
                        }
                    )
                },
                liveTarget: { renderedClientTTY, _, _ in
                    XCTAssertEqual(renderedClientTTY, "/dev/ttys012")
                    liveTargetCallCount += 1
                    switch liveTargetCallCount {
                    case 1:
                        return WorkbenchV2TerminalLiveTarget(
                            sessionName: "shared",
                            windowID: "@0",
                            paneID: "%0"
                        )
                    case 2:
                        throw WorkbenchV2TerminalNavigationError.renderedClientUnavailable(
                            sessionName: "shared",
                            clientTTY: "/dev/ttys012",
                            output: "transient readback miss"
                        )
                    default:
                        return WorkbenchV2TerminalLiveTarget(
                            sessionName: "shared",
                            windowID: "@0",
                            paneID: "%1"
                        )
                    }
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode startup reread retry must not fall back to polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop() }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil {
            store.activePaneRuntimeContext?.desiredPaneRef == nil
                && store.activePaneRuntimeContext?.observedPaneRef?.paneID == secondPane.paneId
        }

        XCTAssertEqual(commands, ["switch-client -c /dev/ttys012 -t %1"])
        XCTAssertEqual(liveTargetCallCount, 3)
        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.windowID, secondPane.windowId)
    }

    @MainActor
    func testUpdateCancelsPreviousControlModeRunWhenTaskIdentityChanges() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: openResult.tileID,
            preferredWindowID: targetPane.windowId,
            preferredPaneID: targetPane.paneId
        )
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        let (firstEvents, firstContinuation) = AsyncStream<ControlModeEvent>.makeStream()
        let (secondEvents, secondContinuation) = AsyncStream<ControlModeEvent>.makeStream()
        var resolveCalls = 0
        var nextLiveTarget = WorkbenchV2TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@7",
            paneID: "%41"
        )
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys001",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    resolveCalls += 1
                    if resolveCalls == 1 {
                        return WorkbenchFocusedNavigationControlModeHandle(
                            events: firstEvents,
                            send: { _ in }
                        )
                    }
                    return WorkbenchFocusedNavigationControlModeHandle(
                        events: secondEvents,
                        send: { _ in }
                    )
                },
                liveTarget: { _, _, _ in
                    return nextLiveTarget
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode path must not use polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer {
            firstContinuation.finish()
            secondContinuation.finish()
            actor.stop()
        }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty,
                taskIdentity: "run-1"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil { resolveCalls == 1 }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty,
                taskIdentity: "run-2"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        await waitUntil { resolveCalls == 2 }

        firstContinuation.yield(.windowPaneChanged(windowId: "@7", paneId: "%41"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotEqual(
            store.activePaneRuntimeContext?.observedPaneRef?.paneID,
            "%41",
            "cancelled control-mode run must not keep mutating navigation state"
        )

        nextLiveTarget = WorkbenchV2TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@8",
            paneID: "%42"
        )
        secondContinuation.yield(.windowPaneChanged(windowId: "@8", paneId: "%42"))
        await waitUntil {
            store.activePaneRuntimeContext?.observedPaneRef?.paneID == "%42"
        }
        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.windowID, "@8")
    }

    @MainActor
    func testControlModeEventReconcilesObservedPaneFromRenderedClientTruth() async throws {
        let firstPane = AgtmuxPane(
            source: "local",
            paneId: "%0",
            sessionName: "shared",
            windowId: "@0"
        )
        let secondPane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "shared",
            windowId: "@0"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: firstPane, hostsConfig: .empty)
        _ = store.syncTerminalNavigation(
            tileID: openResult.tileID,
            preferredWindowID: firstPane.windowId,
            preferredPaneID: firstPane.paneId
        )
        _ = store.openTerminal(for: secondPane, hostsConfig: .empty)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        let (events, continuation) = AsyncStream<ControlModeEvent>.makeStream()
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys001",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in
                    WorkbenchFocusedNavigationControlModeHandle(
                        events: events,
                        send: { _ in }
                    )
                },
                liveTarget: { _, _, _ in
                    WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@0",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("control-mode path must not use polling intent apply")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer {
            continuation.finish()
            actor.stop()
        }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        continuation.yield(.windowPaneChanged(windowId: "@0", paneId: "%0"))
        await waitUntil {
            store.activePaneRuntimeContext?.observedPaneRef?.paneID == "%1"
                && store.activePaneContext?.activePaneRef.paneID == "%1"
        }

        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.paneID, "%1")
        XCTAssertEqual(store.activePaneRuntimeContext?.observedPaneRef?.windowID, "@0")
        XCTAssertEqual(
            store.activePaneContext?.activePaneRef.paneID,
            "%1",
            "session-scoped control-mode payload must not overwrite rendered-client truth"
        )
    }

    @MainActor
    func testUpdateClearsErrorWhenNavigationSyncStops() async throws {
        let targetPane = AgtmuxPane(
            source: "local",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: .empty)
        let workbenchID = try XCTUnwrap(store.activeWorkbench?.id)
        var errorMessages: [String?] = []
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { tileID in
                    GhosttyRenderedTerminalSurfaceState(
                        context: self.makeSurfaceContext(
                            workbenchID: workbenchID,
                            tileID: tileID,
                            sessionName: "shared"
                        ),
                        attachCommand: "tmux attach-session -t shared",
                        clientTTY: "/dev/ttys001",
                        generation: 1
                    )
                },
                resolveControlMode: { _ in nil },
                liveTarget: { _, _, _ in
                    throw WorkbenchV2TerminalNavigationError.activePaneUnavailable(
                        sessionName: "shared",
                        output: "no active pane"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("error path must not apply navigation intent")
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop() }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty,
                taskIdentity: "run-error"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { message in
            errorMessages.append(message)
        }

        await waitUntil {
            errorMessages.last == "Navigation sync failed: active pane unavailable for session 'shared' (no active pane)"
        }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .local, sessionName: "shared"),
                hostsConfig: .empty,
                taskIdentity: "run-stopped",
                shouldRun: false
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { message in
            errorMessages.append(message)
        }

        XCTAssertNil(errorMessages.last ?? nil)
    }

    @MainActor
    func testUpdateSchedulesRemoteStopWhenNavigationSyncStops() {
        let targetPane = AgtmuxPane(
            source: "vm.example.com",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let hostsConfig = makeHostsConfig(
            id: "vm",
            hostname: "vm.example.com",
            user: "alice"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: hostsConfig)
        var scheduledStops: [WorkbenchFocusedNavigationControlModeKey] = []
        var cancelledStops: [WorkbenchFocusedNavigationControlModeKey] = []
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { _ in nil },
                resolveControlMode: { _ in nil },
                liveTarget: { _, _, _ in
                    XCTFail("stop-path test must not fall back to polling")
                    return WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@1",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("stop-path test must not apply navigation intent")
                },
                scheduleControlModeStop: { controlModeKey in
                    if let controlModeKey {
                        scheduledStops.append(controlModeKey)
                    }
                },
                cancelControlModeStop: { controlModeKey in
                    if let controlModeKey {
                        cancelledStops.append(controlModeKey)
                    }
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop(scheduleControlModeStop: false) }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .remote(hostKey: "vm"), sessionName: "shared"),
                hostsConfig: hostsConfig,
                taskIdentity: "run-remote"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .remote(hostKey: "vm"), sessionName: "shared"),
                hostsConfig: hostsConfig,
                taskIdentity: "run-remote-stopped",
                shouldRun: false
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        let expectedKey = WorkbenchFocusedNavigationControlModeKey(
            sessionName: "shared",
            source: "alice@vm.example.com",
            isRemote: true
        )
        XCTAssertEqual(cancelledStops, [expectedKey])
        XCTAssertEqual(scheduledStops, [expectedKey])
    }

    @MainActor
    func testUpdateSchedulesPreviousRemoteStopWhenControlModeSourceChanges() {
        let targetPane = AgtmuxPane(
            source: "vm-a.example.com",
            paneId: "%9",
            sessionName: "shared",
            windowId: "@2"
        )
        let firstHostsConfig = makeHostsConfig(
            id: "vm",
            hostname: "vm-a.example.com",
            user: "alice"
        )
        let secondHostsConfig = makeHostsConfig(
            id: "vm",
            hostname: "vm-b.example.com",
            user: "alice"
        )
        let store = WorkbenchStoreV2()
        let runtimeStore = TerminalRuntimeStore()
        let openResult = store.openTerminal(for: targetPane, hostsConfig: firstHostsConfig)
        var scheduledStops: [WorkbenchFocusedNavigationControlModeKey] = []
        var cancelledStops: [WorkbenchFocusedNavigationControlModeKey] = []
        let actor = WorkbenchFocusedNavigationActor(
            dependencies: WorkbenchFocusedNavigationActorDependencies(
                renderedState: { _ in nil },
                resolveControlMode: { _ in nil },
                liveTarget: { _, _, _ in
                    XCTFail("source-change test must not fall back to polling")
                    return WorkbenchV2TerminalLiveTarget(
                        sessionName: "shared",
                        windowID: "@1",
                        paneID: "%1"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    XCTFail("source-change test must not apply navigation intent")
                },
                scheduleControlModeStop: { controlModeKey in
                    if let controlModeKey {
                        scheduledStops.append(controlModeKey)
                    }
                },
                cancelControlModeStop: { controlModeKey in
                    if let controlModeKey {
                        cancelledStops.append(controlModeKey)
                    }
                },
                sleep: { _ in await Task.yield() }
            )
        )
        defer { actor.stop(scheduleControlModeStop: false) }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .remote(hostKey: "vm"), sessionName: "shared"),
                hostsConfig: firstHostsConfig,
                taskIdentity: "run-remote-a"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        actor.update(
            snapshot: makeSnapshot(
                store: store,
                tileID: openResult.tileID,
                sessionRef: SessionRef(target: .remote(hostKey: "vm"), sessionName: "shared"),
                hostsConfig: secondHostsConfig,
                taskIdentity: "run-remote-b"
            ),
            store: store,
            runtimeStore: runtimeStore
        ) { _ in }

        XCTAssertEqual(scheduledStops, [
            WorkbenchFocusedNavigationControlModeKey(
                sessionName: "shared",
                source: "alice@vm-a.example.com",
                isRemote: true
            )
        ])
        XCTAssertEqual(cancelledStops, [
            WorkbenchFocusedNavigationControlModeKey(
                sessionName: "shared",
                source: "alice@vm-a.example.com",
                isRemote: true
            ),
            WorkbenchFocusedNavigationControlModeKey(
                sessionName: "shared",
                source: "alice@vm-b.example.com",
                isRemote: true
            ),
        ])
    }

    func testTaskIdentityChangesWhenDesiredStateClearsWithoutVisiblePaneIDChange() {
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let observed = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9",
            paneInstanceID: makePaneInstanceID(
                paneID: "%9",
                generation: 3
            )
        )
        let before = WorkbenchFocusedNavigationIdentity.make(
            tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            isFocused: true,
            isReady: true,
            sessionRef: sessionRef,
            controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                sessionRef: sessionRef,
                hostsConfig: .empty
            ),
            desiredPaneRef: observed,
            observedPaneRef: observed
        )
        let after = WorkbenchFocusedNavigationIdentity.make(
            tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            isFocused: true,
            isReady: true,
            sessionRef: sessionRef,
            controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                sessionRef: sessionRef,
                hostsConfig: .empty
            ),
            desiredPaneRef: nil,
            observedPaneRef: observed
        )

        XCTAssertNotEqual(
            before,
            after,
            "task identity must refresh when desired state clears even if the visible pane/window stays the same"
        )
    }

    func testTaskIdentityChangesWhenPaneInstanceIDChangesWithoutPaneIDChange() {
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let desired = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9",
            paneInstanceID: makePaneInstanceID(
                paneID: "%9",
                generation: 3
            )
        )
        let observed = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9",
            paneInstanceID: makePaneInstanceID(
                paneID: "%9",
                generation: 4
            )
        )

        XCTAssertNotEqual(
            WorkbenchFocusedNavigationIdentity.make(
                tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                isFocused: true,
                isReady: true,
                sessionRef: sessionRef,
                controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                    sessionRef: sessionRef,
                    hostsConfig: .empty
                ),
                desiredPaneRef: desired,
                observedPaneRef: desired
            ),
            WorkbenchFocusedNavigationIdentity.make(
                tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                isFocused: true,
                isReady: true,
                sessionRef: sessionRef,
                controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                    sessionRef: sessionRef,
                    hostsConfig: .empty
                ),
                desiredPaneRef: desired,
                observedPaneRef: observed
            ),
            "task identity must refresh when pane-instance identity changes without a pane/window ID change"
        )
    }

    func testTaskIdentityChangesWhenRemoteControlModeSourceChanges() {
        let sessionRef = SessionRef(target: .remote(hostKey: "vm"), sessionName: "shared")
        let firstHostsConfig = makeHostsConfig(
            id: "vm",
            hostname: "vm-a.example.com",
            user: "alice"
        )
        let secondHostsConfig = makeHostsConfig(
            id: "vm",
            hostname: "vm-b.example.com",
            user: "alice"
        )

        XCTAssertNotEqual(
            WorkbenchFocusedNavigationIdentity.make(
                tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                isFocused: true,
                isReady: true,
                sessionRef: sessionRef,
                controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                    sessionRef: sessionRef,
                    hostsConfig: firstHostsConfig
                ),
                desiredPaneRef: nil,
                observedPaneRef: nil
            ),
            WorkbenchFocusedNavigationIdentity.make(
                tileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                isFocused: true,
                isReady: true,
                sessionRef: sessionRef,
                controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                    sessionRef: sessionRef,
                    hostsConfig: secondHostsConfig
                ),
                desiredPaneRef: nil,
                observedPaneRef: nil
            ),
            "task identity must refresh when the remote control-mode source changes"
        )
    }

    @MainActor
    private func makeSnapshot(
        store: WorkbenchStoreV2,
        tileID: UUID,
        sessionRef: SessionRef,
        hostsConfig: HostsConfig,
        taskIdentity: String? = nil,
        shouldRun: Bool = true
    ) -> WorkbenchFocusedNavigationSnapshot {
        let runtimeContext = store.activePaneRuntimeContext
        return WorkbenchFocusedNavigationSnapshot(
            taskIdentity: taskIdentity ?? "test-\(tileID.uuidString)",
            shouldRun: shouldRun,
            workbenchID: store.activeWorkbench?.id ?? UUID(),
            tileID: tileID,
            sessionRef: sessionRef,
            controlModeKey: WorkbenchFocusedNavigationControlModeKey.make(
                sessionRef: sessionRef,
                hostsConfig: hostsConfig
            ),
            hostsConfig: hostsConfig,
            desiredPaneRef: runtimeContext?.desiredPaneRef,
            observedPaneRef: runtimeContext?.observedPaneRef
        )
    }

    private func makeSurfaceContext(
        workbenchID: UUID,
        tileID: UUID,
        sessionName: String
    ) -> GhosttyTerminalSurfaceContext {
        GhosttyTerminalSurfaceContext(
            workbenchID: workbenchID,
            tileID: tileID,
            surfaceKey: "workbench-v2:\(sessionName)",
            sessionRef: SessionRef(target: .local, sessionName: sessionName)
        )
    }

    private func makePaneInstanceID(
        paneID: String,
        generation: UInt64
    ) -> AgtmuxSyncV2PaneInstanceID {
        AgtmuxSyncV2PaneInstanceID(
            paneId: paneID,
            generation: generation,
            birthTs: Date(timeIntervalSince1970: Double(generation))
        )
    }

    private func makeHostsConfig(
        id: String,
        hostname: String,
        user: String?
    ) -> HostsConfig {
        HostsConfig(
            hosts: [
                RemoteHost(
                    id: id,
                    displayName: nil,
                    hostname: hostname,
                    user: user,
                    transport: .ssh
                )
            ]
        )
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
