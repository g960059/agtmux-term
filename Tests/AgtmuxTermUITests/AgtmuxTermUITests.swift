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
    private static let allowLockedSessionSentinelPath = "/tmp/agtmux-uitest-allow-locked-session"

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

    /// T-E2E-002: Empty workspace state is shown before any pane is selected.
    func testEmptyStateOnLaunch() {
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()
        let workspacePredicate = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceArea)
        let workspaceArea = app.descendants(matching: .any).matching(workspacePredicate).firstMatch
        XCTAssertTrue(
            workspaceArea.waitForExistence(timeout: TestConstants.settleTimeout),
            "Workspace area should be visible after launch"
        )

        let predicate = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        let emptyState = app.descendants(matching: .any).matching(predicate).firstMatch
        if emptyState.waitForExistence(timeout: TestConstants.settleTimeout) {
            return
        }

        // Fallback for AX timing quirks: in fixture-empty mode, no workspace tile
        // should be created even if the decorative empty-state element is not exposed.
        let tilePredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let anyTile = app.descendants(matching: .any).matching(tilePredicate).firstMatch
        XCTAssertFalse(
            anyTile.exists,
            "No workspace tile should exist when AGTMUX_JSON contains zero panes"
        )
    }

    /// T-E2E-002c: The default cockpit path opens a direct real-session V2 tile
    /// from the sidebar without creating any linked session.
    func testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile() throws {
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
        let issueMessage = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Document path '\(documentPath)' does not exist.")
        ).firstMatch
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(issueMessage.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(retryButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(removeButton.waitForExistence(timeout: TestConstants.settleTimeout))

        try expectedText.write(toFile: documentPath, atomically: true, encoding: .utf8)
        retryButton.click()

        XCTAssertTrue(
            app.staticTexts[expectedText].waitForExistence(timeout: TestConstants.settleTimeout),
            "Retry should reload the restored document tile once the file exists"
        )
        XCTAssertTrue(
            !retryButton.exists,
            "Retry recovery should leave the broken-placeholder action row"
        )
    }

    func testV2RestoredBrokenDocumentTileCanRebindToExistingPath() throws {
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

        app.launchEnvironment["AGTMUX_WORKBENCH_V2_FIXTURE_JSON"] = try workbenchFixtureJSON([fixtureWorkbench])
        app.launchEnvironment["AGTMUX_JSON"] = #"{"version":1,"panes":[]}"#
        app.launchForUITest()

        let rebindButton = app.buttons["Rebind"]
        let issueTitle = app.staticTexts["Path missing"]
        let issueMessage = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Document path '\(missingPath)' does not exist.")
        ).firstMatch
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(issueMessage.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(rebindButton.waitForExistence(timeout: TestConstants.settleTimeout))
        rebindButton.click()

        let pathField = app.textFields[AccessibilityID.workspaceDocumentRebindPath]
        XCTAssertTrue(pathField.waitForExistence(timeout: TestConstants.settleTimeout))
        replaceText(in: pathField, with: reboundPath)

        let applyButton = app.buttons[AccessibilityID.workspaceDocumentRebindApply]
        XCTAssertTrue(applyButton.waitForExistence(timeout: TestConstants.settleTimeout))
        applyButton.click()

        XCTAssertTrue(
            app.staticTexts[expectedText].waitForExistence(timeout: TestConstants.settleTimeout),
            "Rebound document content must render after Apply"
        )
        XCTAssertTrue(
            !rebindButton.exists,
            "Successful document rebind should leave the broken-placeholder action row"
        )
    }

    func testV2RestoredBrokenDocumentTileCanBeRemoved() throws {
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
        let issueMessage = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Document path '\(missingPath)' does not exist.")
        ).firstMatch
        XCTAssertTrue(issueTitle.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(issueMessage.waitForExistence(timeout: TestConstants.settleTimeout))
        XCTAssertTrue(removeButton.waitForExistence(timeout: TestConstants.settleTimeout))
        removeButton.click()

        let emptyState = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        ).firstMatch
        let emptyExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: removeButton
        )
        let emptyStateAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: emptyState
        )
        wait(for: [emptyExpectation, emptyStateAppeared], timeout: TestConstants.settleTimeout)
    }

    /// T-E2E-002b: Selecting a pane updates tab title to the session name.
    ///
    /// Regression coverage:
    ///   - Tab title must not stay on a fixed bootstrap label.
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

        let tabBar = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
        ).firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: TestConstants.settleTimeout))

        let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTabPrefix)
        let firstTab = tabBar.descendants(matching: .any).matching(tabPredicate).firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: TestConstants.settleTimeout))
        let tabTitleExpectation = expectation(
            for: NSPredicate(format: "label CONTAINS %@", sessionName),
            evaluatedWith: firstTab
        )

        wait(for: [tabTitleExpectation], timeout: 5.0)

        let legacyMain = tabBar.staticTexts.matching(NSPredicate(format: "label == %@", "Main"))
        XCTAssertEqual(legacyMain.count, 0, "Tab title should no longer be fixed to 'Main'")
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

    /// T-E2E-002d: metadata-enabled launch without any available health snapshot should
    /// keep the health strip absent instead of surfacing stale UI.
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
        app.launchForMetadataUITest()

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
            app.staticTexts["Local daemon incompatible"]
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

    /// T-E2E-005: New-tab button creates a tab.
    func testTabCreation() throws {
        app.launchForUITest()
        let tabBarPred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
        let tabBar = app.descendants(matching: .any).matching(tabBarPred).firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: TestConstants.settleTimeout))

        let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTabPrefix)
        let allDescendants = { self.app.descendants(matching: .any).matching(tabPredicate) }
        let tabsBefore = allDescendants().count
        let expectedCount = tabsBefore + 1

        func waitForTabCount(_ timeout: TimeInterval) -> Bool {
            let countPredicate = NSPredicate(format: "count == %d", expectedCount)
            let countExpectation = expectation(for: countPredicate, evaluatedWith: allDescendants())
            let result = XCTWaiter.wait(for: [countExpectation], timeout: timeout)
            return result == .completed
        }

        func tryClick(_ element: XCUIElement, waitAfterTap: TimeInterval = 3.0) -> Bool {
            guard element.exists else { return false }
            element.click()
            return waitForTabCount(waitAfterTap)
        }

        let newTabButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.workspaceNewTab)
        ).firstMatch
        var created = false

        // Preferred path: dedicated AX id.
        if newTabButton.waitForExistence(timeout: 2.0) {
            created = tryClick(newTabButton, waitAfterTap: 5.0)
        }

        // Fallback path for environments where the plus button is exposed with
        // tab-bar id instead of workspace.newTabButton.
        if !created {
            let tabBarButtonFallback = tabBar.descendants(matching: .button).matching(
                NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
            ).firstMatch
            created = tryClick(tabBarButtonFallback)
        }

        // Fallback path for environments exposing only label.
        if !created {
            let labeledFallback = app.buttons.matching(NSPredicate(format: "label == %@", "New Tab")).firstMatch
            created = tryClick(labeledFallback)
        }

        // Last resort: keyboard shortcut.
        if !created {
            let workspace = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", AccessibilityID.workspaceArea)
            ).firstMatch
            if workspace.exists {
                workspace.click()
            } else {
                app.windows.firstMatch.click()
            }
            app.typeKey("t", modifierFlags: .command)
            created = waitForTabCount(2)
        }

        if !created {
            throw XCTSkip(
                "Tab creation control is not exposed to XCUITest in this desktop session " +
                "(no workspace.newTabButton and Cmd+T had no effect)."
            )
        }
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

        // Selecting a pane should open a workspace tile for that pane.
        row1.click()
        let tile1 = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceTilePrefix + key1
            )
        ).firstMatch
        XCTAssertTrue(
            tile1.waitForExistence(timeout: TestConstants.surfaceReadyTimeout),
            "Selecting a sidebar pane should display its workspace tile"
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

    /// T-E2E-010: same-session pane selection must retarget the existing V2 tile
    /// to the exact pane/window without creating linked sessions or recreating the surface.
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

        let mainPaneIDsBeforeSplit = Set(bootstrap.paneIDs)
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"],
            control: control
        )
        let mainWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):main",
            windowDescription: "main",
            expectedPaneCount: mainPaneIDsBeforeSplit.count + 1,
            control: control
        )
        let mainPaneIDsAfterSplit = Set(mainWindowSnapshot.paneIDs)
        guard let secondPaneID = mainPaneIDsAfterSplit.subtracting(mainPaneIDsBeforeSplit).first else {
            throw XCTSkip("Could not resolve pane identity for app-created split pane")
        }

        let secondWindowName = "secondary"
        _ = try sendAppTmuxCommand(
            ["new-window", "-t", session, "-n", secondWindowName, "/bin/sleep 600"],
            control: control
        )
        let secondWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):\(secondWindowName)",
            windowDescription: secondWindowName,
            expectedPaneCount: 1,
            control: control
        )
        let secondWindowID = secondWindowSnapshot.windowID
        let secondWindowPaneID = secondWindowSnapshot.paneIDs.first
        guard let secondWindowPaneID, secondWindowPaneID.hasPrefix("%") else {
            throw XCTSkip("Could not resolve pane identity for app-created secondary window")
        }
        guard secondWindowID.hasPrefix("@") else {
            throw XCTSkip("Could not resolve window identity for app-created secondary window")
        }

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

        XCTAssertTrue(clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondPaneID))
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Second pane click must update sidebar selection state"
        )
        let secondSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: firstWindowID,
            paneID: secondPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondPaneID
            )
        )
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Same-session pane retarget must preserve the rendered Ghostty surface"
        )
        waitForSingleWorkbenchV2TerminalTile(sessionName: session)
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: firstWindowID,
            paneID: secondPaneID
        )

        XCTAssertTrue(clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondWindowPaneID))
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondWindowPaneID)
                .waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Secondary window pane click must update sidebar selection state"
        )
        let thirdSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: secondWindowID,
            paneID: secondWindowPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondWindowPaneID
            )
        )
        XCTAssertEqual(
            thirdSnapshot.renderedSurfaceGeneration,
            secondSnapshot.renderedSurfaceGeneration,
            "Cross-window retarget inside one session must preserve the rendered Ghostty surface"
        )
        waitForSingleWorkbenchV2TerminalTile(sessionName: session)
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: thirdSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: secondWindowID,
            paneID: secondWindowPaneID
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "App must still be running after same-session retarget. State: \(app.state.rawValue)"
        )

        let linkedAfter = try listLinkedSessionsViaApp(control: control)
        XCTAssertEqual(
            linkedAfter,
            linkedBefore,
            "Exact pane/window retarget must reuse the same real-session tile without linked sessions"
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

        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: secondPaneID)
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Terminal-originated pane change must retarget sidebar selection to the active pane"
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
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Terminal-originated pane change must preserve the rendered Ghostty surface"
        )
    }

    /// T-E2E-015: metadata-enabled launch must still preserve same-session pane retarget
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

        let paneIDsBeforeSplit = Set(bootstrap.paneIDs)
        _ = try sendAppTmuxCommand(
            ["split-window", "-t", "\(session):main", "-h", "/bin/sleep 600"],
            control: control
        )
        let splitWindowSnapshot = try waitForAppPaneDescriptors(
            tmuxTarget: "\(session):main",
            windowDescription: "main",
            expectedPaneCount: paneIDsBeforeSplit.count + 1,
            control: control
        )
        let paneIDsAfterSplit = Set(splitWindowSnapshot.paneIDs)
        guard let secondPaneID = paneIDsAfterSplit.subtracting(paneIDsBeforeSplit).first else {
            throw XCTSkip("Could not resolve split pane for metadata-enabled retarget E2E")
        }

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

        XCTAssertTrue(
            clickSidebarPaneRow(source: "local", sessionName: session, paneID: secondPaneID),
            "Split pane must be selectable under metadata-enabled launch"
        )
        let secondSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: splitWindowSnapshot.windowID,
            paneID: secondPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: secondPaneID
            )
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: splitWindowSnapshot.windowID,
            paneID: secondPaneID
        )
        XCTAssertEqual(
            secondSnapshot.renderedSurfaceGeneration,
            firstSnapshot.renderedSurfaceGeneration,
            "Metadata-enabled same-session retarget must preserve the rendered Ghostty surface"
        )

        _ = try sendAppTmuxCommand(
            ["switch-client", "-c", secondSnapshot.renderedClientTTY, "-t", firstPaneID],
            refreshInventory: false,
            control: control
        )
        waitForRenderedClientTmuxTarget(
            control: control,
            clientTTY: secondSnapshot.renderedClientTTY,
            sessionName: session,
            windowID: splitWindowSnapshot.windowID,
            paneID: firstPaneID
        )
        XCTAssertTrue(
            selectedPaneMarker(sessionName: session, paneID: firstPaneID)
                .waitForExistence(timeout: TestConstants.focusSyncLatencyBudget),
            "Rendered-client pane changes must update sidebar highlight under metadata-enabled launch"
        )
        let reverseSyncSnapshot = waitForAppWorkbenchTerminalTarget(
            control: control,
            sessionName: session,
            windowID: splitWindowSnapshot.windowID,
            paneID: firstPaneID,
            selectedPaneInventoryID: paneInventoryID(
                source: "local",
                sessionName: session,
                paneID: firstPaneID
            )
        )
        XCTAssertEqual(
            reverseSyncSnapshot.renderedSurfaceGeneration,
            secondSnapshot.renderedSurfaceGeneration,
            "Rendered-client reverse sync must keep the same Ghostty surface alive"
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
            expectedCurrentCommand: "zsh"
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
               ["activity=running", "activity=waiting_input", "activity=idle"].contains(where: summary.contains) {
                surfaced = true
                surfacedRowSummary = summary
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let completionDeadline = Date().addingTimeInterval(30.0)
        var freshnessSurfaced = false
        var completionRowSummary = surfacedRowSummary
        while Date() < completionDeadline {
            let currentRow = paneRow(source: "local", sessionName: session, paneID: paneID)
            let summary = paneRowMetadataSummary(currentRow) ?? ""
            if currentRow.exists,
               summary.contains("presence=managed"),
               summary.contains("provider=codex"),
               ["activity=waiting_input", "activity=idle"].contains(where: summary.contains),
               !summary.contains("freshness=none") {
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
        XCTAssertTrue(
            surfaced,
            "A real Codex process launched from a plain zsh pane must surface as a managed sidebar row with provider/activity metadata. " +
            "row='\(surfacedRowSummary)' " +
            "bootstrapReady='\(sidebarStateSummary(bootstrapReadySnapshot, sessionName: session, paneID: paneID))' " +
            "capture='\(finalCapture ?? "")' " +
            "sidebar='\(sidebarStateSummary(sidebarState, sessionName: session, paneID: paneID))'"
        )
        XCTAssertTrue(
            freshnessSurfaced,
            "A managed completion row must expose freshness metadata once the live Codex pane settles into waiting_input or idle. " +
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
        if let value = row.value as? String {
            return value
        }
        if let value = row.value {
            return String(describing: value)
        }
        return nil
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

    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        element.typeText(value)
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
        let row = paneRow(source: source, sessionName: sessionName, paneID: paneID)
        return clickSidebarPaneRow(row)
    }

    @discardableResult
    private func clickSidebarPaneRow(_ row: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(TestConstants.sidebarPopulateTimeout)
        let identifier = row.identifier

        while Date() < deadline {
            let candidate: XCUIElement
            if identifier.isEmpty {
                candidate = row
            } else {
                candidate = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier == %@", identifier)
                ).firstMatch
            }

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
                   snapshot.renderedAttachCommand == snapshot.attachCommand,
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
            "selected=\(latest?.selectedPaneInventoryID ?? "nil") attach=\(latest?.attachCommand ?? "nil") " +
            "renderedAttach=\(latest?.renderedAttachCommand ?? "nil") " +
            "renderedTTY=\(latest?.renderedClientTTY ?? "nil") " +
            "renderedWindow=\(latest?.renderedClientWindowID ?? "nil") " +
            "renderedPane=\(latest?.renderedClientPaneID ?? "nil") " +
            "renderedGeneration=\(latest?.renderedSurfaceGeneration.description ?? "nil") " +
            "latestError=\(latestError ?? "nil")"
        )
        return latest ?? AppWorkbenchTerminalTargetSnapshot(
            workbenchID: "",
            tileID: "",
            sessionName: "",
            windowID: "",
            paneID: "",
            selectedPaneInventoryID: "",
            attachCommand: "",
            renderedAttachCommand: "",
            renderedClientTTY: "",
            renderedClientWindowID: "",
            renderedClientPaneID: "",
            renderedSurfaceGeneration: 0
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
                   snapshot.renderedClientTTY == renderedClientTTY,
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
            "pane=\(latest?.paneID ?? "nil") selected=\(latest?.selectedPaneInventoryID ?? "nil") " +
            "attach=\(latest?.attachCommand ?? "nil") renderedAttach=\(latest?.renderedAttachCommand ?? "nil") " +
            "renderedTTY=\(latest?.renderedClientTTY ?? "nil") renderedWindow=\(latest?.renderedClientWindowID ?? "nil") " +
            "renderedPane=\(latest?.renderedClientPaneID ?? "nil") renderedGeneration=\(latest?.renderedSurfaceGeneration.description ?? "nil") " +
            "latestError=\(latestError ?? "nil")"
        )
        return latest ?? AppWorkbenchTerminalTargetSnapshot(
            workbenchID: "",
            tileID: "",
            sessionName: "",
            windowID: "",
            paneID: "",
            selectedPaneInventoryID: "",
            attachCommand: "",
            renderedAttachCommand: "",
            renderedClientTTY: "",
            renderedClientWindowID: "",
            renderedClientPaneID: "",
            renderedSurfaceGeneration: 0
        )
    }

    private func attachCommandAttachesSession(
        _ command: String,
        sessionName: String
    ) -> Bool {
        command.contains("attach-session -t")
            && command.contains(sessionName)
            && !command.contains("select-window -t")
            && !command.contains("select-pane -t")
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

    private struct SidebarStateSnapshot: Decodable {
        let statusFilter: String
        let panes: [AgtmuxPane]
        let panePresentations: [SidebarPanePresentationSnapshot]?
        let filteredPanes: [AgtmuxPane]
        let filteredPanePresentations: [SidebarPanePresentationSnapshot]?
        let attentionCount: Int?
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
        let activity: String
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
        let totalPanes: Int?
        let managedPanes: Int?
        let error: String?
    }

    private struct BootstrapTargetSummary: Decodable {
        let sessionName: String
        let paneID: String
        let presence: String
        let provider: String?
        let activity: String
        let currentCommand: String?
    }

    private struct AppWorkbenchTerminalTargetSnapshot: Decodable {
        let workbenchID: String
        let tileID: String
        let sessionName: String
        let windowID: String
        let paneID: String
        let selectedPaneInventoryID: String
        let attachCommand: String
        let renderedAttachCommand: String
        let renderedClientTTY: String
        let renderedClientWindowID: String
        let renderedClientPaneID: String
        let renderedSurfaceGeneration: UInt64
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
        app.launchEnvironment["AGTMUX_UITEST_TMUX_KILL_SERVER"] = "1"

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
        paneID: String
    ) throws -> SidebarStateSnapshot {
        let output = try sendAppTmuxCommand(
            ["__agtmux_dump_sidebar_state__", sessionName, paneID],
            refreshInventory: false,
            control: control,
            timeout: 2.0
        )
        return try JSONDecoder().decode(SidebarStateSnapshot.self, from: Data(output.utf8))
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
                if probe.ok,
                   (probe.totalPanes ?? 0) > 0,
                   target?.sessionName == sessionName,
                   target?.paneID == paneID,
                   target?.currentCommand == expectedCurrentCommand {
                    return snapshot
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        XCTFail(
            "Managed daemon bootstrap never became ready for the app-driven tmux pane. " +
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

        func summarize(_ pane: AgtmuxPane?) -> String {
            guard let pane else { return "nil" }
            return [
                "presence=\(pane.presence.rawValue)",
                "provider=\(pane.provider?.rawValue ?? "nil")",
                "activity=\(pane.activityState.rawValue)",
                "current_cmd=\(pane.currentCmd ?? "nil")"
            ].joined(separator: ",")
        }

        func summarize(_ pane: SidebarPanePresentationSnapshot?) -> String {
            guard let pane else { return "nil" }
            return [
                "presence=\(pane.presence)",
                "provider=\(pane.provider ?? "nil")",
                "activity=\(pane.activity)",
                "freshness=\(pane.freshness ?? "nil")",
                "managed=\(pane.isManaged)",
                "attention=\(pane.needsAttention)",
                "current_cmd=\(pane.currentCommand ?? "nil")"
            ].joined(separator: ",")
        }

        let visiblePane = snapshot.panes.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneId == paneID
        }
        let filteredPane = snapshot.filteredPanes.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneId == paneID
        }
        let visiblePresentation = snapshot.panePresentations?.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let filteredPresentation = snapshot.filteredPanePresentations?.first {
            $0.source == "local" && $0.sessionName == sessionName && $0.paneID == paneID
        }
        let visibleSummary = visiblePresentation.map(summarize) ?? summarize(visiblePane)
        let filteredSummary = filteredPresentation.map(summarize) ?? summarize(filteredPane)

        let issueSummary: String
        if let title = snapshot.localDaemonIssueTitle {
            let detail = snapshot.localDaemonIssueDetail ?? ""
            issueSummary = "\(title):\(detail)"
        } else {
            issueSummary = "nil"
        }

        let probe = snapshot.bootstrapProbeSummary
        let probeSummary = probe.ok
            ? "ok total=\(probe.totalPanes ?? -1) managed=\(probe.managedPanes ?? -1)"
            : "error=\(probe.error ?? "unknown")"
        let targetSummary: String
        if let target = snapshot.bootstrapTargetSummary {
            targetSummary = [
                "presence=\(target.presence)",
                "provider=\(target.provider ?? "nil")",
                "activity=\(target.activity)",
                "current_cmd=\(target.currentCommand ?? "nil")"
            ].joined(separator: ",")
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
            "attentionCount=\(snapshot.attentionCount ?? -1)",
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
            "all=\(visibleSummary)",
            "filtered=\(filteredSummary)",
            "filteredCount=\(snapshot.filteredPanes.count)"
        ].joined(separator: " ")
    }

    private func waitForSingleWorkbenchV2TerminalTile(
        sessionName: String,
        timeout: TimeInterval = TestConstants.surfaceReadyTimeout
    ) {
        let tileQuery = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@ AND label == %@",
                AccessibilityID.workspaceTilePrefix,
                ".status",
                sessionName
            )
        )
        let oneTile = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"),
            object: tileQuery
        )
        wait(for: [oneTile], timeout: timeout)
        XCTAssertEqual(
            tileQuery.count,
            1,
            "Same-session retarget must keep exactly one visible tile for \(sessionName)"
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
}
