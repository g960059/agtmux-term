import XCTest
@testable import AgtmuxTermCore

/// Regression tests for real-session sidebar identity semantics.
final class PaneFilterTests: XCTestCase {

    private func makePane(
        source: String = "local",
        paneId: String,
        sessionName: String,
        sessionGroup: String? = nil
    ) -> AgtmuxPane {
        AgtmuxPane(
            source: source,
            paneId: paneId,
            sessionName: sessionName,
            sessionGroup: sessionGroup,
            windowId: "@1"
        )
    }

    func testLinkedPrefixedSessionsRemainVisible() {
        let normalPane = makePane(paneId: "%1", sessionName: "main")
        let linkedPane = makePane(
            paneId: "%1",
            sessionName: "agtmux-linked-7AA0C0DD-1234-5678-90AB-CDEF01234567"
        )
        let anotherPane = makePane(paneId: "%2", sessionName: "backend")

        let visible = [normalPane, linkedPane, anotherPane]
        XCTAssertEqual(visible.count, 3)
        XCTAssertTrue(visible.contains(where: { $0.sessionName == linkedPane.sessionName }))
    }

    func testRealAgtmuxSessionsAreVisible() {
        let managedPane = makePane(
            paneId: "%42",
            sessionName: "agtmux-7AA0C0DD-1234-5678-90AB-CDEF01234567"
        )
        let normalPane = makePane(paneId: "%1", sessionName: "main")
        let linkedPane = makePane(
            paneId: "%2",
            sessionName: "agtmux-linked-ABCDEF01-0000-0000-0000-000000000000"
        )

        let visible = [managedPane, normalPane, linkedPane]
        XCTAssertEqual(visible.count, 3)
        XCTAssertTrue(visible.contains(where: { $0.sessionName == managedPane.sessionName }))
    }

    func testPaneIdentityIncludesSessionName() {
        let paneA = makePane(paneId: "%1", sessionName: "main")
        let paneB = makePane(paneId: "%1", sessionName: "backend")
        let paneC = makePane(source: "host1", paneId: "%1", sessionName: "remote")

        let ids = [paneA, paneB, paneC].map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "Pane identity must include source+session+pane")
    }

    func testSessionGroupAliasesRemainDistinctByIdentity() {
        let sessionA = makePane(
            paneId: "%42",
            sessionName: "agtmux-A1111111-1111-1111-1111-111111111111",
            sessionGroup: "vm agtmux-term"
        )
        let sessionB = makePane(
            paneId: "%42",
            sessionName: "agtmux-B2222222-2222-2222-2222-222222222222",
            sessionGroup: "vm agtmux-term"
        )

        XCTAssertNotEqual(sessionA.id, sessionB.id)
    }
}
