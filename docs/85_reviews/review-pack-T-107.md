# Review Pack

## Objective
- Task: T-107
- User story: exact pane metadata/activity must stay isolated to the right row, and same-session pane selection must retarget the existing V2 terminal tile instead of doing nothing
- Acceptance criteria touched: exact-row metadata isolation, idle/running correctness, same-session pane navigation, UI/E2E regression proof

## Summary (3-7 lines)
- T-107 closes two user-visible regressions plus the flaky proof around them.
- Metadata overlay correlation now stays on exact pane-row identity rather than coarse `source + pane_id`.
- Same-session pane selection now preserves pane/window intent through the V2 duplicate-open reveal path.
- The pane-retarget UI smoke no longer depends on runner-created tmux state; it uses app-driven tmux bootstrap/commands and an app-state snapshot oracle.
- Terminal tile accessibility was simplified so the visible status path is the single `.status` contract.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/UITestTmuxBridge.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2TerminalAttach.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV2Models.swift`
- `Sources/AgtmuxTermCore/CoreModels.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter AppViewModelA0Tests` => PASS (21 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (19 tests)
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (6 tests)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux` => PASS
- Notes:
  - targeted UI reruns are pinned to `arch=arm64` to avoid the multiple-destination ambiguity seen in earlier reruns
  - `SACSetScreenSaverCanRun returned 22` still appears but is non-fatal

## Risk declaration
- Breaking change: yes, by design on the V2-only path; no backward-compat shim was added for the coarse metadata aliasing or stale runner-created tmux smoke
- Fallbacks: none in product behavior; test harness retries only at the app-side UITest tmux command seam
- Known gaps / follow-ups:
  - no open product blocker on T-107; broader board follow-up would be a new scoped task rather than a T-107 condition

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Focus review on:
  - whether exact-row metadata isolation can still alias provider/activity state across rows
  - whether same-session pane retarget can regress into duplicate-tile or dropped-intent behavior
  - whether the app-driven UITest tmux bridge introduced hidden race or silent-failure paths
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)
