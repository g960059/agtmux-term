import XCTest
import AppKit
import AgtmuxTermCore
@testable import AgtmuxTerm

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class UITestTmuxBridgeTests: XCTestCase {
    private func makeUserDefaultsSuite() -> UserDefaults {
        let suiteName = "UITestTmuxBridgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeBridgePaths() -> (commandURL: URL, responseURL: URL, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestTmuxBridgeTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (
            commandURL: tempDir.appendingPathComponent("tmux-command.json"),
            responseURL: tempDir.appendingPathComponent("tmux-command-result.json"),
            tempDir: tempDir
        )
    }

    private func makeEnabledMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestTmuxBridgeTests.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    private func writeBridgeCommand(
        id: String,
        args: [String],
        commandURL: URL,
        responseURL: URL
    ) throws {
        let payload: [String: Any] = [
            "id": id,
            "args": args,
            "refreshInventory": false,
            "responsePath": responseURL.path
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: commandURL, options: .atomic)
    }

    private func waitForBridgeResponse(
        at responseURL: URL,
        timeout: TimeInterval = 2.0
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return jsonObject
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for bridge response at \(responseURL.path)")
        return [:]
    }

    private func decodeJSONObject(from string: String) throws -> [String: Any] {
        let data = Data(string.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON object payload")
            return [:]
        }
        return object
    }

    func testAppWindowFocusRequirementDoesNotRequireTerminalFirstResponder() {
        XCTAssertTrue(
            UITestFocusRequirement.appWindow.isSatisfied(
                appIsActive: true,
                windowIsVisible: true,
                windowIsKey: true,
                terminalIsFirstResponder: false
            )
        )
        XCTAssertFalse(
            UITestFocusRequirement.appWindow.isSatisfied(
                appIsActive: false,
                windowIsVisible: true,
                windowIsKey: true,
                terminalIsFirstResponder: false
            )
        )
    }

    func testTerminalHostFocusRequirementRequiresTerminalFirstResponder() {
        XCTAssertTrue(
            UITestFocusRequirement.terminalHost.isSatisfied(
                appIsActive: true,
                windowIsVisible: true,
                windowIsKey: true,
                terminalIsFirstResponder: true
            )
        )
        XCTAssertFalse(
            UITestFocusRequirement.terminalHost.isSatisfied(
                appIsActive: true,
                windowIsVisible: true,
                windowIsKey: true,
                terminalIsFirstResponder: false
            )
        )
    }

    func testTerminalResponderFocusRequirementDoesNotRequireForegroundWindow() {
        XCTAssertTrue(
            UITestFocusRequirement.terminalResponder.isSatisfied(
                appIsActive: false,
                windowIsVisible: true,
                windowIsKey: false,
                terminalIsFirstResponder: true
            )
        )
        XCTAssertFalse(
            UITestFocusRequirement.terminalResponder.isSatisfied(
                appIsActive: false,
                windowIsVisible: false,
                windowIsKey: false,
                terminalIsFirstResponder: true
            )
        )
    }

    func testTerminalViewInWindowRequirementDoesNotRequireRenderedState() {
        let terminalView = GhosttyTerminalView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        container.addSubview(terminalView)

        XCTAssertTrue(
            TerminalViewRegistrationRequirement.terminalViewInWindow.isSatisfied(
                terminalView: terminalView,
                renderedState: nil
            )
        )
        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindowAndRenderedState.isSatisfied(
                terminalView: terminalView,
                renderedState: nil
            )
        )
    }

    func testTerminalViewInWindowRequirementStillRequiresWindowAttachment() {
        let surfaceID = UUID()
        let renderedState = GhosttyRenderedTerminalSurfaceState(
            context: GhosttyTerminalSurfaceContext(
                viewportID: UUID(),
                surfaceID: surfaceID,
                surfaceKey: "main-terminal:local:alpha",
                sessionRef: SessionRef(target: .local, sessionName: "alpha")
            ),
            attachCommand: "tmux attach-session -t alpha",
            clientTTY: "/dev/ttys001",
            generation: 1
        )

        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindow.isSatisfied(
                terminalView: GhosttyTerminalView(),
                renderedState: renderedState
            )
        )
        XCTAssertFalse(
            TerminalViewRegistrationRequirement.terminalViewInWindowAndRenderedState.isSatisfied(
                terminalView: GhosttyTerminalView(),
                renderedState: renderedState
            )
        )
    }

    func testAutomationRequestedIgnoresDefaultsWithoutMarker() {
        let defaults = makeUserDefaultsSuite()
        defaults.set(true, forKey: UITestTmuxBridge.automationEnabledDefaultsKey)

        XCTAssertFalse(
            UITestTmuxBridge.automationRequested(
                environment: [:],
                userDefaults: defaults
            )
        )
    }

    func testAutomationRequestedAcceptsEnabledMarkerWithoutDefaults() throws {
        let markerURL = makeEnabledMarkerURL()
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: markerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent()) }

        XCTAssertTrue(
            UITestTmuxBridge.automationRequested(
                environment: [:],
                userDefaults: makeUserDefaultsSuite(),
                fileManager: .default,
                enabledURL: markerURL
            )
        )
    }

    func testInventoryOnlyRequestedPrefersEnvironmentThenDefaults() {
        let defaults = makeUserDefaultsSuite()
        defaults.set(true, forKey: UITestTmuxBridge.inventoryOnlyDefaultsKey)

        XCTAssertTrue(UITestTmuxBridge.inventoryOnlyRequested(environment: [:], userDefaults: defaults))
        XCTAssertFalse(
            UITestTmuxBridge.inventoryOnlyRequested(
                environment: ["AGTMUX_UITEST_INVENTORY_ONLY": "0"],
                userDefaults: defaults
            )
        )
    }

    func testGhosttySurfacesRequestedFallsBackToDefaults() {
        let defaults = makeUserDefaultsSuite()
        XCTAssertFalse(UITestTmuxBridge.ghosttySurfacesRequested(environment: [:], userDefaults: defaults))

        defaults.set(true, forKey: UITestTmuxBridge.enableGhosttySurfacesDefaultsKey)

        XCTAssertTrue(UITestTmuxBridge.ghosttySurfacesRequested(environment: [:], userDefaults: defaults))
    }

    func testBootstrapScenarioFallsBackToDefaults() {
        let defaults = makeUserDefaultsSuite()
        let scenario = #"{"sessionName":"alpha","windowName":"main","paneCount":1,"shellCommand":"/bin/sleep 60"}"#
        defaults.set(scenario, forKey: UITestTmuxBridge.bootstrapScenarioDefaultsKey)

        XCTAssertEqual(
            UITestTmuxBridge.bootstrapScenario(environment: [:], userDefaults: defaults),
            scenario
        )
    }

    func testStartIfNeededIgnoresStaleBridgeDefaultsWithoutMarker() async {
        let defaults = makeUserDefaultsSuite()
        let paths = makeBridgePaths()
        let bootstrapResultURL = paths.tempDir.appendingPathComponent("tmux-bootstrap-result.json")
        var refreshCount = 0

        defaults.set(true, forKey: UITestTmuxBridge.automationEnabledDefaultsKey)
        defaults.set(true, forKey: UITestTmuxBridge.bridgeEnabledDefaultsKey)
        defaults.set(paths.commandURL.path, forKey: UITestTmuxBridge.commandPathDefaultsKey)
        defaults.set(paths.responseURL.path, forKey: UITestTmuxBridge.commandResultPathDefaultsKey)
        defaults.set(bootstrapResultURL.path, forKey: UITestTmuxBridge.bootstrapResultPathDefaultsKey)
        defaults.set(
            #"{"sessionName":"stale","windowName":"main","paneCount":1,"shellCommand":"/bin/sleep 1"}"#,
            forKey: UITestTmuxBridge.bootstrapScenarioDefaultsKey
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            refreshAll: {
                refreshCount += 1
            },
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
            try? FileManager.default.removeItem(at: paths.tempDir)
        }

        XCTAssertFalse(UITestTmuxBridge.bridgeRequested(environment: [:], userDefaults: defaults))

        await bridge.startIfNeeded()

        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bootstrapResultURL.path))
        XCTAssertEqual(bridge.processedCommandCountForTesting(), 0)
    }

    func testCommandLoopProcessesCommandWrittenAfterLoopStarts() async throws {
        let defaults = makeUserDefaultsSuite()
        let paths = makeBridgePaths()
        defaults.set(true, forKey: UITestTmuxBridge.bridgeEnabledDefaultsKey)
        defaults.set(paths.commandURL.path, forKey: UITestTmuxBridge.commandPathDefaultsKey)
        defaults.set(paths.responseURL.path, forKey: UITestTmuxBridge.commandResultPathDefaultsKey)

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
            try? FileManager.default.removeItem(at: paths.tempDir)
        }

        bridge.startCommandLoopIfNeededForTesting()
        try await Task.sleep(for: .milliseconds(50))

        let responseURL = paths.tempDir.appendingPathComponent("response-1.json")
        try writeBridgeCommand(
            id: "request-1",
            args: ["__agtmux_tmux_bridge_ready__"],
            commandURL: paths.commandURL,
            responseURL: responseURL
        )

        let response = try await waitForBridgeResponse(at: responseURL)
        XCTAssertEqual(response["id"] as? String, "request-1")
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["stdout"] as? String, "ready")
        XCTAssertEqual(bridge.processedCommandCountForTesting(), 1)
    }

    func testCommandLoopProcessesMultipleCommandsWithoutRestart() async throws {
        let defaults = makeUserDefaultsSuite()
        let paths = makeBridgePaths()
        defaults.set(true, forKey: UITestTmuxBridge.bridgeEnabledDefaultsKey)
        defaults.set(paths.commandURL.path, forKey: UITestTmuxBridge.commandPathDefaultsKey)
        defaults.set(paths.responseURL.path, forKey: UITestTmuxBridge.commandResultPathDefaultsKey)

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
            try? FileManager.default.removeItem(at: paths.tempDir)
        }

        bridge.startCommandLoopIfNeededForTesting()

        for index in 1...2 {
            let responseURL = paths.tempDir.appendingPathComponent("response-\(index).json")
            try writeBridgeCommand(
                id: "request-\(index)",
                args: ["__agtmux_tmux_bridge_ready__"],
                commandURL: paths.commandURL,
                responseURL: responseURL
            )

            let response = try await waitForBridgeResponse(at: responseURL)
            XCTAssertEqual(response["id"] as? String, "request-\(index)")
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual(response["stdout"] as? String, "ready")
        }

        XCTAssertEqual(bridge.processedCommandCountForTesting(), 2)
    }

    func testCommandLoopProcessesRegistrationSnapshotAfterSessionOnlyNowaitOpen() async throws {
        let defaults = makeUserDefaultsSuite()
        let paths = makeBridgePaths()
        defaults.set(true, forKey: UITestTmuxBridge.bridgeEnabledDefaultsKey)
        defaults.set(true, forKey: UITestTmuxBridge.sessionOnlyFallbackDefaultsKey)
        defaults.set(paths.commandURL.path, forKey: UITestTmuxBridge.commandPathDefaultsKey)
        defaults.set(paths.responseURL.path, forKey: UITestTmuxBridge.commandResultPathDefaultsKey)

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
            try? FileManager.default.removeItem(at: paths.tempDir)
        }

        bridge.startCommandLoopIfNeededForTesting()

        let openResponseURL = paths.tempDir.appendingPathComponent("response-open.json")
        try writeBridgeCommand(
            id: "request-open",
            args: ["__agtmux_open_terminal_for_pane__", "local", "alpha", "", "nowait"],
            commandURL: paths.commandURL,
            responseURL: openResponseURL
        )

        let openResponse = try await waitForBridgeResponse(at: openResponseURL)
        XCTAssertEqual(openResponse["id"] as? String, "request-open")
        XCTAssertEqual(openResponse["ok"] as? Bool, true)
        let openStdout = try XCTUnwrap(openResponse["stdout"] as? String)
        let openPayload = try decodeJSONObject(from: openStdout)
        let surfaceID = try XCTUnwrap(openPayload["surfaceID"] as? String)

        let registrationResponseURL = paths.tempDir.appendingPathComponent("response-registration.json")
        try writeBridgeCommand(
            id: "request-registration",
            args: ["__agtmux_dump_terminal_registration_state__", surfaceID],
            commandURL: paths.commandURL,
            responseURL: registrationResponseURL
        )

        let registrationResponse = try await waitForBridgeResponse(at: registrationResponseURL)
        XCTAssertEqual(registrationResponse["id"] as? String, "request-registration")
        XCTAssertEqual(registrationResponse["ok"] as? Bool, true)
        let registrationStdout = try XCTUnwrap(registrationResponse["stdout"] as? String)
        let registrationPayload = try decodeJSONObject(from: registrationStdout)
        XCTAssertEqual(registrationPayload["surfaceID"] as? String, surfaceID)
        XCTAssertEqual(registrationPayload["mainTerminalSessionName"] as? String, "alpha")
        XCTAssertEqual(bridge.processedCommandCountForTesting(), 2)
    }

    func testBootstrapSuccessWritesResultBeforeRefreshCompletes() async throws {
        let defaults = makeUserDefaultsSuite()
        let paths = makeBridgePaths()
        let bootstrapResultURL = paths.tempDir.appendingPathComponent("tmux-bootstrap-result.json")
        defaults.set(bootstrapResultURL.path, forKey: UITestTmuxBridge.bootstrapResultPathDefaultsKey)

        let refreshStarted = expectation(description: "refresh started")
        let gate = AsyncGate()
        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            refreshAfterBootstrap: {
                refreshStarted.fulfill()
                await gate.wait()
            },
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task {
                await gate.open()
                await bridge.shutdown()
            }
            try? FileManager.default.removeItem(at: paths.tempDir)
        }

        bridge.completeBootstrapSuccessForTesting(
            sessionName: "alpha",
            windowID: "@1",
            paneIDs: ["%1"],
            socketPath: "/tmp/agtmux-test.sock"
        )

        try await Task.sleep(for: .milliseconds(50))
        let resultData = try Data(contentsOf: bootstrapResultURL)
        let resultObject = try JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        XCTAssertEqual(resultObject?["ok"] as? Bool, true)
        XCTAssertEqual(resultObject?["sessionName"] as? String, "alpha")
        XCTAssertEqual(resultObject?["windowID"] as? String, "@1")
        XCTAssertEqual(resultObject?["socketPath"] as? String, "/tmp/agtmux-test.sock")

        await fulfillment(of: [refreshStarted], timeout: 1.0)
        await gate.open()
    }

    func testDirectLocalPaneFallbackCarriesSocketOverrideIntoMainTerminalAttachPlan() async throws {
        let defaults = makeUserDefaultsSuite()
        let store = MainTerminalStore()
        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: store,
            resolveDirectLocalPane: { sessionName, paneID in
                XCTAssertEqual(sessionName, "alpha")
                XCTAssertEqual(paneID, "%1")
                return UITestTmuxBridge.DirectLocalPaneResolution(
                    pane: AgtmuxPane(
                        source: "local",
                        paneId: "%1",
                        sessionName: "alpha",
                        windowId: "@1",
                        currentPath: "/tmp/alpha",
                        currentCmd: "zsh"
                    ),
                    localSocketOverride: LocalTmuxSocketOverride(socketPath: "/tmp/direct.sock")
                )
            },
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
        }

        _ = try await bridge.openTerminalForPaneForTesting(
            source: "local",
            sessionName: "alpha",
            paneID: "%1",
            waitForRegistration: false
        )

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if let plan = try? store.attachResolution?.get() {
                XCTAssertTrue(plan.command.contains("tmux -S /tmp/direct.sock"))
                XCTAssertEqual(plan.surfaceKey, "main-terminal:local:/tmp/direct.sock:alpha")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Timed out waiting for socket-aware attach plan")
    }

    func testSampleTerminalViewportTextForTestingReturnsSnapshotsForRegisteredTerminalView() async throws {
        let defaults = makeUserDefaultsSuite()
        let surfaceID = UUID()
        let surfaceHandle = GhosttySurfaceHandle(rawValue: 0xCAFE)
        let snapshots = [
            GhosttyTerminalView.ViewportTextSnapshot(
                text: "line-1",
                lineCount: 1,
                characterCount: 6,
                usesAlternateScroll: false
            ),
            GhosttyTerminalView.ViewportTextSnapshot(
                text: "line-2",
                lineCount: 1,
                characterCount: 6,
                usesAlternateScroll: false
            ),
            GhosttyTerminalView.ViewportTextSnapshot(
                text: "line-3",
                lineCount: 1,
                characterCount: 6,
                usesAlternateScroll: false
            ),
        ]
        let terminalView = SampleViewportTerminalViewSpy(snapshots: snapshots)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        terminalView.frame = container.bounds
        container.addSubview(terminalView)

        SurfacePool.shared.resetForTesting()
        defer { SurfacePool.shared.resetForTesting() }
        SurfacePool.shared.register(
            view: terminalView,
            leafID: surfaceID,
            tmuxPaneID: "%1",
            surfaceHandle: surfaceHandle
        )

        let bridge = UITestTmuxBridge(
            viewModel: AppViewModel(),
            mainTerminalStore: MainTerminalStore(),
            env: [:],
            userDefaults: defaults
        )
        defer {
            Task { await bridge.shutdown() }
        }

        let sampling = try await bridge.sampleTerminalViewportTextForTesting(
            surfaceID: surfaceID,
            sampleCount: snapshots.count,
            intervalMilliseconds: 0
        )

        XCTAssertEqual(sampling.samples.count, snapshots.count)
        XCTAssertEqual(
            sampling.samples.map(\.snapshot.text),
            snapshots.map(\.text)
        )
    }
}

private final class SampleViewportTerminalViewSpy: GhosttyTerminalView {
    private let snapshots: [ViewportTextSnapshot]
    private var nextSnapshotIndex = 0

    init(snapshots: [ViewportTextSnapshot]) {
        self.snapshots = snapshots
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewportTextSnapshotForTesting() -> ViewportTextSnapshot {
        let index = min(nextSnapshotIndex, snapshots.count - 1)
        nextSnapshotIndex += 1
        return snapshots[index]
    }
}
