# Review Pack

## Objective
- Task: T-093
- User story: Workbench persistence and restore placeholders umbrella
- Acceptance criteria touched: Workbenches autosave, terminal tiles restore by `SessionRef`, pinned browser/document tiles restore, missing host/session/path surfaces remain visible with `Retry` / `Rebind` / `Remove Tile`

## Summary (3-7 lines)
- `T-093` was executed through `T-104` and `T-105`, separating storage/restore plumbing from restore-failure affordances.
- Workbench snapshots now autosave to app-owned storage, restore on launch when no fixture override is active, persist exact terminal `SessionRef`s, and keep only pinned companion tiles.
- Restore-time failures are explicit rather than silent: broken terminal/document refs remain visible and offer `Retry`, exact-target `Rebind`, and `Remove Tile`.
- Startup races that initially reopened the phase were fixed: terminal restore distinguishes bootstrap from broken state, remote document restore waits for reachability truth, and document rebind no longer falls back missing remote targets to `local`.
- Fresh SPM verification and the targeted restore UI proof both pass on the current worktree.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchStoreV2Persistence.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2TerminalRestore.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2PersistenceTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalRestoreTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchStoreV2PersistenceTests` => PASS (9 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (17 tests)
  - `swift test -q --filter WorkbenchV2DocumentTileTests` => PASS (13 tests)
  - `swift test -q --filter WorkbenchV2TerminalRestoreTests` => PASS (13 tests)
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (4 tests)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredBrokenTerminalTileShowsPlaceholderAndCanBeRemoved -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredHealthyTerminalTileDoesNotSurfaceBrokenPlaceholder` => PASS (2 tests)
- Supporting closeout evidence already captured in split tasks:
  - `docs/85_reviews/review-pack-T-104.md` => `GO` / `GO`
  - `docs/85_reviews/review-pack-T-105.md` => `GO` / `GO`
- Notes:
  - the fresh rerun above exercises both the persistence half (`T-104`) and the restore-placeholder half (`T-105`) on the current worktree
  - the targeted UI proof now executes from an unlocked desktop session and covers both a broken restored terminal tile and a healthy restored terminal tile
  - build/test output still contains an existing unrelated warning in `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift:69` about a main-actor-isolated static property referenced from a nonisolated context

## Risk declaration
- Breaking change: low but real; V2 workbench state now persists across launches, and restore-time failures stay visible instead of silently disappearing
- Fallbacks: none; missing host/session/path truth is explicit, and `Rebind` stays exact-target only
- Known gaps / follow-ups:
  - no targeted UI proof yet for document restore placeholder actions
  - no targeted UI proof yet for terminal `Rebind` execution itself

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Review mode:
  - tracking-only umbrella closeout; no new product diff beyond the already-reviewed split tasks
- Bounded Codex CLI closeout attempts:
  - did not return a usable final verdict in reasonable time
- Inherited reviewer verdicts:
  - `T-104`: `GO`, `GO`
  - `T-105`: `GO`, `GO`
- Final umbrella verdict:
  - direct Codex fallback review: `GO`
- Final note:
  - the only stale gap during umbrella reconciliation was that `docs/60_tasks.md` still showed `T-093` as `IN PROGRESS`; after syncing the parent task entry and acceptance checkboxes, no additional product-level blocker remained
