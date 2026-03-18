import XCTest
@testable import AgtmuxTerm

final class TmuxControlModeTests: XCTestCase {
    func testParserAccumulatesChunkedCommandResponsesAcrossBoundaries() {
        var parser = TmuxControlModeParser(emitsPaneOutput: false)
        var events: [ControlModeEvent] = []

        events += parser.append(Data("%begin 171 9 0\n%layout-cha".utf8))
        events += parser.append(Data("nge @7 tiled tiled *\n%end 171 9 0\n%session-w".utf8))
        events += parser.append(Data("indow-changed $1 @7\n".utf8))

        XCTAssertEqual(events.count, 2)

        guard case let .commandResponse(cmdId, lines) = events[0] else {
            return XCTFail("expected command response, got \(events[0])")
        }
        XCTAssertEqual(cmdId, 9)
        XCTAssertEqual(lines, ["%layout-change @7 tiled tiled *"])

        guard case let .sessionWindowChanged(sessionId, windowId) = events[1] else {
            return XCTFail("expected session window change, got \(events[1])")
        }
        XCTAssertEqual(sessionId, "$1")
        XCTAssertEqual(windowId, "@7")
    }

    func testParserDropsPaneOutputWhenDisabled() {
        var parser = TmuxControlModeParser(emitsPaneOutput: false)

        let events = parser.append(Data("%output %12 rendered text\n".utf8))

        XCTAssertTrue(events.isEmpty)
    }

    func testParserFlushesTrailingOutputOnFinishWhenEnabled() {
        var parser = TmuxControlModeParser(emitsPaneOutput: true)

        let pendingEvents = parser.append(Data("%output %12 rendered".utf8))
        let flushedEvents = parser.finish()

        XCTAssertTrue(pendingEvents.isEmpty)
        XCTAssertEqual(flushedEvents.count, 1)

        guard case let .output(paneId, text) = flushedEvents[0] else {
            return XCTFail("expected pane output, got \(flushedEvents[0])")
        }
        XCTAssertEqual(paneId, "%12")
        XCTAssertEqual(text, "rendered")
    }

    func testLocalProcessArgumentsHonorUITestTmuxConfigPath() {
        let args = TmuxControlMode.localProcessArguments(
            sessionName: "shared",
            env: [
                "AGTMUX_UITEST_TMUX_CONFIG_PATH": "/dev/null",
                "AGTMUX_TMUX_SOCKET_NAME": "bench-socket",
            ]
        )

        XCTAssertEqual(
            args,
            ["tmux", "-f", "/dev/null", "-L", "bench-socket", "-C", "attach-session", "-t", "shared"]
        )
    }
}
