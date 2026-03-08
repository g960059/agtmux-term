import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore
import GhosttyKit

final class GhosttyCLIOSCBridgeTests: XCTestCase {
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
            await Self.invokeHandleActionOffMainThread(
                surfaceHandle: surfaceHandle,
                payload: payload
            )
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
            await Self.invokeHandleActionOffMainThread(
                osc: 7000,
                surfaceHandle: surfaceHandle,
                payload: payload
            )
        }

        XCTAssertFalse(consumed)
        XCTAssertTrue(sawMainActorHop)
        XCTAssertTrue(sawDispatcherOnMainThread)
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
            await Self.invokeHandleActionOffMainThread(
                surfaceHandle: surfaceHandle,
                payload: payload
            )
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
}
