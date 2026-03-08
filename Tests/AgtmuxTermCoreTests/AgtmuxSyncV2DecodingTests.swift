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
              "session_key": "dev",
              "window_id": "@11",
              "pane_instance_id": {
                "pane_id": "%42",
                "generation": 2,
                "birth_ts": "2026-03-06T18:00:00Z"
              },
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
        XCTAssertEqual(bootstrap.panes[0].metadataSessionKey, "dev")
        XCTAssertEqual(
            bootstrap.panes[0].paneInstanceID,
            AgtmuxSyncV2PaneInstanceID(
                paneId: "%42",
                generation: 2,
                birthTs: date("2026-03-06T18:00:00Z")
            )
        )
        XCTAssertEqual(bootstrap.sessions.count, 1)
        XCTAssertEqual(bootstrap.sessions[0].sessionKey, "dev")
        XCTAssertEqual(bootstrap.sessions[0].presence, .managed)
        XCTAssertEqual(bootstrap.sessions[0].evidenceMode, .deterministic)
    }

    func testDecodeBootstrapFailsWhenExactIdentityFieldsAreMissing() throws {
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
              "activity_state": "Running"
            }
          ],
          "sessions": [],
          "generated_at": "2026-03-06T18:31:00Z",
          "replay_cursor": {
            "epoch": 7,
            "seq": 42
          }
        }
        """

        XCTAssertThrowsError(
            try decoder().decode(AgtmuxSyncV2Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(
                error is DecodingError || error is AgtmuxSyncV2ProtocolError,
                "legacy daemon rows with null exact fields must be rejected loudly"
            )
        }
    }

    func testDecodeBootstrapFailsForLegacyDaemonRowsWithSessionIDAndNullExactFields() throws {
        let json = """
        {
          "epoch": 1,
          "snapshot_seq": 1,
          "panes": [
            {
              "pane_id": "%11",
              "session_id": "$11",
              "session_name": null,
              "window_id": null,
              "presence": "managed",
              "activity_state": "Running",
              "provider": "Codex",
              "signature_class": "deterministic"
            }
          ],
          "sessions": [],
          "generated_at": "2026-03-07T16:46:58Z",
          "replay_cursor": {
            "epoch": 1,
            "seq": 2
          }
        }
        """

        XCTAssertThrowsError(
            try decoder().decode(AgtmuxSyncV2Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(
                error is DecodingError || error is AgtmuxSyncV2ProtocolError,
                "legacy daemon rows with null exact fields must be rejected loudly"
            )
        }
    }

    func testDecodeBootstrapFailsWhenLegacySessionIDAppearsAlongsideExactIdentityFields() throws {
        let json = """
        {
          "epoch": 1,
          "snapshot_seq": 1,
          "panes": [
            {
              "pane_id": "%42",
              "session_id": "$42",
              "session_name": "dev",
              "session_key": "dev",
              "window_id": "@11",
              "pane_instance_id": {
                "pane_id": "%42",
                "generation": 2,
                "birth_ts": "2026-03-07T16:57:36Z"
              },
              "presence": "managed",
              "activity_state": "Running",
              "provider": "Codex"
            }
          ],
          "sessions": [],
          "generated_at": "2026-03-07T16:57:36Z",
          "replay_cursor": {
            "epoch": 1,
            "seq": 2
          }
        }
        """

        XCTAssertThrowsError(
            try decoder().decode(AgtmuxSyncV2Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(
                error is DecodingError || error is AgtmuxSyncV2ProtocolError,
                "mixed-era payloads that still carry session_id must be rejected loudly"
            )
        }
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

    func testDecodeChangesFailsWhenLegacySessionIDAppearsAlongsideExactIdentityFields() throws {
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
                "session_id": "$42",
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

        XCTAssertThrowsError(
            try decoder().decode(AgtmuxSyncV2ChangesResponse.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(
                error is DecodingError || error is AgtmuxSyncV2ProtocolError,
                "mixed-era changes payloads that still carry session_id must be rejected loudly"
            )
        }
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

    func testBootstrapEncodeRoundTripPreservesExactIdentityFields() throws {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%51",
            sessionName: "dev",
            windowId: "@12",
            activityState: .running,
            presence: .managed,
            provider: .codex,
            evidenceMode: .deterministic,
            conversationTitle: "Encode identity",
            currentCmd: "node",
            updatedAt: date("2026-03-06T18:30:00Z"),
            ageSecs: 0,
            metadataSessionKey: "dev",
            paneInstanceID: AgtmuxSyncV2PaneInstanceID(
                paneId: "%51",
                generation: 4,
                birthTs: date("2026-03-06T18:00:00Z")
            )
        )
        let bootstrap = AgtmuxSyncV2Bootstrap(
            epoch: 9,
            snapshotSeq: 17,
            panes: [pane],
            sessions: [],
            generatedAt: date("2026-03-06T18:31:00Z"),
            replayCursor: AgtmuxSyncV2Cursor(epoch: 9, seq: 18)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bootstrap)
        let decoded = try decoder().decode(AgtmuxSyncV2Bootstrap.self, from: data)

        XCTAssertEqual(decoded.panes.count, 1)
        XCTAssertEqual(decoded.panes[0].sessionName, "dev")
        XCTAssertEqual(decoded.panes[0].metadataSessionKey, "dev")
        XCTAssertEqual(decoded.panes[0].windowId, "@12")
        XCTAssertEqual(decoded.panes[0].paneInstanceID, pane.paneInstanceID)
    }
}
