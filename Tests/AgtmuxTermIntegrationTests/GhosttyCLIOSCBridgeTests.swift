import XCTest
import AppKit
@testable import AgtmuxTerm
import AgtmuxTermCore
import GhosttyKit

private actor UITestNavigationIntentRecorder {
    private(set) var activePaneRef: ActivePaneRef?
    private(set) var renderedClientTTY: String?
    private(set) var hostsConfig: HostsConfig?

    func record(
        activePaneRef: ActivePaneRef,
        renderedClientTTY: String,
        hostsConfig: HostsConfig
    ) {
        self.activePaneRef = activePaneRef
        self.renderedClientTTY = renderedClientTTY
        self.hostsConfig = hostsConfig
    }
}

final class GhosttyCLIOSCBridgeTests: XCTestCase {
    private var savedTerminalHostModeDefaultsValue: String?
    private var savedTerminalHostModeDefaultsExisted = false

    private func resetTerminalHostModeRuntimeSynchronously() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                TerminalHostModeRuntime.shared.resetForTesting()
                TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
                GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
            }
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            TerminalHostModeRuntime.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
    }

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedTerminalHostModeDefaultsExisted = defaults.object(forKey: TerminalHostMode.userDefaultsKey) != nil
        savedTerminalHostModeDefaultsValue = defaults.string(forKey: TerminalHostMode.userDefaultsKey)
        defaults.removeObject(forKey: TerminalHostMode.userDefaultsKey)
        resetTerminalHostModeRuntimeSynchronously()
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if savedTerminalHostModeDefaultsExisted {
            defaults.set(savedTerminalHostModeDefaultsValue, forKey: TerminalHostMode.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: TerminalHostMode.userDefaultsKey)
        }
        resetTerminalHostModeRuntimeSynchronously()
        super.tearDown()
    }

    func testDecodeRequestRejectsMalformedJSONPayload() {
        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeRequest(from: Data("{".utf8))
        ) { error in
            guard case .malformedJSON(let reason) = error as? GhosttyCLIOSCBridgeError else {
                return XCTFail("Expected malformed JSON error, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testDecodeRequestRejectsNonObjectPayload() {
        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeRequest(from: Data("[1,2,3]".utf8))
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .payloadRootMustBeObject
            )
        }
    }

    func testDecodeRequestRejectsUnsupportedVersion() {
        let payload = """
        {"version":2,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/docs","placement":"replace","pin":false}
        """

        assertDecodeError(
            payload: payload,
            expected: .unsupportedVersion(2)
        )
    }

    func testDecodeRequestRejectsUnsupportedAction() {
        let payload = """
        {"version":1,"action":"reveal","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/docs","placement":"replace","pin":false}
        """

        assertDecodeError(
            payload: payload,
            expected: .unsupportedAction("reveal")
        )
    }

    func testDecodeRequestRejectsUnsupportedKind() {
        let payload = """
        {"version":1,"action":"open","kind":"directory","target":"local","cwd":"/tmp","argument":"/tmp","placement":"replace","pin":false}
        """

        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeRequest(from: Data(payload.utf8))
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .unsupportedKind("directory")
            )
        }
    }

    func testDecodeRequestRejectsRelativeFilePath() {
        let payload = """
        {"version":1,"action":"open","kind":"file","target":"local","cwd":"/tmp","argument":"spec.md","placement":"replace","pin":false}
        """

        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeRequest(from: Data(payload.utf8))
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .relativeFilePath("spec.md")
            )
        }
    }

    func testDecodeRequestRejectsUnsupportedPlacement() {
        let payload = """
        {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/docs","placement":"center","pin":false}
        """

        assertDecodeError(
            payload: payload,
            expected: .unsupportedPlacement("center")
        )
    }

    func testDecodeRequestRejectsEmptyRequiredFields() {
        let cases: [(name: String, payload: String, expected: GhosttyCLIOSCBridgeError)] = [
            (
                "target",
                """
                {"version":1,"action":"open","kind":"url","target":"","cwd":"/tmp","argument":"https://example.com/docs","placement":"replace","pin":false}
                """,
                .emptyTarget
            ),
            (
                "cwd",
                """
                {"version":1,"action":"open","kind":"url","target":"local","cwd":"","argument":"https://example.com/docs","placement":"replace","pin":false}
                """,
                .emptyCwd
            ),
            (
                "argument",
                """
                {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"","placement":"replace","pin":false}
                """,
                .emptyArgument
            )
        ]

        for testCase in cases {
            XCTContext.runActivity(named: testCase.name) { _ in
                assertDecodeError(
                    payload: testCase.payload,
                    expected: testCase.expected
                )
            }
        }
    }

    func testDecodeActionParsesBindClientPayload() throws {
        let payload = """
        {"version":1,"action":"bind_client","client_tty":"/dev/ttys008"}
        """

        XCTAssertEqual(
            try GhosttyCLIOSCBridge.decodeAction(from: Data(payload.utf8)),
            .bindClientTTY("/dev/ttys008")
        )
    }

    func testDecodeActionRejectsEmptyBindClientTTY() {
        let payload = """
        {"version":1,"action":"bind_client","client_tty":""}
        """

        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeAction(from: Data(payload.utf8))
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .emptyClientTTY
            )
        }
    }

    @MainActor
    func testHandleActionConsumes9911CustomOSCFromRegisteredSurfaceAndOpensExpectedTile() async throws {
        let sourceSession = SessionRef(target: .local, sessionName: "source")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .tile(sourceTile),
            focusedTileID: sourceTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench])

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9911)
        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:source",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t backend"
        )

        let payload = """
        {"version":1,"action":"open","kind":"url","target":"docs","cwd":"/srv/docs","argument":"https://example.com/docs","placement":"replace","pin":false}
        """

        var sawMainActorHop = false
        var sawDispatcherOnMainThread = false
        var dispatchResult: GhosttyCLIOSCBridgeResult?
        var reportedError: GhosttyCLIOSCBridgeError?

        let consumed = try await GhosttyApp.withTestBridgeHooks(
            dispatcher: { target, action in
                sawDispatcherOnMainThread = Thread.isMainThread
                let result = try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: target,
                    action: action,
                    store: store,
                    registry: registry
                )
                dispatchResult = result
                return result
            },
            failureReporter: { error in
                reportedError = error as? GhosttyCLIOSCBridgeError
            },
            mainActorObserver: {
                sawMainActorHop = Thread.isMainThread
            }
        ) {
            let consumed = await Self.invokeHandleActionOffMainThread(
                surfaceHandle: surfaceHandle,
                payload: payload
            )
            let delivered = await waitUntil {
                sawMainActorHop
                    && sawDispatcherOnMainThread
                    && dispatchResult != nil
            }
            XCTAssertTrue(delivered)
            return consumed
        }

        XCTAssertTrue(consumed)
        XCTAssertTrue(sawMainActorHop)
        XCTAssertTrue(sawDispatcherOnMainThread)
        XCTAssertNil(reportedError)

        let result = try XCTUnwrap(dispatchResult)
        XCTAssertEqual(store.activeWorkbench?.id, sourceWorkbench.id)
        guard case .bridge(let bridgeResult) = result else {
            return XCTFail("Expected bridge open result")
        }
        XCTAssertEqual(
            result,
            .bridge(.openedBrowser(workbenchID: sourceWorkbench.id, tileID: bridgeResult.tileID))
        )
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, bridgeResult.tileID)

        guard case .tile(let insertedTile)? = store.activeWorkbench?.root else {
            return XCTFail("Expected the bridge open to replace the emitting terminal tile")
        }
        guard case .browser(let url, let sourceContext) = insertedTile.kind else {
            return XCTFail("Expected a browser tile to be opened")
        }

        XCTAssertEqual(url, URL(string: "https://example.com/docs")!)
        XCTAssertEqual(sourceContext, "docs: /srv/docs")
        XCTAssertFalse(insertedTile.pinned)
    }

    @MainActor
    func testHandleActionDoesNotConsumeNon9911CustomOSC() async throws {
        let sourceSession = SessionRef(target: .local, sessionName: "source")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .tile(sourceTile),
            focusedTileID: sourceTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench])

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9912)
        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:source",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t backend"
        )

        let payload = """
        {"version":1,"action":"open","kind":"url","target":"docs","cwd":"/srv/docs","argument":"https://example.com/ignored","placement":"replace","pin":false}
        """

        var sawMainActorHop = false
        var sawDispatcherOnMainThread = false
        var dispatchResult: GhosttyCLIOSCBridgeResult?
        var reportedError: GhosttyCLIOSCBridgeError?

        let consumed = try await GhosttyApp.withTestBridgeHooks(
            dispatcher: { target, action in
                sawDispatcherOnMainThread = Thread.isMainThread
                let result = try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: target,
                    action: action,
                    store: store,
                    registry: registry
                )
                dispatchResult = result
                return result
            },
            failureReporter: { error in
                reportedError = error as? GhosttyCLIOSCBridgeError
            },
            mainActorObserver: {
                sawMainActorHop = Thread.isMainThread
            }
        ) {
            let consumed = await Self.invokeHandleActionOffMainThread(
                osc: 7000,
                surfaceHandle: surfaceHandle,
                payload: payload
            )
            try? await Task.sleep(for: .milliseconds(50))
            return consumed
        }

        XCTAssertFalse(consumed)
        XCTAssertFalse(sawMainActorHop)
        XCTAssertFalse(sawDispatcherOnMainThread)
        XCTAssertNil(dispatchResult)
        XCTAssertNil(reportedError)

        guard case .tile(let remainingTile)? = store.activeWorkbench?.root else {
            return XCTFail("Expected the source terminal tile to remain untouched")
        }

        XCTAssertEqual(remainingTile, sourceTile)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, sourceTile.id)
    }

    @MainActor
    func testDispatchIfBridgeActionBindsRenderedClientTTYForRegisteredSurface() throws {
        let sourceSession = SessionRef(target: .local, sessionName: "source")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .tile(sourceTile),
            focusedTileID: sourceTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench])

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9911)
        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:source",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t source"
        )

        let payload = """
        {"version":1,"action":"bind_client","client_tty":"/dev/ttys008"}
        """

        let result = try XCTUnwrap(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeSurfaceTarget(surfaceHandle),
                    action: action,
                    store: store,
                    registry: registry
                )
            }
        )

        XCTAssertEqual(result, .boundClientTTY("/dev/ttys008"))
        XCTAssertEqual(
            registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY,
            "/dev/ttys008"
        )
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, sourceTile.id)
    }

    @MainActor
    func testDispatchIfBridgeActionStagesRenderedClientTTYUntilSurfaceRegisters() throws {
        let sourceSession = SessionRef(target: .local, sessionName: "source")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .tile(sourceTile),
            focusedTileID: sourceTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench])

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9913)
        let payload = """
        {"version":1,"action":"bind_client","client_tty":"/dev/ttys042"}
        """

        let result = try XCTUnwrap(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeSurfaceTarget(surfaceHandle),
                    action: action,
                    store: store,
                    registry: registry
                )
            }
        )

        XCTAssertEqual(result, .boundClientTTY("/dev/ttys042"))
        XCTAssertNil(registry.renderedState(forSurfaceHandle: surfaceHandle))

        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:source",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t source"
        )

        XCTAssertEqual(
            registry.renderedState(forSurfaceHandle: surfaceHandle)?.clientTTY,
            "/dev/ttys042"
        )
    }

    @MainActor
    func testHandleActionReportsUnregisteredSurfaceFailureThroughReporter() async throws {
        let store = WorkbenchStoreV2()
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x404)
        let payload = """
        {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/fail","placement":"replace","pin":false}
        """

        var sawMainActorHop = false
        var failureReporterOnMainThread = false
        var reportedError: GhosttyCLIOSCBridgeError?

        let consumed = try await GhosttyApp.withTestBridgeHooks(
            dispatcher: { target, action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: target,
                    action: action,
                    store: store,
                    registry: registry
                )
            },
            failureReporter: { error in
                failureReporterOnMainThread = Thread.isMainThread
                reportedError = error as? GhosttyCLIOSCBridgeError
            },
            mainActorObserver: {
                sawMainActorHop = Thread.isMainThread
            }
        ) {
            let consumed = await Self.invokeHandleActionOffMainThread(
                surfaceHandle: surfaceHandle,
                payload: payload
            )
            let delivered = await waitUntil {
                sawMainActorHop
                    && failureReporterOnMainThread
                    && reportedError != nil
            }
            XCTAssertTrue(delivered)
            return consumed
        }

        XCTAssertTrue(consumed)
        XCTAssertTrue(sawMainActorHop)
        XCTAssertTrue(failureReporterOnMainThread)
        XCTAssertEqual(
            reportedError,
            .surfaceResolution(.unregisteredSurface(surfaceHandle))
        )
        XCTAssertTrue(store.activeWorkbench?.root.isEmpty == true)
        XCTAssertNil(store.activeWorkbench?.focusedTileID)
    }

    @MainActor
    func testDispatchIfBridgeActionIgnoresNon9911CustomOSC() throws {
        let store = WorkbenchStoreV2()
        let payload = """
        {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/ignored","placement":"replace","pin":false}
        """

        let result = try withCustomOSCAction(
            osc: 7000,
            payload: payload
        ) { action in
            try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                target: makeAppTarget(),
                action: action,
                store: store,
                registry: GhosttyTerminalSurfaceRegistry()
            )
        }

        XCTAssertNil(result)
        XCTAssertTrue(store.activeWorkbench?.root.isEmpty == true)
        XCTAssertNil(store.activeWorkbench?.focusedTileID)
    }

    @MainActor
    func testDispatchIfBridgeActionOpensBrowserInEmittingWorkbenchAndPreservesSourceMetadata() throws {
        let sourceSession = SessionRef(target: .local, sessionName: "source")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let siblingTile = WorkbenchTile(
            id: UUID(),
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/untouched.md"))
        )
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .split(
                WorkbenchSplit(
                    axis: .horizontal,
                    first: .tile(sourceTile),
                    second: .tile(siblingTile)
                )
            ),
            focusedTileID: siblingTile.id
        )
        let activeWorkbenchTile = WorkbenchTile(
            id: UUID(),
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/active.md"))
        )
        let activeWorkbench = Workbench(
            title: "Active",
            root: .tile(activeWorkbenchTile),
            focusedTileID: activeWorkbenchTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench, activeWorkbench])
        store.activeWorkbenchIndex = 1

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9911)
        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:source",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t backend"
        )

        let payload = """
        {"version":1,"action":"open","kind":"url","target":"docs","cwd":"/srv/docs","argument":"https://example.com/docs","placement":"right","pin":true}
        """

        let result = try XCTUnwrap(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeSurfaceTarget(surfaceHandle),
                    action: action,
                    store: store,
                    registry: registry
                )
            }
        )

        XCTAssertEqual(store.activeWorkbench?.id, sourceWorkbench.id)
        guard case .bridge(let bridgeResult) = result else {
            return XCTFail("Expected bridge open result")
        }
        XCTAssertEqual(
            result,
            .bridge(.openedBrowser(workbenchID: sourceWorkbench.id, tileID: bridgeResult.tileID))
        )
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, bridgeResult.tileID)

        guard case .split(let rootSplit)? = store.activeWorkbench?.root else {
            return XCTFail("Expected the source workbench root split to be preserved")
        }
        guard case .split(let nestedSplit) = rootSplit.first,
              case .tile(let untouchedTile) = rootSplit.second,
              case .tile(let originalTerminal) = nestedSplit.first,
              case .tile(let insertedBrowser) = nestedSplit.second else {
            return XCTFail("Expected right placement to split around the emitting terminal tile")
        }
        guard case .browser(let url, let sourceContext) = insertedBrowser.kind else {
            return XCTFail("Expected a browser tile to be inserted")
        }

        XCTAssertEqual(rootSplit.axis, .horizontal)
        XCTAssertEqual(nestedSplit.axis, .horizontal)
        XCTAssertEqual(untouchedTile, siblingTile)
        XCTAssertEqual(originalTerminal, sourceTile)
        XCTAssertEqual(url, URL(string: "https://example.com/docs")!)
        XCTAssertEqual(sourceContext, "docs: /srv/docs")
        XCTAssertTrue(insertedBrowser.pinned)
    }

    @MainActor
    func testDispatchIfBridgeActionOpensDocumentInEmittingWorkbenchAndPreservesPlacement() throws {
        let sourceSession = SessionRef(target: .remote(hostKey: "edge"), sessionName: "backend")
        let sourceTile = WorkbenchTile(id: UUID(), kind: .terminal(sessionRef: sourceSession))
        let sourceWorkbench = Workbench(
            title: "Source",
            root: .tile(sourceTile),
            focusedTileID: sourceTile.id
        )
        let activeWorkbenchTile = WorkbenchTile(
            id: UUID(),
            kind: .document(ref: DocumentRef(target: .local, path: "/tmp/active.md"))
        )
        let activeWorkbench = Workbench(
            title: "Other",
            root: .tile(activeWorkbenchTile),
            focusedTileID: activeWorkbenchTile.id
        )
        let store = WorkbenchStoreV2(workbenches: [sourceWorkbench, activeWorkbench])
        store.activeWorkbenchIndex = 1

        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9912)
        registry.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: sourceWorkbench.id,
                tileID: sourceTile.id,
                surfaceKey: "wb:backend",
                sessionRef: sourceSession
            ),
            attachCommand: "tmux attach-session -t backend"
        )

        let payload = """
        {"version":1,"action":"open","kind":"file","target":"docs","cwd":"/srv/docs","argument":"/srv/docs/spec.md","placement":"up","pin":false}
        """

        let result = try XCTUnwrap(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeSurfaceTarget(surfaceHandle),
                    action: action,
                    store: store,
                    registry: registry
                )
            }
        )

        XCTAssertEqual(store.activeWorkbench?.id, sourceWorkbench.id)
        guard case .bridge(let bridgeResult) = result else {
            return XCTFail("Expected bridge open result")
        }
        XCTAssertEqual(
            result,
            .bridge(.openedDocument(workbenchID: sourceWorkbench.id, tileID: bridgeResult.tileID))
        )
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, bridgeResult.tileID)

        guard case .split(let split)? = store.activeWorkbench?.root else {
            return XCTFail("Expected up placement to create a split around the emitting terminal tile")
        }
        guard case .tile(let insertedDocument) = split.first,
              case .tile(let originalTerminal) = split.second else {
            return XCTFail("Expected document insertion above the emitting terminal tile")
        }
        guard case .document(let ref) = insertedDocument.kind else {
            return XCTFail("Expected a document tile to be inserted")
        }

        XCTAssertEqual(split.axis, .vertical)
        XCTAssertEqual(originalTerminal, sourceTile)
        XCTAssertEqual(ref, DocumentRef(target: .remote(hostKey: "docs"), path: "/srv/docs/spec.md"))
        XCTAssertFalse(insertedDocument.pinned)
    }

    @MainActor
    func testDispatchIfBridgeActionFailsExplicitlyForUnregisteredSurface() throws {
        let store = WorkbenchStoreV2()
        let registry = GhosttyTerminalSurfaceRegistry()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x404)
        let payload = """
        {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/fail","placement":"replace","pin":false}
        """

        XCTAssertThrowsError(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeSurfaceTarget(surfaceHandle),
                    action: action,
                    store: store,
                    registry: registry
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .surfaceResolution(.unregisteredSurface(surfaceHandle))
            )
        }
    }

    @MainActor
    func testDispatchIfBridgeActionFailsExplicitlyForNonSurfaceTarget() throws {
        let store = WorkbenchStoreV2()
        let payload = """
        {"version":1,"action":"open","kind":"url","target":"local","cwd":"/tmp","argument":"https://example.com/fail","placement":"replace","pin":false}
        """

        XCTAssertThrowsError(
            try withCustomOSCAction(payload: payload) { action in
                try GhosttyCLIOSCBridge.dispatchIfBridgeAction(
                    target: makeAppTarget(),
                    action: action,
                    store: store,
                    registry: GhosttyTerminalSurfaceRegistry()
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                .surfaceResolution(.unsupportedTarget)
            )
        }
    }

    @MainActor
    func testSurfacePoolRegisterRequestsInitialDirtyTickAndDrawsOnce() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        let leafID = UUID()
        var scheduledTicks = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: leafID,
                tmuxPaneID: "%1",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x610)
            )

            XCTAssertEqual(scheduledTicks, 1)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 1)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 1)
        }
    }

    @MainActor
    func testHandleActionRenderQueuesDirectDrawAndDrawsOnlyTargetSurface() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let dirtyView = GhosttyTerminalViewDrawSpy()
        let cleanView = GhosttyTerminalViewDrawSpy()
        let dirtyHandle = GhosttySurfaceHandle(rawValue: 0x611)
        let cleanHandle = GhosttySurfaceHandle(rawValue: 0x612)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        await GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            await GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: dirtyView,
                    leafID: UUID(),
                    tmuxPaneID: "%11",
                    surfaceHandle: dirtyHandle
                )
                SurfacePool.shared.register(
                    view: cleanView,
                    leafID: UUID(),
                    tmuxPaneID: "%12",
                    surfaceHandle: cleanHandle
                )

                GhosttyApp.runDirtyDrawPassForTesting()
                dirtyView.resetDrawTracking()
                cleanView.resetDrawTracking()
                dirtyView.resetScrollTelemetryForTesting()
                cleanView.resetScrollTelemetryForTesting()
                GhosttyApp.resetSurfaceDrawTelemetryForTesting()
                scheduledTicks = 0
                scheduledDirectDraws = 0
                dirtyView.noteScrollInputTelemetryForTesting()

                XCTAssertTrue(
                    GhosttyApp.handleAction(
                        nil,
                        target: makeSurfaceTarget(dirtyHandle),
                        action: makeRenderAction()
                    )
                )

                let drew = await waitUntil {
                    dirtyView.triggerDrawCallCount == 1
                }
                XCTAssertTrue(drew)
                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 1)
                XCTAssertEqual(cleanView.triggerDrawCallCount, 0)

                let viewSnapshot = dirtyView.scrollTelemetrySnapshotForTesting()
                XCTAssertEqual(viewSnapshot.renderRequestCount, 1)
                XCTAssertEqual(viewSnapshot.refreshDrawRequestCount, 1)
                XCTAssertEqual(viewSnapshot.immediatePresentationDrawCount, 0)

                let appSnapshot = GhosttyApp.surfaceDrawTelemetrySnapshotForTesting()
                XCTAssertEqual(appSnapshot.renderCallbackCount, 1)
                XCTAssertEqual(appSnapshot.scheduledDirectDrawPassCount, 1)
                XCTAssertEqual(appSnapshot.immediateDirectDrawPassCount, 0)
                XCTAssertEqual(appSnapshot.dirtyDrawPassCount, 1)
                XCTAssertEqual(appSnapshot.dirtyDrawnSurfaceCount, 1)
            }
        }
    }

    @MainActor
    func testHandleActionRenderOffMainQueuesDirectDrawAndDrawsOnlyTargetSurface() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let dirtyView = GhosttyTerminalViewDrawSpy()
        let cleanView = GhosttyTerminalViewDrawSpy()
        let dirtyHandle = GhosttySurfaceHandle(rawValue: 0x622)
        let cleanHandle = GhosttySurfaceHandle(rawValue: 0x623)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        let consumed = await GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            await GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: dirtyView,
                    leafID: UUID(),
                    tmuxPaneID: "%21",
                    surfaceHandle: dirtyHandle
                )
                SurfacePool.shared.register(
                    view: cleanView,
                    leafID: UUID(),
                    tmuxPaneID: "%22",
                    surfaceHandle: cleanHandle
                )

                GhosttyApp.runDirtyDrawPassForTesting()
                dirtyView.resetDrawTracking()
                cleanView.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0
                let consumed = await Self.invokeHandleRenderOffMainThread(surfaceHandle: dirtyHandle)
                let scheduled = await waitUntil {
                    scheduledDirectDraws == 1
                }
                XCTAssertTrue(scheduled)
                return consumed
            }
        }
        XCTAssertTrue(consumed)
        let drew = await waitUntil {
            dirtyView.triggerDrawCallCount == 1
        }
        XCTAssertTrue(drew)
        XCTAssertEqual(scheduledTicks, 0)
        XCTAssertEqual(cleanView.triggerDrawCallCount, 0)
    }

    @MainActor
    func testHandleActionRenderCoalescesDirectDrawPassScheduling() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        let handle = GhosttySurfaceHandle(rawValue: 0x624)
        var scheduledDirectDraws = 0

        await GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDraws += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: UUID(),
                tmuxPaneID: "%23",
                surfaceHandle: handle
            )

            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetDrawTracking()
            scheduledDirectDraws = 0

            XCTAssertTrue(
                GhosttyApp.handleAction(
                    nil,
                    target: makeSurfaceTarget(handle),
                    action: makeRenderAction()
                )
            )
            XCTAssertTrue(
                GhosttyApp.handleAction(
                    nil,
                    target: makeSurfaceTarget(handle),
                    action: makeRenderAction()
                )
            )

            let drew = await waitUntil {
                view.triggerDrawCallCount == 1
            }
            XCTAssertTrue(drew)
            XCTAssertEqual(scheduledDirectDraws, 1)
        }
    }

    @MainActor
    func testHandleActionRenderRunsDirtyDrawImmediatelyForRecentPreciseAlternateScroll() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let dirtyView = GhosttyTerminalViewDrawSpy()
        let cleanView = GhosttyTerminalViewDrawSpy()
        dirtyView.shouldPreferImmediateDirtyDrawForRenderCallback = true
        let dirtyHandle = GhosttySurfaceHandle(rawValue: 0x625)
        let cleanHandle = GhosttySurfaceHandle(rawValue: 0x626)
        var scheduledDirectDraws = 0

        GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDraws += 1
        }) {
            SurfacePool.shared.register(
                view: dirtyView,
                leafID: UUID(),
                tmuxPaneID: "%24",
                surfaceHandle: dirtyHandle
            )
            SurfacePool.shared.register(
                view: cleanView,
                leafID: UUID(),
                tmuxPaneID: "%25",
                surfaceHandle: cleanHandle
            )

            GhosttyApp.runDirtyDrawPassForTesting()
            dirtyView.resetDrawTracking()
            cleanView.resetDrawTracking()
            dirtyView.resetScrollTelemetryForTesting()
            cleanView.resetScrollTelemetryForTesting()
            GhosttyApp.resetSurfaceDrawTelemetryForTesting()
            scheduledDirectDraws = 0
            dirtyView.noteScrollInputTelemetryForTesting()

            XCTAssertTrue(
                GhosttyApp.handleAction(
                    nil,
                    target: makeSurfaceTarget(dirtyHandle),
                    action: makeRenderAction()
                )
            )

            XCTAssertEqual(dirtyView.triggerDrawCallCount, 1)
            XCTAssertEqual(cleanView.triggerDrawCallCount, 0)
            XCTAssertEqual(scheduledDirectDraws, 0)

            let viewSnapshot = dirtyView.scrollTelemetrySnapshotForTesting()
            XCTAssertEqual(viewSnapshot.renderRequestCount, 1)
            XCTAssertEqual(viewSnapshot.refreshDrawRequestCount, 0)
            XCTAssertEqual(viewSnapshot.immediatePresentationDrawCount, 1)

            let appSnapshot = GhosttyApp.surfaceDrawTelemetrySnapshotForTesting()
            XCTAssertEqual(appSnapshot.renderCallbackCount, 1)
            XCTAssertEqual(appSnapshot.scheduledDirectDrawPassCount, 0)
            XCTAssertEqual(appSnapshot.immediateDirectDrawPassCount, 1)
            XCTAssertEqual(appSnapshot.dirtyDrawPassCount, 1)
            XCTAssertEqual(appSnapshot.dirtyDrawnSurfaceCount, 1)
        }
    }

    @MainActor
    func testHandleActionRenderForNextHostBypassesDirectDrawScheduler() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        view.setTerminalHostMode(.next)
        let handle = GhosttySurfaceHandle(rawValue: 0x627)
        var scheduledDirectDraws = 0

        await GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDraws += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: UUID(),
                tmuxPaneID: "%26",
                surfaceHandle: handle
            )

            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetDrawTracking()
            scheduledDirectDraws = 0
            view.setRendererOwnedRenderCallbackEligibilityForTesting(
                usesAlternateScroll: false,
                precision: true,
                verticalDelta: 10,
                now: ProcessInfo.processInfo.systemUptime
            )

            XCTAssertTrue(
                GhosttyApp.handleAction(
                    nil,
                    target: makeSurfaceTarget(handle),
                    action: makeRenderAction()
                )
            )

            let drew = await waitUntil {
                view.triggerDrawCallCount == 1
            }
            XCTAssertTrue(drew)
            XCTAssertEqual(scheduledDirectDraws, 0)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 1)
        }
    }

    @MainActor
    func testHandleActionRenderForNextHostAlternateScrollBypassesDirectDrawScheduler() async {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        view.setTerminalHostMode(.next)
        let handle = GhosttySurfaceHandle(rawValue: 0x628)
        var scheduledDirectDraws = 0

        await GhosttyApp.withTestDirectDrawScheduleObserver({
            scheduledDirectDraws += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: UUID(),
                tmuxPaneID: "%27",
                surfaceHandle: handle
            )

            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetDrawTracking()
            scheduledDirectDraws = 0
            view.setRendererOwnedRenderCallbackEligibilityForTesting(
                usesAlternateScroll: true,
                precision: true,
                verticalDelta: 10,
                now: ProcessInfo.processInfo.systemUptime
            )

            XCTAssertTrue(
                GhosttyApp.handleAction(
                    nil,
                    target: makeSurfaceTarget(handle),
                    action: makeRenderAction()
                )
            )

            let drew = await waitUntil {
                view.triggerDrawCallCount == 1
            }
            XCTAssertTrue(drew)
            XCTAssertEqual(scheduledDirectDraws, 0)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 1)
        }
    }

    @MainActor
    func testHandleActionRenderDuringTickDoesNotScheduleFollowUpTick() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        let handle = GhosttySurfaceHandle(rawValue: 0x620)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: view,
                    leafID: UUID(),
                    tmuxPaneID: "%18",
                    surfaceHandle: handle
                )
                GhosttyApp.runDirtyDrawPassForTesting()
                view.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0

                GhosttyApp.withTestTickExecutionState(true) {
                    XCTAssertTrue(
                        GhosttyApp.handleAction(
                            nil,
                            target: makeSurfaceTarget(handle),
                            action: makeRenderAction()
                        )
                    )
                }

                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 0)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(view.triggerDrawCallCount, 1)
            }
        }
    }

    @MainActor
    func testHandleActionRenderBackgroundedSurfaceDefersDrawUntilActivate() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        let leafID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x625)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: view,
                    leafID: leafID,
                    tmuxPaneID: "%24",
                    surfaceHandle: surfaceHandle
                )
                GhosttyApp.runDirtyDrawPassForTesting()
                view.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0

                SurfacePool.shared.background(leafID: leafID)
                XCTAssertTrue(
                    GhosttyApp.handleAction(
                        nil,
                        target: makeSurfaceTarget(surfaceHandle),
                        action: makeRenderAction()
                    )
                )

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 0)
                XCTAssertEqual(view.triggerDrawCallCount, 0)

                SurfacePool.shared.activate(leafID: leafID)
                XCTAssertEqual(scheduledTicks, 1)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(view.triggerDrawCallCount, 1)
            }
        }
    }

    @MainActor
    func testBackgroundedDirtySurfaceRequestsTickOnlyAfterReactivation() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let view = GhosttyTerminalViewDrawSpy()
        let leafID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x613)
        var scheduledTicks = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: leafID,
                tmuxPaneID: "%13",
                surfaceHandle: surfaceHandle
            )

            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetDrawTracking()
            scheduledTicks = 0

            SurfacePool.shared.background(leafID: leafID)
            SurfacePool.shared.markDirty(surfaceHandle: surfaceHandle)
            XCTAssertEqual(scheduledTicks, 0)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 0)

            SurfacePool.shared.activate(leafID: leafID)
            XCTAssertEqual(scheduledTicks, 1)

            GhosttyApp.runDirtyDrawPassForTesting()
            XCTAssertEqual(view.triggerDrawCallCount, 1)
        }
    }

    @MainActor
    func testReRegisterReplacesSurfaceHandleDirtyRouting() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let originalView = GhosttyTerminalViewDrawSpy()
        let replacementView = GhosttyTerminalViewDrawSpy()
        let leafID = UUID()
        let originalHandle = GhosttySurfaceHandle(rawValue: 0x614)
        let replacementHandle = GhosttySurfaceHandle(rawValue: 0x615)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: originalView,
                    leafID: leafID,
                    tmuxPaneID: "%14",
                    surfaceHandle: originalHandle
                )
                GhosttyApp.runDirtyDrawPassForTesting()
                originalView.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0

                SurfacePool.shared.register(
                    view: replacementView,
                    leafID: leafID,
                    tmuxPaneID: "%14",
                    surfaceHandle: replacementHandle
                )
                XCTAssertEqual(scheduledTicks, 1)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(replacementView.triggerDrawCallCount, 1)
                replacementView.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0

                XCTAssertTrue(
                    GhosttyApp.handleAction(
                        nil,
                        target: makeSurfaceTarget(originalHandle),
                        action: makeRenderAction()
                    )
                )
                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 0)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(originalView.triggerDrawCallCount, 0)
                XCTAssertEqual(replacementView.triggerDrawCallCount, 0)

                XCTAssertTrue(
                    GhosttyApp.handleAction(
                        nil,
                        target: makeSurfaceTarget(replacementHandle),
                        action: makeRenderAction()
                    )
                )
                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 1)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(replacementView.triggerDrawCallCount, 1)
            }
        }
    }

    @MainActor
    func testStaleReleaseDoesNotTearDownReplacementSurface() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        GhosttyApp.resetSurfaceDrawTelemetryForTesting()
        defer { GhosttyApp.resetSurfaceDrawTelemetryForTesting() }

        let originalView = GhosttyTerminalViewDrawSpy()
        let replacementView = GhosttyTerminalViewDrawSpy()
        let leafID = UUID()
        let originalHandle = GhosttySurfaceHandle(rawValue: 0x616)
        let replacementHandle = GhosttySurfaceHandle(rawValue: 0x617)
        var scheduledTicks = 0
        var scheduledDirectDraws = 0

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            GhosttyApp.withTestDirectDrawScheduleObserver({
                scheduledDirectDraws += 1
            }) {
                SurfacePool.shared.register(
                    view: originalView,
                    leafID: leafID,
                    tmuxPaneID: "%15",
                    surfaceHandle: originalHandle
                )
                GhosttyApp.runDirtyDrawPassForTesting()

                SurfacePool.shared.register(
                    view: replacementView,
                    leafID: leafID,
                    tmuxPaneID: "%15",
                    surfaceHandle: replacementHandle
                )
                GhosttyApp.runDirtyDrawPassForTesting()
                replacementView.resetDrawTracking()
                scheduledTicks = 0
                scheduledDirectDraws = 0

                SurfacePool.shared.release(
                    leafID: leafID,
                    expectedViewID: ObjectIdentifier(originalView)
                )

                XCTAssertTrue(
                    SurfacePool.shared.activeSurfaceViewIDs.contains(ObjectIdentifier(replacementView))
                )

                XCTAssertTrue(
                    GhosttyApp.handleAction(
                        nil,
                        target: makeSurfaceTarget(replacementHandle),
                        action: makeRenderAction()
                    )
                )
                XCTAssertEqual(scheduledTicks, 0)
                XCTAssertEqual(scheduledDirectDraws, 1)

                GhosttyApp.runDirtyDrawPassForTesting()
                XCTAssertEqual(replacementView.triggerDrawCallCount, 1)
            }
        }
    }

    @MainActor
    func testApplyingChangedSurfaceMetricsSchedulesDirtyDrawOnlyForActualMetricDrift() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let view = GhosttyTerminalViewMetricsSpy()
        let leafID = UUID()
        var scheduledTicks = 0
        let initialMetrics = GhosttyTerminalView.SurfaceMetrics(
            pixelWidth: 800,
            pixelHeight: 600,
            xScale: 2.0,
            yScale: 2.0,
            displayID: 77
        )
        let movedDisplayMetrics = GhosttyTerminalView.SurfaceMetrics(
            pixelWidth: 800,
            pixelHeight: 600,
            xScale: 2.0,
            yScale: 2.0,
            displayID: 88
        )

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: leafID,
                tmuxPaneID: "%16",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x618)
            )
            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetMetricTracking()
            scheduledTicks = 0

            view.applySurfaceMetricsForTesting(initialMetrics)
            XCTAssertEqual(
                view.contentScaleUpdates,
                [GhosttyTerminalViewMetricsSpy.ScaleUpdate(xScale: 2.0, yScale: 2.0)]
            )
            XCTAssertEqual(
                view.sizeUpdates,
                [GhosttyTerminalViewMetricsSpy.SizeUpdate(pixelWidth: 800, pixelHeight: 600)]
            )
            XCTAssertEqual(view.displayIDUpdates, [77])
            XCTAssertEqual(scheduledTicks, 1)

            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetMetricTracking()
            scheduledTicks = 0

            view.applySurfaceMetricsForTesting(initialMetrics)
            XCTAssertTrue(view.contentScaleUpdates.isEmpty)
            XCTAssertTrue(view.sizeUpdates.isEmpty)
            XCTAssertTrue(view.displayIDUpdates.isEmpty)
            XCTAssertEqual(scheduledTicks, 0)

            view.applySurfaceMetricsForTesting(movedDisplayMetrics)
            XCTAssertTrue(view.contentScaleUpdates.isEmpty)
            XCTAssertTrue(view.sizeUpdates.isEmpty)
            XCTAssertEqual(view.displayIDUpdates, [88])
            XCTAssertEqual(scheduledTicks, 1)
        }
    }

    @MainActor
    func testApplyingSurfaceMetricsWhileBackgroundedQueuesDrawUntilActivate() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let view = GhosttyTerminalViewMetricsSpy()
        let leafID = UUID()
        var scheduledTicks = 0
        let metrics = GhosttyTerminalView.SurfaceMetrics(
            pixelWidth: 1200,
            pixelHeight: 900,
            xScale: 2.0,
            yScale: 2.0,
            displayID: 91
        )

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: leafID,
                tmuxPaneID: "%17",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x619)
            )
            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetMetricTracking()
            scheduledTicks = 0

            SurfacePool.shared.background(leafID: leafID)
            view.applySurfaceMetricsForTesting(metrics)

            XCTAssertEqual(
                view.contentScaleUpdates,
                [GhosttyTerminalViewMetricsSpy.ScaleUpdate(xScale: 2.0, yScale: 2.0)]
            )
            XCTAssertEqual(
                view.sizeUpdates,
                [GhosttyTerminalViewMetricsSpy.SizeUpdate(pixelWidth: 1200, pixelHeight: 900)]
            )
            XCTAssertEqual(view.displayIDUpdates, [91])
            XCTAssertEqual(scheduledTicks, 0)

            SurfacePool.shared.activate(leafID: leafID)
            XCTAssertEqual(scheduledTicks, 1)
        }
    }

    @MainActor
    func testScrollTelemetrySnapshotTracksCompletedSamplesAndReset() async {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteRenderRequestTelemetry()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteLayerPresentationTelemetryForTesting()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteHostDrawTelemetry()

        view.noteScrollInputTelemetryForTesting()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteRenderRequestTelemetry()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteLayerPresentationTelemetryForTesting()
        try? await Task.sleep(for: .milliseconds(2))
        view.noteHostDrawTelemetry()

        let snapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(snapshot.scrollToRenderRequest.count, 2)
        XCTAssertEqual(snapshot.scrollToFirstDraw.count, 2)
        XCTAssertEqual(snapshot.scrollToLayerPresent.count, 2)
        XCTAssertEqual(snapshot.renderRequestToDraw.count, 2)
        XCTAssertEqual(snapshot.drawGap.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationDrawGap.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationImmediateQueueDelay.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationPumpWakeLateness.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationRecoveryProbeWakeLateness.count, 0)
        XCTAssertEqual(snapshot.scrollInputGap.count, 1)
        XCTAssertEqual(snapshot.scrollInputHandler.count, 0)
        XCTAssertEqual(snapshot.scrollInputDispatch.count, 0)
        XCTAssertEqual(snapshot.scrollInputVerticalDeltaAbs.count, 2)
        XCTAssertEqual(snapshot.scrollToFirstDrawSamplesMs.count, 2)
        XCTAssertEqual(snapshot.scrollToLayerPresentSamplesMs.count, 2)
        XCTAssertEqual(snapshot.scrollPresentationDrawGapSamplesMs.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationImmediateQueueDelaySamplesMs.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationPumpWakeLatenessSamplesMs.count, 0)
        XCTAssertEqual(snapshot.scrollPresentationRecoveryProbeWakeLatenessSamplesMs.count, 0)
        XCTAssertEqual(snapshot.layerPresentGapSamplesMs.count, 1)
        XCTAssertEqual(snapshot.scrollInputGapSamplesMs.count, 1)
        XCTAssertEqual(snapshot.scrollInputHandlerSamplesMs, [])
        XCTAssertEqual(snapshot.scrollInputDispatchSamplesMs, [])
        XCTAssertEqual(snapshot.scrollInputVerticalDeltaAbsSamples.count, 2)
        XCTAssertEqual(snapshot.renderRequestCount, 2)
        XCTAssertEqual(snapshot.refreshDrawRequestCount, 0)
        XCTAssertEqual(snapshot.immediatePresentationDrawCount, 0)
        XCTAssertEqual(snapshot.drawCount, 2)
        XCTAssertEqual(snapshot.scrollPresentationDrawCount, 0)
        XCTAssertEqual(snapshot.layerPresentGap.count, 1)
        XCTAssertEqual(snapshot.layerPresentCount, 2)
        XCTAssertEqual(snapshot.scrollInputCount, 2)
        XCTAssertEqual(snapshot.preciseScrollInputCount, 0)
        XCTAssertEqual(snapshot.directPhaseScrollInputCount, 0)
        XCTAssertEqual(snapshot.momentumPhaseScrollInputCount, 0)
        XCTAssertEqual(snapshot.pendingScrollToRenderCount, 0)
        XCTAssertEqual(snapshot.pendingScrollToDrawCount, 0)
        XCTAssertEqual(snapshot.pendingScrollToLayerPresentCount, 0)
        XCTAssertEqual(snapshot.pendingRenderToDrawCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseEventCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseStepCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseMessageQueueCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseMailboxNotifyCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseWriteQueueCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseWriteQueueBytes, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseWriteCompletedCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseWriteCompletedBytes, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseDrainTurnCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseDrainedMessageCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseDrainRequeueCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadChunkCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadChunkBytes, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadChunkMaxBytes, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseUpSequenceCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseDownSequenceCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseApplicationCursorSequenceCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseNormalCursorSequenceCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadEscapeByteCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadPrintableByteCount, 0)
        XCTAssertEqual(snapshot.alternateScroll.preciseReadNewlineByteCount, 0)
        XCTAssertNotNil(snapshot.scrollToRenderRequest.p95Ms)
        XCTAssertNotNil(snapshot.scrollToFirstDraw.maxMs)
        XCTAssertNotNil(snapshot.scrollToLayerPresent.maxMs)
        XCTAssertNotNil(snapshot.renderRequestToDraw.p50Ms)
        XCTAssertNotNil(snapshot.drawGap.maxMs)
        XCTAssertNotNil(snapshot.layerPresentGap.maxMs)

        view.resetScrollTelemetryForTesting()
        let resetSnapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(resetSnapshot.scrollToRenderRequest.count, 0)
        XCTAssertEqual(resetSnapshot.scrollToFirstDraw.count, 0)
        XCTAssertEqual(resetSnapshot.scrollToLayerPresent.count, 0)
        XCTAssertEqual(resetSnapshot.renderRequestToDraw.count, 0)
        XCTAssertEqual(resetSnapshot.drawGap.count, 0)
        XCTAssertEqual(resetSnapshot.scrollPresentationDrawGap.count, 0)
        XCTAssertEqual(resetSnapshot.scrollPresentationImmediateQueueDelay.count, 0)
        XCTAssertEqual(resetSnapshot.scrollPresentationPumpWakeLateness.count, 0)
        XCTAssertEqual(resetSnapshot.scrollPresentationRecoveryProbeWakeLateness.count, 0)
        XCTAssertEqual(resetSnapshot.scrollInputGap.count, 0)
        XCTAssertEqual(resetSnapshot.scrollInputHandler.count, 0)
        XCTAssertEqual(resetSnapshot.scrollInputDispatch.count, 0)
        XCTAssertEqual(resetSnapshot.scrollInputVerticalDeltaAbs.count, 0)
        XCTAssertEqual(resetSnapshot.scrollToFirstDrawSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollToLayerPresentSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollPresentationDrawGapSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollPresentationImmediateQueueDelaySamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollPresentationPumpWakeLatenessSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollPresentationRecoveryProbeWakeLatenessSamplesMs, [])
        XCTAssertEqual(resetSnapshot.layerPresentGapSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollInputGapSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollInputHandlerSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollInputDispatchSamplesMs, [])
        XCTAssertEqual(resetSnapshot.scrollInputVerticalDeltaAbsSamples, [])
        XCTAssertEqual(resetSnapshot.renderRequestCount, 0)
        XCTAssertEqual(resetSnapshot.refreshDrawRequestCount, 0)
        XCTAssertEqual(resetSnapshot.immediatePresentationDrawCount, 0)
        XCTAssertEqual(resetSnapshot.drawCount, 0)
        XCTAssertEqual(resetSnapshot.scrollPresentationDrawCount, 0)
        XCTAssertEqual(resetSnapshot.layerPresentGap.count, 0)
        XCTAssertEqual(resetSnapshot.layerPresentCount, 0)
        XCTAssertEqual(resetSnapshot.scrollInputCount, 0)
        XCTAssertEqual(resetSnapshot.preciseScrollInputCount, 0)
        XCTAssertEqual(resetSnapshot.directPhaseScrollInputCount, 0)
        XCTAssertEqual(resetSnapshot.momentumPhaseScrollInputCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseEventCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseStepCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseMessageQueueCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseMailboxNotifyCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseWriteQueueCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseWriteQueueBytes, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseWriteCompletedCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseWriteCompletedBytes, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseDrainTurnCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseDrainedMessageCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseDrainRequeueCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadChunkCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadChunkBytes, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadChunkMaxBytes, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseUpSequenceCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseDownSequenceCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseApplicationCursorSequenceCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseNormalCursorSequenceCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadEscapeByteCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadPrintableByteCount, 0)
        XCTAssertEqual(resetSnapshot.alternateScroll.preciseReadNewlineByteCount, 0)
    }

    @MainActor
    func testScrollPresentationDrawTelemetryTracksFirstDrawAndGap() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawTelemetryForTesting(now: 10.004)
        view.noteScrollInputTelemetryForTesting(now: 10.010)
        view.noteScrollPresentationDrawTelemetryForTesting(now: 10.012)

        let snapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(snapshot.scrollToFirstDraw.count, 2)
        XCTAssertEqual(snapshot.scrollPresentationDrawGap.count, 1)
        XCTAssertEqual(snapshot.scrollToFirstDrawSamplesMs.count, 2)
        XCTAssertEqual(snapshot.scrollPresentationDrawGapSamplesMs.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationDrawCount, 2)
        XCTAssertEqual(snapshot.pendingScrollToDrawCount, 0)
        XCTAssertNotNil(snapshot.scrollPresentationDrawGap.maxMs)
    }

    @MainActor
    func testScrollInputTelemetryTracksPrecisionAndPhaseCounts() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(
            now: 10.0,
            precision: true,
            phase: .changed,
            momentumPhase: [],
            verticalDelta: 4.0
        )
        view.noteScrollInputTelemetryForTesting(
            now: 10.01,
            precision: true,
            phase: .ended,
            momentumPhase: .changed,
            verticalDelta: 2.0
        )

        let snapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(snapshot.scrollInputCount, 2)
        XCTAssertEqual(snapshot.preciseScrollInputCount, 2)
        XCTAssertEqual(snapshot.directPhaseScrollInputCount, 1)
        XCTAssertEqual(snapshot.momentumPhaseScrollInputCount, 1)
        XCTAssertEqual(snapshot.scrollInputGap.count, 1)
        XCTAssertEqual(snapshot.scrollInputHandler.count, 0)
        XCTAssertEqual(snapshot.scrollInputDispatch.count, 0)
        XCTAssertEqual(snapshot.scrollInputVerticalDeltaAbs.count, 2)
        XCTAssertEqual(snapshot.scrollInputVerticalDeltaAbsSamples, [4.0, 2.0])
    }

    @MainActor
    func testScrollInputExecutionTelemetryTracksHandlerAndDispatchDurations() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputExecutionTelemetryForTesting(
            handlerDurationMs: 1.5,
            dispatchDurationMs: 0.75
        )
        view.noteScrollInputExecutionTelemetryForTesting(
            handlerDurationMs: 2.5,
            dispatchDurationMs: 1.25
        )

        let snapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(snapshot.scrollInputHandler.count, 2)
        XCTAssertEqual(snapshot.scrollInputDispatch.count, 2)
        XCTAssertEqual(snapshot.scrollInputHandlerSamplesMs, [1.5, 2.5])
        XCTAssertEqual(snapshot.scrollInputDispatchSamplesMs, [0.75, 1.25])
    }

    @MainActor
    func testAlternateScrollUsesNativeBasePrecisionMultiplier() {
        let view = GhosttyTerminalViewDrawSpy()

        XCTAssertEqual(
            view.precisionScrollMultiplierForTesting(usesAlternateScroll: false),
            2.0
        )
        XCTAssertEqual(
            view.precisionScrollMultiplierForTesting(
                usesAlternateScroll: true,
                phase: .changed
            ),
            2.0
        )
        XCTAssertEqual(
            view.precisionScrollMultiplierForTesting(
                usesAlternateScroll: true,
                momentumPhase: .changed
            ),
            2.0
        )
    }

    @MainActor
    func testScrollPresentationSchedulerTelemetryTracksQueueAndWakeLateness() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollPresentationImmediateQueueDelayTelemetryForTesting(
            scheduledAt: 10.0,
            now: 10.003
        )
        view.noteScrollPresentationDrawPumpWakeLatenessTelemetryForTesting(
            scheduledFor: 10.010,
            now: 10.012
        )
        view.noteScrollPresentationRecoveryProbeWakeLatenessTelemetryForTesting(
            scheduledFor: 10.020,
            now: 10.021
        )

        let snapshot = view.scrollTelemetrySnapshotForTesting()
        XCTAssertEqual(snapshot.scrollPresentationImmediateQueueDelay.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationPumpWakeLateness.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationRecoveryProbeWakeLateness.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationImmediateQueueDelaySamplesMs.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationPumpWakeLatenessSamplesMs.count, 1)
        XCTAssertEqual(snapshot.scrollPresentationRecoveryProbeWakeLatenessSamplesMs.count, 1)
        XCTAssertNotNil(snapshot.scrollPresentationImmediateQueueDelay.maxMs)
        XCTAssertNotNil(snapshot.scrollPresentationPumpWakeLateness.maxMs)
        XCTAssertNotNil(snapshot.scrollPresentationRecoveryProbeWakeLateness.maxMs)
    }

    @MainActor
    func testScheduleScrollPresentationDrawCoalescesToSinglePass() async {
        let view = GhosttyTerminalViewDrawSpy()

        view.scheduleScrollPresentationDrawIfNeeded()
        view.scheduleScrollPresentationDrawIfNeeded()

        let drew = await waitUntil(intervalMs: 1) {
            view.scrollPresentationDrawCallCount == 1
        }
        XCTAssertTrue(drew)
    }

    @MainActor
    func testScrollPresentationContinuationSchedulerUsesEarliestDueWake() {
        let view = GhosttyTerminalViewDrawSpy()

        view.configureScrollPresentationContinuationForTesting(
            pumpDue: 10.020,
            recoveryDue: 10.006,
            recoveryDrawUptime: 10.0
        )
        XCTAssertEqual(view.nextScrollPresentationContinuationDueForTesting(), 10.006)

        view.configureScrollPresentationContinuationForTesting(
            pumpDue: 10.020,
            recoveryDue: nil,
            recoveryDrawUptime: nil
        )
        XCTAssertEqual(view.nextScrollPresentationContinuationDueForTesting(), 10.020)
    }

    @MainActor
    func testScheduledScrollContinuationWakeReschedulesPumpAndRecoveryFromFreshDraw() {
        let view = GhosttyTerminalViewDrawSpy()
        let base = ProcessInfo.processInfo.systemUptime

        view.noteScrollInputTelemetryForTesting(now: base)
        view.configureScrollPresentationContinuationForTesting(
            pumpDue: base + 0.010,
            recoveryDue: nil,
            recoveryDrawUptime: nil
        )

        view.runScheduledScrollPresentationContinuationWakeForTesting(now: base + 0.010)

        XCTAssertEqual(view.scrollPresentationDrawCallCount, 1)
        let state = view.scrollPresentationContinuationStateForTesting()
        XCTAssertEqual(state.lastDrawUptime, base + 0.010)
        XCTAssertNotNil(state.pumpDueUptime)
        XCTAssertNotNil(state.recoveryDueUptime)
        XCTAssertEqual(state.recoveryDrawUptime, base + 0.010)
        XCTAssertGreaterThan(state.recoveryDueUptime ?? 0, base + 0.010)
    }

    @MainActor
    func testScheduledScrollContinuationWakeDropsStaleRecoveryWhenPumpSupersedesIt() {
        let view = GhosttyTerminalViewDrawSpy()
        let base = ProcessInfo.processInfo.systemUptime

        view.noteScrollInputTelemetryForTesting(now: base)
        view.noteScrollPresentationDrawForTesting(now: base)
        view.configureScrollPresentationContinuationForTesting(
            pumpDue: base + 0.010,
            recoveryDue: base + 0.010,
            recoveryDrawUptime: base
        )

        view.runScheduledScrollPresentationContinuationWakeForTesting(now: base + 0.010)

        XCTAssertEqual(view.scrollPresentationDrawCallCount, 1)
        let state = view.scrollPresentationContinuationStateForTesting()
        XCTAssertEqual(state.lastDrawUptime, base + 0.010)
        XCTAssertEqual(state.recoveryDrawUptime, base + 0.010)
        XCTAssertNotNil(state.recoveryDueUptime)
        XCTAssertGreaterThan(state.recoveryDueUptime ?? 0, base + 0.010)
    }

    @MainActor
    func testScrollPresentationDrawPumpContinuesBrieflyAfterRecentInput() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)

        XCTAssertTrue(view.runScrollPresentationDrawPumpPassForTesting(now: 10.01))
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 1)

        XCTAssertTrue(view.runScrollPresentationDrawPumpPassForTesting(now: 10.15))
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 2)

        XCTAssertFalse(view.runScrollPresentationDrawPumpPassForTesting(now: 10.25))
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 2)
    }

    @MainActor
    func testScrollPresentationDrawThrottleAppliesWithinPumpInterval() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawForTesting(now: 10.0)
        view.noteLayerPresentationForTesting(now: 10.001)

        XCTAssertTrue(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.005))
        XCTAssertFalse(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.02))
    }

    @MainActor
    func testScrollPresentationDrawDoesNotThrottleBeforeLayerPresentArrives() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawForTesting(now: 10.0)

        XCTAssertFalse(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.005))

        view.noteLayerPresentationForTesting(now: 10.006)
        XCTAssertTrue(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.007))
    }

    @MainActor
    func testActivePreciseGestureBypassesImmediateDrawThrottle() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .changed,
            momentumPhase: [],
            verticalDelta: 2.0,
            now: 10.0
        )
        view.noteScrollPresentationDrawForTesting(now: 10.0)
        view.noteLayerPresentationForTesting(now: 10.001)

        XCTAssertFalse(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.005))
    }

    @MainActor
    func testActivePreciseGestureDisablesHostContinuationPump() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .began,
            momentumPhase: [],
            verticalDelta: -3.0,
            now: 10.0
        )

        XCTAssertFalse(view.shouldUseHostScrollPresentationContinuationForTesting(now: 10.01))
        XCTAssertFalse(view.runScrollPresentationDrawPumpPassForTesting(now: 10.01))
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 0)
    }

    @MainActor
    func testNextTerminalHostModeDisablesHostScrollPresentationForNormalScreen() {
        let view = GhosttyTerminalViewDrawSpy()

        XCTAssertTrue(
            view.shouldUseHostScrollPresentation(
                usesAlternateScroll: false,
                precision: true
            )
        )

        view.setTerminalHostMode(.next)

        XCTAssertFalse(
            view.shouldUseHostScrollPresentation(
                usesAlternateScroll: false,
                precision: true
            )
        )
    }

    @MainActor
    func testSwitchingToNextTerminalHostModeInvalidatesPendingScrollContinuation() {
        let view = GhosttyTerminalViewDrawSpy()

        view.configureScrollPresentationContinuationForTesting(
            pumpDue: 10.02,
            recoveryDue: 10.03,
            recoveryDrawUptime: 10.0
        )

        view.setTerminalHostMode(.next)

        let state = view.scrollPresentationContinuationStateForTesting()
        XCTAssertNil(state.pumpDueUptime)
        XCTAssertNil(state.recoveryDueUptime)
        XCTAssertNil(state.lastDrawUptime)
    }

    @MainActor
    func testMomentumTailReEnablesHostContinuationAfterDirectGestureEnds() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .began,
            momentumPhase: [],
            verticalDelta: -3.0,
            now: 10.0
        )
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .ended,
            momentumPhase: .changed,
            verticalDelta: -2.0,
            now: 10.03
        )

        XCTAssertTrue(view.shouldUseHostScrollPresentationContinuationForTesting(now: 10.031))
    }

    @MainActor
    func testMomentumBoundaryInvalidatesScheduledContinuationWakeups() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .began,
            momentumPhase: [],
            verticalDelta: -3.0,
            now: 10.0
        )
        view.noteScrollPresentationDrawForTesting(now: 10.0)
        view.noteLayerPresentationForTesting(now: 10.001)
        view.configureScrollPresentationContinuationForTesting(
            pumpDue: 10.02,
            recoveryDue: 10.03,
            recoveryDrawUptime: 10.0
        )

        view.updateScrollPresentationGestureStateForTesting(
            precision: true,
            phase: .ended,
            momentumPhase: .began,
            verticalDelta: -2.0,
            now: 10.03
        )

        let state = view.scrollPresentationContinuationStateForTesting()
        XCTAssertNil(state.pumpDueUptime)
        XCTAssertNil(state.recoveryDueUptime)
        XCTAssertNil(state.lastDrawUptime)
        XCTAssertFalse(view.shouldThrottleImmediateScrollPresentationDrawForTesting(now: 10.031))
        XCTAssertTrue(view.shouldUseHostScrollPresentationContinuationForTesting(now: 10.031))
    }

    @MainActor
    func testScrollPresentationRecoveryProbeRedrawsWhenLayerPresentLags() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawForTesting(now: 10.0)

        XCTAssertTrue(
            view.runScrollPresentationRecoveryProbePassForTesting(
                drawUptime: 10.0,
                now: 10.006
            )
        )
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 1)
    }

    @MainActor
    func testScrollPresentationRecoveryProbeDoesNotRedrawAfterLayerPresentAdvances() {
        let view = GhosttyTerminalViewDrawSpy()

        view.noteScrollInputTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawTelemetryForTesting(now: 10.0)
        view.noteScrollPresentationDrawForTesting(now: 10.0)
        view.noteLayerPresentationForTesting(now: 10.003)

        XCTAssertFalse(
            view.runScrollPresentationRecoveryProbePassForTesting(
                drawUptime: 10.0,
                now: 10.006
            )
        )
        XCTAssertEqual(view.scrollPresentationDrawCallCount, 0)
    }

    @MainActor
    func testDetachingViewDoesNotApplyFallbackSurfaceMetricsOrScheduleDraw() {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let view = GhosttyTerminalViewMetricsSpy(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let leafID = UUID()
        var scheduledTicks = 0

        window.contentView = container
        container.addSubview(view)

        GhosttyApp.withTestTickScheduleObserver({
            scheduledTicks += 1
        }) {
            SurfacePool.shared.register(
                view: view,
                leafID: leafID,
                tmuxPaneID: "%19",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x621)
            )
            GhosttyApp.runDirtyDrawPassForTesting()
            view.resetMetricTracking()
            scheduledTicks = 0

            view.removeFromSuperview()

            XCTAssertTrue(view.contentScaleUpdates.isEmpty)
            XCTAssertTrue(view.sizeUpdates.isEmpty)
            XCTAssertTrue(view.displayIDUpdates.isEmpty)
            XCTAssertEqual(scheduledTicks, 0)
        }
    }

    @MainActor
    func testUITestTmuxBridgeTerminalViewportTextSnapshotUsesRegisteredView() throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let view = GhosttyTerminalViewViewportTextSpy()
        let expected = GhosttyTerminalView.ViewportTextSnapshot(
            text: "alpha\nbeta",
            lineCount: 2,
            characterCount: 10,
            usesAlternateScroll: false
        )
        view.snapshots = [expected]

        SurfacePool.shared.register(
            view: view,
            leafID: tileID,
            tmuxPaneID: "%31",
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x631)
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [:]
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot, expected)
    }

    @MainActor
    func testUITestTmuxBridgeTerminalViewportTextSnapshotResolvesNextHostActiveLeafID() throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let leafID = UUID()
        let view = GhosttyTerminalViewViewportTextSpy()
        let expected = GhosttyTerminalView.ViewportTextSnapshot(
            text: "next-host",
            lineCount: 1,
            characterCount: 9,
            usesAlternateScroll: true
        )
        view.snapshots = [expected]

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%41",
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x641)
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [:]
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot, expected)
    }

    @MainActor
    func testUITestTmuxBridgeTerminalViewportTextSnapshotFallsBackToRenderedNextHostSurface() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }
        defer { GhosttyTerminalSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "next-rendered-fallback")
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x642)
        let view = GhosttyTerminalViewViewportTextSpy()
        let expected = GhosttyTerminalView.ViewportTextSnapshot(
            text: "rendered-next-host",
            lineCount: 1,
            characterCount: 18,
            usesAlternateScroll: false
        )
        view.snapshots = [expected]

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%42",
            surfaceHandle: surfaceHandle
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:next-rendered-fallback",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t \(sessionRef.sessionName)"
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        try await bridge.waitForTerminalViewRegistrationForTesting(
            tileID: tileID,
            timeoutMilliseconds: 200
        )
        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot, expected)
    }

    @MainActor
    func testUITestTmuxBridgeTerminalViewportTextSnapshotPrefersActiveLeafOverRenderedNextHostSurfaceHandle() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }
        defer { GhosttyTerminalSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let activeLeafID = UUID()
        let renderedLeafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "next-handle-priority")
        let renderedHandle = GhosttySurfaceHandle(rawValue: 0x643)
        let activeHandle = GhosttySurfaceHandle(rawValue: 0x644)

        let activeView = GhosttyTerminalViewViewportTextSpy()
        let expected = GhosttyTerminalView.ViewportTextSnapshot(
            text: "active-leaf-view",
            lineCount: 1,
            characterCount: 16,
            usesAlternateScroll: false
        )
        activeView.snapshots = [expected]
        let renderedView = GhosttyTerminalViewViewportTextSpy()
        renderedView.snapshots = [
            .init(text: "stale-rendered-view", lineCount: 1, characterCount: 19, usesAlternateScroll: false)
        ]

        SurfacePool.shared.register(
            view: activeView,
            leafID: activeLeafID,
            tmuxPaneID: "%43",
            surfaceHandle: activeHandle
        )
        SurfacePool.shared.register(
            view: renderedView,
            leafID: renderedLeafID,
            tmuxPaneID: "%44",
            surfaceHandle: renderedHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(activeLeafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: renderedHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:next-handle-priority",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t \(sessionRef.sessionName)"
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        try await bridge.waitForTerminalViewRegistrationForTesting(tileID: tileID, timeoutMilliseconds: 200)
        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot, expected)
    }

    @MainActor
    func testUITestTmuxBridgeRenderedTerminalTargetSnapshotUsesRegisteredSurfaceState() async throws {
        let tileID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "vm agtmux-term")
        let tile = WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(tile),
            focusedTileID: tileID
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9914)

        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:live",
                sessionRef: sessionRef
            ),
            attachCommand: "tmux attach-session -t vm agtmux-term"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys042",
            forSurfaceHandle: surfaceHandle
        )
        defer {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: surfaceHandle)
        }

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: WorkbenchStoreV2(
                workbenches: [workbench],
                activeWorkbenchIndex: 0,
                persistence: nil
            ),
            resolveRenderedLiveTarget: { renderedClientTTY, target, _ in
                XCTAssertEqual(renderedClientTTY, "/dev/ttys042")
                XCTAssertEqual(target, .local)
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: sessionRef.sessionName,
                    windowID: "@9",
                    paneID: "%901"
                )
            },
            env: [:]
        )

        let snapshot = try await bridge.renderedTerminalTargetSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.terminalHostMode, "legacy")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, sessionRef.sessionName)
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys042")
        XCTAssertEqual(snapshot.renderedClientWindowID, "@9")
        XCTAssertEqual(snapshot.renderedClientPaneID, "%901")
    }

    @MainActor
    func testUITestTmuxBridgeRenderedTerminalTargetSnapshotFallsBackToNextHostBootstrapSurface() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }
        defer { GhosttyTerminalSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let tile = WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(tile),
            focusedTileID: tileID
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9918)
        let view = GhosttyTerminalViewViewportTextSpy()

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:main-bootstrap",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: WorkbenchStoreV2(
                workbenches: [workbench],
                activeWorkbenchIndex: 0,
                persistence: nil
            ),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        try await bridge.waitForTerminalViewRegistrationForTesting(tileID: tileID, timeoutMilliseconds: 200)
        let snapshot = try await bridge.renderedTerminalTargetSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, sessionRef.sessionName)
        XCTAssertEqual(snapshot.renderedClientTTY, "")
        XCTAssertEqual(snapshot.renderedClientWindowID, "")
        XCTAssertEqual(snapshot.renderedClientPaneID, "")
    }

    @MainActor
    func testUITestTmuxBridgeRenderedTerminalTargetSnapshotFallsBackWhenRenderedLiveTargetTimesOut() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        defer { TerminalHostActiveSurfaceRegistry.shared.resetForTesting() }
        defer { GhosttyTerminalSurfaceRegistry.shared.resetForTesting() }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let tile = WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(tile),
            focusedTileID: tileID
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9922)
        let view = GhosttyTerminalViewViewportTextSpy()

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:main-render-timeout",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys125",
            forSurfaceHandle: surfaceHandle
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: WorkbenchStoreV2(
                workbenches: [workbench],
                activeWorkbenchIndex: 0,
                persistence: nil
            ),
            resolveRenderedLiveTarget: { _, _, _ in
                try await Task.sleep(for: .seconds(2))
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: "main",
                    windowID: "@9",
                    paneID: "%902"
                )
            },
            env: [
                TerminalHostMode.environmentKey: "next",
                "AGTMUX_UITEST_RENDERED_LIVE_TARGET_TIMEOUT_MS": "10"
            ]
        )

        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await bridge.renderedTerminalTargetSnapshotForTesting(tileID: tileID)
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, sessionRef.sessionName)
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys125")
        XCTAssertEqual(snapshot.renderedClientWindowID, "")
        XCTAssertEqual(snapshot.renderedClientPaneID, "")
    }

    @MainActor
    func testUITestTmuxBridgeFocusRenderedPaneUsesRenderedClientTTYAndTargetPane() async throws {
        let tileID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "vm agtmux-term")
        let tile = WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(tile),
            focusedTileID: tileID
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9915)
        let recorder = UITestNavigationIntentRecorder()

        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:live",
                sessionRef: sessionRef
            ),
            attachCommand: "tmux attach-session -t vm agtmux-term"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys099",
            forSurfaceHandle: surfaceHandle
        )
        defer {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: surfaceHandle)
        }

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: WorkbenchStoreV2(
                workbenches: [workbench],
                activeWorkbenchIndex: 0,
                persistence: nil
            ),
            applyNavigationIntent: { activePaneRef, renderedClientTTY, hostsConfig in
                await recorder.record(
                    activePaneRef: activePaneRef,
                    renderedClientTTY: renderedClientTTY,
                    hostsConfig: hostsConfig
                )
            },
            env: [:]
        )

        try await bridge.focusRenderedPaneForTesting(tileID: tileID, paneID: "%777")

        let recordedActivePaneRef = await recorder.activePaneRef
        let recordedRenderedClientTTY = await recorder.renderedClientTTY
        let recordedHostsConfig = await recorder.hostsConfig
        XCTAssertEqual(recordedActivePaneRef?.target, .local)
        XCTAssertEqual(recordedActivePaneRef?.sessionName, sessionRef.sessionName)
        XCTAssertEqual(recordedActivePaneRef?.paneID, "%777")
        XCTAssertEqual(recordedRenderedClientTTY, "/dev/ttys099")
        XCTAssertEqual(recordedHostsConfig, HostsConfig(hosts: []))
    }

    @MainActor
    func testUITestTmuxBridgeSamplesTerminalViewportTextRepeatedly() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let tileID = UUID()
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "row-1", lineCount: 1, characterCount: 5, usesAlternateScroll: false),
            .init(text: "row-2", lineCount: 1, characterCount: 5, usesAlternateScroll: false),
            .init(text: "row-3", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]

        SurfacePool.shared.register(
            view: view,
            leafID: tileID,
            tmuxPaneID: "%32",
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x632)
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [:]
        )

        let sampling = try await bridge.sampleTerminalViewportTextForTesting(
            tileID: tileID,
            sampleCount: 3,
            intervalMilliseconds: 0
        )

        XCTAssertEqual(sampling.samples.map(\.sampleIndex), [0, 1, 2])
        XCTAssertEqual(
            sampling.samples.map(\.snapshot.text),
            ["row-1", "row-2", "row-3"]
        )
        XCTAssertTrue(sampling.samples.allSatisfy { $0.elapsedMs >= 0 })
    }

    @MainActor
    func testUITestTmuxBridgeMeasuresInternalTerminalScrollBurst() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let tileID = UUID()
        let view = GhosttyTerminalViewScrollInjectionSpy()
        SurfacePool.shared.register(
            view: view,
            leafID: tileID,
            tmuxPaneID: "%33",
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x633)
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [:]
        )

        let measurement = try await bridge.measureTerminalScrollBurstForTesting(
            tileID: tileID,
            verticalDelta: 10,
            repeatCount: 4,
            intervalMilliseconds: 0,
            sampleCount: 1,
            sampleIntervalMilliseconds: 0,
            phaseMode: .trackpadBurst
        )

        XCTAssertEqual(measurement.sender.mode, "bridge-internal")
        XCTAssertTrue(measurement.sender.sent)
        XCTAssertTrue(measurement.sender.trusted)
        XCTAssertEqual(measurement.sender.scrollRepeat, 4)
        XCTAssertEqual(measurement.sender.deliveredEventCount, 5)
        XCTAssertEqual(measurement.sender.deliveredDeltaEventCount, 4)
        XCTAssertEqual(measurement.sampling.samples.count, 1)
        XCTAssertEqual(view.prepareCallCount, 1)
        XCTAssertEqual(
            view.injectedSteps,
            [
                .init(verticalDelta: 10, phase: .began, momentumPhase: [], precision: true),
                .init(verticalDelta: 10, phase: .changed, momentumPhase: [], precision: true),
                .init(verticalDelta: 10, phase: .changed, momentumPhase: [], precision: true),
                .init(verticalDelta: 10, phase: .changed, momentumPhase: [], precision: true),
                .init(verticalDelta: 0, phase: .ended, momentumPhase: [], precision: true),
            ]
        )
    }

    @MainActor
    func testUITestTmuxBridgeWaitsForTerminalViewRegistration() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let tileID = UUID()
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(
                hostsConfig: HostsConfig(hosts: [])
            ),
            env: [:]
        )

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            SurfacePool.shared.register(
                view: view,
                leafID: tileID,
                tmuxPaneID: "%77",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x677)
            )
        }

        try await bridge.waitForTerminalViewRegistrationForTesting(
            tileID: tileID,
            timeoutMilliseconds: 500
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.text, "ready")
    }

    @MainActor
    func testUITestTmuxBridgeWaitsForNextHostActiveLeafRegistration() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let nextLeafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "next-registration")
        let tileView = GhosttyTerminalViewViewportTextSpy()
        tileView.snapshots = [
            .init(text: "tile-fallback", lineCount: 1, characterCount: 13, usesAlternateScroll: false)
        ]
        let nextLeafView = GhosttyTerminalViewViewportTextSpy()
        nextLeafView.snapshots = [
            .init(text: "next-leaf", lineCount: 1, characterCount: 9, usesAlternateScroll: false)
        ]

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            SurfacePool.shared.register(
                view: tileView,
                leafID: tileID,
                tmuxPaneID: "%77",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x678)
            )
            try? await Task.sleep(for: .milliseconds(80))
            TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(nextLeafID, forTileID: tileID)
            SurfacePool.shared.register(
                view: nextLeafView,
                leafID: nextLeafID,
                tmuxPaneID: "%78",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x679)
            )
            GhosttyTerminalSurfaceRegistry.shared.register(
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x679),
                context: GhosttyTerminalSurfaceContext(
                    workbenchID: workbenchID,
                    tileID: tileID,
                    surfaceKey: "wb:next-registration",
                    sessionRef: sessionRef,
                    terminalHostMode: .next
                ),
                attachCommand: "tmux attach-session -t \(sessionRef.sessionName)"
            )
        }

        try await bridge.waitForTerminalViewRegistrationForTesting(
            tileID: tileID,
            timeoutMilliseconds: 500
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.text, "next-leaf")
    }

    @MainActor
    func testUITestTmuxBridgeTerminalViewportSnapshotPrefersNextHostActiveLeafViewOverStaleTileHandle() throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let staleLeafID = UUID()
        let activeLeafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "next-stale-tile-handle")
        let staleView = GhosttyTerminalViewViewportTextSpy()
        staleView.snapshots = [
            .init(text: "stale-tile-view", lineCount: 1, characterCount: 15, usesAlternateScroll: false)
        ]
        let activeLeafView = GhosttyTerminalViewViewportTextSpy()
        activeLeafView.snapshots = [
            .init(text: "active-leaf-view", lineCount: 1, characterCount: 16, usesAlternateScroll: false)
        ]
        let staleHandle = GhosttySurfaceHandle(rawValue: 0x681)
        let activeHandle = GhosttySurfaceHandle(rawValue: 0x682)

        SurfacePool.shared.register(
            view: staleView,
            leafID: staleLeafID,
            tmuxPaneID: "%80",
            surfaceHandle: staleHandle
        )
        SurfacePool.shared.register(
            view: activeLeafView,
            leafID: activeLeafID,
            tmuxPaneID: "%81",
            surfaceHandle: activeHandle
        )
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: staleHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:next-stale-tile",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t \(sessionRef.sessionName)"
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(activeLeafID, forTileID: tileID)

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.text, "active-leaf-view")
    }

    @MainActor
    func testUITestTmuxBridgeWaitsForNextHostRenderedSurfaceState() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let nextLeafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "next-rendered-state")
        let nextLeafView = GhosttyTerminalViewViewportTextSpy()
        nextLeafView.snapshots = [
            .init(text: "next-rendered", lineCount: 1, characterCount: 13, usesAlternateScroll: false)
        ]

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [TerminalHostMode.environmentKey: "next"]
        )

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(nextLeafID, forTileID: tileID)
            SurfacePool.shared.register(
                view: nextLeafView,
                leafID: nextLeafID,
                tmuxPaneID: "%79",
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x680)
            )
            try? await Task.sleep(for: .milliseconds(80))
            GhosttyTerminalSurfaceRegistry.shared.register(
                surfaceHandle: GhosttySurfaceHandle(rawValue: 0x680),
                context: GhosttyTerminalSurfaceContext(
                    workbenchID: workbenchID,
                    tileID: tileID,
                    surfaceKey: "wb:next-rendered",
                    sessionRef: sessionRef,
                    terminalHostMode: .next
                ),
                attachCommand: "tmux attach-session -t \(sessionRef.sessionName)"
            )
        }

        try await bridge.waitForTerminalViewRegistrationForTesting(
            tileID: tileID,
            timeoutMilliseconds: 500
        )

        let snapshot = try bridge.terminalViewportTextSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.text, "next-rendered")
    }

    @MainActor
    func testUITestTmuxBridgeActiveTerminalTargetSnapshotFallsBackToFocusedRenderedTile() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))),
            focusedTileID: tileID
        )
        let workbenchStore = WorkbenchStoreV2(
            workbenches: [workbench],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9916)

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:main",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys123",
            forSurfaceHandle: surfaceHandle
        )
        defer {
            GhosttyTerminalSurfaceRegistry.shared.unregister(surfaceHandle: surfaceHandle)
        }

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: workbenchStore,
            resolveRenderedLiveTarget: { renderedClientTTY, target, _ in
                XCTAssertEqual(renderedClientTTY, "/dev/ttys123")
                XCTAssertEqual(target, .local)
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: "main",
                    windowID: "@0",
                    paneID: "%0"
                )
            },
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try await bridge.activeTerminalTargetSnapshotForTesting()
        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, "main")
        XCTAssertEqual(snapshot.windowID, "@0")
        XCTAssertEqual(snapshot.paneID, "%0")
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys123")
        XCTAssertEqual(snapshot.renderedClientWindowID, "@0")
        XCTAssertEqual(snapshot.renderedClientPaneID, "%0")
    }

    @MainActor
    func testUITestTmuxBridgeActiveTerminalTargetSnapshotFallsBackToBootstrapNextHostSurface() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "main",
            windowID: "@0",
            paneID: "%0"
        )
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))),
            focusedTileID: tileID,
            activePaneRef: activePaneRef
        )
        let workbenchStore = WorkbenchStoreV2(
            workbenches: [workbench],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9919)

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:main-bootstrap",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: workbenchStore,
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try await bridge.activeTerminalTargetSnapshotForTesting()
        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, "main")
        XCTAssertEqual(snapshot.windowID, "@0")
        XCTAssertEqual(snapshot.paneID, "%0")
        XCTAssertEqual(snapshot.renderedClientTTY, "")
        XCTAssertEqual(snapshot.renderedClientWindowID, "")
        XCTAssertEqual(snapshot.renderedClientPaneID, "")
    }

    @MainActor
    func testUITestTmuxBridgeActiveTerminalTargetSnapshotFallsBackWhenRenderedLiveTargetTimesOut() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let tileID = UUID()
        let leafID = UUID()
        let workbenchID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let activePaneRef = ActivePaneRef(
            target: .local,
            sessionName: "main",
            windowID: "@0",
            paneID: "%0"
        )
        let workbench = Workbench(
            id: workbenchID,
            title: "Live",
            root: .tile(WorkbenchTile(id: tileID, kind: .terminal(sessionRef: sessionRef))),
            focusedTileID: tileID,
            activePaneRef: activePaneRef
        )
        let workbenchStore = WorkbenchStoreV2(
            workbenches: [workbench],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9921)

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: workbenchID,
                tileID: tileID,
                surfaceKey: "wb:main-timeout",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys124",
            forSurfaceHandle: surfaceHandle
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: workbenchStore,
            resolveRenderedLiveTarget: { _, _, _ in
                try await Task.sleep(for: .seconds(2))
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: "main",
                    windowID: "@9",
                    paneID: "%901"
                )
            },
            env: [
                TerminalHostMode.environmentKey: "next",
                "AGTMUX_UITEST_RENDERED_LIVE_TARGET_TIMEOUT_MS": "10"
            ]
        )

        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try await bridge.activeTerminalTargetSnapshotForTesting()
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.workbenchID, workbenchID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, "main")
        XCTAssertEqual(snapshot.windowID, "@0")
        XCTAssertEqual(snapshot.paneID, "%0")
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys124")
        XCTAssertEqual(snapshot.renderedClientWindowID, "")
        XCTAssertEqual(snapshot.renderedClientPaneID, "")
    }

    @MainActor
    func testUITestTmuxBridgeActiveTerminalTargetSnapshotPrefersMainTerminalStore() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let viewportID = UUID()
        let tileID = UUID()
        let leafID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let requestedPaneRef = ActivePaneRef(
            target: .local,
            sessionName: "main",
            windowID: "@1",
            paneID: "%2"
        )
        let mainTerminalStore = MainTerminalStore(
            viewportID: viewportID,
            surfaceID: tileID,
            mode: .tmux(
                sessionRef: sessionRef,
                requestedPaneRef: requestedPaneRef,
                resolvedPaneRef: nil
            ),
            focusRequestNonce: 7,
            diagnostic: .restoreFallbackUsed(requested: nil, resolved: requestedPaneRef)
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9923)
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%2",
            surfaceHandle: surfaceHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: viewportID,
                tileID: tileID,
                surfaceKey: "main-terminal:test",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys200",
            forSurfaceHandle: surfaceHandle
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            mainTerminalStore: mainTerminalStore,
            resolveRenderedLiveTarget: { renderedClientTTY, target, _ in
                XCTAssertEqual(renderedClientTTY, "/dev/ttys200")
                XCTAssertEqual(target, .local)
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: "main",
                    windowID: "@1",
                    paneID: "%2"
                )
            },
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try await bridge.activeTerminalTargetSnapshotForTesting()
        XCTAssertEqual(snapshot.workbenchID, viewportID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.mainTerminalMode, "tmux")
        XCTAssertEqual(snapshot.sessionName, "main")
        XCTAssertEqual(snapshot.windowID, "@1")
        XCTAssertEqual(snapshot.paneID, "%2")
        XCTAssertEqual(snapshot.desiredWindowID, "@1")
        XCTAssertEqual(snapshot.desiredPaneID, "%2")
        XCTAssertEqual(snapshot.focusRequestNonce, 7)
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys200")
        XCTAssertEqual(snapshot.diagnosticCode, "restoreFallbackUsed")
    }

    @MainActor
    func testUITestTmuxBridgeRenderedTerminalTargetSnapshotUsesMainTerminalStoreSurface() async throws {
        SurfacePool.shared.resetForTesting()
        TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
        GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        defer {
            SurfacePool.shared.resetForTesting()
            TerminalHostActiveSurfaceRegistry.shared.resetForTesting()
            GhosttyTerminalSurfaceRegistry.shared.resetForTesting()
        }

        let viewportID = UUID()
        let tileID = UUID()
        let leafID = UUID()
        let sessionRef = SessionRef(target: .local, sessionName: "main")
        let mainTerminalStore = MainTerminalStore(
            viewportID: viewportID,
            surfaceID: tileID,
            mode: .tmux(
                sessionRef: sessionRef,
                requestedPaneRef: nil,
                resolvedPaneRef: ActivePaneRef(
                    target: .local,
                    sessionName: "main",
                    windowID: "@0",
                    paneID: "%0"
                )
            )
        )
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0x9924)
        let view = GhosttyTerminalViewViewportTextSpy()

        SurfacePool.shared.register(
            view: view,
            leafID: leafID,
            tmuxPaneID: "%0",
            surfaceHandle: surfaceHandle
        )
        TerminalHostActiveSurfaceRegistry.shared.setActiveLeafID(leafID, forTileID: tileID)
        GhosttyTerminalSurfaceRegistry.shared.register(
            surfaceHandle: surfaceHandle,
            context: GhosttyTerminalSurfaceContext(
                workbenchID: viewportID,
                tileID: tileID,
                surfaceKey: "main-terminal:test",
                sessionRef: sessionRef,
                terminalHostMode: .next
            ),
            attachCommand: "tmux attach-session -t main"
        )
        try GhosttyTerminalSurfaceRegistry.shared.register(
            clientTTY: "/dev/ttys201",
            forSurfaceHandle: surfaceHandle
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            mainTerminalStore: mainTerminalStore,
            resolveRenderedLiveTarget: { renderedClientTTY, target, _ in
                XCTAssertEqual(renderedClientTTY, "/dev/ttys201")
                XCTAssertEqual(target, .local)
                return WorkbenchV2TerminalLiveTarget(
                    sessionName: "main",
                    windowID: "@0",
                    paneID: "%0"
                )
            },
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try await bridge.renderedTerminalTargetSnapshotForTesting(tileID: tileID)
        XCTAssertEqual(snapshot.workbenchID, viewportID.uuidString)
        XCTAssertEqual(snapshot.tileID, tileID.uuidString)
        XCTAssertEqual(snapshot.sessionName, "main")
        XCTAssertEqual(snapshot.renderedClientTTY, "/dev/ttys201")
        XCTAssertEqual(snapshot.renderedClientWindowID, "@0")
        XCTAssertEqual(snapshot.renderedClientPaneID, "%0")
    }

    @MainActor
    func testUITestTmuxBridgeStartsCommandLoopFromUserDefaultsConfiguration() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL = tmpdir.appendingPathComponent("command.json")
        let resultURL = tmpdir.appendingPathComponent("result.json")
        let suiteName = "UITestTmuxBridgeDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL.path, forKey: "UITestTmuxCommandResultPath")

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()

        let requestID = UUID().uuidString
        let request = """
        {"id":"\(requestID)","args":["__agtmux_tmux_bridge_ready__"],"refreshInventory":false}
        """
        try request.write(to: commandURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(2)
        var responseData: Data?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: resultURL), !data.isEmpty {
                responseData = data
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let data = try XCTUnwrap(responseData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, requestID)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["stdout"] as? String, "ready")

        await bridge.shutdown()
    }

    @MainActor
    func testUITestTmuxBridgeStartsCommandLoopAfterLateUserDefaultsConfiguration() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-late-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL = tmpdir.appendingPathComponent("command.json")
        let resultURL = tmpdir.appendingPathComponent("result.json")
        let suiteName = "UITestTmuxBridgeLateDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()
        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL.path, forKey: "UITestTmuxCommandResultPath")

        let requestID = UUID().uuidString
        let request = """
        {"id":"\(requestID)","args":["__agtmux_tmux_bridge_ready__"],"refreshInventory":false}
        """
        try request.write(to: commandURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(3)
        var responseData: Data?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: resultURL), !data.isEmpty {
                responseData = data
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let data = try XCTUnwrap(responseData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, requestID)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["stdout"] as? String, "ready")

        await bridge.shutdown()
    }

    @MainActor
    func testUITestTmuxBridgeWritesCommandResponseToPerRequestPath() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-response-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL = tmpdir.appendingPathComponent("command.json")
        let defaultResultURL = tmpdir.appendingPathComponent("default-result.json")
        let requestResultURL = tmpdir.appendingPathComponent("request-result.json")
        let suiteName = "UITestTmuxBridgeResponsePath-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL.path, forKey: "UITestTmuxCommandPath")
        defaults.set(defaultResultURL.path, forKey: "UITestTmuxCommandResultPath")

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()

        let requestID = UUID().uuidString
        let request = """
        {"id":"\(requestID)","args":["__agtmux_tmux_bridge_ready__"],"refreshInventory":false,"responsePath":"\(requestResultURL.path)"}
        """
        try request.write(to: commandURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(2)
        var responseData: Data?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: requestResultURL), !data.isEmpty {
                responseData = data
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let data = try XCTUnwrap(responseData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, requestID)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["stdout"] as? String, "ready")
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultResultURL.path))

        await bridge.shutdown()
    }

    @MainActor
    func testUITestTmuxBridgeConsumesCommandFileAfterProcessing() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-consume-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL = tmpdir.appendingPathComponent("command.json")
        let resultURL = tmpdir.appendingPathComponent("result.json")
        let suiteName = "UITestTmuxBridgeConsumeCommand-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL.path, forKey: "UITestTmuxCommandResultPath")

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()

        let requestID = UUID().uuidString
        let request = """
        {"id":"\(requestID)","args":["__agtmux_tmux_bridge_ready__"],"refreshInventory":false}
        """
        try request.write(to: commandURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(2)
        var responseData: Data?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: resultURL), !data.isEmpty {
                responseData = data
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let data = try XCTUnwrap(responseData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, requestID)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL.path))

        await bridge.shutdown()
    }

    @MainActor
    func testUITestTmuxBridgeRebindsCommandLoopAfterCommandPathChange() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-rebind-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL1 = tmpdir.appendingPathComponent("command-1.json")
        let resultURL1 = tmpdir.appendingPathComponent("result-1.json")
        let commandURL2 = tmpdir.appendingPathComponent("command-2.json")
        let resultURL2 = tmpdir.appendingPathComponent("result-2.json")
        let suiteName = "UITestTmuxBridgeRebindDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL1.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL1.path, forKey: "UITestTmuxCommandResultPath")

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()

        func writeReadyRequest(to commandURL: URL, requestID: String) throws {
            let request = """
            {"id":"\(requestID)","args":["__agtmux_tmux_bridge_ready__"],"refreshInventory":false}
            """
            try request.write(to: commandURL, atomically: true, encoding: .utf8)
        }

        func waitForReadyResponse(at resultURL: URL, requestID: String, timeoutSeconds: Double) async throws {
            let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: resultURL), !data.isEmpty {
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    if json["id"] as? String == requestID {
                        XCTAssertEqual(json["ok"] as? Bool, true)
                        XCTAssertEqual(json["stdout"] as? String, "ready")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out waiting for response \(requestID) at \(resultURL.path)")
        }

        let requestID1 = UUID().uuidString
        try writeReadyRequest(to: commandURL1, requestID: requestID1)
        try await waitForReadyResponse(at: resultURL1, requestID: requestID1, timeoutSeconds: 2)

        defaults.set(commandURL2.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL2.path, forKey: "UITestTmuxCommandResultPath")

        let requestID2 = UUID().uuidString
        try writeReadyRequest(to: commandURL2, requestID: requestID2)
        try await waitForReadyResponse(at: resultURL2, requestID: requestID2, timeoutSeconds: 3)

        await bridge.shutdown()
    }

    @MainActor
    func testUITestTmuxBridgeSetTerminalHostModeRespondsPromptly() async throws {
        let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-bridge-host-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }

        let commandURL = tmpdir.appendingPathComponent("command.json")
        let resultURL = tmpdir.appendingPathComponent("result.json")
        let suiteName = "UITestTmuxBridgeHostMode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "UITestBridgeEnabled")
        defaults.set(commandURL.path, forKey: "UITestTmuxCommandPath")
        defaults.set(resultURL.path, forKey: "UITestTmuxCommandResultPath")

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            env: [:],
            userDefaults: defaults
        )

        await bridge.startIfNeeded()

        let requestID = UUID().uuidString
        let request = """
        {"id":"\(requestID)","args":["__agtmux_set_terminal_host_mode__","next"],"refreshInventory":false}
        """
        try request.write(to: commandURL, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(1)
        var responseData: Data?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: resultURL), !data.isEmpty {
                responseData = data
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let data = try XCTUnwrap(responseData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, requestID)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["stdout"] as? String, TerminalHostMode.next.rawValue)
        XCTAssertEqual(TerminalHostModeRuntime.shared.overrideMode, .next)

        await bridge.shutdown()
    }

    func testUITestTmuxBridgeRequestedIsTrueForUserDefaultsConfiguration() throws {
        let suiteName = "UITestTmuxBridgeRequested-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(UITestTmuxBridge.bridgeRequested(environment: [:], userDefaults: defaults))

        defaults.set(true, forKey: "UITestBridgeEnabled")
        XCTAssertTrue(UITestTmuxBridge.bridgeRequested(environment: [:], userDefaults: defaults))

        defaults.removeObject(forKey: "UITestBridgeEnabled")
        defaults.set("/tmp/command.json", forKey: "UITestTmuxCommandPath")
        defaults.set("/tmp/result.json", forKey: "UITestTmuxCommandResultPath")
        XCTAssertTrue(UITestTmuxBridge.bridgeRequested(environment: [:], userDefaults: defaults))
    }

    func testUITestTmuxBridgeRequestedIsTrueForStableAttachMarker() throws {
        let markerURL = UITestTmuxBridge.stableAttachEnabledURL
        let fileManager = FileManager.default
        let originalData = try? Data(contentsOf: markerURL)
        defer {
            if let originalData {
                try? originalData.write(to: markerURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: markerURL)
            }
        }

        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1".utf8).write(to: markerURL, options: .atomic)

        let suiteName = "UITestTmuxBridgeStableAttach-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(UITestTmuxBridge.bridgeRequested(environment: [:], userDefaults: defaults))
    }

    @MainActor
    func testUITestTmuxBridgeCanFocusExistingTerminalTileInActiveWorkbench() throws {
        let terminalTileID = UUID()
        let documentTileID = UUID()
        let workbench = Workbench(
            title: "Main",
            root: .split(
                WorkbenchSplit(
                    axis: .horizontal,
                    first: .tile(WorkbenchTile(id: documentTileID, kind: .document(ref: .init(target: .local, path: "/tmp/doc.txt")))),
                    second: .tile(WorkbenchTile(id: terminalTileID, kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "vm agtmux-term"))))
                )
            ),
            focusedTileID: documentTileID
        )
        let store = WorkbenchStoreV2(
            workbenches: [workbench],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: store,
            env: [:]
        )

        let snapshot = try bridge.focusExistingTerminalTileForTesting(sessionName: "vm agtmux-term")

        XCTAssertEqual(snapshot.terminalHostMode, "legacy")
        XCTAssertEqual(snapshot.tileID, terminalTileID.uuidString)
        XCTAssertEqual(snapshot.workbenchID, workbench.id.uuidString)
        XCTAssertEqual(snapshot.sessionName, "vm agtmux-term")
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, terminalTileID)
        XCTAssertEqual(store.focusedTerminalTileContext?.tileID, terminalTileID)
        XCTAssertEqual(store.focusedTerminalTileContext?.sessionRef.sessionName, "vm agtmux-term")
    }

    @MainActor
    func testUITestTmuxBridgeCanFocusExistingTerminalTileAcrossWorkbenches() throws {
        let documentWorkbench = Workbench(
            title: "Docs",
            root: .tile(WorkbenchTile(kind: .document(ref: .init(target: .local, path: "/tmp/doc.txt"))))
        )
        let terminalTileID = UUID()
        let terminalWorkbench = Workbench(
            title: "Live",
            root: .tile(
                WorkbenchTile(
                    id: terminalTileID,
                    kind: .terminal(sessionRef: SessionRef(target: .local, sessionName: "vm agtmux-term"))
                )
            ),
            focusedTileID: terminalTileID
        )
        let store = WorkbenchStoreV2(
            workbenches: [documentWorkbench, terminalWorkbench],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(hostsConfig: HostsConfig(hosts: [])),
            workbenchStore: store,
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let snapshot = try bridge.focusExistingTerminalTileForTesting(sessionName: "vm agtmux-term")

        XCTAssertEqual(snapshot.terminalHostMode, "next")
        XCTAssertEqual(snapshot.tileID, terminalTileID.uuidString)
        XCTAssertEqual(snapshot.workbenchID, terminalWorkbench.id.uuidString)
        XCTAssertEqual(store.activeWorkbenchIndex, 1)
        XCTAssertEqual(store.activeWorkbench?.focusedTileID, terminalTileID)
    }

    @MainActor
    func testUITestTmuxBridgeOpenTerminalForPaneReturnsOpenedThenRevealedExisting() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let pane = AgtmuxPane(
            source: "local",
            paneId: "%901",
            sessionName: "bridge-open-terminal-\(UUID().uuidString)",
            windowId: "@901",
            windowIndex: 1,
            windowName: "main",
            currentPath: "/tmp"
        )
        let viewModel = AppViewModel(
            hostsConfig: HostsConfig(hosts: [])
        )
        viewModel.panes = [pane]
        let mainTerminalStore = MainTerminalStore()
        let workbenchStore = WorkbenchStoreV2(
            workbenches: [.empty()],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            env: [:]
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: pane.paneId,
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x690)
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId,
            waitForRegistration: false
        )
        XCTAssertEqual(opened.terminalHostMode, "legacy")
        XCTAssertEqual(opened.disposition, "opened")
        XCTAssertFalse(opened.usedSessionOnlyFallback)
        XCTAssertEqual(opened.source, "local")
        XCTAssertEqual(opened.sessionName, pane.sessionName)
        XCTAssertEqual(opened.paneID, pane.paneId)
        XCTAssertEqual(opened.tileID, mainTerminalStore.surfaceID.uuidString)
        XCTAssertEqual(opened.workbenchID, mainTerminalStore.viewportID.uuidString)

        let revealed = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId
        )
        XCTAssertEqual(revealed.terminalHostMode, "legacy")
        XCTAssertEqual(revealed.disposition, "revealedExisting")
        XCTAssertFalse(revealed.usedSessionOnlyFallback)
        XCTAssertEqual(revealed.tileID, opened.tileID)
        XCTAssertEqual(revealed.workbenchID, opened.workbenchID)
    }

    @MainActor
    func testUITestTmuxBridgeOpenTerminalForPaneFallsBackToDefaultLocalPaneResolver() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let tileID = UUID()
        let workbenchID = UUID()
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%662",
            sessionName: "vm agtmux-term",
            windowId: "@1",
            windowIndex: 1,
            windowName: "main",
            currentPath: "/tmp/live-pane"
        )
        let viewModel = AppViewModel(
            hostsConfig: HostsConfig(hosts: [])
        )
        viewModel.panes = []
        let mainTerminalStore = MainTerminalStore(
            viewportID: workbenchID,
            surfaceID: tileID
        )

        let workbenchStore = WorkbenchStoreV2(
            workbenches: [
                Workbench(
                    id: workbenchID,
                    title: "Live",
                    root: .tile(
                        WorkbenchTile(
                            id: tileID,
                            kind: .terminal(
                                sessionRef: SessionRef(target: .local, sessionName: pane.sessionName)
                            )
                        )
                    ),
                    focusedTileID: tileID
                )
            ],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { sessionName, paneID in
                XCTAssertEqual(sessionName, pane.sessionName)
                XCTAssertEqual(paneID, pane.paneId)
                return pane
            },
            env: [:]
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: pane.paneId,
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x691)
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId,
            waitForRegistration: false
        )

        XCTAssertEqual(opened.terminalHostMode, "legacy")
        XCTAssertEqual(opened.disposition, "opened")
        XCTAssertFalse(opened.usedSessionOnlyFallback)
        XCTAssertEqual(opened.source, "local")
        XCTAssertEqual(opened.sessionName, pane.sessionName)
        XCTAssertEqual(opened.paneID, pane.paneId)
        XCTAssertEqual(opened.tileID, mainTerminalStore.surfaceID.uuidString)
        XCTAssertEqual(opened.workbenchID, mainTerminalStore.viewportID.uuidString)
        XCTAssertEqual(viewModel.panes, [pane])
        XCTAssertTrue(viewModel.runtimeStore.hasCompletedInitialFetch)
        XCTAssertFalse(viewModel.runtimeStore.offlineHosts.contains("local"))
        XCTAssertTrue(
            viewModel.runtimeStore.livePaneSessionKeys.contains("local:\(pane.sessionName)")
        )

        let nextMainTerminalStore = MainTerminalStore(
            mode: .tmux(
                sessionRef: SessionRef(target: .local, sessionName: pane.sessionName),
                requestedPaneRef: nil,
                resolvedPaneRef: ActivePaneRef(
                    target: .local,
                    sessionName: pane.sessionName,
                    windowID: pane.windowId,
                    paneID: pane.paneId
                )
            )
        )

        let nextBridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: nextMainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { _, _ in pane },
            env: [TerminalHostMode.environmentKey: "next"]
        )

        let nextOpened = try await nextBridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId,
            waitForRegistration: false
        )

        XCTAssertEqual(nextOpened.terminalHostMode, "next")
        XCTAssertEqual(nextOpened.disposition, "revealedExisting")
        XCTAssertFalse(nextOpened.usedSessionOnlyFallback)
        XCTAssertEqual(nextOpened.paneID, pane.paneId)
    }

    @MainActor
    func testUITestTmuxBridgeOpenTerminalForPaneCanUseSessionOnlyFallback() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let viewModel = AppViewModel(
            hostsConfig: HostsConfig(hosts: [])
        )
        viewModel.panes = []
        let mainTerminalStore = MainTerminalStore()

        let workbenchStore = WorkbenchStoreV2(
            workbenches: [.empty()],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { _, _ in
                return nil
            },
            env: ["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK": "1"]
        )

        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: "%657",
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x657)
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: "vm agtmux-term",
            paneID: "%657",
            waitForRegistration: false
        )

        XCTAssertEqual(opened.terminalHostMode, "legacy")
        XCTAssertEqual(opened.disposition, "opened")
        XCTAssertTrue(opened.usedSessionOnlyFallback)
        XCTAssertEqual(opened.source, "local")
        XCTAssertEqual(opened.sessionName, "vm agtmux-term")
        XCTAssertEqual(opened.paneID, "%657")
        XCTAssertEqual(opened.tileID, mainTerminalStore.surfaceID.uuidString)
        XCTAssertEqual(opened.workbenchID, mainTerminalStore.viewportID.uuidString)
        XCTAssertTrue(viewModel.runtimeStore.hasCompletedInitialFetch)
        XCTAssertFalse(viewModel.runtimeStore.offlineHosts.contains("local"))
        XCTAssertTrue(
            viewModel.runtimeStore.livePaneSessionKeys.contains("local:vm agtmux-term")
        )
    }

    @MainActor
    func testUITestTmuxBridgeOpenTerminalForPanePrefersDirectResolverBeforeSessionOnlyFallbackWithoutExistingTile() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let pane = AgtmuxPane(
            source: "local",
            paneId: "%777",
            sessionName: "live-direct-fallback",
            windowId: "@7",
            currentCmd: "python3"
        )
        let viewModel = AppViewModel(hostsConfig: HostsConfig(hosts: []))
        viewModel.panes = []
        let mainTerminalStore = MainTerminalStore()

        let workbenchStore = WorkbenchStoreV2(
            workbenches: [.empty()],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: pane.paneId,
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x777)
        )

        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { sessionName, paneID in
                XCTAssertEqual(sessionName, pane.sessionName)
                XCTAssertEqual(paneID, pane.paneId)
                return pane
            },
            env: ["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK": "1"]
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId
        )

        XCTAssertEqual(opened.disposition, "opened")
        XCTAssertFalse(opened.usedSessionOnlyFallback)
        XCTAssertEqual(opened.sessionName, pane.sessionName)
        XCTAssertEqual(opened.paneID, pane.paneId)
        XCTAssertEqual(viewModel.panes, [pane])
        XCTAssertTrue(viewModel.runtimeStore.livePaneSessionKeys.contains("local:\(pane.sessionName)"))
    }

    @MainActor
    func testUITestTmuxBridgePrefersDirectLocalPaneResolverBeforeSessionOnlyFallback() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let tileID = UUID()
        let workbenchID = UUID()
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%657",
            sessionName: "vm agtmux-term",
            windowId: "@1",
            currentCmd: "codex"
        )
        let viewModel = AppViewModel(hostsConfig: HostsConfig(hosts: []))
        viewModel.panes = []
        let mainTerminalStore = MainTerminalStore(
            mode: .tmux(
                sessionRef: SessionRef(target: .local, sessionName: pane.sessionName),
                requestedPaneRef: nil,
                resolvedPaneRef: ActivePaneRef(
                    target: .local,
                    sessionName: pane.sessionName,
                    windowID: pane.windowId,
                    paneID: pane.paneId
                )
            )
        )

        let workbenchStore = WorkbenchStoreV2(
            workbenches: [
                Workbench(
                    id: workbenchID,
                    title: "Live",
                    root: .tile(
                        WorkbenchTile(
                            id: tileID,
                            kind: .terminal(
                                sessionRef: SessionRef(target: .local, sessionName: pane.sessionName)
                            )
                        )
                    ),
                    focusedTileID: tileID
                )
            ],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: pane.paneId,
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x693)
        )

        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { sessionName, paneID in
                XCTAssertEqual(sessionName, pane.sessionName)
                XCTAssertEqual(paneID, pane.paneId)
                return pane
            },
            env: ["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK": "1"]
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: pane.sessionName,
            paneID: pane.paneId
        )

        XCTAssertEqual(opened.disposition, "revealedExisting")
        XCTAssertFalse(opened.usedSessionOnlyFallback)
        XCTAssertEqual(viewModel.panes, [pane])
        XCTAssertTrue(viewModel.runtimeStore.livePaneSessionKeys.contains("local:\(pane.sessionName)"))
    }

    @MainActor
    func testUITestTmuxBridgeOpenTerminalForPaneCanUseLocalPaneIDInventoryFallback() async throws {
        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }

        let viewModel = AppViewModel(
            hostsConfig: HostsConfig(hosts: [])
        )
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%657",
            sessionName: "different-session",
            windowId: "@42",
            currentCmd: "claude"
        )
        viewModel.panes = [pane]
        let mainTerminalStore = MainTerminalStore()

        let workbenchStore = WorkbenchStoreV2(
            workbenches: [.empty()],
            activeWorkbenchIndex: 0,
            persistence: nil
        )
        let bridge = UITestTmuxBridge(
            viewModel: viewModel,
            mainTerminalStore: mainTerminalStore,
            workbenchStore: workbenchStore,
            resolveDirectLocalPane: { _, _ in
                XCTFail("pane-id inventory fallback should skip direct pane resolution")
                return nil
            },
            env: ["AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK": "1"]
        )

        let view = GhosttyTerminalViewViewportTextSpy()
        view.snapshots = [
            .init(text: "ready", lineCount: 1, characterCount: 5, usesAlternateScroll: false)
        ]
        SurfacePool.shared.register(
            view: view,
            leafID: mainTerminalStore.surfaceID,
            tmuxPaneID: pane.paneId,
            surfaceHandle: GhosttySurfaceHandle(rawValue: 0x658)
        )

        let opened = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: "vm agtmux-term",
            paneID: pane.paneId
        )

        XCTAssertEqual(opened.disposition, "opened")
        XCTAssertFalse(opened.usedSessionOnlyFallback)
        XCTAssertEqual(mainTerminalStore.requestedPaneRef?.windowID, pane.windowId)
        XCTAssertEqual(mainTerminalStore.requestedPaneRef?.paneID, pane.paneId)
        XCTAssertEqual(mainTerminalStore.requestedPaneRef?.sessionName, pane.sessionName)
    }

    private func assertDecodeError(
        payload: String,
        expected: GhosttyCLIOSCBridgeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try GhosttyCLIOSCBridge.decodeRequest(from: Data(payload.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? GhosttyCLIOSCBridgeError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func withCustomOSCAction<T>(
        osc: UInt16 = GhosttyCLIOSCBridge.command,
        payload: String,
        _ body: (ghostty_action_s) throws -> T
    ) rethrows -> T {
        let data = Data(payload.utf8)
        return try data.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            let customOSC = ghostty_action_custom_osc_s(
                osc: osc,
                payload: pointer,
                len: UInt(data.count)
            )
            let action = ghostty_action_s(
                tag: GHOSTTY_ACTION_CUSTOM_OSC,
                action: ghostty_action_u(custom_osc: customOSC)
            )
            return try body(action)
        }
    }

    private func makeSurfaceTarget(_ surfaceHandle: GhosttySurfaceHandle) -> ghostty_target_s {
        ghostty_target_s(
            tag: GHOSTTY_TARGET_SURFACE,
            target: ghostty_target_u(
                surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)!
            )
        )
    }

    private func makeAppTarget() -> ghostty_target_s {
        ghostty_target_s(
            tag: GHOSTTY_TARGET_APP,
            target: ghostty_target_u(surface: nil)
        )
    }

    private func makeRenderAction() -> ghostty_action_s {
        ghostty_action_s(
            tag: GHOSTTY_ACTION_RENDER,
            action: ghostty_action_u()
        )
    }

    private static func invokeHandleActionOffMainThread(
        osc: UInt16 = GhosttyCLIOSCBridge.command,
        surfaceHandle: GhosttySurfaceHandle,
        payload: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ghosttyTarget = ghostty_target_s(
                    tag: GHOSTTY_TARGET_SURFACE,
                    target: ghostty_target_u(
                        surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)!
                    )
                )

                let data = Data(payload.utf8)
                let consumed = data.withUnsafeBytes { rawBuffer in
                    let pointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                    let customOSC = ghostty_action_custom_osc_s(
                        osc: osc,
                        payload: pointer,
                        len: UInt(data.count)
                    )
                    let action = ghostty_action_s(
                        tag: GHOSTTY_ACTION_CUSTOM_OSC,
                        action: ghostty_action_u(custom_osc: customOSC)
                    )
                    return GhosttyApp.handleAction(nil, target: ghosttyTarget, action: action)
                }

                continuation.resume(returning: consumed)
            }
        }
    }

    private static func invokeHandleRenderOffMainThread(
        surfaceHandle: GhosttySurfaceHandle
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ghosttyTarget = ghostty_target_s(
                    tag: GHOSTTY_TARGET_SURFACE,
                    target: ghostty_target_u(
                        surface: UnsafeMutableRawPointer(bitPattern: surfaceHandle.rawValue)!
                    )
                )
                let consumed = GhosttyApp.handleAction(
                    nil,
                    target: ghosttyTarget,
                    action: ghostty_action_s(
                        tag: GHOSTTY_ACTION_RENDER,
                        action: ghostty_action_u()
                    )
                )
                continuation.resume(returning: consumed)
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        intervalMs: UInt64 = 25,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return await condition()
    }
}

@MainActor
private final class GhosttyTerminalViewDrawSpy: GhosttyTerminalView {
    private(set) var triggerDrawCallCount = 0
    private(set) var scrollPresentationDrawCallCount = 0
    var shouldPreferImmediateDirtyDrawForRenderCallback = false

    override func hasSurfaceForScrollPresentationDraw() -> Bool {
        true
    }

    override func prefersImmediateDirtyDrawForRenderCallback(now: TimeInterval) -> Bool {
        shouldPreferImmediateDirtyDrawForRenderCallback
    }

    override func triggerDraw() {
        triggerDrawCallCount += 1
        super.triggerDraw()
    }

    override func triggerDirtyDrawForRenderCallback(now: TimeInterval) {
        if shouldPreferImmediateDirtyDrawForRenderCallback {
            triggerDrawCallCount += 1
        }
        super.triggerDirtyDrawForRenderCallback(now: now)
    }

    override func performScrollPresentationDraw() {
        scrollPresentationDrawCallCount += 1
        super.performScrollPresentationDraw()
    }

    func resetDrawTracking() {
        triggerDrawCallCount = 0
        scrollPresentationDrawCallCount = 0
    }
}

@MainActor
private final class GhosttyTerminalViewMetricsSpy: GhosttyTerminalView {
    struct ScaleUpdate: Equatable {
        let xScale: Double
        let yScale: Double
    }

    struct SizeUpdate: Equatable {
        let pixelWidth: UInt32
        let pixelHeight: UInt32
    }

    private(set) var contentScaleUpdates: [ScaleUpdate] = []
    private(set) var sizeUpdates: [SizeUpdate] = []
    private(set) var displayIDUpdates: [UInt32] = []

    override func hasSurfaceForMetricsSync() -> Bool {
        true
    }

    override func updateSurfaceContentScale(xScale: Double, yScale: Double) {
        contentScaleUpdates.append(ScaleUpdate(xScale: xScale, yScale: yScale))
    }

    override func updateSurfaceSize(pixelWidth: UInt32, pixelHeight: UInt32) {
        sizeUpdates.append(
            SizeUpdate(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        )
    }

    override func updateSurfaceDisplayID(_ displayID: UInt32) {
        displayIDUpdates.append(displayID)
    }

    func resetMetricTracking() {
        contentScaleUpdates.removeAll()
        sizeUpdates.removeAll()
        displayIDUpdates.removeAll()
    }
}

@MainActor
private final class GhosttyTerminalViewViewportTextSpy: GhosttyTerminalView {
    var snapshots: [ViewportTextSnapshot] = []

    override func viewportTextSnapshotForTesting() -> ViewportTextSnapshot {
        guard snapshots.isEmpty == false else {
            return super.viewportTextSnapshotForTesting()
        }
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return snapshots.removeFirst()
    }
}

@MainActor
private final class GhosttyTerminalViewScrollInjectionSpy: GhosttyTerminalView {
    struct InjectedStep: Equatable {
        let verticalDelta: Double
        let phase: NSEvent.Phase
        let momentumPhase: NSEvent.Phase
        let precision: Bool
    }

    private(set) var injectedSteps: [InjectedStep] = []
    private(set) var prepareCallCount = 0

    override func prepareForInternalTrackpadScrollInjectionForTesting() {
        prepareCallCount += 1
    }

    override func dispatchInternalTrackpadScrollStepForTesting(
        horizontalDelta: Double,
        verticalDelta: Double,
        precision: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) {
        injectedSteps.append(
            InjectedStep(
                verticalDelta: verticalDelta,
                phase: phase,
                momentumPhase: momentumPhase,
                precision: precision
            )
        )
    }
}
