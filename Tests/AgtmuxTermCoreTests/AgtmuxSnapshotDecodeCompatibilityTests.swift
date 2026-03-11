import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSnapshotDecodeCompatibilityTests: XCTestCase {
    func testDecodeIgnoresUnknownTopLevelAndPaneFields() throws {
        let json = """
        {
          "version": 1,
          "cache": {
            "inventory_state": "fresh",
            "metadata_state": "stale",
            "metadata_failure_streak": 3
          },
          "panes": [
            {
              "pane_id": "%42",
              "session_name": "dev",
              "window_id": "@11",
              "presence": "managed",
              "activity_state": "running",
              "provider": "codex",
              "evidence_mode": "deterministic",
              "metadata_stale": true,
              "metadata_backoff_until": "2026-03-05T15:00:00Z",
              "unknown_new_field": "ignored"
            }
          ],
          "future_top_level_field": {
            "nested": "ignored"
          }
        }
        """

        let snapshot = try AgtmuxSnapshot.decode(from: Data(json.utf8), source: "local")
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.panes.count, 1)
        XCTAssertEqual(snapshot.panes[0].paneId, "%42")
        XCTAssertEqual(snapshot.panes[0].presence, .managed)
        XCTAssertEqual(snapshot.panes[0].provider, .codex)
        XCTAssertEqual(snapshot.panes[0].activityState, .running)
    }

    func testDecodeHandlesNullActivityStateFromSnapshotAwareJson() throws {
        let json = """
        {
          "version": 1,
          "panes": [
            {
              "pane_id": "%0",
              "session_name": "smoke",
              "window_id": "@0",
              "presence": "unmanaged",
              "activity_state": null,
              "evidence_mode": "none",
              "metadata_stale": null
            }
          ]
        }
        """

        let snapshot = try AgtmuxSnapshot.decode(from: Data(json.utf8), source: "local")
        XCTAssertEqual(snapshot.panes.count, 1)
        XCTAssertEqual(snapshot.panes[0].activityState, .unknown)
        XCTAssertEqual(snapshot.panes[0].presence, .unmanaged)
    }

    func testDecodePreservesSessionSubtitleAndUsesWorkingDirectoryLeafAsManagedTitleFallback() throws {
        let json = """
        {
          "version": 1,
          "panes": [
            {
              "pane_id": "%7",
              "session_name": "dev",
              "window_id": "@1",
              "presence": "managed",
              "activity_state": "running",
              "provider": "codex",
              "conversation_title": "",
              "session_subtitle": "Review sidebar metadata",
              "current_path": "/Users/test/src/agtmux-term"
            }
          ]
        }
        """

        let snapshot = try AgtmuxSnapshot.decode(from: Data(json.utf8), source: "local")
        let pane = try XCTUnwrap(snapshot.panes.first)

        XCTAssertEqual(pane.sessionSubtitle, "Review sidebar metadata")
        XCTAssertEqual(pane.primaryLabel, "Review sidebar metadata")
    }
}
