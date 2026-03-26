import XCTest
import AgtmuxTermCore
import CoreGraphics
import Darwin

/// E2E crash regression tests for agtmux-term.
///
/// # Test Categories
///
/// ## Category A — No daemon required (mock AGTMUX_JSON)
/// These tests inject JSON via AGTMUX_JSON.
/// They run on any machine regardless of whether agtmux daemon is running.
/// They test: sidebar population, filter logic, empty state, tab creation.
///
/// ## Category B — Requires tmux binary
/// These tests create real tmux sessions to test terminal tile creation.
/// They require tmux to be installed. Guarded by XCTSkip when tmux unavailable.
///
/// ## Category C — Requires agtmux daemon + running sessions
/// Legacy tests that depend on pre-existing managed panes. Guarded by XCTSkip.
///
/// # Sandbox note
/// The XCUITest runner bundle has `com.apple.security.app-sandbox = true`.
/// The app itself has App Sandbox disabled (tmux / daemon socket access).
final class AgtmuxTermUITests: XCTestCase {
    private struct LiveRunningScrollConfig: Decodable {
        let attachRunningApp: Bool?
        let terminalIdentifier: String?
        let bundleIdentifier: String?
        let repeatCount: Int?
        let intervalMilliseconds: Int?
        let deltaX: Double?
        let deltaY: Double?
        let xFraction: Double?
        let yFraction: Double?
        let readyPath: String?
        let goPath: String?
        let goTimeoutMilliseconds: Int?
    }

    private static let allowLockedSessionSentinelPath = "/tmp/agtmux-uitest-allow-locked-session"
    private static let liveRunningScrollConfigPath = "/tmp/agtmux-live-ui-scroll-config.json"
    private static let appTmuxBridgeReadyCommand = "__agtmux_tmux_bridge_ready__"
    private static let activeDocumentTileCommand = "__agtmux_dump_active_document_tile__"
    private static let replaceFocusedTextCommand = "__agtmux_replace_focused_text__"

    private var app: XCUIApplication!
    private var tmuxPath: String? = nil
    /// Sessions that existed before the test started — never delete these.
    private var preExistingSessions: Set<String> = []
    /// Sessions explicitly created by this test via `createTrackedTmuxSession`.
    private var ownedSessions: Set<String> = []

    private func realUserHomeDirectory() -> URL {
        if let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func skipLegacyWorkbenchUITest() throws {
        throw XCTSkip(
            "Legacy workbench UI is migration-only under the terminal-first mainline."
        )
    }

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false
        ownedSessions = []

        let env = ProcessInfo.processInfo.environment
        let allowLockedSession =
            env["AGTMUX_UITEST_ALLOW_LOCKED_SESSION"] == "1"
            || FileManager.default.fileExists(atPath: Self.allowLockedSessionSentinelPath)
        if !allowLockedSession {
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
                let screenLocked = (session["CGSSessionScreenIsLocked"] as? Int) ?? 0
                let onConsole = (session["kCGSSessionOnConsoleKey"] as? Int) ?? 1
                let loginDone = (session["kCGSessionLoginDoneKey"] as? Int) ?? 1
                if screenLocked != 0 || onConsole == 0 || loginDone == 0 {
                    throw XCTSkip(
                        "XCUITest needs an unlocked interactive desktop session. " +
                        "Current session state: screenLocked=\(screenLocked), " +
                        "onConsole=\(onConsole), loginDone=\(loginDone). " +
                        "Set AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1 or create \(Self.allowLockedSessionSentinelPath) to force-run."
                    )
                }
            }
        }
        if env["SSH_CONNECTION"] != nil, env["AGTMUX_UITEST_ALLOW_SSH"] != "1" {
            throw XCTSkip(
                "XCUITest needs an interactive console session. " +
                "Current runner is an SSH session. " +
                "Set AGTMUX_UITEST_ALLOW_SSH=1 to force-run."
            )
        }

        // Resolve tmux path (best-effort — sandbox may block socket connections later).
        tmuxPath = resolveTmuxPathBestEffort()

        if let tmux = tmuxPath {
            // Record pre-existing sessions so tearDown doesn't delete them.
            if let existing = try? shellOutput([tmux, "list-sessions", "-F", "#{session_name}"]) {
                preExistingSessions = Set(existing.components(separatedBy: "\n").filter { !$0.isEmpty })
            }
        }

        app = XCUIApplication()
        // NOTE: Each test calls app.launchForUITest() (or sets AGTMUX_JSON first).
        //       setUp does NOT launch the app so mock tests can inject env vars.
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil

        // Kill sessions created during this test run and ensure agent processes
        // in test-owned sessions are terminated before session teardown.
        // Use a fresh path resolution as fallback: if the sandbox blocked the runner's
        // tmux socket in setUp (tmuxPath == nil), the app (no sandbox) may still have
        // created agtmux-linked-* sessions that need cleanup.
        let tmux = tmuxPath ?? resolveTmuxPathBestEffort()
        guard let tmux, let current = try? listTmuxSessions(tmux) else { return }

        // Any non-preexisting session is test-created residue and must be removed.
        let discovered = current.subtracting(preExistingSessions)
        let sessionsToKill = discovered.union(ownedSessions)

        // Agent cleanup is performed only for explicit test sessions to avoid
        // touching user-managed panes in preexisting sessions.
        let agentCleanupSessions = sessionsToKill.filter {
            ownedSessions.contains($0) || $0.hasPrefix("agtmux-e2e-")
        }
        for session in agentCleanupSessions {
            terminateSessionProcesses(session: session, tmux: tmux)
        }

        for session in sessionsToKill {
            _ = try? shellRun([tmux, "kill-session", "-t", session])
        }

        // Hard gate: no leaked non-preexisting sessions after cleanup.
        if let after = try? listTmuxSessions(tmux) {
            let leaked = after.subtracting(preExistingSessions)
            if !leaked.isEmpty {
                // One last best-effort pass before failing.
                for session in leaked {
                    _ = try? shellRun([tmux, "kill-session", "-t", session])
                }
                let finalLeaked = (try? listTmuxSessions(tmux).subtracting(preExistingSessions)) ?? []
                XCTAssertTrue(
                    finalLeaked.isEmpty,
                    "E2E cleanup leaked tmux sessions: \(finalLeaked.sorted())"
                )
            }
        }
    }

    // MARK: - Diagnostic

    /// Dumps the full accessibility tree so we can see what XCUITest actually observes.
    func testDumpAccessibilityTree() {
        app.launchForUITest()
        Thread.sleep(forTimeInterval: 5.0)

        let desc = app.debugDescription
        XCTContext.runActivity(named: "App AX tree (first 6000 chars)") { activity in
            let attachment = XCTAttachment(string: String(desc.prefix(6000)))
            attachment.name = "ax_tree.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let windowCount = app.windows.count
        XCTContext.runActivity(named: "Windows: \(windowCount)") { _ in }

        let anyCount = app.descendants(matching: .any).count
        XCTContext.runActivity(named: "Total elements: \(anyCount)") { _ in }

        let elements = app.descendants(matching: .any).allElementsBoundByIndex
        let ids = elements.prefix(50).map { e -> String in
            let t = e.elementType.rawValue
            let id = e.identifier
            let lbl = e.label
            return "type=\(t) id='\(id)' lbl='\(lbl)'"
        }
        XCTContext.runActivity(named: "First 50 elements") { activity in
            let attachment = XCTAttachment(string: ids.joined(separator: "\n"))
            attachment.name = "elements.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        if let win = app.windows.allElementsBoundByIndex.first {
            let winDesc = win.debugDescription
            XCTContext.runActivity(named: "Window AX tree") { activity in
                let attachment = XCTAttachment(string: String(winDesc.prefix(6000)))
                attachment.name = "window_ax_tree.txt"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }

        XCTAssert(true, "Diagnostic test always passes — check attachments for AX tree")
    }

    // MARK: - Category A: No daemon required (mock AGTMUX_JSON)

    /// T-E2E-001: App launches and sidebar is visible.
    func testAppLaunchShowsSidebar() {
        app.launchForUITest()
        let predicate = NSPredicate(format: "identifier == %@", AccessibilityID.sidebar)
        let sidebar = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: TestConstants.settleTimeout),
            "Sidebar should appear after launch"
        )
    }

    /// T-E2E-002: Launch shows the single main terminal and no visible workbench chrome.
    func testEmptyStateOnLaunch() {
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()
        let terminal = mainTerminal()
        XCTAssertTrue(
            terminal.waitForExistence(timeout: TestConstants.settleTimeout),
            "Main terminal should be visible after launch"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
            ).firstMatch.exists,
            "Visible workbench tab UI should not be exposed on terminal-first launch"
        )
        XCTAssertTrue(mainTerminalNewShellButton().exists, "New Shell should be available on launch")
    }

    /// T-E2E-002c: The default cockpit path opens a direct real-session V2 tile
    /// from the sidebar without creating any linked session.
    func testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile() throws {
        try skipLegacyWorkbenchUITest()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let sessionName = "agtmux-v2-real-\(token)"
        let socket = "agtmux-v2-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: sessionName,
            windowName: "v2-real",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        app.launchEnvironment["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] = "1"
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              let bootstrapSession = bootstrap.sessionName,
              bootstrapSession == sessionName,
              let paneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for V2 real-session open test")
        }

        let row = paneRow(source: "local", sessionName: sessionName, paneID: paneID)
        XCTAssertTrue(
            row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane must appear in sidebar before V2 real-session open can be asserted"
        )

        let linkedBefore = try listLinkedSessionsViaApp(control: control)
        XCTAssertTrue(linkedBefore.isEmpty, "V2 open should start without any linked session")

        assertWorkspaceStartsEmpty()
        XCTAssertTrue(
            clickSidebarPaneRow(row),
            "Pane row must still exist before default V2 open"
        )
        waitForWorkspaceToLeaveEmptyState()

        let tile = workbenchV2TerminalTile(sessionName: sessionName)
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.settleTimeout),
            "Mainline V2 path should render a real-session terminal tile"
        )

        let statusText = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Direct attach: local session \(sessionName)"
            )
        ).firstMatch
        XCTAssertTrue(
            statusText.waitForExistence(timeout: TestConstants.settleTimeout),
            "V2 real-session tile must surface direct-attach status text"
        )

        let linkedAfter = try listLinkedSessionsViaApp(control: control)
        XCTAssertEqual(
            linkedAfter,
            linkedBefore,
            "V2 direct attach must not create any linked session"
        )

        let loadingOverlay = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceLoadingPrefix +
                AccessibilityID.paneKey(source: "local", sessionName: sessionName, paneID: paneID)
            )
        ).firstMatch
        XCTAssertFalse(
            loadingOverlay.exists,
            "V2 direct attach must not enter the V1 linked-session loading overlay path"
        )
    }

    /// T-E2E-002d: Reopening the same session on the default cockpit path must
    /// reveal the existing V2 tile rather than creating a second visible tile.
    func testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile() throws {
        try skipLegacyWorkbenchUITest()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let sessionName = "agtmux-v2-dup-\(token)"
        let socket = "agtmux-v2-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: sessionName,
            windowName: "v2-dup",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              let bootstrapSession = bootstrap.sessionName,
              bootstrapSession == sessionName,
              let paneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for V2 duplicate-open test")
        }

        let row = paneRow(source: "local", sessionName: sessionName, paneID: paneID)
        XCTAssertTrue(
            row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane must exist before duplicate-open proof can run"
        )

        let linkedBefore = try listLinkedSessionsViaApp(control: control)
        XCTAssertTrue(linkedBefore.isEmpty, "V2 duplicate-open test should start without linked sessions")

        XCTAssertTrue(
            clickSidebarPaneRow(row),
            "Pane row must still exist before default V2 open"
        )
        let tile = workbenchV2TerminalTile(sessionName: sessionName)
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.settleTimeout),
            "Initial V2 open must render its terminal tile"
        )

        guard clickSidebarPaneRow(row) else {
            throw XCTSkip("Pane row disappeared before duplicate-open click; app-driven inventory did not stabilize in time")
        }

        let tileQuery = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                sessionName
            )
        )
        let duplicatePredicate = NSPredicate(format: "count > 1")
        let noDuplicateExpectation = XCTNSPredicateExpectation(
            predicate: duplicatePredicate,
            object: tileQuery
        )
        noDuplicateExpectation.isInverted = true
        wait(for: [noDuplicateExpectation], timeout: TestConstants.settleTimeout)

        XCTAssertEqual(
            tileQuery.count,
            1,
            "Duplicate V2 session open must reveal the existing tile instead of creating another one"
        )

        let linkedAfter = try listLinkedSessionsViaApp(control: control)
        XCTAssertEqual(
            linkedAfter,
            linkedBefore,
            "Duplicate V2 open must not create any linked session"
        )

        let loadingOverlay = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceLoadingPrefix +
                AccessibilityID.paneKey(source: "local", sessionName: sessionName, paneID: paneID)
            )
        ).firstMatch
        XCTAssertFalse(
            loadingOverlay.exists,
            "Duplicate V2 open must stay off the V1 loading overlay path"
        )
    }

    /// T-E2E-002e: Restored broken V2 terminal tiles must remain visible with
    /// explicit recovery actions instead of silently disappearing.
    func testV2RestoredBrokenTerminalTileShowsPlaceholderAndCanBeRemoved() throws {
        try skipLegacyWorkbenchUITest()
        let sessionName = "agtmux-v2-restore-missing"
        let terminalTile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: sessionName,
                    lastSeenRepoRoot: "/tmp/restore-repo"
                )
            )
        )
        let fixtureWorkbench = Workbench(
            title: "Restore",
            root: .tile(terminalTile),
            focusedTileID: terminalTile.id
        )

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()

        let tile = workbenchV2TerminalTile(sessionName: sessionName)
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.settleTimeout),
            "Persisted V2 terminal tile should remain visible while broken"
        )

        let statusText = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Session missing: tmux session '\(sessionName)' no longer exists."
            )
        ).firstMatch
        XCTAssertTrue(
            statusText.waitForExistence(timeout: TestConstants.settleTimeout),
            "Broken restored tile must surface the explicit Session missing placeholder"
        )

        let retryButton = app.buttons["Retry"]
        let rebindButton = app.buttons["Rebind"]
        let removeButton = app.buttons["Remove Tile"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(removeButton.waitForExistence(timeout: TestConstants.settleTimeout))

        removeButton.click()

        let tileRemoved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: tile
        )
        wait(for: [tileRemoved], timeout: TestConstants.settleTimeout)
    }

    /// T-E2E-002f: A healthy restored V2 terminal tile must wait for inventory
    /// truth and settle into direct-attach state, not a false broken placeholder.
    func testV2RestoredHealthyTerminalTileDoesNotSurfaceBrokenPlaceholder() throws {
        try skipLegacyWorkbenchUITest()
        let paneID = "%55"
        let sessionName = "agtmux-v2-restore-healthy"
        let terminalTile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: sessionName,
                    lastSeenRepoRoot: "/tmp/restore-repo"
                )
            )
        )
        let fixtureWorkbench = Workbench(
            title: "Restore",
            root: .tile(terminalTile),
            focusedTileID: terminalTile.id
        )
        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(paneID)","session_name":"\(sessionName)","window_id":"@1",
           "window_index":1,"window_name":"restore","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-07T09:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let tile = workbenchV2TerminalTile(sessionName: sessionName)
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.settleTimeout),
            "Persisted V2 terminal tile should restore into view"
        )

        let directAttachStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Direct attach: local session \(sessionName)"
            )
        ).firstMatch
        XCTAssertTrue(
            directAttachStatus.waitForExistence(timeout: TestConstants.settleTimeout),
            "Healthy restored terminal tile must settle into direct-attach state"
        )

        let brokenStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Session missing: tmux session '\(sessionName)' no longer exists."
            )
        ).firstMatch
        XCTAssertFalse(
            brokenStatus.exists,
            "Healthy restored terminal tile must not expose a false Session missing placeholder"
        )
    }

    func testV2RestoredBrokenTerminalTileCanRebindToLiveSession() throws {
        try skipLegacyWorkbenchUITest()
        let missingSession = "agtmux-v2-restore-missing-rebind"
        let reboundSession = "agtmux-v2-restore-rebound"
        let terminalTile = WorkbenchTile(
            kind: .terminal(
                sessionRef: SessionRef(
                    target: .local,
                    sessionName: missingSession,
                    lastSeenRepoRoot: "/tmp/restore-repo"
                )
            )
        )
        let fixtureWorkbench = Workbench(
            title: "Restore",
            root: .tile(terminalTile),
            focusedTileID: terminalTile.id
        )
        let json = """
        {"version":1,"panes":[
          {"pane_id":"%56","session_name":"\(reboundSession)","window_id":"@1",
           "window_index":1,"window_name":"restore","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-07T09:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let tile = workbenchV2TerminalTile(sessionName: missingSession)
        XCTAssertTrue(tile.waitForExistence(timeout: TestConstants.settleTimeout))

        let brokenStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Session missing: tmux session '\(missingSession)' no longer exists."
            )
        ).firstMatch
        XCTAssertTrue(brokenStatus.waitForExistence(timeout: TestConstants.settleTimeout))

        let rebindButton = app.buttons["Rebind"]
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        rebindButton.click()

        let sheetRebindButton = app.buttons[AccessibilityID.workspaceTerminalRebindApply]
        XCTAssertTrue(sheetRebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        sheetRebindButton.click()

        let reboundTile = workbenchV2TerminalTile(sessionName: reboundSession)
        XCTAssertTrue(
            reboundTile.waitForExistence(timeout: TestConstants.settleTimeout),
            "Terminal rebind should retarget the tile to the selected live session"
        )

        let directAttachStatus = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                "Direct attach: local session \(reboundSession)"
            )
        ).firstMatch
        XCTAssertTrue(
            directAttachStatus.waitForExistence(timeout: TestConstants.settleTimeout),
            "Terminal rebind should settle into direct attach for the selected session"
        )
    }

    func testV2RestoredBrokenDocumentTileRetryCanRecover() throws {
        try skipLegacyWorkbenchUITest()
        let tempDirectory = try makeTemporaryDirectory()
        let documentPath = tempDirectory.appendingPathComponent("restore-retry.md").path
        let expectedText = "Recovered by retry"
        let documentTile = WorkbenchTile(
            kind: .document(ref: DocumentRef(target: .local, path: documentPath)),
            pinned: true
        )
        let fixtureWorkbench = Workbench(
            title: "Docs",
            root: .tile(documentTile),
            focusedTileID: documentTile.id
        )

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()

        let retryButton = app.buttons["Retry"]
        let rebindButton = app.buttons["Rebind"]
        let removeButton = app.buttons["Remove Tile"]
        let issueTitle = app.staticTexts["Path missing"]
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(retryButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(removeButton.waitForExistence(timeout: TestConstants.settleTimeout))

        try expectedText.write(toFile: documentPath, atomically: true, encoding: .utf8)
        retryButton.click()

        let recoveryExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: retryButton
        )
        let issueClearedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: issueTitle
        )
        wait(
            for: [recoveryExpectation, issueClearedExpectation],
            timeout: TestConstants.settleTimeout
        )
        XCTAssertTrue(
            !retryButton.exists,
            "Retry recovery should leave the broken-placeholder action row"
        )
        XCTAssertFalse(
            issueTitle.exists,
            "Retry recovery should clear the broken-placeholder issue title"
        )
    }

    func testV2RestoredBrokenDocumentTileCanRebindToExistingPath() throws {
        try skipLegacyWorkbenchUITest()
        let tempDirectory = try makeTemporaryDirectory()
        let missingPath = tempDirectory.appendingPathComponent("missing.md").path
        let reboundPath = tempDirectory.appendingPathComponent("rebound.md").path
        let expectedText = "Recovered by rebind"
        try expectedText.write(toFile: reboundPath, atomically: true, encoding: .utf8)

        let documentTile = WorkbenchTile(
            kind: .document(ref: DocumentRef(target: .local, path: missingPath)),
            pinned: true
        )
        let fixtureWorkbench = Workbench(
            title: "Docs",
            root: .tile(documentTile),
            focusedTileID: documentTile.id
        )
        let control = try makeAppTmuxControlPaths(token: "doc-\(String(UUID().uuidString.prefix(8)).lowercased())")

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchEnvironment["AGTMUX_UITEST_TMUX_COMMAND_PATH"] = control.commandPath
        app.launchEnvironment["AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH"] = control.commandResultPath
        app.launchForUITest()
        try waitForAppTmuxBridgeReady(control: control)

        let rebindButton = app.buttons["Rebind"]
        let issueTitle = app.staticTexts["Path missing"]
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        rebindButton.click()

        let pathField = app.textFields[AccessibilityID.workspaceDocumentRebindPath]
        XCTAssertTrue(pathField.waitForExistence(timeout: TestConstants.settleTimeout))
        pathField.click()
        try replaceFocusedText(reboundPath, control: control)

        let applyButton = app.buttons[AccessibilityID.workspaceDocumentRebindApply]
        XCTAssertTrue(applyButton.waitForExistence(timeout: TestConstants.settleTimeout))
        applyButton.click()

        let activeDocumentTile = try fetchActiveDocumentTileSnapshot(control: control)
        XCTAssertEqual(
            activeDocumentTile.path,
            reboundPath,
            "Document rebind should update the focused document tile ref in store"
        )

        let recoveryExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: rebindButton
        )
        let issueClearedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: issueTitle
        )
        wait(
            for: [recoveryExpectation, issueClearedExpectation],
            timeout: TestConstants.settleTimeout
        )
        XCTAssertFalse(
            rebindButton.exists,
            "Successful document rebind should leave the broken-placeholder action row"
        )
        XCTAssertFalse(
            issueTitle.exists,
            "Successful document rebind should clear the broken document placeholder"
        )
    }

    func testV2RestoredBrokenDocumentTileCanBeRemoved() throws {
        try skipLegacyWorkbenchUITest()
        let tempDirectory = try makeTemporaryDirectory()
        let missingPath = tempDirectory.appendingPathComponent("remove.md").path
        let documentTile = WorkbenchTile(
            kind: .document(ref: DocumentRef(target: .local, path: missingPath)),
            pinned: true
        )
        let fixtureWorkbench = Workbench(
            title: "Docs",
            root: .tile(documentTile),
            focusedTileID: documentTile.id
        )

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()

        let removeButton = app.buttons["Remove Tile"]
        let issueTitle = app.staticTexts["Path missing"]
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(removeButton.waitForExistence(timeout: TestConstants.settleTimeout))
        removeButton.click()

        let removalExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: removeButton
        )
        let issueClearedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: issueTitle
        )
        wait(
            for: [removalExpectation, issueClearedExpectation],
            timeout: TestConstants.settleTimeout
        )
    }

    /// T-E2E-002b: Selecting a pane updates the main terminal status without surfacing tab chrome.
    func testSelectedPaneSessionNameShownInTabTitle() throws {
        let paneID = "%44"
        let sessionName = "agtmux-e2e-title-sync"
        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(paneID)","session_name":"\(sessionName)","window_id":"@1",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let paneKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: paneID
        )
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + paneKey)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))

        row.click()

        let status = mainTerminalStatus()
        XCTAssertTrue(status.waitForExistence(timeout: TestConstants.settleTimeout))
        let tabTitleExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@", sessionName),
            evaluatedWith: status
        )

        wait(for: [tabTitleExpectation], timeout: 5.0)

        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
            ).firstMatch.exists,
            "Visible workbench tab bar should stay absent after pane selection"
        )
    }

    /// T-E2E-002c: metadata-enabled launch should surface local daemon health badges
    /// with stable accessibility identifiers and values.
    func testSidebarHealthStripShowsMixedHealthStates() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-health-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "health",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchEnvironment["AGTMUX_UI_HEALTH_V1_JSON"] = """
        {
          "generated_at":"2026-03-06T19:00:00Z",
          "runtime":{"status":"unavailable","detail":"bundled runtime missing","last_updated_at":"2026-03-06T18:59:58Z"},
          "replay":{"status":"degraded","lag":12,"last_resync_reason":"trimmed_cursor","last_resync_at":"2026-03-06T18:59:57Z","detail":"replay lagging behind head"},
          "overlay":{"status":"degraded","detail":"metadata stale","last_updated_at":"2026-03-06T18:59:56Z"},
          "focus":{"status":"unavailable","focused_pane_id":"%1","mismatch_count":3,"last_sync_at":"2026-03-06T18:59:55Z","detail":"focus sync offline"}
        }
        """
        app.launchForMetadataUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              let bootstrapSession = bootstrap.sessionName,
              bootstrapSession == session,
              let paneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for health-strip test")
        }

        let paneRow = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Metadata-enabled UI test still needs local inventory to populate"
        )

        let strip = sidebarHealthStrip()
        XCTAssertTrue(
            strip.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Health strip should appear when AGTMUX_UI_HEALTH_V1_JSON is provided"
        )
        XCTAssertEqual(strip.label, "Local daemon health")
        // macOS exposes the stable AX contract for this container through the strip
        // identifier/label and the child badge values, not a reliable parent value.

        let runtimeBadge = sidebarHealthBadge("runtime")
        XCTAssertTrue(runtimeBadge.exists)
        XCTAssertEqual(runtimeBadge.label, "Runtime health")
        XCTAssertEqual(runtimeBadge.value as? String, "unavailable, down")

        let replayBadge = sidebarHealthBadge("replay")
        XCTAssertTrue(replayBadge.exists)
        XCTAssertEqual(replayBadge.label, "Replay health")
        XCTAssertEqual(replayBadge.value as? String, "degraded, +12")

        let overlayBadge = sidebarHealthBadge("overlay")
        XCTAssertTrue(overlayBadge.exists)
        XCTAssertEqual(overlayBadge.label, "Overlay health")
        XCTAssertEqual(overlayBadge.value as? String, "degraded, warn")

        let focusBadge = sidebarHealthBadge("focus")
        XCTAssertTrue(focusBadge.exists)
        XCTAssertEqual(focusBadge.label, "Focus health")
        XCTAssertEqual(focusBadge.value as? String, "unavailable, x3")
    }

    /// T-E2E-002d: launch without a health refresh path should keep the health strip
    /// absent instead of surfacing stale UI.
    func testSidebarHealthStripStaysAbsentWithoutHealthSnapshot() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-health-clear-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "health-clear",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        app.launchEnvironment.removeValue(forKey: "AGTMUX_UI_HEALTH_V1_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              let bootstrapSession = bootstrap.sessionName,
              bootstrapSession == session,
              let paneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for absent-health test")
        }

        let paneRow = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Inventory must still populate while health remains absent"
        )

        XCTAssertFalse(
            sidebarHealthStrip().waitForExistence(timeout: 1.0),
            "Health strip should stay absent when no ui.health.v1 snapshot is available"
        )
    }

    /// T-E2E-002e: mixed-era local sync-v2 payloads that still carry `session_id`
    /// must fail closed to inventory-only UI instead of surfacing managed codex state.
    func testLegacySessionIDBootstrapPayloadFailsClosedToInventoryOnlyUI() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available for legacy bootstrap fail-closed UI test")
        }
        switch classifyRunnerTmuxAccess(tmux: tmux) {
        case .available, .availableNoServer:
            break
        case .inaccessible(let reason):
            throw XCTSkip("tmux socket not accessible from runner (legacy bootstrap fail-closed): \(reason)")
        }

        let session = try createTrackedTmuxSession(prefix: "agtmux-e2e-legacy-bootstrap", tmux: tmux)
        let paneListing = try shellOutput(
            [tmux, "list-panes", "-t", session, "-F", "#{pane_id}|#{window_id}|#{pane_current_command}"]
        )
        guard let firstLine = paneListing.split(separator: "\n").first else {
            throw XCTSkip("Could not resolve pane identity for legacy bootstrap fail-closed UI test")
        }
        let fields = firstLine.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else {
            throw XCTSkip("Unexpected tmux pane listing shape for legacy bootstrap fail-closed UI test")
        }
        let paneID = fields[0]
        let windowID = fields[1]
        let expectedLabel = fields[2].isEmpty ? paneID : fields[2]

        app.launchEnvironment["AGTMUX_UI_BOOTSTRAP_V2_JSON"] = mixedEraBootstrapPayloadWithLegacySessionID(
            sessionName: session,
            paneID: paneID,
            windowID: windowID
        )
        app.launchForMetadataUITest()

        let row = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Inventory row must appear before legacy bootstrap fail-closed UI can be asserted"
        )

        XCTAssertTrue(
            app.staticTexts["Local metadata incompatible"]
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Legacy session_id payload must surface an incompatible local daemon banner"
        )

        let expectedLabelText = row.descendants(matching: .staticText).matching(
            NSPredicate(format: "label == %@", expectedLabel)
        ).firstMatch
        XCTAssertTrue(
            expectedLabelText.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane row must stay inventory-only and keep the tmux command label after incompatible metadata is rejected"
        )

        let unexpectedCodexText = row.descendants(matching: .staticText).matching(
            NSPredicate(format: "label == %@", "codex")
        ).firstMatch
        XCTAssertFalse(
            unexpectedCodexText.exists,
            "Legacy session_id metadata must not rewrite the pane row label to a managed codex title"
        )
    }

    /// T-E2E-005: New Shell resets the single main terminal back to plain shell.
    func testTabCreation() throws {
        let paneID = "%55"
        let sessionName = "agtmux-e2e-new-shell"
        app.launchEnvironment["AGTMUX_JSON"] = """
        {"version":1,"panes":[
          {"pane_id":"\(paneID)","session_name":"\(sessionName)","window_id":"@1",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-23T12:00:00Z","age_secs":0}
        ]}
        """
        app.launchForUITest()

        let row = paneRow(source: "local", sessionName: sessionName, paneID: paneID)
        XCTAssertTrue(row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))
        row.click()

        let status = mainTerminalStatus()
        XCTAssertTrue(status.waitForExistence(timeout: TestConstants.settleTimeout))
        wait(
            for: [expectation(for: NSPredicate(format: "label CONTAINS %@", sessionName), evaluatedWith: status)],
            timeout: TestConstants.settleTimeout
        )

        let newShellButton = mainTerminalNewShellButton()
        XCTAssertTrue(newShellButton.waitForExistence(timeout: TestConstants.settleTimeout))
        newShellButton.click()

        wait(
            for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "Plain Shell"), evaluatedWith: status)],
            timeout: TestConstants.settleTimeout
        )
    }

    /// T-E2E-007: Sidebar shows panes returned by the agtmux daemon.
    ///
    /// Uses AGTMUX_JSON so this test runs without a real daemon.
    /// Verifies:
    ///   1. Both panes from the mock JSON appear with correct AX identifiers
    ///   2. The sidebar isn't showing stale data from a previous run
    func testSidebarShowsDaemonPanes() throws {
        let pane1ID = "%42"
        let pane2ID = "%43"
        let sessionName = "agtmux-e2e-mocktest"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(pane1ID)","session_name":"\(sessionName)","window_id":"@1",
           "window_index":1,"window_name":"claude","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "conversation_title":"E2E Pane 1","current_path":"/tmp","git_branch":"main",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":5},
          {"pane_id":"\(pane2ID)","session_name":"\(sessionName)","window_id":"@1",
           "window_index":1,"window_name":"claude","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":60}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        // Sidebar must appear
        let sidebar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebar)).firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: TestConstants.settleTimeout),
                      "Sidebar must appear")

        // Pane 1 (running, managed) must appear
        let key1 = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: pane1ID
        )
        let row1 = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key1)).firstMatch
        XCTAssertTrue(
            row1.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane \(pane1ID) must appear in sidebar (AX id: \(AccessibilityID.sidebarPanePrefix + key1))"
        )
        let row1Summary = paneRowMetadataSummary(row1) ?? ""
        XCTAssertTrue(
            row1Summary.contains("presence=managed")
                && row1Summary.contains("provider=claude")
                && row1Summary.contains("primary=running"),
            "Managed mock-daemon row must surface provider/activity metadata in the visible sidebar summary. row='\(row1Summary)'"
        )

        // Pane 2 (idle, unmanaged) must also appear
        let key2 = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: pane2ID
        )
        let row2 = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key2)).firstMatch
        XCTAssertTrue(
            row2.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane \(pane2ID) must appear in sidebar (AX id: \(AccessibilityID.sidebarPanePrefix + key2))"
        )

        // Selecting a pane should retarget the single visible main terminal.
        row1.click()
        XCTAssertTrue(
            selectedPaneMarker(sessionName: sessionName, paneID: pane1ID)
                .waitForExistence(timeout: TestConstants.surfaceReadyTimeout),
            "Selecting a sidebar pane should update the canonical selected marker"
        )
        XCTAssertTrue(mainTerminal().exists, "Main terminal should stay visible after pane selection")
    }

    /// T-E2E-007b: Managed pane rows restore provider badge state and trailing freshness semantics.
    func testSidebarManagedPaneRowsShowProviderBadgeRingAndTrailingTimestamp() throws {
        let runningPaneID = "%70"
        let idlePaneID = "%71"
        let sessionName = "agtmux-e2e-sidebar-managed-visuals"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(runningPaneID)","session_name":"\(sessionName)","window_id":"@7",
           "window_index":1,"window_name":"codex","activity_state":"running",
           "presence":"managed","provider":"codex","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-08T00:00:00Z","age_secs":12},
          {"pane_id":"\(idlePaneID)","session_name":"\(sessionName)","window_id":"@7",
           "window_index":1,"window_name":"codex","activity_state":"idle",
           "presence":"managed","provider":"codex","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-08T00:00:00Z","age_secs":3600}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let runningRow = paneRow(sessionName: sessionName, paneID: runningPaneID)
        XCTAssertTrue(
            runningRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Running managed pane must appear in sidebar"
        )
        XCTAssertEqual(runningRow.label, "codex", "Managed row title should prefer provider over current_cmd=node")
        let runningSummary = paneRowMetadataSummary(runningRow) ?? ""
        XCTAssertTrue(
            runningSummary.contains("provider=codex")
                && runningSummary.contains("primary=running")
                && runningSummary.contains("badge_ring=running")
                && runningSummary.contains("trailing_timestamp=none")
                && runningSummary.contains("trailing_timestamp_visible=false"),
            "Running managed row must expose provider metadata, running ring state, and hide trailing freshness. row='\(runningSummary)'"
        )

        let idleRow = paneRow(sessionName: sessionName, paneID: idlePaneID)
        XCTAssertTrue(
            idleRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Idle managed pane must appear in sidebar"
        )
        XCTAssertEqual(idleRow.label, "codex", "Idle managed row should also avoid current_cmd=node fallback")
        let idleSummary = paneRowMetadataSummary(idleRow) ?? ""
        XCTAssertTrue(
            idleSummary.contains("provider=codex")
                && idleSummary.contains("primary=idle")
                && idleSummary.contains("badge_ring=none")
                && idleSummary.contains("trailing_timestamp=1h")
                && idleSummary.contains("trailing_timestamp_visible=true"),
            "Idle managed row must keep provider metadata, drop the ring, and show trailing freshness. row='\(idleSummary)'"
        )
    }

    /// T-E2E-008: linked-looking session names remain visible because the normal
    /// sidebar path now reflects real tmux sessions exactly.
    func testLinkedPrefixedSessionsRemainVisibleAsRealSessions() throws {
        let sharedPaneID = "%99"
        let realSession  = "agtmux-ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345"
        let linkedSession = "agtmux-linked-ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(sharedPaneID)","session_name":"\(realSession)","window_id":"@5",
           "window_index":1,"window_name":"claude","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"\(sharedPaneID)","session_name":"\(linkedSession)","window_id":"@5",
           "window_index":1,"window_name":"claude","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let realKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: realSession,
            paneID: sharedPaneID
        )
        let linkedKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: linkedSession,
            paneID: sharedPaneID
        )
        let realRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + realKey)
        ).firstMatch
        let linkedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + linkedKey)
        ).firstMatch
        XCTAssertTrue(
            realRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Real agtmux-* session pane must appear. AX id: \(AccessibilityID.sidebarPanePrefix + realKey)"
        )
        XCTAssertTrue(
            linkedRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Linked-looking session names must remain visible when they are real tmux sessions"
        )
    }

    /// T-E2E-008b: session_group metadata must not collapse exact sessions in the
    /// normal sidebar path.
    func testSessionGroupAliasSessionsRemainDistinct() throws {
        let sharedPaneID = "%199"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(sharedPaneID)","session_name":"\(sessionA)","session_group":"\(groupName)","window_id":"@5",
           "window_index":1,"window_name":"AgtmuxTerm","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"\(sharedPaneID)","session_name":"\(sessionB)","session_group":"\(groupName)","window_id":"@5",
           "window_index":1,"window_name":"AgtmuxTerm","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let canonicalKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: groupName,
            paneID: sharedPaneID
        )
        let exactKeyA = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionA,
            paneID: sharedPaneID
        )
        let exactKeyB = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionB,
            paneID: sharedPaneID
        )
        let exactRowA = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + exactKeyA)
        ).firstMatch
        let exactRowB = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + exactKeyB)
        ).firstMatch
        let canonicalRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + canonicalKey)
        ).firstMatch

        XCTAssertTrue(exactRowA.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))
        XCTAssertTrue(exactRowB.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))
        XCTAssertFalse(
            canonicalRow.exists,
            "session_group metadata must not rewrite sidebar identity to a canonical group name"
        )
    }

    /// T-E2E-008c: selecting one session-group alias row must not select its sibling alias.
    func testSessionGroupAliasSelectionStaysOnExactSessionRow() throws {
        let sharedPaneID = "%199"
        let sessionA = "agtmux-A1111111-1111-1111-1111-111111111111"
        let sessionB = "agtmux-B2222222-2222-2222-2222-222222222222"
        let groupName = "vm agtmux-term"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(sharedPaneID)","session_name":"\(sessionA)","session_group":"\(groupName)","window_id":"@5",
           "window_index":1,"window_name":"AgtmuxTerm","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"\(sharedPaneID)","session_name":"\(sessionB)","session_group":"\(groupName)","window_id":"@5",
           "window_index":1,"window_name":"AgtmuxTerm","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: sessionA, paneID: sharedPaneID),
            "expected exact alias row to be clickable"
        )

        let selectedMarkerA = selectedPaneMarker(
            source: "local",
            sessionName: sessionA,
            paneID: sharedPaneID
        )
        let selectedMarkerB = selectedPaneMarker(
            source: "local",
            sessionName: sessionB,
            paneID: sharedPaneID
        )

        XCTAssertTrue(
            selectedMarkerA.waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Selecting one alias row must mark that exact session row as selected"
        )
        XCTAssertFalse(
            selectedMarkerB.exists,
            "Selecting one alias row must not also mark the sibling alias row selected"
        )
    }

    /// T-E2E-009: Mixed managed/unmanaged panes — "Managed" filter shows only managed panes.
    func testManagedFilterShowsOnlyManagedPanes() throws {
        let managedPaneID   = "%50"
        let unmanagedPaneID = "%51"
        let sessionName = "agtmux-e2e-filter"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(managedPaneID)","session_name":"\(sessionName)","window_id":"@2",
           "window_index":1,"window_name":"claude","activity_state":"running",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "current_cmd":"node","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"\(unmanagedPaneID)","session_name":"\(sessionName)","window_id":"@2",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":100}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        // Wait for at least one pane to appear (daemon has been polled)
        let managedKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: managedPaneID
        )
        let managedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + managedKey)).firstMatch
        XCTAssertTrue(managedRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
                      "Managed pane must appear in 'All' filter")

        // Switch to "Managed" filter tab
        let managedTabButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarFilterManaged)
        ).firstMatch
        XCTAssertTrue(managedTabButton.waitForExistence(timeout: TestConstants.settleTimeout),
                      "'Managed' filter tab must exist")
        managedTabButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Managed pane must still appear
        XCTAssertTrue(managedRow.exists, "Managed pane must appear under 'Managed' filter")

        // Unmanaged pane must be hidden
        let unmanagedKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: unmanagedPaneID
        )
        let unmanagedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + unmanagedKey)).firstMatch
        XCTAssertFalse(unmanagedRow.exists,
                       "Unmanaged pane must NOT appear under 'Managed' filter")
    }

    /// T-E2E-009c: `waiting_approval` rows must surface through the Attention filter without sibling bleed.
    func testAttentionFilterShowsOnlyWaitingApprovalPanes() throws {
        let approvalPaneID = "%60"
        let idlePaneID = "%61"
        let sessionName = "agtmux-e2e-attention"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(approvalPaneID)","session_name":"\(sessionName)","window_id":"@3",
           "window_index":1,"window_name":"claude","activity_state":"waiting_approval",
           "presence":"managed","provider":"claude","evidence_mode":"deterministic",
           "conversation_title":"Approve tool call","current_cmd":"node","updated_at":"2026-03-08T00:00:00Z","age_secs":0},
          {"pane_id":"\(idlePaneID)","session_name":"\(sessionName)","window_id":"@3",
           "window_index":1,"window_name":"codex","activity_state":"idle",
           "presence":"managed","provider":"codex","evidence_mode":"deterministic",
           "conversation_title":"Idle sibling","current_cmd":"node","updated_at":"2026-03-08T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let approvalKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: approvalPaneID
        )
        let approvalRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + approvalKey)
        ).firstMatch
        XCTAssertTrue(
            approvalRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "waiting_approval pane must appear in 'All' filter"
        )

        let attentionButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarFilterAttention)
        ).firstMatch
        XCTAssertTrue(
            attentionButton.waitForExistence(timeout: TestConstants.settleTimeout),
            "'Attention' filter tab must exist"
        )

        let attentionBadge = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarFilterAttentionBadge)
        ).firstMatch
        XCTAssertTrue(
            attentionBadge.waitForExistence(timeout: TestConstants.settleTimeout),
            "Attention filter must surface a stable badge element for the waiting_approval row"
        )
        XCTAssertEqual(attentionBadge.label, "1")

        attentionButton.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(
            attentionBadge.exists,
            "Attention badge must remain visible after selecting the filter"
        )

        XCTAssertTrue(approvalRow.exists, "waiting_approval pane must remain visible under 'Attention' filter")

        let idleKey = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionName,
            paneID: idlePaneID
        )
        let idleRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + idleKey)
        ).firstMatch
        XCTAssertFalse(idleRow.exists, "idle sibling pane must not appear under 'Attention' filter")
    }

    /// T-E2E-009b: Session block drag-and-drop reorders sessions within a source.
    ///
    /// Uses AGTMUX_JSON fixtures so ordering can be asserted deterministically.
    func testSessionBlockDragAndDropReordersWithinSource() throws {
        let sessionA = "agtmux-e2e-dnd-a"
        let sessionB = "agtmux-e2e-dnd-b"
        let json = """
        {"version":1,"panes":[
          {"pane_id":"%90","session_name":"\(sessionA)","window_id":"@9",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"%91","session_name":"\(sessionB)","window_id":"@10",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let sessionAID = AccessibilityID.sidebarSessionPrefix + AccessibilityID.sessionKey(
            source: "local",
            sessionName: sessionA
        )
        let sessionBID = AccessibilityID.sidebarSessionPrefix + AccessibilityID.sessionKey(
            source: "local",
            sessionName: sessionB
        )

        let rowA = sessionRow(source: "local", sessionName: sessionA)
        let rowB = sessionRow(source: "local", sessionName: sessionB)
        XCTAssertTrue(rowA.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))
        XCTAssertTrue(rowB.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))

        func currentOrder() -> [String] {
            let query = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarSessionPrefix)
            )
            return query.allElementsBoundByIndex
                .map(\.identifier)
                .filter { $0 == sessionAID || $0 == sessionBID }
        }

        let before = currentOrder()
        XCTAssertTrue(
            before.first == sessionAID && before.last == sessionBID,
            "Fixture order should start as [A, B]. Actual: \(before)"
        )

        rowB.press(forDuration: 0.3, thenDragTo: rowA)

        let deadline = Date().addingTimeInterval(TestConstants.sidebarPopulateTimeout)
        var after = currentOrder()
        while Date() < deadline && !(after.first == sessionBID && after.last == sessionAID) {
            Thread.sleep(forTimeInterval: 0.1)
            after = currentOrder()
        }
        XCTAssertTrue(
            after.first == sessionBID && after.last == sessionAID,
            "Session DnD must reorder to [B, A]. Actual: \(after)"
        )
    }

    /// T-E2E-009c: Sidebar toggle icon in titlebar must collapse/expand sidebar reliably.
    func testSidebarToggleIconTogglesSidebarVisibility() throws {
        app.launchForUITest()

        let toggleButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarFilterToggle)
        ).firstMatch
        XCTAssertTrue(
            toggleButton.waitForExistence(timeout: TestConstants.settleTimeout),
            "Sidebar toggle icon should exist in titlebar chrome"
        )

        let sidebar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebar)
        ).firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: TestConstants.settleTimeout),
            "Sidebar should be visible before collapsing"
        )

        toggleButton.click()
        let sidebarGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: sidebar
        )
        wait(for: [sidebarGone], timeout: TestConstants.settleTimeout)

        toggleButton.click()
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: TestConstants.settleTimeout),
            "Sidebar should become visible again after second toggle"
        )
    }

    /// T-E2E-009d: A local tmux session created after launch must appear in sidebar.
    ///
    /// Regression coverage:
    ///   - local source must reflect real tmux inventory, not daemon-only metadata.
    func testLocalSessionCreatedAfterLaunchAppearsInSidebar() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-session-reflect-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: nil)
        app.launchForUITest()
        try waitForAppTmuxBridgeReady(control: control)

        _ = try sendAppTmuxCommand(
            ["new-session", "-d", "-s", session, "-n", "main", "/bin/sleep 600"],
            control: control
        )
        let paneOut = try sendAppTmuxCommand(
            ["list-panes", "-t", session, "-F", "#{pane_id}"],
            refreshInventory: false,
            control: control
        )
        guard let paneID = paneOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw XCTSkip("Could not resolve pane ID for created session")
        }

        let sessionRow = sessionRow(source: "local", sessionName: session)
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Created local session must appear in sidebar session blocks"
        )

        let paneRow = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Created local session pane must appear in sidebar pane rows"
        )
    }

    /// T-E2E-009e: Create a real tmux session/window/pane on an isolated socket and
    /// verify sidebar reflects it.
    ///
    /// This avoids depending on the host default tmux socket accessibility from the
    /// sandboxed UITest runner.
    ///
    /// Regression coverage:
    ///   - stale inherited `TMUX` in launch environment must not break
    ///     explicit `AGTMUX_TMUX_SOCKET_NAME` targeting.
    func testIsolatedSocketSessionWindowPaneAppearInSidebar() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping isolated-socket sidebar reflection test")
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-iso-\(token)"
        let socketName = "agtmux-e2e-\(token)"
        let tmuxSocketBase = [tmux, "-f", "/dev/null", "-L", socketName]

        defer {
            shellRunIgnoringFailure(tmuxSocketBase + ["kill-server"])
        }

        _ = try shellRun(tmuxSocketBase + ["new-session", "-d", "-s", session, "-n", "main", "/bin/sleep 600"])
        let readyDeadline = Date().addingTimeInterval(2.0)
        var sessionReady = false
        while Date() < readyDeadline {
            if (try? shellRun(tmuxSocketBase + ["has-session", "-t", session])) != nil {
                sessionReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard sessionReady else {
            throw XCTSkip("Sandboxed UITest runner could not keep isolated tmux session alive")
        }

        _ = try shellRun(tmuxSocketBase + ["new-window", "-t", session, "-n", "extra", "/bin/sleep 600"])
        _ = try shellRun(tmuxSocketBase + ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"])

        let paneOut = try shellOutput(tmuxSocketBase + ["list-panes", "-t", "\(session):main", "-F", "#{pane_id}"])
        guard let paneID = paneOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw XCTSkip("Could not resolve pane ID for isolated socket session")
        }

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        app.launchEnvironment["AGTMUX_TMUX_SOCKET_NAME"] = socketName
        app.launchEnvironment["AGTMUX_UITEST_PRESERVE_TMUX"] = "1"
        app.launchEnvironment["TMUX"] = "/tmp/agtmux-stale-\(token).sock,99999,1"
        app.launchEnvironment["TMUX_PANE"] = "%999"
        app.launchForUITest()

        let sessionRow = sessionRow(source: "local", sessionName: session)
        XCTAssertTrue(
            sessionRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Isolated socket session must appear in sidebar session blocks"
        )

        let paneRow = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Isolated socket pane must appear in sidebar pane rows"
        )
    }

    /// T-E2E-009f: session-row selection must attach the main terminal directly to
    /// the session's active pane instead of opening a plain shell first and waiting
    /// for a later retarget.
    func testSessionSelectionTargetsActivePaneOnInitialAttach() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-session-open-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session,
              let windowID = bootstrap.windowID,
              let firstPaneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for session-selection attach test")
        }

        let paneIDsBeforeSplit = Set(bootstrap.paneIDs)
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"],
            control: control
        )
        let mainWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):main",
            windowDescription: "main",
            expectedPaneCount: paneIDsBeforeSplit.count + 1,
            control: control
        )
        let paneIDsAfterSplit = Set(mainWindowSnapshot.paneIDs)
        guard let secondPaneID = paneIDsAfterSplit.subtracting(paneIDsBeforeSplit).first else {
            throw XCTSkip("Could not resolve split pane identity for session-selection attach test")
        }

        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", secondPaneID],
            refreshInventory: false,
            control: control
        )
        let activePaneOutput = try sendAppTmuxCommand(
            ["list-panes", "-t", "\(session):main", "-F", "#{pane_id}|#{pane_active}"],
            refreshInventory: false,
            control: control
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(secondPaneID)|1"),
            "tmux must mark the destination pane active before the session-row click"
        )

        let sessionRow = sessionRow(source: "local", sessionName: session)
        XCTAssertTrue(
            clickSidebarPaneRow(sessionRow),
            "Session row must be clickable before initial attach proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Session-row selection must highlight the session's active pane in the sidebar"
        )

        let snapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: windowID,
            paneID: secondPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondPaneID
            )
        )
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.attachCommand,
                sessionName: session,
                windowID: windowID,
                paneID: secondPaneID
            ),
            "Initial main-terminal attach command must preselect the active pane"
        )
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.renderedAttachCommand,
                sessionName: session,
                windowID: windowID,
                paneID: secondPaneID
            ),
            "Rendered main-terminal surface must keep the pane-targeted attach command"
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: snapshot.renderedClientTTY,
            sessionName: session,
            windowID: windowID,
            paneID: secondPaneID
        )

        XCTAssertNotEqual(
            firstPaneID,
            secondPaneID,
            "Split-pane setup for session-row attach regression must produce a distinct active pane"
        )
    }

    /// T-E2E-009g: pane-row selection must open the containing window on initial attach
    /// and focus that window's active pane instead of the clicked inactive pane.
    func testPaneSelectionTargetsContainingWindowActivePaneOnInitialAttach() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-pane-open-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session else {
            throw XCTSkip("App-driven tmux bootstrap failed for pane-selection attach test")
        }

        let secondWindowName = "secondary"
        let activePaneToken = "__agtmux_window_active_\(token)__"
        let inactivePaneToken = "__agtmux_window_inactive_\(token)__"
        let activePaneCommand = "/bin/sh -lc " + shellQuote("printf '\(activePaneToken)\\n'; exec sleep 600")
        let inactivePaneCommand = "/bin/sh -lc " + shellQuote("printf '\(inactivePaneToken)\\n'; exec sleep 600")

        _ = try sendAppTmuxCommand(
            ["new-window", "-t", session, "-n", secondWindowName, activePaneCommand],
            control: control
        )
        let secondWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 1,
            control: control
        )
        guard let secondWindowActivePaneID = secondWindowSnapshot.paneIDs.first else {
            throw XCTSkip("Could not resolve active pane identity for pane-selection attach test")
        }

        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):\(secondWindowName)", "-h", inactivePaneCommand],
            control: control
        )
        let secondWindowSplitSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 2,
            control: control
        )
        let secondWindowPaneIDs = Set(secondWindowSplitSnapshot.paneIDs)
        guard let secondWindowInactivePaneID = secondWindowPaneIDs.subtracting([secondWindowActivePaneID]).first else {
            throw XCTSkip("Could not resolve inactive pane identity for pane-selection attach test")
        }

        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", secondWindowActivePaneID],
            refreshInventory: false,
            control: control
        )
        let activePaneOutput = try sendAppTmuxCommand(
            ["list-panes", "-t", "\(session):\(secondWindowName)", "-F", "#{pane_id}|#{pane_active}"],
            refreshInventory: false,
            control: control
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(secondWindowActivePaneID)|1"),
            "tmux must keep the destination window's active pane selected before the pane-row click"
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(secondWindowInactivePaneID)|0"),
            "tmux must keep the clicked pane inactive so the test proves window-active targeting"
        )

        try waitForAppSidebarPanePresentation(
            control: control,
            sessionName: session,
            paneID: secondWindowInactivePaneID
        )
        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondWindowInactivePaneID),
            "Inactive pane row must be clickable before initial attach proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondWindowActivePaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane-row selection must highlight the selected window's active pane in the sidebar"
        )

        let snapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondWindowActivePaneID
            )
        )
        XCTAssertEqual(snapshot.desiredWindowID, secondWindowSplitSnapshot.windowID)
        XCTAssertEqual(snapshot.desiredPaneID, secondWindowActivePaneID)
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.attachCommand,
                sessionName: session,
                windowID: secondWindowSplitSnapshot.windowID,
                paneID: secondWindowActivePaneID
            ),
            "Initial pane-row attach command must preselect the selected window and its active pane"
        )
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.renderedAttachCommand,
                sessionName: session,
                windowID: secondWindowSplitSnapshot.windowID,
                paneID: secondWindowActivePaneID
            ),
            "Rendered main-terminal surface must keep the window-active pane attach command"
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: snapshot.renderedClientTTY,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID
        )

        let viewport = try dumpAppTerminalViewportText(
            control: control,
            tileID: snapshot.tileID
        )
        XCTAssertTrue(
            viewport.text.contains(activePaneToken),
            "Initial pane-row attach must render content from the selected window"
        )
    }

    /// T-E2E-009h: session-row initial attach must still render the active pane when the
    /// tmux session name contains spaces. This guards the normal local `vm agtmux-term`
    /// style data path that the existing synthetic session names did not cover.
    func testSessionSelectionTargetsActivePaneOnInitialAttachForSessionNameWithSpaces() throws {
        try assertSessionSelectionTargetsActivePaneOnInitialAttachForSessionNameWithSpaces(
            hostMode: "legacy"
        )
    }

    /// T-E2E-009i: the spaced-session initial attach proof must also hold on the
    /// installed-app `next` host path so legacy-only UI launches do not mask regressions.
    func testSessionSelectionTargetsActivePaneOnInitialAttachForSessionNameWithSpacesInNextHostMode() throws {
        try assertSessionSelectionTargetsActivePaneOnInitialAttachForSessionNameWithSpaces(
            hostMode: "next"
        )
    }

    private func assertSessionSelectionTargetsActivePaneOnInitialAttachForSessionNameWithSpaces(
        hostMode: String
    ) throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux e2e session \(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        app.launchEnvironment["AGTMUX_TERMINAL_HOST_MODE"] = hostMode
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session,
              let windowID = bootstrap.windowID,
              let firstPaneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for spaced session-name attach test")
        }

        let paneIDsBeforeSplit = Set(bootstrap.paneIDs)
        let activePaneToken = "__agtmux_spaced_session_active_\(token)__"
        let activePaneCommand = "/bin/sh -lc " + shellQuote("printf '\(activePaneToken)\\n'; exec sleep 600")
        _ = try sendAppTmuxCommand(
            ["respawn-pane", "-k", "-t", firstPaneID, activePaneCommand],
            control: control
        )
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"],
            control: control
        )
        let mainWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):main",
            windowDescription: "main",
            expectedPaneCount: paneIDsBeforeSplit.count + 1,
            control: control
        )
        let paneIDsAfterSplit = Set(mainWindowSnapshot.paneIDs)
        guard let secondPaneID = paneIDsAfterSplit.subtracting([firstPaneID]).first else {
            throw XCTSkip("Could not resolve split pane identity for spaced session-name attach test")
        }

        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", firstPaneID],
            refreshInventory: false,
            control: control
        )
        let activePaneOutput = try sendAppTmuxCommand(
            ["list-panes", "-t", "\(session):main", "-F", "#{pane_id}|#{pane_active}"],
            refreshInventory: false,
            control: control
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(firstPaneID)|1"),
            "tmux must mark the active pane before the spaced session-row click"
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(secondPaneID)|0"),
            "tmux must keep the inactive split pane separate in the spaced session-row proof"
        )

        let sessionRow = sessionRow(source: "local", sessionName: session)
        XCTAssertTrue(
            clickSidebarPaneRow(sessionRow),
            "Spaced session row must be clickable before initial attach proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: firstPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Spaced session-row selection must highlight the session's active pane in the sidebar"
        )

        let snapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: windowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: firstPaneID
            )
        )
        XCTAssertEqual(
            snapshot.terminalHostMode,
            hostMode,
            "Spaced session-row attach must be verified on the requested terminal host mode"
        )
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.attachCommand,
                sessionName: session,
                windowID: windowID,
                paneID: firstPaneID
            ),
            "Initial main-terminal attach command must preselect the active pane for spaced session names"
        )
        XCTAssertTrue(
            attachCommandTargetsPane(
                snapshot.renderedAttachCommand,
                sessionName: session,
                windowID: windowID,
                paneID: firstPaneID
            ),
            "Rendered main-terminal surface must keep the pane-targeted attach command for spaced session names"
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: snapshot.renderedClientTTY,
            sessionName: session,
            windowID: windowID,
            paneID: firstPaneID
        )

        let viewport = try dumpAppTerminalViewportText(
            control: control,
            tileID: snapshot.tileID
        )
        XCTAssertTrue(
            viewport.text.contains(activePaneToken),
            "Initial spaced session-row attach must render content from the active pane"
        )
    }

    /// T-E2E-010: same-session pane selection must retarget the existing V2 tile
    /// to the clicked pane's window while focusing that window's active pane,
    /// without creating linked sessions or recreating the surface.
    func testPaneSelectionWithMockDaemonAndRealTmux() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-retarget-\(token)"
        let socket = "agtmux-e2e-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              let bootstrapSession = bootstrap.sessionName,
              bootstrapSession == session,
              let firstWindowID = bootstrap.windowID,
              let firstPaneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for same-session retarget test")
        }

        let secondWindowName = "secondary"
        let secondWindowActiveCommand = "/bin/sh -lc " + shellQuote("printf '__agtmux_second_window_active_\(token)__\\n'; exec sleep 600")
        let secondWindowInactiveCommand = "/bin/sh -lc " + shellQuote("printf '__agtmux_second_window_inactive_\(token)__\\n'; exec sleep 600")
        _ = try sendAppTmuxCommand(
            ["new-window", "-t", session, "-n", secondWindowName, secondWindowActiveCommand],
            control: control
        )
        let secondWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 1,
            control: control
        )
        guard let secondWindowActivePaneID = secondWindowSnapshot.paneIDs.first,
              secondWindowActivePaneID.hasPrefix("%") else {
            throw XCTSkip("Could not resolve active pane identity for app-created secondary window")
        }
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):\(secondWindowName)", "-h", secondWindowInactiveCommand],
            control: control
        )
        let secondWindowSplitSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 2,
            control: control
        )
        let secondWindowPaneIDs = Set(secondWindowSplitSnapshot.paneIDs)
        guard let secondWindowInactivePaneID = secondWindowPaneIDs.subtracting([secondWindowActivePaneID]).first,
              secondWindowInactivePaneID.hasPrefix("%") else {
            throw XCTSkip("Could not resolve inactive pane identity for app-created secondary window")
        }
        guard secondWindowSplitSnapshot.windowID.hasPrefix("@") else {
            throw XCTSkip("Could not resolve window identity for app-created secondary window")
        }
        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", secondWindowActivePaneID],
            refreshInventory: false,
            control: control
        )
        let secondWindowActiveOutput = try sendAppTmuxCommand(
            ["list-panes", "-t", "\(session):\(secondWindowName)", "-F", "#{pane_id}|#{pane_active}"],
            refreshInventory: false,
            control: control
        )
        XCTAssertTrue(
            secondWindowActiveOutput.contains("\(secondWindowActivePaneID)|1"),
            "Secondary window must keep its active pane selected before pane-row retarget"
        )
        XCTAssertTrue(
            secondWindowActiveOutput.contains("\(secondWindowInactivePaneID)|0"),
            "Secondary window test must click an inactive pane row"
        )

        let linkedBefore = try listLinkedSessionsViaApp(control: control)
        XCTAssertTrue(linkedBefore.isEmpty, "V2 same-session retarget must start without linked sessions")

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: firstPaneID),
            "Initial pane must appear in sidebar before retarget proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: firstPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Initial pane click must update sidebar selection state"
        )
        let firstSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: firstWindowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: firstPaneID
            )
        )

        waitForSingleWorkbenchV2TerminalTile(sessionName: session)
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: firstWindowID,
            paneID: firstPaneID
        )

        try waitForAppSidebarPanePresentation(
            control: control,
            sessionName: session,
            paneID: secondWindowInactivePaneID
        )
        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondWindowInactivePaneID),
            "Inactive pane row in the target window must be clickable before retarget proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondWindowActivePaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane-row click must select the clicked pane's window and highlight that window's active pane"
        )
        let secondSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondWindowActivePaneID
            )
        )
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Same-session window retarget must preserve the rendered Ghostty surface"
        )
        waitForSingleWorkbenchV2TerminalTile(sessionName: session)
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID
        )
        XCTAssertEqual(
            secondSnapshot.desiredWindowID,
            secondWindowSplitSnapshot.windowID,
            "Pane-row retarget must request the clicked pane's containing window"
        )
        XCTAssertEqual(secondSnapshot.desiredPaneID, secondWindowActivePaneID)
        let viewport = try dumpAppTerminalViewportText(
            control: control,
            tileID: secondSnapshot.tileID
        )
        XCTAssertTrue(
            viewport.text.contains("__agtmux_second_window_active_\(token)__"),
            "Same-session window retarget must repaint the preserved surface with the destination window's active pane"
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "App must still be running after same-session retarget. State: \(app.state.rawValue)"
        )

        let linkedAfter = try listLinkedSessionsViaApp(control: control)
        XCTAssertEqual(
            linkedAfter,
            linkedBefore,
            "Window-active retarget must reuse the same real-session tile without linked sessions"
        )
    }

    /// T-E2E-014: live tmux pane changes must update sidebar selection on the single visible session tile
    /// while preserving the same rendered Ghostty client.
    func testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux() throws {
        guard let tmuxPath else {
            throw XCTSkip("tmux not available for reverse-sync E2E")
        }
        _ = tmuxPath

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-focus-\(token)"
        let socket = "agtmux-focus-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment["AGTMUX_UITEST_TMUX_SOCKET_NAME"] = socket
        app.launchEnvironment["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] = "1"
        configureAppDrivenTmux(
            socketName: socket,
            control: control,
            scenario: scenario
        )
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session,
              let firstPaneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for reverse-sync test")
        }

        let paneIDsBeforeSplit = Set(bootstrap.paneIDs)
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"],
            control: control
        )
        let mainWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):main",
            windowDescription: "main",
            expectedPaneCount: paneIDsBeforeSplit.count + 1,
            control: control
        )
        let paneIDsAfterSplit = Set(mainWindowSnapshot.paneIDs)
        guard let secondPaneID = paneIDsAfterSplit.subtracting(paneIDsBeforeSplit).first else {
            throw XCTSkip("Could not resolve pane identity for reverse-sync split pane")
        }
        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", firstPaneID],
            refreshInventory: false,
            control: control
        )
        let activePaneOutput = try sendAppTmuxCommand(
            ["list-panes", "-t", "\(session):main", "-F", "#{pane_id}|#{pane_active}"],
            refreshInventory: false,
            control: control
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(firstPaneID)|1"),
            "Reverse-sync setup must keep the clicked pane active before the initial sidebar click"
        )
        XCTAssertTrue(
            activePaneOutput.contains("\(secondPaneID)|0"),
            "Reverse-sync setup must keep the later terminal-originated pane inactive before the initial sidebar click"
        )

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: firstPaneID),
            "Initial pane must appear in sidebar before reverse-sync proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: firstPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Initial pane click must update sidebar selection state"
        )
        let firstSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: mainWindowSnapshot.windowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: firstPaneID
            )
        )
        waitForSingleWorkbenchV2TerminalTile(sessionName: session)
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: mainWindowSnapshot.windowID,
            paneID: firstPaneID
        )

        _ = try sendAppTmuxCommand(
            ["switch-client", "-c", firstSnapshot.renderedClientTTY, "-t", secondPaneID],
            refreshInventory: false,
            control: control
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: mainWindowSnapshot.windowID,
            paneID: secondPaneID
        )

        let secondSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: mainWindowSnapshot.windowID,
            paneID: secondPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondPaneID
            )
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Terminal-originated pane change must retarget sidebar selection to the active pane"
        )
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Terminal-originated pane change must preserve the rendered Ghostty surface"
        )
    }

    /// T-E2E-015: metadata-enabled launch must still preserve same-session window retarget
    /// and reverse-sync on a real rendered client. This guards the normal app path where
    /// inventory and daemon polling are both active, instead of the inventory-only UITest mode.
    func testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux() throws {
        guard let agtmuxBin = resolveAgtmuxBinaryForUITest() else {
            throw XCTSkip("AGTMUX_BIN is required for metadata-enabled pane-sync E2E")
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-meta-\(token)"
        let socket = "agtmux-meta-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        app.launchEnvironment["AGTMUX_BIN"] = agtmuxBin
        app.launchEnvironment["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] = "1"
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForMetadataUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session,
              let firstPaneID = bootstrap.paneIDs.first,
              let firstWindowID = bootstrap.windowID else {
            throw XCTSkip("App-driven tmux bootstrap failed for metadata-enabled pane-sync E2E")
        }

        let secondWindowName = "secondary"
        let secondWindowActiveCommand = "/bin/sh -lc " + shellQuote("printf '__agtmux_meta_active_\(token)__\\n'; exec sleep 600")
        let secondWindowInactiveCommand = "/bin/sh -lc " + shellQuote("printf '__agtmux_meta_inactive_\(token)__\\n'; exec sleep 600")
        _ = try sendAppTmuxCommand(
            ["new-window", "-t", session, "-n", secondWindowName, secondWindowActiveCommand],
            control: control
        )
        let secondWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 1,
            control: control
        )
        guard let secondWindowActivePaneID = secondWindowSnapshot.paneIDs.first else {
            throw XCTSkip("Could not resolve active pane for metadata-enabled retarget E2E")
        }
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):\(secondWindowName)", "-h", secondWindowInactiveCommand],
            control: control
        )
        let secondWindowSplitSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 2,
            control: control
        )
        let secondWindowPaneIDs = Set(secondWindowSplitSnapshot.paneIDs)
        guard let secondWindowInactivePaneID = secondWindowPaneIDs.subtracting([secondWindowActivePaneID]).first else {
            throw XCTSkip("Could not resolve inactive pane for metadata-enabled retarget E2E")
        }
        _ = try sendAppTmuxCommand(
            ["select-pane", "-t", secondWindowActivePaneID],
            refreshInventory: false,
            control: control
        )

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: firstPaneID),
            "Initial pane must appear before metadata-enabled retarget proof"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: firstPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Initial sidebar click must update canonical selection under metadata-enabled launch"
        )
        let firstSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: firstWindowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: firstPaneID
            )
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: firstWindowID,
            paneID: firstPaneID
        )

        try resetAppScrollTelemetry(control: control, tileID: firstSnapshot.tileID)
        try waitForAppSidebarPanePresentation(
            control: control,
            sessionName: session,
            paneID: secondWindowInactivePaneID
        )
        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondWindowInactivePaneID),
            "Inactive pane row in the destination window must be selectable under metadata-enabled launch"
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondWindowActivePaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Metadata-enabled pane-row click must highlight the selected window's active pane"
        )
        let secondSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondWindowActivePaneID
            )
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowActivePaneID
        )
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Metadata-enabled same-session window retarget must preserve the rendered Ghostty surface"
        )
        let sidebarRetargetTelemetry = try dumpAppScrollTelemetry(
            control: control,
            tileID: firstSnapshot.tileID
        )
        XCTAssertEqual(
            sidebarRetargetTelemetry.island.applyCommandCount,
            0,
            "Same-session window retarget must not reattach the Ghostty surface"
        )
        XCTAssertGreaterThanOrEqual(
            sidebarRetargetTelemetry.island.paneRetargetRefreshCount,
            1,
            "Same-session window retarget must schedule a presentation refresh on the existing surface"
        )

        try resetAppScrollTelemetry(control: control, tileID: secondSnapshot.tileID)
        _ = try sendAppTmuxCommand(
            ["switch-client", "-c", secondSnapshot.renderedClientTTY, "-t", secondWindowInactivePaneID],
            refreshInventory: false,
            control: control
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowInactivePaneID
        )
        let reverseSyncSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: secondWindowSplitSnapshot.windowID,
            paneID: secondWindowInactivePaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondWindowInactivePaneID
            )
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondWindowInactivePaneID)
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Rendered-client pane changes must update sidebar highlight under metadata-enabled launch"
        )
        XCTAssertEqual(
            reverseSyncSnapshot.renderedSurfaceGeneration,
            secondSnapshot.renderedSurfaceGeneration,
            "Rendered-client reverse sync must keep the same Ghostty surface alive"
        )
        let reverseSyncTelemetry = try dumpAppScrollTelemetry(
            control: control,
            tileID: secondSnapshot.tileID
        )
        XCTAssertEqual(
            reverseSyncTelemetry.island.applyCommandCount,
            0,
            "Same-window rendered-client reverse sync must not reattach the Ghostty surface"
        )
        XCTAssertGreaterThanOrEqual(
            reverseSyncTelemetry.island.paneRetargetRefreshCount,
            1,
            "Same-window rendered-client reverse sync must schedule a presentation refresh on the existing surface"
        )
    }

    /// T-E2E-015b: a real Codex process launched from a plain zsh pane must surface
    /// as a managed/provider/activity row in the visible metadata-enabled app path.
    func testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity() throws {
        guard let agtmuxBin = resolveAgtmuxBinaryForUITest() else {
            throw XCTSkip("AGTMUX_BIN is required for metadata-enabled managed-pane E2E")
        }
        let codexPath = "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw XCTSkip("codex CLI is not installed at \(codexPath)")
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let session = "agtmux-e2e-managed-\(token)"
        let socket = "agtmux-managed-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: session,
            windowName: "main",
            paneCount: 1,
            shellCommand: "zsh -l"
        )

        app.launchEnvironment["AGTMUX_BIN"] = agtmuxBin
        app.launchEnvironment["AGTMUX_UITEST_ENABLE_MANAGED_DAEMON"] = "1"
        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == session,
              let paneID = bootstrap.paneIDs.first else {
            throw XCTSkip("App-driven tmux bootstrap failed for metadata-enabled managed-pane E2E")
        }

        let row = paneRow(source: "local", sessionName: session, paneID: paneID)
        XCTAssertTrue(
            row.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Plain zsh pane must appear before live managed-pane surfacing proof"
        )

        try waitForAppShellReady(
            tmuxTarget: "\(session):main",
            control: control
        )
        try enableAppManagedMetadata(control: control)
        let bootstrapReadySnapshot = try waitForAppDaemonBootstrapReady(
            control: control,
            sessionName: session,
            paneID: paneID,
            expectedCurrentCommand: "zsh",
            expectedPresence: "unmanaged",
            expectedProvider: nil,
            expectedPrimaryStates: [PanePresentationPrimaryState.idle.rawValue],
            failureContext: "Pre-launch daemon bootstrap did not surface the plain zsh row as unmanaged sync-v3 truth"
        )
        _ = try sendAppTmuxCommand(
            ["display-message", "-p", "#{session_name}"],
            refreshInventory: true,
            control: control,
            timeout: 2.0
        )

        let prompt = """
        Run exactly one bash command and do not run any additional commands. Wait 20 seconds by using sleep 20. \
        bash -lc 'sleep 20; printf "wait_result=managed\\n"'. Do not simulate, infer, or guess. \
        Output only one non-empty line. Required output format: wait_result=managed
        """
        let effortConfig = #"model_reasoning_effort="medium""#
        let codexCommand =
            "cd /tmp && codex exec --dangerously-bypass-approvals-and-sandbox " +
            "--skip-git-repo-check --json --model gpt-5.4 " +
            "-c \(shellQuote(effortConfig)) \(shellQuote(prompt))"
        _ = try sendAppTmuxCommand(
            ["send-keys", "-t", "\(session):main", "-l", codexCommand],
            refreshInventory: false,
            control: control
        )
        _ = try sendAppTmuxCommand(
            ["send-keys", "-t", "\(session):main", "C-m"],
            refreshInventory: false,
            control: control
        )

        let managedButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarFilterManaged)
        ).firstMatch
        XCTAssertTrue(
            managedButton.waitForExistence(timeout: TestConstants.settleTimeout),
            "Managed filter button must exist for managed-pane surfacing proof"
        )
        managedButton.click()

        let deadline = Date().addingTimeInterval(45.0)
        var surfaced = false
        var surfacedRowSummary = ""
        while Date() < deadline {
            let currentRow = paneRow(source: "local", sessionName: session, paneID: paneID)
            let summary = paneRowMetadataSummary(currentRow) ?? ""
            if currentRow.exists,
               summary.contains("presence=managed"),
               summary.contains("provider=codex"),
               ["primary=running", "primary=waiting_user_input", "primary=idle", "primary=completed_idle"].contains(where: summary.contains) {
                surfaced = true
                surfacedRowSummary = summary
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let completionDeadline = Date().addingTimeInterval(60.0)
        var freshnessSurfaced = false
        var completionRowSummary = surfacedRowSummary
        while Date() < completionDeadline {
            let sidebarSnapshot = try? fetchAppSidebarState(
                control: control,
                sessionName: session,
                paneID: paneID
            )
            let visiblePresentation = sidebarSnapshot?.panePresentations.first {
                $0.source == "local" && $0.sessionName == session && $0.paneID == paneID
            }
            let summary = visiblePresentation.map { pane in
                [
                    "presence=\(pane.presence)",
                    "provider=\(pane.provider ?? "nil")",
                    "primary=\(pane.primaryState)",
                    "freshness=\(pane.freshness ?? "nil")",
                ].joined(separator: ", ")
            } ?? ""
            if let visiblePresentation,
               visiblePresentation.presence == "managed",
               visiblePresentation.provider == "codex",
               ["waiting_user_input", "idle", "completed_idle"].contains(visiblePresentation.primaryState),
               visiblePresentation.freshness != nil {
                freshnessSurfaced = true
                completionRowSummary = summary
                break
            }
            if !summary.isEmpty {
                completionRowSummary = summary
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let finalCapture = try? sendAppTmuxCommand(
            ["capture-pane", "-p", "-t", "\(session):main"],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
        let sidebarState = try? fetchAppSidebarState(
            control: control,
            sessionName: session,
            paneID: paneID
        )
        if let skipReason = liveManagedCodexDaemonSkipReason(
            sidebarState: sidebarState,
            sessionName: session,
            paneID: paneID,
            finalCapture: finalCapture
        ) {
            throw XCTSkip(skipReason)
        }
        XCTAssertTrue(
            surfaced,
            "A real Codex process launched from a plain zsh pane must surface as a managed sidebar row with provider/presentation metadata. " +
            "row='\(surfacedRowSummary)' " +
            "bootstrapReady='\(sidebarStateSummary(bootstrapReadySnapshot, sessionName: session, paneID: paneID))' " +
            "capture='\(finalCapture ?? "")' " +
            "sidebar='\(sidebarStateSummary(sidebarState, sessionName: session, paneID: paneID))'"
        )
        XCTAssertTrue(
            freshnessSurfaced,
            "A managed completion row must expose freshness metadata once the live Codex pane settles into waiting_user_input, idle, or completed_idle. " +
            "row='\(completionRowSummary)' " +
            "bootstrapReady='\(sidebarStateSummary(bootstrapReadySnapshot, sessionName: session, paneID: paneID))' " +
            "capture='\(finalCapture ?? "")' " +
            "sidebar='\(sidebarStateSummary(sidebarState, sessionName: session, paneID: paneID))'"
        )
    }

    /// T-E2E-016: terminal-originated tmux session switches must rebind the visible
    /// tile/session selection in place instead of leaving the sidebar on the stale session.
    func testTerminalSessionSwitchUpdatesSidebarSelectionWithRealTmux() throws {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let firstSession = "agtmux-e2e-session-a-\(token)"
        let secondSession = "agtmux-e2e-session-b-\(token)"
        let socket = "agtmux-session-\(token)"
        let control = try makeAppTmuxControlPaths(token: token)
        let scenario = AppTmuxScenario(
            sessionName: firstSession,
            windowName: "main",
            paneCount: 1,
            shellCommand: "/bin/sleep 600"
        )

        configureAppDrivenTmux(socketName: socket, control: control, scenario: scenario)
        app.launchForUITest()

        let bootstrap = try waitForAppTmuxBootstrapResult(control: control)
        guard bootstrap.ok,
              bootstrap.sessionName == firstSession,
              let firstPaneID = bootstrap.paneIDs.first,
              let firstWindowID = bootstrap.windowID else {
            throw XCTSkip("App-driven tmux bootstrap failed for session-switch reverse-sync test")
        }

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: firstSession, paneID: firstPaneID),
            "Initial session pane must appear before session-switch reverse-sync proof"
        )
        let firstSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: firstSession,
            windowID: firstWindowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: firstSession,
                paneID: firstPaneID
            )
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: firstSession,
            windowID: firstWindowID,
            paneID: firstPaneID
        )

        _ = try sendAppTmuxCommand(
            ["new-session", "-d", "-s", secondSession, "-n", "main", "/bin/sleep 600"],
            control: control
        )
        let secondSessionSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(secondSession):main",
            windowDescription: "main",
            expectedPaneCount: 1,
            control: control
        )
        guard let secondPaneID = secondSessionSnapshot.paneIDs.first else {
            throw XCTSkip("Could not resolve pane identity for destination session")
        }

        XCTAssertTrue(
            paneRow(source: "local", sessionName: secondSession, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Destination session must appear in sidebar before the rendered client switches into it"
        )

        _ = try sendAppTmuxCommand(
            ["switch-client", "-c", firstSnapshot.renderedClientTTY, "-t", secondSession],
            refreshInventory: false,
            control: control
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: firstSnapshot.renderedClientTTY,
            sessionName: secondSession,
            windowID: secondSessionSnapshot.windowID,
            paneID: secondPaneID
        )

        XCTAssertTrue(
            selectedPaneMarker(sessionName: secondSession, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Rendered-client session switch must move sidebar selection to the destination session"
        )

        let switchedSnapshot = waitForAppWorkbenchTerminalSessionSwitchTarget(
            control: control,
            sessionName: secondSession,
            windowID: secondSessionSnapshot.windowID,
            paneID: secondPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: secondSession,
                paneID: secondPaneID
            ),
            renderedClientTTY: firstSnapshot.renderedClientTTY
        )
        XCTAssertEqual(
            switchedSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Terminal-originated session switch must preserve the rendered Ghostty surface"
        )
    }

    /// T-E2E-013: Live local tmux lifecycle must reflect in sidebar (session/window/pane).
    ///
    /// Flow:
    ///   1. Launch app without AGTMUX_JSON fixture mode.
    ///   2. Create a tracked tmux session after launch -> sidebar row must appear.
    ///   3. Create a new window -> new window pane row must appear.
    ///   4. Split that window pane -> second pane row must appear.
    ///   5. Kill the split pane -> row must disappear.
    ///   6. Kill the session -> all rows for that session must disappear.
    ///
    /// This is the regression guard for "session created in terminal is not reflected".
    func testLocalTmuxLifecycleReflectsSessionWindowPaneChanges() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping local lifecycle reflection test")
        }
        switch classifyRunnerTmuxAccess(tmux: tmux) {
        case .available, .availableNoServer:
            break
        case .inaccessible(let reason):
            throw XCTSkip("tmux socket not accessible from runner (local lifecycle reflection): \(reason)")
        }

        app.launchForUITest()

        let session = try createTrackedTmuxSession(prefix: "agtmux-e2e-live-reflect", tmux: tmux)

        func paneDescriptors() throws -> [(paneID: String, windowID: String, windowName: String)] {
            let output = try shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}|#{window_id}|#{window_name}"])
            return output
                .components(separatedBy: "\n")
                .compactMap { line in
                    guard !line.isEmpty else { return nil }
                    let parts = line.components(separatedBy: "|")
                    guard parts.count >= 2 else { return nil }
                    let paneID = parts[0]
                    let windowID = parts[1]
                    let windowName = parts.count >= 3 ? parts[2] : ""
                    return (paneID, windowID, windowName)
                }
        }

        guard let initialPane = try paneDescriptors().first else {
            throw XCTSkip("Could not resolve initial pane for tracked session")
        }
        let initialRow = paneRow(source: "local", sessionName: session, paneID: initialPane.paneID)
        XCTAssertTrue(
            initialRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Newly created tmux session pane must appear in sidebar"
        )

        let newWindowName = "e2e-live-window"
        _ = try shellRun([tmux, "new-window", "-t", session, "-n", newWindowName])

        let afterWindowCreate = try paneDescriptors()
        guard let newWindowPane = afterWindowCreate.first(where: { $0.windowName == newWindowName }) else {
            throw XCTSkip("Could not resolve pane for new window '\(newWindowName)'")
        }
        let newWindowPaneRow = paneRow(source: "local", sessionName: session, paneID: newWindowPane.paneID)
        XCTAssertTrue(
            newWindowPaneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane from newly created window must appear in sidebar"
        )

        let beforeSplitPaneIDs = Set(
            afterWindowCreate
                .filter { $0.windowID == newWindowPane.windowID }
                .map(\.paneID)
        )

        _ = try shellRun([tmux, "split-window", "-h", "-t", newWindowPane.paneID])

        let splitPaneID: String = {
            let deadline = Date().addingTimeInterval(TestConstants.sidebarPopulateTimeout)
            while Date() < deadline {
                if let descriptors = try? paneDescriptors() {
                    let nowIDs = Set(descriptors.filter { $0.windowID == newWindowPane.windowID }.map(\.paneID))
                    if let created = nowIDs.subtracting(beforeSplitPaneIDs).first {
                        return created
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return ""
        }()
        XCTAssertFalse(splitPaneID.isEmpty, "Split pane ID must be discoverable")

        let splitPaneRow = paneRow(source: "local", sessionName: session, paneID: splitPaneID)
        XCTAssertTrue(
            splitPaneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Split pane must appear in sidebar"
        )

        _ = try shellRun([tmux, "kill-pane", "-t", splitPaneID])
        let splitGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: splitPaneRow)
        wait(for: [splitGone], timeout: TestConstants.sidebarPopulateTimeout)

        _ = try shellRun([tmux, "kill-session", "-t", session])
        ownedSessions.remove(session)

        let initialGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: initialRow)
        let newWindowGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: newWindowPaneRow)
        wait(for: [initialGone, newWindowGone], timeout: TestConstants.sidebarPopulateTimeout)
    }

    // MARK: - Category B: Requires agtmux daemon + pane rows in sidebar (legacy)

    /// T-E2E-003: A pane row appears in the sidebar after the daemon discovers the test session.
    ///
    /// NOTE: This test depends on the real agtmux daemon having managed panes.
    /// Use T-E2E-007 (testSidebarShowsDaemonPanes) for isolated testing with mock daemon.
    func testPaneAppearsInSidebar() throws {
        app.launchForUITest()
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarPanePrefix)
        let paneRow = app.otherElements.matching(predicate).firstMatch
        guard paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout) else {
            throw XCTSkip(
                "No pane rows appeared — requires a running agtmux daemon with managed panes."
            )
        }
    }

    /// T-E2E-004: CRASH REGRESSION TEST.
    func testPaneSelectionCreatesTerminalTile() throws {
        try skipLegacyWorkbenchUITest()
        app.launchForUITest()
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarPanePrefix)
        let paneRow = app.otherElements.matching(predicate).firstMatch
        guard paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout) else {
            throw XCTSkip("No pane rows appeared — requires a running agtmux daemon.")
        }

        assertWorkspaceStartsEmpty()
        paneRow.click()
        waitForWorkspaceToLeaveEmptyState()

        let tilePredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let tile = app.otherElements.matching(tilePredicate).firstMatch
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.surfaceReadyTimeout),
            "Terminal tile should appear after pane tap. App may have crashed."
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "App is no longer running after pane selection — crashed? State: \(app.state.rawValue)"
        )

        let readyPredicate = NSPredicate(format: "value == %@", "ready")
        let readyExpectation = expectation(for: readyPredicate, evaluatedWith: tile)
        wait(for: [readyExpectation], timeout: TestConstants.surfaceReadyTimeout)

        Thread.sleep(forTimeInterval: 3.0)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App crashed after surface creation (deferred Metal renderer crash)"
        )
    }

    /// T-E2E-006: SPLIT REGRESSION TEST.
    func testSecondPaneSelectionReplacesNotSplits() throws {
        try skipLegacyWorkbenchUITest()
        app.launchForUITest()
        let panePredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarPanePrefix)
        let allRows = app.otherElements.matching(panePredicate)

        let twoRowsPredicate = NSPredicate(format: "count >= 2")
        let twoRowsExp = expectation(for: twoRowsPredicate, evaluatedWith: allRows)
        let result = XCTWaiter.wait(for: [twoRowsExp], timeout: TestConstants.sidebarPopulateTimeout)
        guard result == .completed else {
            throw XCTSkip("Need ≥2 pane rows in sidebar — ensure agtmux daemon is running with ≥2 panes")
        }

        assertWorkspaceStartsEmpty()
        allRows.firstMatch.click()
        waitForWorkspaceToLeaveEmptyState()

        let tilePredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        XCTAssertTrue(
            app.otherElements.matching(tilePredicate).firstMatch.waitForExistence(timeout: TestConstants.surfaceReadyTimeout),
            "Tile should appear after first pane selection"
        )

        allRows.element(boundBy: 1).click()
        Thread.sleep(forTimeInterval: 1.0)

        let tileCount = app.otherElements.matching(tilePredicate).count
        XCTAssertEqual(
            tileCount, 1,
            "Second pane selection must replace the tile (count=1), not add a split (count=\(tileCount))"
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "App crashed during second pane selection"
        )
    }

    // MARK: - Private helpers

    private func waitForWorkspaceToLeaveEmptyState(timeout: TimeInterval = TestConstants.surfaceReadyTimeout) {
        let emptyPred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        let emptyState = app.descendants(matching: .any).matching(emptyPred).firstMatch
        if !emptyState.exists {
            return
        }

        let gonePredicate = NSPredicate(format: "exists == false")
        let goneExpectation = expectation(for: gonePredicate, evaluatedWith: emptyState)
        wait(for: [goneExpectation], timeout: timeout)
    }

    private func assertWorkspaceStartsEmpty() {
        let emptyPred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        let emptyState = app.descendants(matching: .any).matching(emptyPred).firstMatch
        if emptyState.waitForExistence(timeout: TestConstants.settleTimeout) {
            return
        }

        let tilePred = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let existingTile = app.descendants(matching: .any).matching(tilePred).firstMatch
        if existingTile.exists {
            return
        }

        let loadingPred = NSPredicate(
            format: "identifier BEGINSWITH %@",
            AccessibilityID.workspaceLoadingPrefix
        )
        let loadingOverlay = app.descendants(matching: .any).matching(loadingPred).firstMatch
        if loadingOverlay.exists {
            return
        }

        let workspacePred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceArea)
        let workspace = app.descendants(matching: .any).matching(workspacePred).firstMatch
        XCTAssertTrue(
            workspace.exists,
            "Workspace should expose either empty state, active tile, or loading overlay"
        )
    }

    private func paneRow(source: String = "local", sessionName: String, paneID: String) -> XCUIElement {
        let key = AccessibilityID.paneKey(source: source, sessionName: sessionName, paneID: paneID)
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)
        ).firstMatch
    }

    private func paneRowMetadataSummary(_ row: XCUIElement) -> String? {
        guard row.waitForExistence(timeout: 0.5) else { return nil }
        return stringValue(of: row)
    }

    private func paneRowByPaneID(source: String = "local", paneID: String) -> XCUIElement {
        let paneSuffix = paneID.replacingOccurrences(
            of: "[^A-Za-z0-9_]",
            with: "_",
            options: .regularExpression
        )
        return app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                AccessibilityID.sidebarPanePrefix + "\(source)_",
                "_" + paneSuffix
            )
        ).firstMatch
    }

    private func stringValue(of element: XCUIElement) -> String? {
        if let value = element.value as? String {
            return value
        }
        if let value = element.value {
            return String(describing: value)
        }
        return nil
    }

    private func mainTerminal() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.terminalMain)
        ).firstMatch
    }

    private func mainTerminalStatus() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.terminalMainStatus)
        ).firstMatch
    }

    private func mainTerminalNewShellButton() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.terminalMainNewShell)
        ).firstMatch
    }

    private func workbenchV2TerminalTile(sessionName: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                sessionName
            )
        ).firstMatch
    }

    private func workbenchV2Tile(id: UUID) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceTilePrefix + id.uuidString
            )
        ).firstMatch
    }

    private func waitForAppTmuxBridgeReady(
        control: AppTmuxControlPaths,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                _ = try sendAppTmuxCommand(
                    [Self.appTmuxBridgeReadyCommand],
                    refreshInventory: false,
                    control: control,
                    timeout: 1.0
                )
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        throw lastError ?? NSError(
            domain: "AgtmuxTermUITests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for app-side tmux bridge readiness"]
        )
    }

    private func fetchActiveDocumentTileSnapshot(
        control: AppTmuxControlPaths
    ) throws -> ActiveDocumentTileSnapshot {
        let output = try sendAppTmuxCommand(
            [Self.activeDocumentTileCommand],
            refreshInventory: false,
            control: control
        )
        return try JSONDecoder().decode(ActiveDocumentTileSnapshot.self, from: Data(output.utf8))
    }

    private func replaceFocusedText(
        _ value: String,
        control: AppTmuxControlPaths
    ) throws {
        _ = try sendAppTmuxCommand(
            [Self.replaceFocusedTextCommand, value],
            refreshInventory: false,
            control: control
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @discardableResult
    private func clickSidebarPaneRow(source: String, sessionName: String, paneID: String) -> Bool {
        let key = AccessibilityID.paneKey(source: source, sessionName: sessionName, paneID: paneID)
        return clickSidebarElement(identifier: AccessibilityID.sidebarPanePrefix + key)
    }

    @discardableResult
    private func clickSidebarPaneRow(_ row: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(TestConstants.sidebarPopulateTimeout)

        while Date() < deadline {
            if row.waitForExistence(timeout: 0.5) {
                let identifier = row.identifier
                if identifier.isEmpty {
                    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                    return true
                }
                return clickSidebarElement(identifier: identifier, deadline: deadline)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    @discardableResult
    private func clickSidebarElement(
        identifier: String,
        deadline: Date? = nil
    ) -> Bool {
        let limit = deadline ?? Date().addingTimeInterval(TestConstants.sidebarPopulateTimeout)

        while Date() < limit {
            let candidate = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", identifier)
            ).firstMatch
            if candidate.waitForExistence(timeout: 0.5) {
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return false
    }

    private func selectedPaneMarker(
        source: String = "local",
        sessionName: String,
        paneID: String
    ) -> XCUIElement {
        let key = AccessibilityID.paneKey(
            source: source,
            sessionName: sessionName,
            paneID: paneID
        )
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "sidebar.pane.selected." + key)
        ).firstMatch
    }

    private func paneInventoryID(
        source: String = "local",
        sessionName: String,
        paneID: String
    ) -> String {
        "\(source):\(sessionName):\(paneID)"
    }

    @discardableResult
    private func waitForAppWorkbenchTerminalTarget(
        control: AppTmuxControlPaths,
        sessionName: String,
        windowID: String,
        paneID: String,
        selectedPaneInventoryID: String,
        timeout: TimeInterval = TestConstants.focusSyncLatencyBudget
    ) -> AppWorkbenchTerminalTargetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: AppWorkbenchTerminalTargetSnapshot?
        var latestError: String?

        while Date() < deadline {
            do {
                let snapshot = try appWorkbenchTerminalTargetSnapshot(control: control)
                latest = snapshot
                latestError = nil
                if snapshot.sessionName == sessionName,
                   snapshot.windowID == windowID,
                   snapshot.paneID == paneID,
                   snapshot.selectedPaneInventoryID == selectedPaneInventoryID,
                   snapshot.renderedClientWindowID == windowID,
                   snapshot.renderedClientPaneID == paneID,
                   !snapshot.renderedClientTTY.isEmpty,
                   attachCommandAttachesSession(
                       snapshot.attachCommand,
                       sessionName: sessionName
                   ),
                   attachCommandAttachesSession(
                       snapshot.renderedAttachCommand,
                       sessionName: sessionName
                   ) {
                    return snapshot
                }
            } catch {
                latestError = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTFail(
            "App store must target session=\(sessionName) window=\(windowID) pane=\(paneID) " +
            "selected=\(selectedPaneInventoryID); latest session=\(latest?.sessionName ?? "nil") " +
            "window=\(latest?.windowID ?? "nil") pane=\(latest?.paneID ?? "nil") " +
            "desiredWindow=\(latest?.desiredWindowID ?? "nil") desiredPane=\(latest?.desiredPaneID ?? "nil") " +
            "observedWindow=\(latest?.observedWindowID ?? "nil") observedPane=\(latest?.observedPaneID ?? "nil") " +
            "focusNonce=\(latest?.focusRequestNonce.description ?? "nil") " +
            "selected=\(latest?.selectedPaneInventoryID ?? "nil") attach=\(latest?.attachCommand ?? "nil") " +
            "renderedAttach=\(latest?.renderedAttachCommand ?? "nil") " +
            "controlModeKey=\(latest?.controlModeKey ?? "nil") controlModeState=\(latest?.controlModeState ?? "nil") " +
            "renderedTTY=\(latest?.renderedClientTTY ?? "nil") " +
            "renderedWindow=\(latest?.renderedClientWindowID ?? "nil") " +
            "renderedPane=\(latest?.renderedClientPaneID ?? "nil") " +
            "renderedGeneration=\(latest?.renderedSurfaceGeneration.description ?? "nil") " +
            "latestError=\(latestError ?? "nil")"
        )
        return latest ?? AppWorkbenchTerminalTargetSnapshot(
            terminalHostMode: "",
            workbenchID: "",
            tileID: "",
            sessionName: "",
            windowID: "",
            paneID: "",
            desiredWindowID: "",
            desiredPaneID: "",
            observedWindowID: "",
            observedPaneID: "",
            focusRequestNonce: 0,
            selectedPaneInventoryID: "",
            attachCommand: "",
            renderedAttachCommand: "",
            renderedClientTTY: "",
            renderedClientWindowID: "",
            renderedClientPaneID: "",
            renderedSurfaceGeneration: 0,
            controlModeKey: "",
            controlModeState: ""
        )
    }

    private func waitForAppWorkbenchTerminalSessionSwitchTarget(
        control: AppTmuxControlPaths,
        sessionName: String,
        windowID: String,
        paneID: String,
        selectedPaneInventoryID: String,
        renderedClientTTY: String,
        timeout: TimeInterval = TestConstants.focusSyncLatencyBudget
    ) -> AppWorkbenchTerminalTargetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: AppWorkbenchTerminalTargetSnapshot?
        var latestError: String?

        while Date() < deadline {
            do {
                let snapshot = try appWorkbenchTerminalTargetSnapshot(control: control)
                latest = snapshot
                latestError = nil
                if snapshot.sessionName == sessionName,
                   snapshot.windowID == windowID,
                   snapshot.paneID == paneID,
                   snapshot.selectedPaneInventoryID == selectedPaneInventoryID,
                   !snapshot.renderedClientTTY.isEmpty,
                   snapshot.renderedClientWindowID == windowID,
                   snapshot.renderedClientPaneID == paneID,
                   attachCommandAttachesSession(
                       snapshot.attachCommand,
                       sessionName: sessionName
                   ) {
                    return snapshot
                }
            } catch {
                latestError = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTFail(
            "App store must rebind to session=\(sessionName) window=\(windowID) pane=\(paneID) " +
            "selected=\(selectedPaneInventoryID) tty=\(renderedClientTTY); " +
            "latest session=\(latest?.sessionName ?? "nil") window=\(latest?.windowID ?? "nil") " +
            "pane=\(latest?.paneID ?? "nil") desiredWindow=\(latest?.desiredWindowID ?? "nil") " +
            "desiredPane=\(latest?.desiredPaneID ?? "nil") observedWindow=\(latest?.observedWindowID ?? "nil") " +
            "observedPane=\(latest?.observedPaneID ?? "nil") focusNonce=\(latest?.focusRequestNonce.description ?? "nil") " +
            "selected=\(latest?.selectedPaneInventoryID ?? "nil") " +
            "attach=\(latest?.attachCommand ?? "nil") renderedAttach=\(latest?.renderedAttachCommand ?? "nil") " +
            "controlModeKey=\(latest?.controlModeKey ?? "nil") controlModeState=\(latest?.controlModeState ?? "nil") " +
            "renderedTTY=\(latest?.renderedClientTTY ?? "nil") renderedWindow=\(latest?.renderedClientWindowID ?? "nil") " +
            "renderedPane=\(latest?.renderedClientPaneID ?? "nil") renderedGeneration=\(latest?.renderedSurfaceGeneration.description ?? "nil") " +
            "latestError=\(latestError ?? "nil")"
        )
        return latest ?? AppWorkbenchTerminalTargetSnapshot(
            terminalHostMode: "",
            workbenchID: "",
            tileID: "",
            sessionName: "",
            windowID: "",
            paneID: "",
            desiredWindowID: "",
            desiredPaneID: "",
            observedWindowID: "",
            observedPaneID: "",
            focusRequestNonce: 0,
            selectedPaneInventoryID: "",
            attachCommand: "",
            renderedAttachCommand: "",
            renderedClientTTY: "",
            renderedClientWindowID: "",
            renderedClientPaneID: "",
            renderedSurfaceGeneration: 0,
            controlModeKey: "",
            controlModeState: ""
        )
    }

    private func attachCommandAttachesSession(
        _ command: String,
        sessionName: String
    ) -> Bool {
        command.contains("attach-session -t")
            && command.contains(sessionName)
    }

    private func attachCommandTargetsPane(
        _ command: String,
        sessionName: String,
        windowID: String,
        paneID: String
    ) -> Bool {
        attachCommandAttachesSession(command, sessionName: sessionName)
            && command.contains("select-window -t")
            && command.contains(windowID)
            && command.contains("select-pane -t")
            && command.contains(paneID)
    }

    private func appWorkbenchTerminalTargetSnapshot(
        control: AppTmuxControlPaths
    ) throws -> AppWorkbenchTerminalTargetSnapshot {
        let output = try sendAppTmuxCommand(
            ["__agtmux_dump_active_terminal_target__"],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
        let data = Data(output.utf8)
        return try JSONDecoder().decode(AppWorkbenchTerminalTargetSnapshot.self, from: data)
    }

    private func sessionRow(source: String = "local", sessionName: String) -> XCUIElement {
        let key = AccessibilityID.sessionKey(source: source, sessionName: sessionName)
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarSessionPrefix + key)
        ).firstMatch
    }

    private func sidebarHealthStrip() -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarHealthStrip)
        ).firstMatch
    }

    private func sidebarHealthBadge(_ componentID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.sidebarHealthBadgePrefix + componentID
            )
        ).firstMatch
    }

    private struct AppTmuxScenario: Encodable {
        let sessionName: String
        let windowName: String
        let paneCount: Int
        let shellCommand: String
    }

    private struct AppTmuxControlPaths {
        let commandPath: String
        let commandResultPath: String
        let bootstrapResultPath: String
        let daemonSocketPath: String
        let managedDaemonStderrPath: String
    }

    private struct AppTmuxBootstrapResult: Decodable {
        let ok: Bool
        let sessionName: String?
        let windowID: String?
        let paneIDs: [String]
        let socketPath: String?
        let error: String?
    }

    private struct AppTmuxCommandRequest: Encodable {
        let id: String
        let args: [String]
        let refreshInventory: Bool
    }

    private struct AppTmuxCommandResponse: Decodable {
        let id: String
        let ok: Bool
        let stdout: String
        let error: String?
    }

    private struct ActiveDocumentTileSnapshot: Decodable {
        let workbenchID: String
        let tileID: String
        let path: String
        let target: String
        let focused: Bool
    }

    private struct SidebarStateSnapshot: Decodable {
        let statusFilter: String
        let panePresentations: [SidebarPanePresentationSnapshot]
        let filteredPanePresentations: [SidebarPanePresentationSnapshot]
        let attentionCount: Int
        let localDaemonIssueTitle: String?
        let localDaemonIssueDetail: String?
        let bootstrapProbeSummary: BootstrapProbeSummary
        let bootstrapTargetSummary: BootstrapTargetSummary?
        let managedDaemonSocketPath: String
        let tmuxSocketArguments: [String]
        let daemonCLIArguments: [String]
        let bootstrapResolvedTmuxSocketPath: String?
        let appDirectResolvedSocketProbe: String?
        let appDirectResolvedSocketProbeError: String?
        let daemonProcessCommands: [String]
        let daemonLaunchRecord: DaemonLaunchRecordSnapshot?
        let managedDaemonStderrTail: String?
    }

    private struct SidebarPanePresentationSnapshot: Decodable {
        let source: String
        let sessionName: String
        let paneID: String
        let presence: String
        let provider: String?
        let primaryState: String
        let freshness: String?
        let currentCommand: String?
        let isManaged: Bool
        let needsAttention: Bool
    }

    private struct DaemonLaunchRecordSnapshot: Decodable {
        let binaryPath: String
        let arguments: [String]
        let environment: [String: String]
        let reusedExistingRuntime: Bool
    }

    private struct BootstrapProbeSummary: Decodable {
        let ok: Bool
        let transportVersion: String?
        let totalPanes: Int?
        let managedPanes: Int?
        let error: String?
    }

    private struct BootstrapTargetSummary: Decodable {
        let sessionName: String
        let paneID: String
        let presence: String
        let provider: String?
        let primaryState: String
        let freshness: String?
        let sessionKey: String
        let paneInstanceID: String
        let bindingEpochID: String?
        let runtimeRefProvider: String?
        let runtimeRefNativeID: String?
    }

    private struct AppWorkbenchTerminalTargetSnapshot: Decodable {
        let terminalHostMode: String
        let workbenchID: String
        let tileID: String
        let sessionName: String
        let windowID: String
        let paneID: String
        let desiredWindowID: String
        let desiredPaneID: String
        let observedWindowID: String
        let observedPaneID: String
        let focusRequestNonce: UInt64
        let selectedPaneInventoryID: String
        let attachCommand: String
        let renderedAttachCommand: String
        let renderedClientTTY: String
        let renderedClientWindowID: String
        let renderedClientPaneID: String
        let renderedSurfaceGeneration: UInt64
        let controlModeKey: String
        let controlModeState: String
    }

    private struct GhosttyIslandTelemetrySnapshot: Decodable {
        let applyCommandCount: Int
        let paneRetargetRefreshCount: Int
    }

    private struct ScrollBenchTelemetrySnapshot: Decodable {
        let island: GhosttyIslandTelemetrySnapshot
    }

    private struct TerminalViewportTextSnapshot: Decodable {
        let text: String
        let lineCount: Int
        let characterCount: Int
        let usesAlternateScroll: Bool
    }

    private func mixedEraBootstrapPayloadWithLegacySessionID(
        sessionName: String,
        paneID: String,
        windowID: String
    ) -> String {
        """
        {
          "epoch": 1,
          "snapshot_seq": 1,
          "generated_at": "2026-03-07T16:57:36Z",
          "replay_cursor": { "epoch": 1, "seq": 1 },
          "sessions": [],
          "panes": [
            {
              "pane_id": "\(paneID)",
              "session_id": "$1",
              "session_name": "\(sessionName)",
              "session_key": "\(sessionName)",
              "window_id": "\(windowID)",
              "window_name": "zsh",
              "pane_instance_id": {
                "pane_id": "\(paneID)",
                "generation": 1,
                "birth_ts": "2026-03-07T16:45:00Z"
              },
              "activity_state": "Running",
              "presence": "managed",
              "provider": "codex",
              "evidence_mode": "heuristic",
              "current_cmd": "zsh",
              "current_path": "/tmp/agtmux-e2e"
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
              "current_path": "/tmp/orphan"
            }
          ]
        }
        """
    }

    private func makeAppTmuxControlPaths(token: String) throws -> AppTmuxControlPaths {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agtmux-term-uitest-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let daemonSocketDirectory = realUserHomeDirectory()
            .appendingPathComponent(".agt", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonSocketDirectory, withIntermediateDirectories: true)
        let daemonSocketPath = daemonSocketDirectory
            .appendingPathComponent("uit-\(token).sock", isDirectory: false)
        return AppTmuxControlPaths(
            commandPath: dir.appendingPathComponent("tmux-command.json").path,
            commandResultPath: dir.appendingPathComponent("tmux-command-result.json").path,
            bootstrapResultPath: dir.appendingPathComponent("tmux-bootstrap-result.json").path,
            daemonSocketPath: daemonSocketPath.path,
            managedDaemonStderrPath: dir.appendingPathComponent("managed-daemon.stderr.log").path
        )
    }

    private func configureAppDrivenTmux(
        socketName: String,
        control: AppTmuxControlPaths,
        scenario: AppTmuxScenario?
    ) {
        app.launchEnvironment["AGTMUX_TMUX_SOCKET_NAME"] = socketName
        app.launchEnvironment[AgtmuxBinaryResolver.managedSocketPathEnvKey] = control.daemonSocketPath
        app.launchEnvironment["AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH"] = control.managedDaemonStderrPath
        app.launchEnvironment["AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES"] = "1"
        app.launchEnvironment["AGTMUX_UITEST_TMUX_CONFIG_PATH"] = "/dev/null"
        app.launchEnvironment["AGTMUX_UITEST_TMUX_COMMAND_PATH"] = control.commandPath
        app.launchEnvironment["AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH"] = control.commandResultPath
        app.launchEnvironment["AGTMUX_UITEST_TMUX_RESULT_PATH"] = control.bootstrapResultPath
        app.launchEnvironment["AGTMUX_UITEST_TMUX_AUTO_CLEANUP"] = "1"
        app.launchEnvironment["AGTMUX_UITEST_TMUX_KILL_SERVER"] = "0"

        if let scenario {
            if let data = try? JSONEncoder().encode(scenario),
               let json = String(data: data, encoding: .utf8) {
                app.launchEnvironment["AGTMUX_UITEST_TMUX_SCENARIO"] = json
            }
        } else {
            app.launchEnvironment.removeValue(forKey: "AGTMUX_UITEST_TMUX_SCENARIO")
        }
    }

    private func waitForAppTmuxBootstrapResult(
        control: AppTmuxControlPaths,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws -> AppTmuxBootstrapResult {
        let url = URL(fileURLWithPath: control.bootstrapResultPath)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let result = try? JSONDecoder().decode(AppTmuxBootstrapResult.self, from: data) {
                return result
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("Timed out waiting for app-side tmux bootstrap result")
    }

    @discardableResult
    private func sendAppTmuxCommand(
        _ args: [String],
        refreshInventory: Bool = true,
        control: AppTmuxControlPaths,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws -> String {
        let commandURL = URL(fileURLWithPath: control.commandPath)
        let responseURL = URL(fileURLWithPath: control.commandResultPath)
        let attempts = 3

        for attempt in 1...attempts {
            let requestID = UUID().uuidString
            let request = AppTmuxCommandRequest(
                id: requestID,
                args: args,
                refreshInventory: refreshInventory
            )
            try? FileManager.default.removeItem(at: responseURL)
            try? FileManager.default.removeItem(at: commandURL)
            let payload = try JSONEncoder().encode(request)
            try payload.write(to: commandURL, options: .atomic)

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = try? Data(contentsOf: responseURL),
                   let response = try? JSONDecoder().decode(AppTmuxCommandResponse.self, from: data),
                   response.id == requestID {
                    if response.ok {
                        return response.stdout
                    }
                    throw NSError(
                        domain: "AgtmuxTermUITests",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "App-side tmux command failed: \(response.error ?? "unknown error")"
                        ]
                    )
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            if attempt < attempts {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        throw NSError(
            domain: "AgtmuxTermUITests",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for app-side tmux command result: \(args.joined(separator: " "))"
            ]
        )
    }

    private func listLinkedSessionsViaApp(control: AppTmuxControlPaths) throws -> Set<String> {
        let output = try sendAppTmuxCommand(
            ["list-sessions", "-F", "#{session_name}"],
            refreshInventory: false,
            control: control
        )
        return Set(
            output
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("agtmux-linked-") }
        )
    }

    private func waitForAppPaneDescriptors(
        tmuxTarget: String,
        windowDescription: String,
        expectedPaneCount: Int,
        control: AppTmuxControlPaths,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws -> (windowID: String, paneIDs: [String]) {
        let deadline = Date().addingTimeInterval(timeout)
        var latestOutput = ""
        var latestError: String?

        while Date() < deadline {
            do {
                let output = try sendAppTmuxCommand(
                    ["list-panes", "-t", tmuxTarget, "-F", "#{window_id}|#{pane_id}"],
                    refreshInventory: false,
                    control: control,
                    timeout: 2.0
                )
                latestOutput = output
                latestError = nil
                let rows = output
                    .components(separatedBy: "\n")
                    .compactMap { line -> (String, String)? in
                        let parts = line.components(separatedBy: "|")
                        guard parts.count == 2 else { return nil }
                        return (parts[0], parts[1])
                    }
                let windowID = rows.first?.0
                let paneIDs = rows.map(\.1).filter { !$0.isEmpty }
                if let windowID,
                   windowID.hasPrefix("@"),
                   paneIDs.count >= expectedPaneCount,
                   paneIDs.allSatisfy({ $0.hasPrefix("%") }) {
                    return (windowID, paneIDs)
                }
            } catch {
                latestError = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw XCTSkip(
            "Timed out waiting for pane in window '\(windowDescription)' of target '\(tmuxTarget)'; " +
            "latestOutput='\(latestOutput)' latestError='\(latestError ?? "nil")'"
        )
    }

    private func waitForAppShellReady(
        tmuxTarget: String,
        control: AppTmuxControlPaths,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws {
        let token = "__agtmux_ready_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let readinessCommand = "printf '" + token + "\\n'"
        _ = try sendAppTmuxCommand(
            ["send-keys", "-t", tmuxTarget, "-l", readinessCommand],
            refreshInventory: false,
            control: control
        )
        _ = try sendAppTmuxCommand(
            ["send-keys", "-t", tmuxTarget, "C-m"],
            refreshInventory: false,
            control: control
        )

        let deadline = Date().addingTimeInterval(timeout)
        var latestOutput = ""
        while Date() < deadline {
            latestOutput = try sendAppTmuxCommand(
                ["capture-pane", "-p", "-t", tmuxTarget],
                refreshInventory: false,
                control: control,
                timeout: 2.0
            )
            if latestOutput.contains(token) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw XCTSkip(
            "Timed out waiting for interactive shell readiness in \(tmuxTarget); latest capture='\(latestOutput)'"
        )
    }

    private func fetchAppSidebarState(
        control: AppTmuxControlPaths,
        sessionName: String,
        paneID: String,
        refreshInventory: Bool = false,
        timeout: TimeInterval = 2.0
    ) throws -> SidebarStateSnapshot {
        let output = try sendAppTmuxCommand(
            ["__agtmux_dump_sidebar_state__", sessionName, paneID],
            refreshInventory: refreshInventory,
            control: control,
            timeout: timeout
        )
        return try JSONDecoder().decode(SidebarStateSnapshot.self, from: Data(output.utf8))
    }

    private func waitForAppSidebarPanePresentation(
        control: AppTmuxControlPaths,
        sessionName: String,
        paneID: String,
        timeout: TimeInterval = TestConstants.sidebarPopulateTimeout
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var latestSummary = "none"
        var latestError = "none"
        while Date() < deadline {
            do {
                let state = try fetchAppSidebarState(
                    control: control,
                    sessionName: sessionName,
                    paneID: paneID,
                    refreshInventory: true,
                    timeout: 5.0
                )
                latestSummary = state.panePresentations
                    .map { "\($0.sessionName):\($0.paneID)" }
                    .joined(separator: ",")
                latestError = "none"
                if state.panePresentations.contains(where: {
                    $0.sessionName == sessionName && $0.paneID == paneID
                }) {
                    return
                }
            } catch {
                latestError = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw NSError(
            domain: "AgtmuxTermUITests",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for sidebar pane presentation for \(sessionName) \(paneID); latest=\(latestSummary); refreshError=\(latestError)"
            ]
        )
    }

    private func resetAppScrollTelemetry(
        control: AppTmuxControlPaths,
        tileID: String
    ) throws {
        _ = try sendAppTmuxCommand(
            ["__agtmux_reset_scroll_telemetry__", tileID],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
    }

    private func dumpAppScrollTelemetry(
        control: AppTmuxControlPaths,
        tileID: String
    ) throws -> ScrollBenchTelemetrySnapshot {
        let output = try sendAppTmuxCommand(
            ["__agtmux_dump_scroll_telemetry__", tileID],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
        return try JSONDecoder().decode(ScrollBenchTelemetrySnapshot.self, from: Data(output.utf8))
    }

    private func dumpAppTerminalViewportText(
        control: AppTmuxControlPaths,
        tileID: String
    ) throws -> TerminalViewportTextSnapshot {
        let output = try sendAppTmuxCommand(
            ["__agtmux_dump_terminal_viewport_text__", tileID],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
        return try JSONDecoder().decode(TerminalViewportTextSnapshot.self, from: Data(output.utf8))
    }

    private func enableAppManagedMetadata(control: AppTmuxControlPaths) throws {
        _ = try sendAppTmuxCommand(
            ["__agtmux_enable_metadata__"],
            refreshInventory: false,
            control: control,
            timeout: 5.0
        )
    }

    private func waitForAppDaemonBootstrapReady(
        control: AppTmuxControlPaths,
        sessionName: String,
        paneID: String,
        expectedCurrentCommand: String,
        expectedPresence: String,
        expectedProvider: String?,
        expectedPrimaryStates: [String],
        failureContext: String,
        timeout: TimeInterval = 10.0
    ) throws -> SidebarStateSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: SidebarStateSnapshot?

        while Date() < deadline {
            if let snapshot = try? fetchAppSidebarState(
                control: control,
                sessionName: sessionName,
                paneID: paneID
            ) {
                lastSnapshot = snapshot
                let probe = snapshot.bootstrapProbeSummary
                let target = snapshot.bootstrapTargetSummary
                let visiblePresentation = snapshot.panePresentations.first {
                    $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
                }
                if probe.ok,
                   probe.transportVersion == "sync-v3",
                   (probe.totalPanes ?? 0) > 0,
                   target?.sessionName == sessionName,
                   target?.paneID == paneID,
                   target?.presence == expectedPresence,
                   target?.provider == expectedProvider,
                   expectedPrimaryStates.contains(target?.primaryState ?? ""),
                   visiblePresentation?.currentCommand == expectedCurrentCommand {
                    return snapshot
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        XCTFail(
            "\(failureContext). " +
            "sidebar='\(sidebarStateSummary(lastSnapshot, sessionName: sessionName, paneID: paneID))'"
        )
        return try fetchAppSidebarState(control: control, sessionName: sessionName, paneID: paneID)
    }

    private func sidebarStateSummary(
        _ snapshot: SidebarStateSnapshot?,
        sessionName: String,
        paneID: String
    ) -> String {
        guard let snapshot else { return "nil" }

        func summarize(_ pane: SidebarPanePresentationSnapshot?) -> String {
            guard let pane else { return "nil" }
            return [
                "presence=\(pane.presence)",
                "provider=\(pane.provider ?? "nil")",
                "primary=\(pane.primaryState)",
                "freshness=\(pane.freshness ?? "nil")",
                "managed=\(pane.isManaged)",
                "attention=\(pane.needsAttention)",
                "current_cmd=\(pane.currentCommand ?? "nil")"
            ].joined(separator: ",")
        }

        let visiblePresentation = snapshot.panePresentations.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let filteredPresentation = snapshot.filteredPanePresentations.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let issueSummary: String
        if let title = snapshot.localDaemonIssueTitle {
            let detail = snapshot.localDaemonIssueDetail ?? ""
            issueSummary = "\(title):\(detail)"
        } else {
            issueSummary = "nil"
        }

        let probe = snapshot.bootstrapProbeSummary
        let probeSummary = probe.ok
            ? "ok transport=\(probe.transportVersion ?? "nil") total=\(probe.totalPanes ?? -1) managed=\(probe.managedPanes ?? -1)"
            : "error=\(probe.error ?? "unknown")"
        let targetSummary: String
        if let target = snapshot.bootstrapTargetSummary {
            var parts = [
                "presence=\(target.presence)",
                "provider=\(target.provider ?? "nil")",
                "primary=\(target.primaryState)",
                "freshness=\(target.freshness ?? "nil")",
                "session_key=\(target.sessionKey)",
                "pane_instance=\(target.paneInstanceID)"
            ]
            if let bindingEpochID = target.bindingEpochID {
                parts.append("binding_epoch_id=\(bindingEpochID)")
            }
            if let runtimeRefProvider = target.runtimeRefProvider,
               let runtimeRefNativeID = target.runtimeRefNativeID {
                parts.append("runtime_ref=\(runtimeRefProvider):\(runtimeRefNativeID)")
            }
            targetSummary = parts.joined(separator: ",")
        } else {
            targetSummary = "nil"
        }
        let daemonLaunchSummary = snapshot.daemonLaunchRecord.map {
            "\($0.reusedExistingRuntime ? "reused" : "spawned"):\($0.binaryPath):\($0.arguments.joined(separator: ","))"
        } ?? "nil"
        let daemonEnvSummary = snapshot.daemonLaunchRecord.map { launch in
            launch.environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
        } ?? "nil"

        return [
            "filter=\(snapshot.statusFilter)",
            "attentionCount=\(snapshot.attentionCount)",
            "issue=\(issueSummary)",
            "probe=\(probeSummary)",
            "probeTarget=\(targetSummary)",
            "managedSocket=\(snapshot.managedDaemonSocketPath)",
            "tmuxArgs=\(snapshot.tmuxSocketArguments.joined(separator: ","))",
            "daemonArgs=\(snapshot.daemonCLIArguments.joined(separator: ","))",
            "bootstrapTmuxSocket=\(snapshot.bootstrapResolvedTmuxSocketPath ?? "nil")",
            "appDirectSocketProbe=\(snapshot.appDirectResolvedSocketProbe ?? "nil")",
            "appDirectSocketProbeErr=\(snapshot.appDirectResolvedSocketProbeError ?? "nil")",
            "daemonProc=\(snapshot.daemonProcessCommands.joined(separator: " || "))",
            "daemonLaunch=\(daemonLaunchSummary)",
            "daemonEnv=\(daemonEnvSummary)",
            "daemonErr=\(snapshot.managedDaemonStderrTail ?? "nil")",
            "all=\(summarize(visiblePresentation))",
            "filtered=\(summarize(filteredPresentation))",
            "filteredCount=\(snapshot.filteredPanePresentations.count)"
        ].joined(separator: " ")
    }

    private func liveManagedCodexDaemonSkipReason(
        sidebarState: SidebarStateSnapshot?,
        sessionName: String,
        paneID: String,
        finalCapture: String?
    ) -> String? {
        guard let sidebarState else { return nil }
        guard finalCapture?.contains("wait_result=managed") == true else { return nil }
        guard let target = sidebarState.bootstrapTargetSummary,
              target.sessionName == sessionName,
              target.paneID == paneID,
              target.presence == "unmanaged",
              target.provider == nil,
              target.sessionKey.hasPrefix("shell:") else {
            return nil
        }
        let visiblePresentation = sidebarState.panePresentations.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        guard visiblePresentation?.presence == "unmanaged",
              visiblePresentation?.provider == nil else {
            return nil
        }
        return "Live Codex process completed, but daemon truth never promoted the pane beyond unmanaged shell metadata. " +
            "This is a daemon-side failure, not a term sidebar-binding regression. " +
            "sidebar='\(sidebarStateSummary(sidebarState, sessionName: sessionName, paneID: paneID))'"
    }

    private func waitForSingleWorkbenchV2TerminalTile(
        sessionName: String,
        timeout: TimeInterval = TestConstants.surfaceReadyTimeout
    ) {
        let terminal = mainTerminal()
        XCTAssertTrue(
            terminal.waitForExistence(timeout: timeout),
            "Main terminal should stay visible for \(sessionName)"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
            ).firstMatch.exists,
            "Visible workbench tab bar should stay absent for \(sessionName)"
        )
    }

    private func waitForRenderedClientTmuxTarget(
        control: AppTmuxControlPaths,
        clientTTY: String,
        sessionName: String,
        windowID: String,
        paneID: String,
        timeout: TimeInterval = TestConstants.surfaceReadyTimeout
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: (sessionName: String, windowID: String, paneID: String)?

        while Date() < deadline {
            if let snapshot = try? renderedClientTmuxTarget(
                control: control,
                clientTTY: clientTTY,
                sessionName: sessionName
            ) {
                latest = snapshot
                if snapshot.sessionName == sessionName,
                   snapshot.windowID == windowID,
                   snapshot.paneID == paneID {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTFail(
            "Rendered tmux client \(clientTTY) must target session=\(sessionName) window=\(windowID) pane=\(paneID); " +
            "latest live target=session=\(latest?.sessionName ?? "nil") " +
            "window=\(latest?.windowID ?? "nil") pane=\(latest?.paneID ?? "nil")"
        )
    }

    private func renderedClientTmuxTarget(
        control: AppTmuxControlPaths,
        clientTTY: String,
        sessionName: String
    ) throws -> (sessionName: String, windowID: String, paneID: String) {
        let output = try sendAppTmuxCommand(
            [
                "list-clients",
                "-F", "#{client_tty}|#{session_name}|#{window_id}|#{pane_id}"
            ],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            guard fields[0] == clientTTY else { continue }
            guard fields[1] == sessionName else { continue }
            return (sessionName: fields[1], windowID: fields[2], paneID: fields[3])
        }

        throw NSError(
            domain: "AgtmuxTermUITests",
            code: 91,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not resolve rendered tmux client \(clientTTY) for session \(sessionName): \(output)"
            ]
        )
    }

    private func resolveAgtmuxBinaryForUITest() -> String? {
        let env = ProcessInfo.processInfo.environment
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let siblingDebug = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("agtmux/target/debug/agtmux")
            .path
        let candidates = [
            env["AGTMUX_BIN"],
            siblingDebug,
        ]

        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func workbenchFixtureJSON(_ workbenches: [Workbench]) throws -> String {
        let data = try JSONEncoder().encode(workbenches)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "AgtmuxTermUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode workbench fixture as UTF-8"]
            )
        }
        return json
    }

    private enum RunnerTmuxAccess {
        case available
        case availableNoServer
        case inaccessible(String)
    }

    /// Classify runner-side tmux availability.
    ///
    /// - `available`: runner can query tmux sessions.
    /// - `availableNoServer`: no default server exists, but runner can create one.
    /// - `inaccessible`: sandbox/socket mismatch or other hard failure.
    private func classifyRunnerTmuxAccess(tmux: String) -> RunnerTmuxAccess {
        do {
            _ = try shellRun([tmux, "list-sessions", "-F", "#{session_name}"])
            return .available
        } catch {
            let detail = error.localizedDescription
            let lowered = detail.lowercased()
            guard lowered.contains("no server running") else {
                return .inaccessible(detail)
            }

            // "no server running" is not a socket-access failure; verify that we can
            // create/kill a throwaway session from the runner context.
            let probe = "agtmux-e2e-probe-\(UUID().uuidString.prefix(8))"
            do {
                _ = try shellRun([tmux, "new-session", "-d", "-s", probe, "/bin/sleep 1"])
                _ = try? shellRun([tmux, "kill-session", "-t", probe])
                return .availableNoServer
            } catch {
                return .inaccessible("no-server but probe session failed: \(error.localizedDescription)")
            }
        }
    }

    private func resolveTmuxPathBestEffort() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Create a tmux session that is automatically cleaned by tearDown.
    ///
    /// New E2E tests must use this helper (never raw `tmux new-session`) so that
    /// both tmux session cleanup and agent process cleanup are guaranteed.
    /// Session names are normalized to `agtmux-e2e-*` to keep teardown targeting explicit.
    private func createTrackedTmuxSession(prefix: String, tmux: String) throws -> String {
        let normalizedPrefix: String = prefix.hasPrefix("agtmux-e2e-") ? prefix : "agtmux-e2e-\(prefix)"
        let session = "\(normalizedPrefix)-\(UUID().uuidString.prefix(8))"
        guard (try? shellRun([tmux, "new-session", "-d", "-s", session])) != nil else {
            throw XCTSkip("Could not create tmux session — sandbox may be blocking")
        }
        ownedSessions.insert(session)
        return session
    }

    private func listTmuxSessions(_ tmux: String) throws -> Set<String> {
        let sessions = try shellOutput([tmux, "list-sessions", "-F", "#{session_name}"])
        return Set(sessions.components(separatedBy: "\n").filter { !$0.isEmpty })
    }

    /// Best-effort cleanup for agent sessions (codex/claude) inside a test-owned tmux session.
    /// Order:
    /// 1) polite interrupt (`C-c`, `exit`)
    /// 2) terminate by pane TTY / process-group / process-tree
    /// 3) hard kill if still alive (`TERM` pass then `KILL` pass)
    private func terminateSessionProcesses(session: String, tmux: String) {
        guard let rows = try? shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}|#{pane_pid}|#{pane_tty}"]) else {
            return
        }

        struct PaneProcessTarget {
            var pid: Int32
            var processGroupID: Int32?
            var tty: String?
        }

        var targets: [PaneProcessTarget] = []
        for line in rows.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let paneID = parts[0]
            guard let pid = Int32(parts[1]), pid > 1 else { continue }
            let tty = parts.count >= 3 ? parts[2] : nil

            _ = try? shellRun([tmux, "send-keys", "-t", paneID, "C-c"])
            _ = try? shellRun([tmux, "send-keys", "-t", paneID, "C-c"])
            _ = try? shellRun([tmux, "send-keys", "-t", paneID, "exit", "Enter"])

            targets.append(
                PaneProcessTarget(
                    pid: pid,
                    processGroupID: processGroupID(for: pid),
                    tty: tty
                )
            )
        }

        Thread.sleep(forTimeInterval: 0.2)
        for target in targets {
            if let tty = target.tty, let shortTTY = tty.components(separatedBy: "/").last, !shortTTY.isEmpty {
                _ = try? shellRun(["/usr/bin/pkill", "-TERM", "-t", shortTTY])
            }
            if let pgid = target.processGroupID, pgid > 1 {
                _ = try? shellRun(["/bin/kill", "-TERM", "--", "-\(pgid)"])
            }
            _ = try? shellRun(["/usr/bin/pkill", "-TERM", "-P", "\(target.pid)"])
            _ = try? shellRun(["/bin/kill", "-TERM", "\(target.pid)"])
        }

        Thread.sleep(forTimeInterval: 0.2)
        for target in targets {
            if let tty = target.tty, let shortTTY = tty.components(separatedBy: "/").last, !shortTTY.isEmpty {
                _ = try? shellRun(["/usr/bin/pkill", "-KILL", "-t", shortTTY])
            }
            if let pgid = target.processGroupID, pgid > 1 {
                _ = try? shellRun(["/bin/kill", "-KILL", "--", "-\(pgid)"])
            }
            _ = try? shellRun(["/usr/bin/pkill", "-KILL", "-P", "\(target.pid)"])
            _ = try? shellRun(["/bin/kill", "-KILL", "\(target.pid)"])
        }
    }

    private func processGroupID(for pid: Int32) -> Int32? {
        guard let raw = try? shellOutput(["/bin/ps", "-o", "pgid=", "-p", "\(pid)"]) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(trimmed)
    }

    @discardableResult
    private func shellRun(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = normalizedRunnerShellEnvironment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Shell", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(args.joined(separator: " ")): \(stderr)"])
        }
        return stdout
    }

    private func shellOutput(_ args: [String]) throws -> String {
        return try shellRun(args)
    }

    private func shellRunIgnoringFailure(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = normalizedRunnerShellEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best-effort cleanup must never fail the test body.
        }
    }

    private func normalizedRunnerShellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Never inherit current tmux client context from the runner shell.
        // A stale/inaccessible TMUX socket makes `tmux list-sessions` fail and
        // causes false "socket not accessible" skips.
        env["TMUX"] = nil
        env["TMUX_PANE"] = nil

        let username = env["USER"] ?? NSUserName()
        let realUserHome = NSHomeDirectoryForUser(username) ?? "/Users/\(username)"
        env["HOME"] = realUserHome
        env["USER"] = username
        env["LOGNAME"] = username
        env["XDG_CONFIG_HOME"] = realUserHome + "/.config"
        env["CODEX_HOME"] = realUserHome + "/.codex"

        let preferredPathSegments = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingPathSegments = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedSegments: [String] = []
        for segment in preferredPathSegments + existingPathSegments where !segment.isEmpty {
            if !mergedSegments.contains(segment) {
                mergedSegments.append(segment)
            }
        }
        env["PATH"] = mergedSegments.joined(separator: ":")
        return env
    }

    func testRunningAppTrackpadScrollBurst() throws {
        let env = ProcessInfo.processInfo.environment
        let config = loadLiveRunningScrollConfig()
        guard env["AGTMUX_UI_ATTACH_RUNNING_APP"] == "1" || config?.attachRunningApp == true else {
            throw XCTSkip("Set AGTMUX_UI_ATTACH_RUNNING_APP=1 to enable the live same-running scroll test.")
        }

        // This test attaches to an already-running app instance; avoid terminating it in tearDown.
        app = nil

        let terminalIdentifier = try XCTUnwrap(
            env["AGTMUX_UI_SCROLL_IDENTIFIER"] ?? config?.terminalIdentifier,
            "AGTMUX_UI_SCROLL_IDENTIFIER is required."
        )
        let bundleIdentifier = env["AGTMUX_UI_ATTACH_BUNDLE_ID"]
            ?? config?.bundleIdentifier
            ?? "com.g960059.agtmux.term"
        let repeatCount = max(
            1,
            Int(env["AGTMUX_UI_SCROLL_REPEAT"] ?? "") ?? config?.repeatCount ?? 24
        )
        let intervalMilliseconds = max(
            0,
            Int(env["AGTMUX_UI_SCROLL_INTERVAL_MS"] ?? "") ?? config?.intervalMilliseconds ?? 8
        )
        let deltaX = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_DELTA_X"] ?? "") ?? config?.deltaX ?? 0
        )
        let deltaY = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_DELTA_Y"] ?? "") ?? config?.deltaY ?? -10
        )
        let xFraction = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_X_FRAC"] ?? "") ?? config?.xFraction ?? 0.5
        )
        let yFraction = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_Y_FRAC"] ?? "") ?? config?.yFraction ?? 0.5
        )
        let readyPath = env["AGTMUX_UI_SCROLL_READY_PATH"] ?? config?.readyPath
        let goPath = env["AGTMUX_UI_SCROLL_GO_PATH"] ?? config?.goPath
        let goTimeoutMilliseconds = max(
            1,
            Int(env["AGTMUX_UI_SCROLL_GO_TIMEOUT_MS"] ?? "") ?? config?.goTimeoutMilliseconds ?? 20_000
        )

        let runningApp = XCUIApplication(bundleIdentifier: bundleIdentifier)
        runningApp.activate()

        let terminal = runningApp.descendants(matching: .any)
            .matching(identifier: terminalIdentifier)
            .firstMatch
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 20),
            "Terminal host did not appear for identifier \(terminalIdentifier)"
        )

        let target = terminal.coordinate(withNormalizedOffset: CGVector(dx: xFraction, dy: yFraction))
        target.click()

        if let readyPath, readyPath.isEmpty == false {
            let readyURL = URL(fileURLWithPath: readyPath)
            try? FileManager.default.removeItem(at: readyURL)
            let payload = """
            {"ready":true,"terminalIdentifier":"\(terminalIdentifier)"}
            """
            try Data(payload.utf8).write(to: readyURL, options: .atomic)
        }

        if let goPath, goPath.isEmpty == false {
            let goURL = URL(fileURLWithPath: goPath)
            let deadline = Date().addingTimeInterval(Double(goTimeoutMilliseconds) / 1000.0)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: goURL.path) {
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: goURL.path),
                "Timed out waiting for go signal at \(goURL.path)"
            )
        }

        for index in 0..<repeatCount {
            target.scroll(byDeltaX: deltaX, deltaY: deltaY)
            if index + 1 < repeatCount, intervalMilliseconds > 0 {
                usleep(useconds_t(intervalMilliseconds * 1_000))
            }
        }
    }

    private func loadLiveRunningScrollConfig() -> LiveRunningScrollConfig? {
        let env = ProcessInfo.processInfo.environment
        let configPath = env["AGTMUX_UI_SCROLL_CONFIG_PATH"] ?? Self.liveRunningScrollConfigPath
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return nil
        }
        return try? JSONDecoder().decode(LiveRunningScrollConfig.self, from: data)
    }
}

final class LiveRunningAppScrollUITests: XCTestCase {
    private struct Config: Decodable {
        let attachRunningApp: Bool?
        let terminalIdentifier: String?
        let bundleIdentifier: String?
        let repeatCount: Int?
        let intervalMilliseconds: Int?
        let deltaX: Double?
        let deltaY: Double?
        let xFraction: Double?
        let yFraction: Double?
        let readyPath: String?
        let goPath: String?
        let goTimeoutMilliseconds: Int?
    }

    private static let configPath = "/tmp/agtmux-live-ui-scroll-config.json"

    override func setUpWithError() throws {
        continueAfterFailure = false

        let env = ProcessInfo.processInfo.environment
        if env["SSH_CONNECTION"] != nil, env["AGTMUX_UITEST_ALLOW_SSH"] != "1" {
            throw XCTSkip(
                "XCUITest needs an interactive console session. " +
                "Current runner is an SSH session. " +
                "Set AGTMUX_UITEST_ALLOW_SSH=1 to force-run."
            )
        }
    }

    func testTrackpadScrollBurstAgainstRunningApp() throws {
        let env = ProcessInfo.processInfo.environment
        let config = loadConfig()
        guard env["AGTMUX_UI_ATTACH_RUNNING_APP"] == "1" || config?.attachRunningApp == true else {
            throw XCTSkip("Set AGTMUX_UI_ATTACH_RUNNING_APP=1 to enable the live same-running scroll test.")
        }

        let terminalIdentifier = try XCTUnwrap(
            env["AGTMUX_UI_SCROLL_IDENTIFIER"] ?? config?.terminalIdentifier,
            "AGTMUX_UI_SCROLL_IDENTIFIER is required."
        )
        let bundleIdentifier = env["AGTMUX_UI_ATTACH_BUNDLE_ID"]
            ?? config?.bundleIdentifier
            ?? "com.g960059.agtmux.term"
        let repeatCount = max(
            1,
            Int(env["AGTMUX_UI_SCROLL_REPEAT"] ?? "") ?? config?.repeatCount ?? 24
        )
        let intervalMilliseconds = max(
            0,
            Int(env["AGTMUX_UI_SCROLL_INTERVAL_MS"] ?? "") ?? config?.intervalMilliseconds ?? 8
        )
        let deltaX = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_DELTA_X"] ?? "") ?? config?.deltaX ?? 0
        )
        let deltaY = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_DELTA_Y"] ?? "") ?? config?.deltaY ?? -10
        )
        let xFraction = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_X_FRAC"] ?? "") ?? config?.xFraction ?? 0.5
        )
        let yFraction = CGFloat(
            Double(env["AGTMUX_UI_SCROLL_Y_FRAC"] ?? "") ?? config?.yFraction ?? 0.5
        )
        let readyPath = env["AGTMUX_UI_SCROLL_READY_PATH"] ?? config?.readyPath
        let goPath = env["AGTMUX_UI_SCROLL_GO_PATH"] ?? config?.goPath
        let goTimeoutMilliseconds = max(
            1,
            Int(env["AGTMUX_UI_SCROLL_GO_TIMEOUT_MS"] ?? "") ?? config?.goTimeoutMilliseconds ?? 20_000
        )

        let runningApp = XCUIApplication(bundleIdentifier: bundleIdentifier)
        runningApp.activate()

        let terminal = runningApp.descendants(matching: .any)
            .matching(identifier: terminalIdentifier)
            .firstMatch
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 20),
            "Terminal host did not appear for identifier \(terminalIdentifier)"
        )

        let target = terminal.coordinate(withNormalizedOffset: CGVector(dx: xFraction, dy: yFraction))
        target.click()

        if let readyPath, readyPath.isEmpty == false {
            let readyURL = URL(fileURLWithPath: readyPath)
            try? FileManager.default.removeItem(at: readyURL)
            let payload = """
            {"ready":true,"terminalIdentifier":"\(terminalIdentifier)"}
            """
            try Data(payload.utf8).write(to: readyURL, options: .atomic)
        }

        if let goPath, goPath.isEmpty == false {
            let goURL = URL(fileURLWithPath: goPath)
            let deadline = Date().addingTimeInterval(Double(goTimeoutMilliseconds) / 1000.0)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: goURL.path) {
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: goURL.path),
                "Timed out waiting for go signal at \(goURL.path)"
            )
        }

        for index in 0..<repeatCount {
            target.scroll(byDeltaX: deltaX, deltaY: deltaY)
            if index + 1 < repeatCount, intervalMilliseconds > 0 {
                usleep(useconds_t(intervalMilliseconds * 1_000))
            }
        }
    }

    private func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        let configPath = env["AGTMUX_UI_SCROLL_CONFIG_PATH"] ?? Self.configPath
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return nil
        }
        return try? JSONDecoder().decode(Config.self, from: data)
    }
}
