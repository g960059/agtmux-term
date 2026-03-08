# Review Pack

## Objective
- Task: T-105
- User story: Workbench restore failure placeholders and recovery actions
- Acceptance criteria touched: broken terminal/document refs remain visible after restore instead of silently disappearing, `Retry` re-attempts the failed attach/load path, `Rebind` allows manual exact-target reassignment only, `Remove Tile` removes the broken tile from the restored Workbench

## Summary (3-7 lines)
- Document restore now resolves explicit typed placeholder states from persisted `DocumentRef` plus live host/offline truth, with `Retry`, exact-target `Rebind`, and `Remove Tile` wired in the tile surface.
- Terminal restore now resolves render-time broken states from persisted `SessionRef` plus live tmux inventory truth without persisting any extra restore-status field.
- Local daemon issues, missing/offline remote hosts, local tmux unavailability, and exact session disappearance surface as explicit terminal placeholder states instead of silently disappearing.
- Exact-target terminal rebind options are synthesized from live pane inventory only; no fuzzy matching or silent fallback was added.
- Focused UI proof now covers a restored broken terminal tile staying visible and removable in the V2 path.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2TerminalRestore.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalRestoreTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2DocumentTileTests` => PASS (10 tests)
  - `swift test -q --filter WorkbenchV2TerminalRestoreTests` => PASS (13 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (17 tests)
  - `swift test -q --filter WorkbenchStoreV2PersistenceTests` => PASS (9 tests)
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (4 tests)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredBrokenTerminalTileShowsPlaceholderAndCanBeRemoved -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredHealthyTerminalTileDoesNotSurfaceBrokenPlaceholder` => PASS
- Notes:
  - targeted UI proof now exercises both a broken restored terminal session and a healthy restored terminal session, including the bootstrap-to-direct-attach transition and executed `Remove Tile`
  - build/test output still contains an existing unrelated warning in `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift:69` about a main-actor-isolated static property referenced from a nonisolated context
  - `xcodebuild` emitted the usual multiple-destination warning and non-fatal `SACSetScreenSaverCanRun returned 22`

## Risk declaration
- Breaking change: low but real; restored V2 terminal tiles now block direct attach when live inventory truth says the exact session is broken
- Fallbacks: none; restore state is explicit and fail-loud, exact-target only
- Known gaps / follow-ups:
  - no targeted UI proof yet for terminal `Rebind` execution itself
  - no targeted UI proof yet for document restore placeholder actions

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Initial reviewer verdicts:
  - independent Codex review #1: `NO_GO`
  - independent Codex review #2: `NO_GO`
- Initial blocking findings:
  - healthy restored terminal tiles could surface a false broken placeholder before the first inventory fetch completed
  - terminal rebind options could include stale sessions from offline sources
  - remote document restore could race startup reachability and stick on a generic load failure
  - document rebind silently fell back a missing remote target to `local`
- Remediation status:
  - terminal tiles now resolve explicit `bootstrapping / ready / broken` state and block both direct attach and broken-tile actions until the initial inventory fetch completes
  - terminal rebind options now require `hasCompletedInitialFetch == true` and filter offline sources out of the exact-target picker
  - document remote loads now defer until inventory reachability is ready and the task id includes live offline-host state so startup reachability changes rerun the load path automatically
  - document rebind now preserves missing remote targets as an explicit unavailable picker row instead of silently selecting `local`
  - added focused unit coverage for both bootstrap guards and stale-option filtering, plus a healthy restored terminal UI proof
- Re-review status:
  - final Codex re-review #1: `GO`
  - final Codex re-review #2: `GO`
