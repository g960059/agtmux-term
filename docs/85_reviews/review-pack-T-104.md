# Review Pack

## Objective
- Task: T-104
- User story: Workbench autosave/load snapshot plumbing
- Acceptance criteria touched: app launch restores the last autosaved Workbench snapshot when no fixture override is active, terminal tiles persist by exact `SessionRef`, unpinned browser/document tiles are dropped from the persisted snapshot, pinned browser/document tiles restore from the persisted snapshot

## Summary (3-7 lines)
- Added `WorkbenchStoreV2Persistence` for the fixed app-owned snapshot path, validated encode/decode, and atomic writes.
- `WorkbenchStoreV2(env:)` now restores the persisted snapshot when no fixture override is present, while `AGTMUX_WORKBENCH_V2_FIXTURE_JSON` still wins for tests.
- `WorkbenchStoreV2.save()` now persists the current snapshot explicitly and representative store mutations autosave fail-loud when persistence is configured.
- Save-time pruning removes unpinned browser/document tiles from the persisted snapshot while keeping terminal tiles and pinned companions.
- Bridge-opened companion mutations now autosave too, so pinned browser/document tiles created through the CLI bridge reach the persisted snapshot before app exit.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchStoreV2Persistence.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2PersistenceTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift test --filter WorkbenchStoreV2` => PASS (14 tests total; `WorkbenchStoreV2PersistenceTests` 6/6, `WorkbenchStoreV2Tests` 8/8)
  - `swift test --filter WorkbenchV2BridgeDispatchTests` => PASS (7 tests)
- Notes:
  - focused coverage exercises persisted load, fixture override precedence, save-time prune semantics, exact terminal `SessionRef` restore, representative autosave behavior, explicit-save failure when persistence is unavailable, and bridge-opened pinned companion persistence
  - build emitted an existing unrelated warning in `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift:69` about a main-actor-isolated static property from a nonisolated context

## Risk declaration
- Breaking change: low but real; V2 store mutations now autosave to app-owned disk state when persistence is configured
- Fallbacks: none; explicit `save()` throws when persistence is unavailable and autosave failures are fatal
- Known gaps / follow-ups:
  - no live app-launch/manual filesystem check yet against the real `~/Library/Application Support/AGTMUXDesktop/workbench-v2.json` path

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Initial reviewer verdicts:
  - independent Codex review #1: `GO`
  - independent Codex review #2: `NO_GO`
- Initial blocking finding:
  - the CLI bridge dispatch mutation path in `WorkbenchV2BridgeDispatch.swift` updated `workbenches` and `activeWorkbenchIndex` without autosaving, so pinned companions opened from the bridge could miss persistence
- Remediation status:
  - bridge dispatch now autosaves immediately after mutation and the current worktree includes executed proof that a bridge-opened pinned companion reaches persisted snapshot state
- Re-review status:
  - final Codex re-review #1: `GO`
  - final Codex re-review #2: `GO`
