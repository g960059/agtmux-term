import XCTest
import AgtmuxTermCore

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

    private var app: XCUIApplication!
    private var tmuxPath: String? = nil
    /// Sessions that existed before the test started — never delete these.
    private var preExistingSessions: Set<String> = []
    /// Sessions explicitly created by this test via `createTrackedTmuxSession`.
    private var ownedSessions: Set<String> = []

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false
        ownedSessions = []

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
        app.launchForUITest()
        let predicate = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        let emptyState = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: TestConstants.settleTimeout),
            "Empty state should be visible when no pane is selected"
        )
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

    /// T-E2E-005: New-tab button creates a tab.
    func testTabCreation() {
        app.launchForUITest()
        let tabBarPred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceTabBar)
        let tabBar = app.descendants(matching: .any).matching(tabBarPred).firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: TestConstants.settleTimeout))

        let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTabPrefix)
        let allDescendants = { self.app.descendants(matching: .any).matching(tabPredicate) }
        let tabsBefore = allDescendants().count

        let newTabButton = app.buttons.matching(NSPredicate(format: "label == %@", "New Tab")).firstMatch
        XCTAssertTrue(
            newTabButton.waitForExistence(timeout: TestConstants.settleTimeout),
            "New Tab (+) button should be visible in the tab bar"
        )
        newTabButton.click()

        let expectedCount = tabsBefore + 1
        let countPredicate = NSPredicate(format: "count == %d", expectedCount)
        let countExpectation = expectation(for: countPredicate, evaluatedWith: allDescendants())
        wait(for: [countExpectation], timeout: 5)
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

        // Selecting a pane should replace the workspace empty state.
        assertWorkspaceStartsEmpty()
        row1.click()
        waitForWorkspaceToLeaveEmptyState()
    }

    /// T-E2E-008: agtmux-linked-* sessions are filtered; real agtmux-* sessions remain visible.
    ///
    /// Regression test for T-056 (status dots hidden bug):
    ///   - Old bug: filter `hasPrefix("agtmux-")` removed real user sessions
    ///   - Fix: filter `hasPrefix("agtmux-linked-")` removes only internal linked sessions
    ///
    /// Mock returns two panes with the same pane_id in two sessions:
    ///   - "agtmux-REAL-UUID" (real user session → must appear, 1 row)
    ///   - "agtmux-linked-UUID" (internal linked session → must NOT appear)
    func testLinkedSessionsHiddenRealSessionsVisible() throws {
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

        let key = AccessibilityID.paneKey(
            source: "local",
            sessionName: realSession,
            paneID: sharedPaneID
        )
        let pred = NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)

        // The real session pane must appear
        let firstRow = app.descendants(matching: .any).matching(pred).firstMatch
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Real agtmux-* session pane must appear (T-056 regression). AX id: \(AccessibilityID.sidebarPanePrefix + key)"
        )

        // Exactly ONE row must exist — the linked-session duplicate must be filtered
        let allRows = app.descendants(matching: .any).matching(pred).allElementsBoundByIndex
        XCTAssertEqual(
            allRows.count, 1,
            "agtmux-linked-* pane must be filtered: expected 1 row, got \(allRows.count). " +
            "Multi-highlight regression (T-054) or filter regression (T-056)."
        )
    }

    /// T-E2E-008b: session-group aliases are canonicalized and duplicate pane rows collapse.
    ///
    /// Two raw sessions sharing the same pane and session_group must render as one row
    /// under the canonical group name.
    func testSessionGroupAliasSessionsAreDeduplicated() throws {
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
        let rowPredicate = NSPredicate(
            format: "identifier == %@",
            AccessibilityID.sidebarPanePrefix + canonicalKey
        )
        let rows = app.descendants(matching: .any).matching(rowPredicate).allElementsBoundByIndex

        XCTAssertEqual(
            rows.count, 1,
            "Aliased sessions in the same group must collapse to one sidebar pane row"
        )

        let rawKeyA = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionA,
            paneID: sharedPaneID
        )
        let rawKeyB = AccessibilityID.paneKey(
            source: "local",
            sessionName: sessionB,
            paneID: sharedPaneID
        )
        let rawRowsA = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + rawKeyA)
        ).allElementsBoundByIndex
        let rawRowsB = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + rawKeyB)
        ).allElementsBoundByIndex
        XCTAssertEqual(rawRowsA.count, 0, "Raw alias session A should be hidden after normalization")
        XCTAssertEqual(rawRowsB.count, 0, "Raw alias session B should be hidden after normalization")
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
        let managedTabButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Managed")).firstMatch
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
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping local session reflection test")
        }
        guard (try? listTmuxSessions(tmux)) != nil else {
            throw XCTSkip("tmux socket not accessible from runner — skipping local session reflection test")
        }

        app.launchEnvironment.removeValue(forKey: "AGTMUX_JSON")
        app.launchForUITest()

        let session = try createTrackedTmuxSession(prefix: "agtmux-e2e-session-reflect", tmux: tmux)
        let paneOut = try shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}"])
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

    /// T-E2E-010: Selecting a mock-daemon pane backed by a real tmux session creates a terminal tile.
    ///
    /// Flow:
    ///   1. Create real tmux session (so LinkedSessionManager can create a linked session)
    ///   2. Get the real pane ID and window ID from that session
    ///   3. Mock daemon returns that pane
    ///   4. Click the sidebar row
    ///   5. Terminal tile must appear and app must not crash
    func testPaneSelectionWithMockDaemonAndRealTmux() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping terminal tile test")
        }

        // Create a tracked tmux session so tearDown can always cleanup session + agents.
        let realSession = try createTrackedTmuxSession(prefix: "agtmux-e2e-tile", tmux: tmux)

        // Get real pane ID
        let paneOut = try shellOutput([tmux, "list-panes", "-t", realSession, "-F", "#{pane_id}"])
        guard let realPaneID = paneOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw XCTSkip("Could not get pane ID from test session")
        }

        // Get real window ID
        let winOut = try shellOutput([tmux, "list-windows", "-t", realSession, "-F", "#{window_id}"])
        let realWindowID = winOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "@0"

        // Create mock daemon returning this real pane
        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(realPaneID)","session_name":"\(realSession)","window_id":"\(realWindowID)",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        // Wait for pane to appear in sidebar
        let key = AccessibilityID.paneKey(
            source: "local",
            sessionName: realSession,
            paneID: realPaneID
        )
        let panePred = NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)
        let paneRow = app.descendants(matching: .any).matching(panePred).firstMatch
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane \(realPaneID) from session '\(realSession)' must appear in sidebar. " +
            "AX id: \(AccessibilityID.sidebarPanePrefix + key)"
        )

        // Click the pane — should create a terminal tile
        assertWorkspaceStartsEmpty()
        paneRow.click()
        waitForWorkspaceToLeaveEmptyState()

        let tilePred = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let tile = app.otherElements.matching(tilePred).firstMatch
        XCTAssertTrue(
            tile.waitForExistence(timeout: TestConstants.surfaceReadyTimeout),
            "Terminal tile must appear after pane click. App may have crashed. " +
            "Tile AX prefix: \(AccessibilityID.workspaceTilePrefix)"
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "App must still be running after pane selection — crashed? State: \(app.state.rawValue)"
        )

        // Wait 3 seconds for deferred Metal crashes
        Thread.sleep(forTimeInterval: 3.0)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App crashed after surface creation (deferred Metal renderer crash)"
        )
    }

    /// T-E2E-011: Linked session status-left should preserve parent style/template
    /// while avoiding internal linked session-name leakage.
    ///
    /// Regression coverage:
    ///   - internal linked session names (`agtmux-linked-UUID`) should not leak into
    ///     tmux status title for user-facing terminals.
    ///   - LinkedSessionManager must preserve user status-left style, replacing only
    ///     session-name tokens with `#{session_group}`.
    func testLinkedSessionStatusTitleUsesParentSessionGroup() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping linked-session title test")
        }

        guard let existingSessions = try? listTmuxSessions(tmux) else {
            throw XCTSkip("tmux socket not accessible from runner — skipping linked-session title test")
        }
        let linkedBefore = existingSessions.filter { $0.hasPrefix("agtmux-linked-") }
        let realSession = try createTrackedTmuxSession(prefix: "agtmux-e2e-title", tmux: tmux)
        let parentStatusLeftTemplate = "#[fg=cyan,bg=black]#S #[fg=yellow,bold]tab#[default] ##S"
        let parentSetTitlesStringTemplate = "#S"
        _ = try shellRun([tmux, "set-option", "-t", realSession, "status-left", parentStatusLeftTemplate])
        _ = try shellRun([tmux, "set-option", "-t", realSession, "set-titles-string", parentSetTitlesStringTemplate])
        let expectedLinkedStatusLeft = "#[fg=cyan,bg=black]#{session_group} #[fg=yellow,bold]tab#[default] ##S"
        let expectedLinkedSetTitlesString = "#{session_group}"

        let paneOut = try shellOutput([tmux, "list-panes", "-t", realSession, "-F", "#{pane_id}"])
        guard let realPaneID = paneOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw XCTSkip("Could not get pane ID from test session")
        }

        let winOut = try shellOutput([tmux, "list-windows", "-t", realSession, "-F", "#{window_id}"])
        let realWindowID = winOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "@0"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(realPaneID)","session_name":"\(realSession)","window_id":"\(realWindowID)",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let key = AccessibilityID.paneKey(
            source: "local",
            sessionName: realSession,
            paneID: realPaneID
        )
        let panePred = NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)
        let paneRow = app.descendants(matching: .any).matching(panePred).firstMatch
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane \(realPaneID) from session '\(realSession)' must appear in sidebar"
        )

        assertWorkspaceStartsEmpty()
        paneRow.click()
        waitForWorkspaceToLeaveEmptyState()

        let tilePred = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let tile = app.otherElements.matching(tilePred).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: TestConstants.surfaceReadyTimeout))

        let linkedCreated = try waitForNewLinkedSessions(tmux: tmux, existing: linkedBefore, timeout: 5.0)
        XCTAssertFalse(
            linkedCreated.isEmpty,
            "Pane selection should create at least one linked session"
        )

        for linked in linkedCreated {
            let statusLeft = try shellOutput([tmux, "show-options", "-v", "-t", linked, "status-left"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                statusLeft, expectedLinkedStatusLeft,
                "Linked session '\(linked)' must preserve parent status-left style and rewrite only session token"
            )
            XCTAssertFalse(
                statusLeft.contains("agtmux-linked-"),
                "Linked session '\(linked)' must not leak internal linked session name in status-left template"
            )
            let setTitlesString = try shellOutput([tmux, "show-options", "-v", "-t", linked, "set-titles-string"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                setTitlesString, expectedLinkedSetTitlesString,
                "Linked session '\(linked)' must use session_group for set-titles-string"
            )
        }
    }

    /// T-E2E-011b: Parent session may inherit title templates from global options.
    /// Linked-session rewrite must use effective value (local or global), not local-only.
    func testLinkedSessionStatusTitleFallsBackToGlobalTemplate() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping linked-session global-template test")
        }

        guard let existingSessions = try? listTmuxSessions(tmux) else {
            throw XCTSkip("tmux socket not accessible from runner — skipping linked-session global-template test")
        }
        let linkedBefore = existingSessions.filter { $0.hasPrefix("agtmux-linked-") }
        let realSession = try createTrackedTmuxSession(prefix: "agtmux-e2e-title-global", tmux: tmux)

        let previousGlobalStatusLeft = try shellOutput([tmux, "show-options", "-gv", "status-left"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousGlobalSetTitlesString = try shellOutput([tmux, "show-options", "-gv", "set-titles-string"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            _ = try? shellRun([tmux, "set-option", "-g", "status-left", previousGlobalStatusLeft])
            _ = try? shellRun([tmux, "set-option", "-g", "set-titles-string", previousGlobalSetTitlesString])
        }

        let globalStatusLeftTemplate = "#[fg=green,bg=black]#S #[fg=magenta]global#[default]"
        let globalSetTitlesStringTemplate = "#S"
        _ = try shellRun([tmux, "set-option", "-g", "status-left", globalStatusLeftTemplate])
        _ = try shellRun([tmux, "set-option", "-g", "set-titles-string", globalSetTitlesStringTemplate])

        // Ensure parent session does not have local overrides.
        _ = try shellRun([tmux, "set-option", "-u", "-t", realSession, "status-left"])
        _ = try shellRun([tmux, "set-option", "-u", "-t", realSession, "set-titles-string"])

        let expectedLinkedStatusLeft = "#[fg=green,bg=black]#{session_group} #[fg=magenta]global#[default]"
        let expectedLinkedSetTitlesString = "#{session_group}"

        let paneOut = try shellOutput([tmux, "list-panes", "-t", realSession, "-F", "#{pane_id}"])
        guard let realPaneID = paneOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw XCTSkip("Could not get pane ID from test session")
        }

        let winOut = try shellOutput([tmux, "list-windows", "-t", realSession, "-F", "#{window_id}"])
        let realWindowID = winOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "@0"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(realPaneID)","session_name":"\(realSession)","window_id":"\(realWindowID)",
           "window_index":1,"window_name":"zsh","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let key = AccessibilityID.paneKey(
            source: "local",
            sessionName: realSession,
            paneID: realPaneID
        )
        let panePred = NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)
        let paneRow = app.descendants(matching: .any).matching(panePred).firstMatch
        XCTAssertTrue(
            paneRow.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout),
            "Pane \(realPaneID) from session '\(realSession)' must appear in sidebar"
        )

        assertWorkspaceStartsEmpty()
        paneRow.click()
        waitForWorkspaceToLeaveEmptyState()

        let tilePred = NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        let tile = app.otherElements.matching(tilePred).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: TestConstants.surfaceReadyTimeout))

        let linkedCreated = try waitForNewLinkedSessions(tmux: tmux, existing: linkedBefore, timeout: 5.0)
        XCTAssertFalse(linkedCreated.isEmpty, "Pane selection should create at least one linked session")

        for linked in linkedCreated {
            let statusLeft = try shellOutput([tmux, "show-options", "-v", "-t", linked, "status-left"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                statusLeft, expectedLinkedStatusLeft,
                "Linked session '\(linked)' must use effective(global) status-left template and rewrite session token"
            )
            XCTAssertFalse(
                statusLeft.contains("agtmux-linked-"),
                "Linked session '\(linked)' must not leak internal linked session name in status-left template"
            )
            let setTitlesString = try shellOutput([tmux, "show-options", "-v", "-t", linked, "set-titles-string"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                setTitlesString, expectedLinkedSetTitlesString,
                "Linked session '\(linked)' must use effective(global) set-titles-string template"
            )
        }
    }

    /// T-E2E-012: Main panel pane focus changes sync back to sidebar selection highlight.
    ///
    /// Flow:
    ///   1. Create a real tmux session with two panes in one window.
    ///   2. Mock daemon exposes both panes in sidebar.
    ///   3. Click a sidebar pane row to open it in workspace.
    ///   4. Run `tmux select-pane` to change active pane inside that window.
    ///   5. Sidebar selected row must follow the new active pane.
    func testMainPanelPaneFocusSyncsSidebarSelection() throws {
        guard let tmux = resolveTmuxPathBestEffort() else {
            throw XCTSkip("tmux not available — skipping pane-focus sync test")
        }
        guard let existingSessions = try? listTmuxSessions(tmux) else {
            throw XCTSkip("tmux socket not accessible from runner — skipping pane-focus sync test")
        }
        let linkedBefore = existingSessions.filter { $0.hasPrefix("agtmux-linked-") }

        let session = try createTrackedTmuxSession(prefix: "agtmux-e2e-focus-sync", tmux: tmux)

        _ = try shellRun([tmux, "split-window", "-t", session, "-h"])

        let panesOutput = try shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}"])
        let paneIDs = panesOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard paneIDs.count >= 2 else {
            throw XCTSkip("Need at least two panes in the test window")
        }
        let paneA = paneIDs[0]
        let paneB = paneIDs[1]

        let winOut = try shellOutput([tmux, "list-windows", "-t", session, "-F", "#{window_id}"])
        let windowID = winOut.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "@0"

        let json = """
        {"version":1,"panes":[
          {"pane_id":"\(paneA)","session_name":"\(session)","window_id":"\(windowID)",
           "window_index":1,"window_name":"focus-sync","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0},
          {"pane_id":"\(paneB)","session_name":"\(session)","window_id":"\(windowID)",
           "window_index":1,"window_name":"focus-sync","activity_state":"idle",
           "presence":"unmanaged","evidence_mode":"none",
           "current_cmd":"zsh","updated_at":"2026-03-04T00:00:00Z","age_secs":0}
        ]}
        """

        app.launchEnvironment["AGTMUX_JSON"] = json
        app.launchForUITest()

        let rowA = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.sidebarPanePrefix + AccessibilityID.paneKey(
                    source: "local",
                    sessionName: session,
                    paneID: paneA
                )
            )
        ).firstMatch
        let rowB = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.sidebarPanePrefix + AccessibilityID.paneKey(
                    source: "local",
                    sessionName: session,
                    paneID: paneB
                )
            )
        ).firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))
        XCTAssertTrue(rowB.waitForExistence(timeout: TestConstants.sidebarPopulateTimeout))

        rowA.click()

        let tileA = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceTilePrefix + AccessibilityID.paneKey(
                    source: "local",
                    sessionName: session,
                    paneID: paneA
                )
            )
        ).firstMatch
        XCTAssertTrue(tileA.waitForExistence(timeout: TestConstants.surfaceReadyTimeout))

        // Single-surface contract: only one workspace tile should exist for a window.
        let anyTile = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.workspaceTilePrefix)
        )
        XCTAssertEqual(anyTile.count, 1, "Window open should render exactly one workspace tile")

        let linkedCreated = try waitForNewLinkedSessions(tmux: tmux, existing: linkedBefore, timeout: 5.0)
        guard !linkedCreated.isEmpty else {
            XCTFail("Opening a window must create at least one linked session")
            return
        }

        // Ensure focus-sync monitoring is bound to linked session runtime, not parent session.
        _ = try shellRun([tmux, "kill-session", "-t", session])
        ownedSessions.remove(session)

        // Trigger pane focus change from tmux side (as if user switched pane in terminal).
        _ = try shellRun([tmux, "select-pane", "-t", paneB])

        let selectedB = expectation(for: NSPredicate(format: "value == %@", "selected"), evaluatedWith: rowB)
        wait(for: [selectedB], timeout: 5.0)

        let unselectedA = expectation(for: NSPredicate(format: "value == %@", "unselected"), evaluatedWith: rowA)
        wait(for: [unselectedA], timeout: 5.0)

        // The single workspace tile should now be keyed by paneB after focus sync.
        let tileB = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                AccessibilityID.workspaceTilePrefix + AccessibilityID.paneKey(
                    source: "local",
                    sessionName: session,
                    paneID: paneB
                )
            )
        ).firstMatch
        XCTAssertTrue(tileB.waitForExistence(timeout: TestConstants.surfaceReadyTimeout))
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
        guard (try? listTmuxSessions(tmux)) != nil else {
            throw XCTSkip("tmux socket not accessible from runner — skipping local lifecycle reflection test")
        }

        app.launchForUITest()

        let session = try createTrackedTmuxSession(prefix: "agtmux-e2e-live-reflect", tmux: tmux)

        func paneDescriptors() throws -> [(paneID: String, windowID: String, windowName: String)] {
            let output = try shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}\t#{window_id}\t#{window_name}"])
            return output
                .components(separatedBy: "\n")
                .compactMap { line in
                    guard !line.isEmpty else { return nil }
                    let parts = line.components(separatedBy: "\t")
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

        let gonePredicate = NSPredicate(format: "exists == false")
        let goneExpectation = expectation(for: gonePredicate, evaluatedWith: emptyState)
        wait(for: [goneExpectation], timeout: timeout)
    }

    private func assertWorkspaceStartsEmpty() {
        let emptyPred = NSPredicate(format: "identifier == %@", AccessibilityID.workspaceEmpty)
        let emptyState = app.descendants(matching: .any).matching(emptyPred).firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: TestConstants.settleTimeout),
            "Workspace should start in empty state before selecting a pane"
        )
    }

    private func paneRow(source: String = "local", sessionName: String, paneID: String) -> XCUIElement {
        let key = AccessibilityID.paneKey(source: source, sessionName: sessionName, paneID: paneID)
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarPanePrefix + key)
        ).firstMatch
    }

    private func sessionRow(source: String = "local", sessionName: String) -> XCUIElement {
        let key = AccessibilityID.sessionKey(source: source, sessionName: sessionName)
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", AccessibilityID.sidebarSessionPrefix + key)
        ).firstMatch
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

    private func waitForNewLinkedSessions(
        tmux: String,
        existing: Set<String>,
        timeout: TimeInterval
    ) throws -> Set<String> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = try listTmuxSessions(tmux)
            let linked = Set(now.filter { $0.hasPrefix("agtmux-linked-") })
            let created = linked.subtracting(existing)
            if !created.isEmpty {
                return created
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return []
    }

    /// Best-effort cleanup for agent sessions (codex/claude) inside a test-owned tmux session.
    /// Order:
    /// 1) polite interrupt (`C-c`, `exit`)
    /// 2) terminate by pane TTY / process-group / process-tree
    /// 3) hard kill if still alive (`TERM` pass then `KILL` pass)
    private func terminateSessionProcesses(session: String, tmux: String) {
        guard let rows = try? shellOutput([tmux, "list-panes", "-t", session, "-F", "#{pane_id}\t#{pane_pid}\t#{pane_tty}"]) else {
            return
        }

        struct PaneProcessTarget {
            var pid: Int32
            var processGroupID: Int32?
            var tty: String?
        }

        var targets: [PaneProcessTarget] = []
        for line in rows.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
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
        var env = ProcessInfo.processInfo.environment
        // Never inherit current tmux client context from the runner shell.
        // A stale/inaccessible TMUX socket makes `tmux list-sessions` fail and
        // causes false "socket not accessible" skips.
        env["TMUX"] = nil
        env["TMUX_PANE"] = nil
        process.environment = env
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
        var env = ProcessInfo.processInfo.environment
        env["TMUX"] = nil
        env["TMUX_PANE"] = nil
        process.environment = env
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
}
