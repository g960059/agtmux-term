import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSyncV3DecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    /// Temporary local fixture scaffold derived from `/tmp/agtmux-status-v3-final-design-20260309.md`.
    /// Replace with daemon-owned canonical fixtures once they are available.
    private func bootstrapJSON(paneFields: String) -> String {
        """
        {
          "version": 3,
          "epoch": 9,
          "snapshot_seq": 44,
          "panes": [
            \(paneFields)
          ],
          "generated_at": "2026-03-09T20:11:05Z",
          "replay_cursor": {
            "epoch": 9,
            "seq": 45
          }
        }
        """
    }

    func testDecodeBootstrapMapsStructuredStatusAxesAndProviderRaw() throws {
        let json = bootstrapJSON(
            paneFields: """
            {
              "session_name": "workbench",
              "window_id": "@5",
              "session_key": "codex:%12",
              "pane_id": "%12",
              "pane_instance_id": {
                "pane_id": "%12",
                "generation": 7,
                "birth_ts": "2026-03-09T20:09:54Z"
              },
              "provider": "codex",
              "presence": "managed",
              "agent": {
                "lifecycle": "running"
              },
              "thread": {
                "lifecycle": "active",
                "blocking": "waiting_approval",
                "execution": "tool_running",
                "flags": {
                  "review_mode": true,
                  "subagent_active": false
                },
                "turn": {
                  "outcome": "none",
                  "sequence": 42,
                  "started_at": "2026-03-09T20:10:00Z",
                  "completed_at": null
                }
              },
              "pending_requests": [
                {
                  "request_id": "req_approval_123",
                  "kind": "approval",
                  "title": "Apply patch",
                  "detail": "Approve file modifications",
                  "created_at": "2026-03-09T20:11:04Z",
                  "updated_at": "2026-03-09T20:11:04Z",
                  "status": "pending",
                  "source": {
                    "provider": "codex",
                    "source_kind": "codex_appserver"
                  }
                }
              ],
              "attention": {
                "active_kinds": ["approval"],
                "highest_priority": "approval",
                "unresolved_count": 1,
                "generation": 9,
                "latest_at": "2026-03-09T20:11:04Z"
              },
              "freshness": {
                "snapshot": "fresh",
                "blocking": "fresh",
                "execution": "fresh"
              },
              "provider_raw": {
                "codex": {
                  "thread_status_type": "active",
                  "active_flags": ["waitingOnApproval"],
                  "agent_status": "running",
                  "review_mode": true
                }
              },
              "updated_at": "2026-03-09T20:11:04Z"
            }
            """
        )

        let bootstrap = try decoder().decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))

        XCTAssertEqual(bootstrap.version, 3)
        XCTAssertEqual(bootstrap.epoch, 9)
        XCTAssertEqual(bootstrap.snapshotSeq, 44)
        XCTAssertEqual(bootstrap.generatedAt, date("2026-03-09T20:11:05Z"))
        XCTAssertEqual(bootstrap.replayCursor, AgtmuxSyncV3Cursor(epoch: 9, seq: 45))
        XCTAssertEqual(bootstrap.panes.count, 1)

        let pane = bootstrap.panes[0]
        XCTAssertEqual(pane.sessionName, "workbench")
        XCTAssertEqual(pane.windowID, "@5")
        XCTAssertEqual(pane.sessionKey, "codex:%12")
        XCTAssertEqual(pane.paneID, "%12")
        XCTAssertEqual(
            pane.paneInstanceID,
            AgtmuxSyncV3PaneInstanceID(
                paneId: "%12",
                generation: 7,
                birthTs: date("2026-03-09T20:09:54Z")
            )
        )
        XCTAssertEqual(pane.provider, .codex)
        XCTAssertEqual(pane.presence, .managed)
        XCTAssertEqual(pane.agent.lifecycle, .running)
        XCTAssertEqual(pane.thread.lifecycle, .active)
        XCTAssertEqual(pane.thread.blocking, .waitingApproval)
        XCTAssertEqual(pane.thread.execution, .toolRunning)
        XCTAssertEqual(pane.thread.flags.reviewMode, true)
        XCTAssertEqual(pane.thread.flags.subagentActive, false)
        XCTAssertEqual(pane.thread.turn.outcome, .none)
        XCTAssertEqual(pane.thread.turn.sequence, 42)
        XCTAssertEqual(pane.pendingRequests.map(\.requestID), ["req_approval_123"])
        XCTAssertEqual(pane.attention.highestPriority, .approval)
        XCTAssertEqual(pane.attention.generation, 9)
        XCTAssertEqual(pane.freshness.execution, .fresh)
        XCTAssertEqual(pane.updatedAt, date("2026-03-09T20:11:04Z"))

        guard case let .object(codexRaw)? = pane.providerRaw?[.codex]?.storage else {
            return XCTFail("expected codex provider_raw payload")
        }
        XCTAssertEqual(codexRaw["thread_status_type"], AgtmuxSyncV3JSONValue(.string("active")))
    }

    func testDecodeBootstrapAllowsCompletedAgentAlongsideIdleThread() throws {
        let json = bootstrapJSON(
            paneFields: """
            {
              "session_name": "demo",
              "window_id": "@1",
              "session_key": "codex:%4",
              "pane_id": "%4",
              "pane_instance_id": {
                "pane_id": "%4",
                "generation": 2,
                "birth_ts": "2026-03-09T21:00:00Z"
              },
              "presence": "managed",
              "agent": {
                "lifecycle": "completed"
              },
              "thread": {
                "lifecycle": "idle",
                "blocking": "none",
                "execution": "none",
                "flags": {
                  "review_mode": false,
                  "subagent_active": false
                },
                "turn": {
                  "outcome": "completed",
                  "sequence": 7,
                  "started_at": "2026-03-09T21:00:00Z",
                  "completed_at": "2026-03-09T21:00:09Z"
                }
              },
              "pending_requests": [],
              "attention": {
                "active_kinds": ["completion"],
                "highest_priority": "completion",
                "unresolved_count": 0,
                "generation": 11,
                "latest_at": "2026-03-09T21:00:09Z"
              },
              "freshness": {
                "snapshot": "fresh",
                "blocking": "fresh",
                "execution": "fresh"
              },
              "updated_at": "2026-03-09T21:00:09Z"
            }
            """
        )

        let bootstrap = try decoder().decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))

        XCTAssertEqual(bootstrap.panes[0].agent.lifecycle, .completed)
        XCTAssertEqual(bootstrap.panes[0].thread.lifecycle, .idle)
        XCTAssertEqual(bootstrap.panes[0].thread.turn.outcome, .completed)
    }

    func testDecodeBootstrapFailsWhenExactIdentityFieldsAreMissing() throws {
        let json = bootstrapJSON(
            paneFields: """
            {
              "window_id": "@1",
              "session_key": "codex:%4",
              "pane_id": "%4",
              "pane_instance_id": {
                "pane_id": "%4",
                "generation": 2,
                "birth_ts": "2026-03-09T21:00:00Z"
              },
              "presence": "managed",
              "agent": {
                "lifecycle": "running"
              },
              "thread": {
                "lifecycle": "active",
                "blocking": "none",
                "execution": "thinking",
                "flags": {
                  "review_mode": false,
                  "subagent_active": false
                },
                "turn": {
                  "outcome": "none",
                  "sequence": null,
                  "started_at": null,
                  "completed_at": null
                }
              },
              "pending_requests": [],
              "attention": {
                "active_kinds": [],
                "highest_priority": "none",
                "unresolved_count": 0,
                "generation": 0,
                "latest_at": null
              },
              "freshness": {
                "snapshot": "fresh",
                "blocking": "fresh",
                "execution": "fresh"
              },
              "updated_at": "2026-03-09T21:00:09Z"
            }
            """
        )

        XCTAssertThrowsError(
            try decoder().decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? AgtmuxSyncV3ProtocolError,
                .missingBootstrapPaneField("session_name")
            )
        }
    }
}
