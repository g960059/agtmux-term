import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

@MainActor
final class MainTerminalStoreTests: XCTestCase {
    func testStoreStartsInPlainShellMode() {
        let store = MainTerminalStore(
            dependencies: makeDependencies()
        )

        XCTAssertEqual(store.mode, .plainShell)
        XCTAssertNil(store.sessionRef)
        XCTAssertNil(store.requestedPaneRef)
        XCTAssertNil(store.resolvedPaneRef)
        XCTAssertEqual(store.statusTitle, "Plain Shell")
        XCTAssertEqual(store.statusDetail, "Local shell")
    }

    func testActivateSessionUsesLiveTargetBeforeFallbacks() async {
        let session = makeSession(
            sessionName: "main",
            windows: [
                makeWindow(sessionName: "main", windowID: "@1", paneIDs: ["%1", "%2"])
            ]
        )
        let store = MainTerminalStore(
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    TerminalLiveTarget(
                        sessionName: "main",
                        windowID: "@1",
                        paneID: "%2"
                    )
                }
            )
        )

        await store.activate(session: session, hostsConfig: .empty)

        XCTAssertEqual(store.sessionRef?.target, .local)
        XCTAssertEqual(store.sessionRef?.sessionName, "main")
        XCTAssertEqual(store.requestedPaneRef?.windowID, "@1")
        XCTAssertEqual(store.requestedPaneRef?.paneID, "%2")
        XCTAssertNil(store.diagnostic)

        store.startPlainShell()
    }

    func testActivateSessionFallsBackToLastRestoreTargetWhenLiveTargetFails() async {
        let session = makeSession(
            sessionName: "shared",
            windows: [
                makeWindow(sessionName: "shared", windowID: "@1", paneIDs: ["%1"])
            ]
        )
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let restoredPaneRef = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@9",
            paneID: "%9"
        )
        let store = MainTerminalStore(
            lastRestoreTargetBySession: [sessionRef: restoredPaneRef],
            dependencies: makeDependencies(
                liveTarget: { _, _ in throw StubError.liveTargetUnavailable }
            )
        )

        await store.activate(session: session, hostsConfig: .empty)

        XCTAssertEqual(store.requestedPaneRef, restoredPaneRef)
        XCTAssertEqual(
            store.diagnostic,
            .restoreFallbackUsed(requested: nil, resolved: restoredPaneRef)
        )

        store.startPlainShell()
    }

    func testActivateSessionFallsBackToFirstListedPaneWhenNoRestoreExists() async {
        let session = makeSession(
            sessionName: "shared",
            windows: [
                makeWindow(sessionName: "shared", windowID: "@2", paneIDs: ["%3", "%4"])
            ]
        )
        let store = MainTerminalStore(
            dependencies: makeDependencies(
                liveTarget: { _, _ in throw StubError.liveTargetUnavailable }
            )
        )

        await store.activate(session: session, hostsConfig: .empty)

        XCTAssertEqual(store.requestedPaneRef?.windowID, "@2")
        XCTAssertEqual(store.requestedPaneRef?.paneID, "%3")
        XCTAssertEqual(
            store.diagnostic,
            .restoreFallbackUsed(
                requested: nil,
                resolved: ActivePaneRef(
                    target: .local,
                    sessionName: "shared",
                    windowID: "@2",
                    paneID: "%3"
                )
            )
        )

        store.startPlainShell()
    }

    func testActivateWindowSurfacesDiagnosticWhenNoPanesAreListed() async {
        let window = WindowGroup(
            source: "local",
            sessionName: "main",
            windowId: "@4",
            panes: []
        )
        let store = MainTerminalStore(
            dependencies: makeDependencies()
        )

        await store.activate(window: window, hostsConfig: .empty)

        XCTAssertEqual(store.mode, .plainShell)
        XCTAssertEqual(
            store.diagnostic,
            .attachFailed(
                SessionRef(target: .local, sessionName: "main"),
                detail: "Window target unavailable: no panes are listed for @4."
            )
        )
    }

    func testPaneActivationHighlightsClickedInventoryPane() async {
        let firstPane = makePane(sessionName: "shared", windowID: "@1", paneID: "%1")
        let secondPane = makePane(sessionName: "shared", windowID: "@1", paneID: "%2")
        let store = MainTerminalStore(
            dependencies: makeDependencies()
        )

        await store.activate(pane: secondPane, hostsConfig: .empty)

        XCTAssertEqual(
            store.selectedPaneInventoryID(
                panes: [firstPane, secondPane],
                hostsConfig: .empty
            ),
            secondPane.id
        )
        XCTAssertEqual(store.requestedPaneRef?.windowID, "@1")
        XCTAssertEqual(store.requestedPaneRef?.paneID, "%2")

        store.startPlainShell()
    }

    func testCrossSessionActivationUpdatesAttachPlanForSingleTerminalReattach() async {
        let firstPane = makePane(sessionName: "alpha", windowID: "@1", paneID: "%1")
        let secondPane = makePane(sessionName: "beta", windowID: "@2", paneID: "%4")
        let store = MainTerminalStore(
            dependencies: makeDependencies()
        )

        await store.activate(pane: firstPane, hostsConfig: .empty)
        let firstPlan = try? store.attachResolution?.get()
        let stableSurfaceID = store.surfaceID

        await store.activate(pane: secondPane, hostsConfig: .empty)
        let secondPlan = try? store.attachResolution?.get()

        XCTAssertEqual(store.surfaceID, stableSurfaceID)
        XCTAssertEqual(store.sessionRef?.sessionName, "beta")
        XCTAssertEqual(firstPlan?.surfaceKey, "main-terminal:local:alpha")
        XCTAssertEqual(secondPlan?.surfaceKey, "main-terminal:local:beta")
        XCTAssertNotEqual(firstPlan?.command, secondPlan?.command)
        XCTAssertEqual(store.requestedPaneRef?.paneID, "%4")

        store.startPlainShell()
    }

    func testSameSessionActivationWithoutRenderedClientForcesFreshAttachPlanAndSurfaceRemount() async throws {
        let surfaceID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let currentPaneRef = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let clickedPane = makePane(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let store = MainTerminalStore(
            surfaceID: surfaceID,
            mode: .tmux(
                sessionRef: sessionRef,
                requestedPaneRef: nil,
                resolvedPaneRef: currentPaneRef
            ),
            attachSurfaceGeneration: 7,
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    throw StubError.unexpectedSessionLiveTargetLookup
                },
                renderedState: { renderedSurfaceID in
                    XCTAssertEqual(renderedSurfaceID, surfaceID)
                    return self.makeRenderedState(
                        surfaceID: renderedSurfaceID,
                        sessionRef: sessionRef,
                        clientTTY: nil,
                        attachCommand: "tmux attach-session -t shared"
                    )
                }
            )
        )

        await store.activate(pane: clickedPane, hostsConfig: .empty)

        let plan = try XCTUnwrap(try? store.attachResolution?.get())
        XCTAssertEqual(store.attachSurfaceGeneration, 8)
        XCTAssertTrue(plan.command.contains("select-window -t"))
        XCTAssertTrue(plan.command.contains("@2"))
        XCTAssertTrue(plan.command.contains("select-pane -t"))
        XCTAssertTrue(plan.command.contains("%8"))

        store.startPlainShell()
    }

    func testSessionActivationAttachPlanTargetsResolvedLivePane() async throws {
        let session = makeSession(
            sessionName: "feature branch",
            windows: [
                makeWindow(sessionName: "feature branch", windowID: "@1", paneIDs: ["%1", "%2"])
            ]
        )
        let store = MainTerminalStore(
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    TerminalLiveTarget(
                        sessionName: "feature branch",
                        windowID: "@1",
                        paneID: "%2"
                    )
                }
            )
        )

        await store.activate(session: session, hostsConfig: .empty)

        let plan = try XCTUnwrap(try? store.attachResolution?.get())
        XCTAssertTrue(plan.command.contains("select-window -t"))
        XCTAssertTrue(plan.command.contains("@1"))
        XCTAssertTrue(plan.command.contains("select-pane -t"))
        XCTAssertTrue(plan.command.contains("%2"))
        XCTAssertTrue(plan.command.contains("attach-session -t"))
        XCTAssertTrue(plan.command.contains("feature branch"))

        store.startPlainShell()
    }

    func testSameSessionRetargetUsesClickedPaneAndClearsRequestedPane() async throws {
        let clickedPane = makePane(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let initialLiveTarget = TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let resolvedLiveTarget = TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let renderedTargets = LiveTargetSequence([initialLiveTarget, resolvedLiveTarget])
        let navigationRecorder = NavigationRecorder()
        let sleepController = SleepController(allowedSleeps: 2)
        let surfaceID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let store = MainTerminalStore(
            surfaceID: surfaceID,
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    await renderedTargets.next()
                },
                renderedState: { renderedSurfaceID in
                    XCTAssertEqual(renderedSurfaceID, surfaceID)
                    return self.makeRenderedState(
                        surfaceID: renderedSurfaceID,
                        sessionRef: sessionRef,
                        clientTTY: "/dev/ttys001"
                    )
                },
                applyNavigationIntent: { paneRef, renderedClientTTY, _ in
                    await navigationRecorder.record(
                        paneRef: paneRef,
                        renderedClientTTY: renderedClientTTY
                    )
                },
                sleep: { _ in
                    try await sleepController.sleep()
                }
            )
        )

        await store.activate(pane: clickedPane, hostsConfig: .empty)

        let didResolve = try await waitUntil {
            store.requestedPaneRef == nil
                && store.resolvedPaneRef?.paneID == "%8"
                && store.resolvedPaneRef?.windowID == "@2"
        }

        XCTAssertTrue(didResolve, "Expected the main terminal to resolve the clicked pane")
        XCTAssertNil(store.diagnostic)

        let calls = await navigationRecorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].paneRef.windowID, "@2")
        XCTAssertEqual(calls[0].paneRef.paneID, "%8")
        XCTAssertEqual(calls[0].renderedClientTTY, "/dev/ttys001")

        store.startPlainShell()
    }

    func testRetargetFailureSurfacesTypedDiagnostic() async throws {
        let clickedPane = makePane(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let liveTarget = TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let surfaceID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let sleepController = SleepController(allowedSleeps: 1)
        let store = MainTerminalStore(
            surfaceID: surfaceID,
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    liveTarget
                },
                renderedState: { renderedSurfaceID in
                    XCTAssertEqual(renderedSurfaceID, surfaceID)
                    return self.makeRenderedState(
                        surfaceID: renderedSurfaceID,
                        sessionRef: sessionRef,
                        clientTTY: "/dev/ttys002"
                    )
                },
                applyNavigationIntent: { _, _, _ in
                    throw StubError.renderedLiveTargetUnavailable
                },
                sleep: { _ in
                    try await sleepController.sleep()
                }
            )
        )

        await store.activate(pane: clickedPane, hostsConfig: .empty)

        let didSurfaceDiagnostic = try await waitUntil {
            store.diagnostic == .retargetFailed(
                ActivePaneRef(
                    target: .local,
                    sessionName: "shared",
                    windowID: "@2",
                    paneID: "%8"
                ),
                detail: StubError.renderedLiveTargetUnavailable.localizedDescription
            )
        }

        XCTAssertTrue(didSurfaceDiagnostic, "Expected retarget failure diagnostic to surface")
        store.startPlainShell()
    }

    func testResolvedNavigationStopsPollingAfterConvergence() async throws {
        let clickedPane = makePane(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let initialLiveTarget = TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let resolvedLiveTarget = TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%8"
        )
        let renderedTargets = LiveTargetSequence([
            initialLiveTarget,
            resolvedLiveTarget
        ])
        let liveTargetCalls = Counter()
        let navigationRecorder = NavigationRecorder()
        let sleepController = SleepController(allowedSleeps: 2)
        let surfaceID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "shared")
        let store = MainTerminalStore(
            surfaceID: surfaceID,
            dependencies: makeDependencies(
                liveTarget: { _, _ in
                    await liveTargetCalls.increment()
                    return await renderedTargets.next()
                },
                renderedState: { renderedSurfaceID in
                    XCTAssertEqual(renderedSurfaceID, surfaceID)
                    return self.makeRenderedState(
                        surfaceID: renderedSurfaceID,
                        sessionRef: sessionRef,
                        clientTTY: "/dev/ttys009"
                    )
                },
                applyNavigationIntent: { paneRef, renderedClientTTY, _ in
                    await navigationRecorder.record(
                        paneRef: paneRef,
                        renderedClientTTY: renderedClientTTY
                    )
                },
                sleep: { _ in
                    try await sleepController.sleep()
                }
            )
        )

        await store.activate(pane: clickedPane, hostsConfig: .empty)

        let didObserveDrift = try await waitUntil {
            store.requestedPaneRef == nil
                && store.resolvedPaneRef?.windowID == "@2"
                && store.resolvedPaneRef?.paneID == "%8"
        }
        let calls = await navigationRecorder.calls()
        let liveTargetCallCount = await liveTargetCalls.value()

        XCTAssertTrue(
            didObserveDrift,
            "Expected navigation loop to converge on the clicked pane"
        )
        XCTAssertEqual(
            liveTargetCallCount,
            2,
            "Converged navigation should stop polling the session live target after the clicked pane is visible"
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].paneRef.windowID, "@2")
        XCTAssertEqual(calls[0].paneRef.paneID, "%8")
        XCTAssertNil(store.diagnostic)

        store.startPlainShell()
    }

    private func makeDependencies(
        liveTarget: @escaping @Sendable (SessionRef, HostsConfig) async throws -> TerminalLiveTarget = { _, _ in
            throw StubError.liveTargetUnavailable
        },
        liveWindowTarget: @escaping @Sendable (SessionRef, String, HostsConfig) async throws -> TerminalLiveTarget = { _, _, _ in
            throw StubError.liveTargetUnavailable
        },
        renderedLiveTarget: @escaping @Sendable (String, TargetRef, HostsConfig) async throws -> TerminalLiveTarget = { _, _, _ in
            throw StubError.renderedLiveTargetUnavailable
        },
        renderedState: @escaping @MainActor (UUID) -> GhosttyRenderedTerminalSurfaceState? = { _ in nil },
        applyNavigationIntent: @escaping @Sendable (ActivePaneRef, String, HostsConfig) async throws -> Void = { _, _, _ in },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
            throw CancellationError()
        }
    ) -> MainTerminalStoreDependencies {
        MainTerminalStoreDependencies(
            liveTarget: liveTarget,
            liveWindowTarget: liveWindowTarget,
            renderedLiveTarget: renderedLiveTarget,
            renderedState: renderedState,
            applyNavigationIntent: applyNavigationIntent,
            sleep: sleep
        )
    }

    private func makeSession(
        source: String = "local",
        sessionName: String,
        windows: [WindowGroup]
    ) -> SessionGroup {
        SessionGroup(
            source: source,
            sessionName: sessionName,
            windows: windows
        )
    }

    private func makeWindow(
        source: String = "local",
        sessionName: String,
        windowID: String,
        paneIDs: [String]
    ) -> WindowGroup {
        WindowGroup(
            source: source,
            sessionName: sessionName,
            windowId: windowID,
            panes: paneIDs.enumerated().map { index, paneID in
                makePane(
                    source: source,
                    sessionName: sessionName,
                    windowID: windowID,
                    paneID: paneID,
                    windowIndex: index + 1
                )
            }
        )
    }

    private func makePane(
        source: String = "local",
        sessionName: String,
        windowID: String,
        paneID: String,
        windowIndex: Int? = 1
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: source,
            paneId: paneID,
            sessionName: sessionName,
            windowId: windowID,
            windowIndex: windowIndex,
            currentPath: "/tmp/\(sessionName)",
            currentCmd: "zsh"
        )
    }

    private func makeRenderedState(
        surfaceID: UUID,
        sessionRef: SessionRef,
        clientTTY: String?,
        attachCommand: String? = nil
    ) -> GhosttyRenderedTerminalSurfaceState {
        GhosttyRenderedTerminalSurfaceState(
            context: GhosttyTerminalSurfaceContext(
                viewportID: UUID(),
                surfaceID: surfaceID,
                surfaceKey: "main-terminal:test",
                sessionRef: sessionRef
            ),
            attachCommand: attachCommand ?? "tmux attach-session -t \(sessionRef.sessionName)",
            clientTTY: clientTTY,
            generation: 1
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        condition: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try await Task.sleep(for: pollInterval)
        }
        return condition()
    }
}

private enum StubError: LocalizedError {
    case liveTargetUnavailable
    case renderedLiveTargetUnavailable
    case unexpectedSessionLiveTargetLookup

    var errorDescription: String? {
        switch self {
        case .liveTargetUnavailable:
            return "live target unavailable"
        case .renderedLiveTargetUnavailable:
            return "rendered live target unavailable"
        case .unexpectedSessionLiveTargetLookup:
            return "unexpected session live target lookup"
        }
    }
}

private actor LiveTargetSequence {
    private var remaining: [TerminalLiveTarget]
    private var last: TerminalLiveTarget

    init(_ values: [TerminalLiveTarget]) {
        precondition(!values.isEmpty, "LiveTargetSequence requires at least one value")
        self.remaining = values
        self.last = values[0]
    }

    func next() -> TerminalLiveTarget {
        guard remaining.isEmpty == false else {
            return last
        }
        let next = remaining.removeFirst()
        last = next
        return next
    }
}

private actor NavigationRecorder {
    struct Call: Equatable, Sendable {
        let paneRef: ActivePaneRef
        let renderedClientTTY: String
    }

    private var storedCalls: [Call] = []

    func record(paneRef: ActivePaneRef, renderedClientTTY: String) {
        storedCalls.append(
            Call(
                paneRef: paneRef,
                renderedClientTTY: renderedClientTTY
            )
        )
    }

    func calls() -> [Call] {
        storedCalls
    }
}

private actor Counter {
    private var storedValue = 0

    func increment() {
        storedValue += 1
    }

    func value() -> Int {
        storedValue
    }
}

private actor SleepController {
    private var remainingSuccessfulSleeps: Int

    init(allowedSleeps: Int) {
        self.remainingSuccessfulSleeps = allowedSleeps
    }

    func sleep() throws {
        if remainingSuccessfulSleeps > 0 {
            remainingSuccessfulSleeps -= 1
            return
        }
        throw CancellationError()
    }
}
