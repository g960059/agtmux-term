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
        XCTAssertNil(bootstrap.epoch)
        XCTAssertNil(bootstrap.snapshotSeq)
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
}
