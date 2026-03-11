import XCTest
@testable import AgtmuxTermCore

final class AgtmuxSyncV3DecodingTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    private func fixturePane(_ name: String, filePath: StaticString = #filePath) throws -> AgtmuxSyncV3PaneSnapshot {
        let bootstrap = try AgtmuxSyncV3FixtureLoader.bootstrap(named: name, filePath: filePath)
        XCTAssertEqual(bootstrap.version, 3)
        XCTAssertEqual(bootstrap.panes.count, 1, "fixture \(name) should contain one pane")
        return try XCTUnwrap(bootstrap.panes.first)
    }

    func testDecodeCanonicalCodexRunningFixture() throws {
        let bootstrap = try AgtmuxSyncV3FixtureLoader.bootstrap(named: "codex-running")
        let pane = try XCTUnwrap(bootstrap.panes.first)

        XCTAssertEqual(bootstrap.version, 3)
        XCTAssertNil(bootstrap.replayCursor)
        XCTAssertEqual(bootstrap.generatedAt, date("2026-03-09T20:11:04Z"))
        XCTAssertEqual(pane.provider, .codex)
        XCTAssertEqual(pane.presence, .managed)
        XCTAssertEqual(pane.agent.lifecycle, .running)
        XCTAssertEqual(pane.thread.lifecycle, .active)
        XCTAssertEqual(pane.thread.blocking, .none)
        XCTAssertEqual(pane.thread.execution, .thinking)
    }

    func testDecodeCanonicalCodexWaitingApprovalFixture() throws {
        let pane = try fixturePane("codex-waiting-approval")

        XCTAssertEqual(pane.thread.blocking, .waitingApproval)
        XCTAssertEqual(pane.thread.execution, .toolRunning)
        XCTAssertEqual(pane.thread.flags.reviewMode, true)
        XCTAssertEqual(pane.pendingRequests.map(\.requestID), ["req_codex_approval_001"])
        XCTAssertEqual(pane.attention.highestPriority, .approval)
    }

    func testDecodeCanonicalCodexCompletedIdleFixture() throws {
        let pane = try fixturePane("codex-completed-idle")

        XCTAssertEqual(pane.agent.lifecycle, .completed)
        XCTAssertEqual(pane.thread.lifecycle, .idle)
        XCTAssertEqual(pane.thread.turn.outcome, .completed)
        XCTAssertEqual(pane.attention.highestPriority, .completion)
    }

    func testDecodeCanonicalClaudeApprovalFixture() throws {
        let pane = try fixturePane("claude-approval")

        XCTAssertEqual(pane.provider, .claude)
        XCTAssertEqual(pane.thread.blocking, .waitingApproval)
        XCTAssertEqual(pane.pendingRequests.first?.source.sourceKind, "claude_hooks")
        guard case let .object(raw)? = pane.providerRaw?[.claude]?.storage else {
            return XCTFail("expected opaque claude provider_raw object")
        }
        XCTAssertEqual(raw["hook_event"], AgtmuxSyncV3JSONValue(.string("PermissionRequest")))
    }

    func testDecodeCanonicalClaudeStopIdleFixture() throws {
        let pane = try fixturePane("claude-stop-idle")

        XCTAssertEqual(pane.provider, .claude)
        XCTAssertEqual(pane.thread.lifecycle, .idle)
        XCTAssertEqual(pane.thread.turn.outcome, .completed)
        XCTAssertEqual(pane.attention.highestPriority, .completion)
    }

    func testDecodeCanonicalUnmanagedDemotionFixture() throws {
        let pane = try fixturePane("unmanaged-demotion")

        XCTAssertNil(pane.provider)
        XCTAssertEqual(pane.presence, .unmanaged)
        XCTAssertEqual(pane.agent.lifecycle, .unknown)
        XCTAssertEqual(pane.freshness.snapshot, .down)
    }

    func testDecodeCanonicalErrorFixture() throws {
        let pane = try fixturePane("error")

        XCTAssertEqual(pane.agent.lifecycle, .errored)
        XCTAssertEqual(pane.thread.lifecycle, .errored)
        XCTAssertEqual(pane.thread.turn.outcome, .errored)
        guard case let .object(codexRaw)? = pane.providerRaw?[.codex]?.storage,
              case let .object(errorObject)? = codexRaw["error"]?.storage else {
            return XCTFail("expected nested error object in provider_raw")
        }
        XCTAssertEqual(errorObject["message"], AgtmuxSyncV3JSONValue(.string("tool invocation failed")))
    }

    func testDecodeCanonicalFreshnessDegradedFixture() throws {
        let pane = try fixturePane("freshness-degraded")

        XCTAssertEqual(pane.thread.execution, .streaming)
        XCTAssertEqual(pane.freshness.snapshot, .stale)
        XCTAssertEqual(pane.freshness.execution, .stale)
    }

    func testDecodeBootstrapPreservesSessionSubtitle() throws {
        let json = """
        {
          "version": 3,
          "generated_at": "2026-03-09T20:11:05Z",
          "panes": [
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
              "provider": "codex",
              "session_subtitle": "Pick up the sync-v3 follow-up",
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
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bootstrap = try decoder.decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))

        XCTAssertEqual(bootstrap.panes.first?.sessionSubtitle, "Pick up the sync-v3 follow-up")
    }

    func testDecodeBootstrapFailsWhenExactIdentityFieldsAreMissing() throws {
        let json = """
        {
          "version": 3,
          "generated_at": "2026-03-09T20:11:05Z",
          "panes": [
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
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(
            try decoder.decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? AgtmuxSyncV3ProtocolError,
                .missingBootstrapPaneField("session_name")
            )
        }
    }

    func testDecodeBootstrapFailsWhenPaneInstanceIdentityDoesNotMatchPaneID() throws {
        let json = """
        {
          "version": 3,
          "generated_at": "2026-03-09T20:11:05Z",
          "panes": [
            {
              "session_name": "demo",
              "window_id": "@1",
              "session_key": "codex:%4",
              "pane_id": "%4",
              "pane_instance_id": {
                "pane_id": "%999",
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
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(
            try decoder.decode(AgtmuxSyncV3Bootstrap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? AgtmuxSyncV3ProtocolError,
                .paneInstanceIDMismatch(topLevelPaneID: "%4", paneInstancePaneID: "%999")
            )
        }
    }

    func testDecodeChangesV3UpsertBatchPreservesExactIdentity() throws {
        let json = """
        {
          "version": 3,
          "from_seq": 41,
          "to_seq": 41,
          "next_cursor": { "seq": 41 },
          "changes": [
            {
              "seq": 41,
              "at": "2026-03-09T20:11:05Z",
              "kind": "upsert",
              "session_name": "workbench",
              "window_id": "@5",
              "session_key": "codex:%12",
              "pane_id": "%12",
              "pane_instance_id": {
                "pane_id": "%12",
                "generation": 7,
                "birth_ts": "2026-03-09T20:09:54Z"
              },
              "field_groups": ["thread", "pending_requests", "attention"],
              "pane": {
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
                "agent": { "lifecycle": "running" },
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
                    "sequence": 43,
                    "started_at": "2026-03-09T20:10:59Z",
                    "completed_at": null
                  }
                },
                "pending_requests": [
                  {
                    "request_id": "req_codex_approval_001",
                    "kind": "approval",
                    "title": "Apply patch",
                    "detail": "Apply worktree patch",
                    "created_at": "2026-03-09T20:11:00Z",
                    "updated_at": "2026-03-09T20:11:04Z",
                    "status": "pending",
                    "source": {
                      "provider": "codex",
                      "source_kind": "codex_jsonl"
                    }
                  }
                ],
                "attention": {
                  "active_kinds": ["approval"],
                  "highest_priority": "approval",
                  "unresolved_count": 1,
                  "generation": 12,
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
                    "active_flags": ["waitingOnApproval"]
                  }
                },
                "updated_at": "2026-03-09T20:11:04Z"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AgtmuxSyncV3ChangesResponse.self, from: Data(json.utf8))

        guard case let .changes(payload) = response else {
            return XCTFail("expected changes response")
        }
        XCTAssertEqual(payload.fromSeq, 41)
        XCTAssertEqual(payload.toSeq, 41)
        XCTAssertEqual(payload.nextCursor, AgtmuxSyncV3Cursor(seq: 41))
        XCTAssertEqual(payload.changes.count, 1)
        let change = try XCTUnwrap(payload.changes.first)
        XCTAssertEqual(change.kind, .upsert)
        XCTAssertEqual(change.fieldGroups, [.thread, .pendingRequests, .attention])
        XCTAssertEqual(change.pane?.thread.blocking, .waitingApproval)
    }

    func testDecodeChangesV3RemoveBatchRequiresNoNestedPanePayload() throws {
        let json = """
        {
          "version": 3,
          "from_seq": 44,
          "to_seq": 44,
          "next_cursor": { "seq": 44 },
          "changes": [
            {
              "seq": 44,
              "at": "2026-03-09T20:11:08Z",
              "kind": "remove",
              "session_name": "workbench",
              "window_id": "@5",
              "session_key": "codex:%12",
              "pane_id": "%12",
              "pane_instance_id": {
                "pane_id": "%12",
                "generation": 7,
                "birth_ts": "2026-03-09T20:09:54Z"
              },
              "field_groups": ["presence"],
              "pane": {
                "session_name": "workbench",
                "window_id": "@5",
                "session_key": "codex:%12",
                "pane_id": "%12",
                "pane_instance_id": {
                  "pane_id": "%12",
                  "generation": 7,
                  "birth_ts": "2026-03-09T20:09:54Z"
                },
                "presence": "missing",
                "agent": { "lifecycle": "not_found" },
                "thread": {
                  "lifecycle": "shutdown",
                  "blocking": "none",
                  "execution": "none",
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
                  "snapshot": "down",
                  "blocking": "down",
                  "execution": "down"
                },
                "updated_at": "2026-03-09T20:11:08Z"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(
            try decoder.decode(AgtmuxSyncV3ChangesResponse.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? AgtmuxSyncV3ProtocolError,
                .invalidChangesPayload("remove change must not include pane payload")
            )
        }
    }

    func testDecodeChangesV3ResyncRequiredRejectsBatchMetadata() throws {
        let json = """
        {
          "version": 3,
          "from_seq": 90,
          "to_seq": 90,
          "next_cursor": { "seq": 90 },
          "changes": [],
          "resync_required": {
            "latest_snapshot_seq": 99,
            "reason": "trimmed_cursor"
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(
            try decoder.decode(AgtmuxSyncV3ChangesResponse.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? AgtmuxSyncV3ProtocolError,
                .invalidChangesPayload("resync_required response must not include batch cursors or changes")
            )
        }
    }
}
