import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSyncV2DecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    func testDecodeBootstrapMapsSnakeCaseFields() throws {
        let json = """
        {
          "epoch": 7,
          "snapshot_seq": 41,
          "panes": [
            {
              "pane_id": "%42",
              "session_name": "dev",
              "window_id": "@11",
              "presence": "managed",
              "activity_state": "Running",
              "provider": "Codex",
              "evidence_mode": "Deterministic",
              "conversation_title": "Ship A1",
              "updated_at": "2026-03-06T18:30:00Z"
            }
          ],
          "sessions": [
            {
              "session_key": "dev",
              "presence": "Managed",
              "evidence_mode": "Deterministic",
              "activity_state": "Running",
              "updated_at": "2026-03-06T18:29:00Z"
            }
          ],
          "generated_at": "2026-03-06T18:31:00Z",
          "replay_cursor": {
            "epoch": 7,
            "seq": 42
          }
        }
        """

        let bootstrap = try decoder().decode(AgtmuxSyncV2Bootstrap.self, from: Data(json.utf8))

        XCTAssertEqual(bootstrap.epoch, 7)
        XCTAssertEqual(bootstrap.snapshotSeq, 41)
        XCTAssertEqual(bootstrap.generatedAt, date("2026-03-06T18:31:00Z"))
        XCTAssertEqual(bootstrap.replayCursor, AgtmuxSyncV2Cursor(epoch: 7, seq: 42))
        XCTAssertEqual(bootstrap.panes.count, 1)
        XCTAssertEqual(bootstrap.panes[0].source, "local")
        XCTAssertEqual(bootstrap.panes[0].activityState, .running)
        XCTAssertEqual(bootstrap.panes[0].provider, .codex)
        XCTAssertEqual(bootstrap.sessions.count, 1)
        XCTAssertEqual(bootstrap.sessions[0].sessionKey, "dev")
        XCTAssertEqual(bootstrap.sessions[0].presence, .managed)
        XCTAssertEqual(bootstrap.sessions[0].evidenceMode, .deterministic)
    }

    func testDecodeChangesResponse() throws {
        let json = """
        {
          "epoch": 7,
          "changes": [
            {
              "seq": 42,
              "session_key": "dev",
              "pane_id": "%42",
              "timestamp": "2026-03-06T18:32:00Z",
              "pane": {
                "pane_instance_id": {
                  "pane_id": "%42",
                  "generation": 3,
                  "birth_ts": "2026-03-06T18:00:00Z"
                },
                "presence": "Managed",
                "evidence_mode": "Deterministic",
                "activity_state": "Running",
                "provider": "Codex",
                "session_key": "dev",
                "updated_at": "2026-03-06T18:32:00Z"
              }
            }
          ],
          "from_seq": 42,
          "to_seq": 42,
          "next_cursor": {
            "epoch": 7,
            "seq": 43
          }
        }
        """

        let response = try decoder().decode(AgtmuxSyncV2ChangesResponse.self, from: Data(json.utf8))
        guard case let .changes(changes) = response else {
            return XCTFail("expected changes response")
        }

        XCTAssertEqual(changes.epoch, 7)
        XCTAssertEqual(changes.fromSeq, 42)
        XCTAssertEqual(changes.toSeq, 42)
        XCTAssertEqual(changes.nextCursor, AgtmuxSyncV2Cursor(epoch: 7, seq: 43))
        XCTAssertEqual(changes.changes.count, 1)
        XCTAssertEqual(changes.changes[0].sessionKey, "dev")
        XCTAssertEqual(changes.changes[0].paneId, "%42")
        XCTAssertEqual(changes.changes[0].pane?.paneId, "%42")
        XCTAssertEqual(changes.changes[0].pane?.provider, .codex)
    }

    func testDecodeResyncRequiredResponse() throws {
        let json = """
        {
          "resync_required": {
            "current_epoch": 8,
            "latest_snapshot_seq": 100,
            "reason": "trimmed_cursor"
          }
        }
        """

        let response = try decoder().decode(AgtmuxSyncV2ChangesResponse.self, from: Data(json.utf8))
        guard case let .resyncRequired(payload) = response else {
            return XCTFail("expected resync response")
        }

        XCTAssertEqual(payload.currentEpoch, 8)
        XCTAssertEqual(payload.latestSnapshotSeq, 100)
        XCTAssertEqual(payload.reason, "trimmed_cursor")
    }

    func testDecodeUIHealthV1MapsSnakeCaseFields() throws {
        let json = """
        {
          "generated_at": "2026-03-06T18:40:00Z",
          "runtime": {
            "status": "ok",
            "detail": "managed daemon ready",
            "last_updated_at": "2026-03-06T18:39:59Z"
          },
          "replay": {
            "status": "degraded",
            "current_epoch": 7,
            "cursor_seq": 101,
            "head_seq": 109,
            "lag": 8,
            "last_resync_reason": "trimmed_cursor",
            "last_resync_at": "2026-03-06T18:35:00Z",
            "detail": "replay is catching up"
          },
          "overlay": {
            "status": "ok",
            "detail": "overlay fresh",
            "last_updated_at": "2026-03-06T18:39:58Z"
          },
          "focus": {
            "status": "degraded",
            "focused_pane_id": "%42",
            "mismatch_count": 2,
            "last_sync_at": "2026-03-06T18:39:57Z",
            "detail": "focus mismatch observed"
          }
        }
        """

        let health = try decoder().decode(AgtmuxUIHealthV1.self, from: Data(json.utf8))

        XCTAssertEqual(health.generatedAt, date("2026-03-06T18:40:00Z"))
        XCTAssertEqual(health.runtime.status, .ok)
        XCTAssertEqual(health.runtime.detail, "managed daemon ready")
        XCTAssertEqual(health.runtime.lastUpdatedAt, date("2026-03-06T18:39:59Z"))
        XCTAssertEqual(health.replay.status, .degraded)
        XCTAssertEqual(health.replay.currentEpoch, 7)
        XCTAssertEqual(health.replay.cursorSeq, 101)
        XCTAssertEqual(health.replay.headSeq, 109)
        XCTAssertEqual(health.replay.lag, 8)
        XCTAssertEqual(health.replay.lastResyncReason, "trimmed_cursor")
        XCTAssertEqual(health.replay.lastResyncAt, date("2026-03-06T18:35:00Z"))
        XCTAssertEqual(health.overlay.status, .ok)
        XCTAssertEqual(health.overlay.lastUpdatedAt, date("2026-03-06T18:39:58Z"))
        XCTAssertEqual(health.focus.status, .degraded)
        XCTAssertEqual(health.focus.focusedPaneID, "%42")
        XCTAssertEqual(health.focus.mismatchCount, 2)
        XCTAssertEqual(health.focus.lastSyncAt, date("2026-03-06T18:39:57Z"))
    }
}
