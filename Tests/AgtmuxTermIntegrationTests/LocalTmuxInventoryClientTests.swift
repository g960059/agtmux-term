import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class LocalTmuxInventoryClientTests: XCTestCase {
    private let separator = "AGTMUXFIELDSEP9F6F2D4D"

    func testParseParsesTokenSeparatedInventoryLine() throws {
        let line = [
            "%42",
            "dev-session",
            "@7",
            "7",
            "main",
            "/tmp",
            "zsh",
            "group-alpha",
        ].joined(separator: separator)

        let panes = try LocalTmuxInventoryClient.parse(output: line, source: "local")
        XCTAssertEqual(panes.count, 1)

        let pane = try XCTUnwrap(panes.first)
        XCTAssertEqual(pane.source, "local")
        XCTAssertEqual(pane.paneId, "%42")
        XCTAssertEqual(pane.sessionName, "dev-session")
        XCTAssertEqual(pane.sessionGroup, "group-alpha")
        XCTAssertEqual(pane.windowId, "@7")
        XCTAssertEqual(pane.windowIndex, 7)
        XCTAssertEqual(pane.windowName, "main")
        XCTAssertEqual(pane.currentPath, "/tmp")
        XCTAssertEqual(pane.currentCmd, "zsh")
    }

    func testParseRejectsTabDelimitedInventoryLine() {
        let tabDelimited = "%42\tdev-session\t@7\t7\tmain\t/tmp\tzsh\tgroup-alpha"

        XCTAssertThrowsError(
            try LocalTmuxInventoryClient.parse(output: tabDelimited, source: "local")
        ) { error in
            guard case let DaemonError.parseError(message) = error else {
                XCTFail("expected DaemonError.parseError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("expected 8 fields"))
        }
    }

    func testParseRejectsInvalidWindowIndex() {
        let line = [
            "%42",
            "dev-session",
            "@7",
            "not-a-number",
            "main",
            "/tmp",
            "zsh",
            "group-alpha",
        ].joined(separator: separator)

        XCTAssertThrowsError(
            try LocalTmuxInventoryClient.parse(output: line, source: "local")
        ) { error in
            guard case let DaemonError.parseError(message) = error else {
                XCTFail("expected DaemonError.parseError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("invalid window_index"))
        }
    }
}
