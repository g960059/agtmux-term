import XCTest
@testable import AgtmuxTermCore

/// Regression tests for the sidebar filter behavior.
///
/// # LinkedSession prefix (T-056)
/// LinkedSessionManager creates "agtmux-linked-{UUID}" sessions (originally "agtmux-{UUID}").
/// The prefix was renamed to avoid collision with real user sessions: the agtmux CLI itself
/// creates sessions named "agtmux-{UUID}" where Claude Code runs. Filtering "agtmux-" would
/// hide ALL managed panes (status dots). Filtering "agtmux-linked-" only hides our tiles.
final class PaneFilterTests: XCTestCase {

    private func makePane(source: String = "local", paneId: String, sessionName: String) -> AgtmuxPane {
        AgtmuxPane(source: source, paneId: paneId, sessionName: sessionName, windowId: "@1")
    }

    /// Verify that linked-session panes (agtmux-linked-* prefix) are excluded.
    func testLinkedSessionPanesAreFiltered() {
        let normalPane  = makePane(paneId: "%1", sessionName: "main")
        let linkedPane  = makePane(paneId: "%1", sessionName: "agtmux-linked-7AA0C0DD-1234-5678-90AB-CDEF01234567")
        let anotherPane = makePane(paneId: "%2", sessionName: "backend")

        let all = [normalPane, linkedPane, anotherPane]
        let visible = all.filter { !$0.sessionName.hasPrefix("agtmux-linked-") }

        XCTAssertEqual(visible.count, 2, "Linked session panes must be excluded from the sidebar")
        XCTAssertFalse(visible.contains(where: { $0.sessionName.hasPrefix("agtmux-linked-") }),
                       "No agtmux-linked-* session should appear in filtered panes")
    }

    /// Verify that real user sessions named "agtmux-{UUID}" (created by agtmux CLI)
    /// are NOT filtered out. These sessions contain Claude Code processes with status dots.
    func testRealAgtmuxSessionsAreVisible() {
        let managedPane = makePane(paneId: "%42", sessionName: "agtmux-7AA0C0DD-1234-5678-90AB-CDEF01234567")
        let normalPane  = makePane(paneId: "%1",  sessionName: "main")
        let linkedPane  = makePane(paneId: "%2",  sessionName: "agtmux-linked-ABCDEF01-0000-0000-0000-000000000000")

        let all = [managedPane, normalPane, linkedPane]
        let visible = all.filter { !$0.sessionName.hasPrefix("agtmux-linked-") }

        XCTAssertEqual(visible.count, 2, "Real agtmux-* sessions must remain visible (they contain Claude Code)")
        XCTAssertTrue(visible.contains(where: { $0.sessionName.hasPrefix("agtmux-") && !$0.sessionName.hasPrefix("agtmux-linked-") }),
                      "Managed pane in agtmux-* session must be visible for status dots to show")
    }

    /// Confirm that pane identity includes session context.
    func testPaneIdentityIncludesSessionName() {
        let p1 = makePane(paneId: "%1", sessionName: "main")
        let p2 = makePane(paneId: "%1", sessionName: "backend")
        let p3 = makePane(source: "host1", paneId: "%1", sessionName: "remote")

        let ids = [p1, p2, p3].map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "Pane identity must include source+session+pane")
    }

    /// Even when paneId is shared (session aliases), identity must stay distinct.
    func testLinkedPaneHasDistinctIdentityFromOriginal() {
        let original = makePane(paneId: "%42", sessionName: "main")
        let linked   = makePane(paneId: "%42", sessionName: "agtmux-linked-ABCDEF01")

        XCTAssertNotEqual(
            original.id, linked.id,
            "Pane identity should differ by session even when paneId is the same"
        )

        // With the filter, only the original appears.
        let visible = [original, linked].filter { !$0.sessionName.hasPrefix("agtmux-linked-") }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].sessionName, "main")
    }
}
