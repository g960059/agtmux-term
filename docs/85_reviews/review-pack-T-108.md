# Review Pack

## Objective
- Task: T-108
- User story: active-pane single-source-of-truth and pane-instance identity recovery
- Acceptance criteria touched:
  - sync-v2 / XPC bootstrap preserves `session_key` and `pane_instance_id`
  - missing exact identity degrades to inventory-only with explicit incompatibility
  - stale provider/activity metadata cannot bleed across reused pane IDs / exact-session aliases
  - same-session pane retarget preserves tile identity while applying live navigation
  - terminal-originated pane changes update canonical active-pane state and sidebar highlight
  - live tmux regression coverage proves sidebar -> terminal and terminal -> sidebar flows

## Summary
- Tightened local metadata handling so bootstrap location collisions now fail closed for the whole local metadata epoch instead of picking a preferred managed row.
- `AppViewModel` now surfaces those bootstrap collisions as `daemon incompatible` and immediately republishes inventory-only local rows.
- Same-session pane retarget no longer relies on a one-shot `switch-client`; the visible terminal tile now keeps retrying exact-client navigation until the rendered tmux client reports the requested pane/window.
- Reducer-owned runtime pane state now carries a focus-restore nonce so sidebar-initiated same-session retarget returns first responder to the visible Ghostty host without recreating the tile.
- Focused regression coverage now directly exercises bootstrap fail-close, exact-client retry semantics, and focus-restore token behavior.

## Change scope
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2NavigationSyncResolver.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2NavigationSyncResolverTests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter AppViewModelA0Tests` => PASS
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS
  - `swift test -q --filter WorkbenchV2NavigationSyncResolverTests` => PASS
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS
  - `xcodegen generate` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux` => BLOCKED by host session state (`CGSSessionScreenIsLocked = 1`; app remains `Running Background`)
- Notes:
  - current blocker text from the latest rerun is `Timed out while enabling automation mode.`
  - `SACSetScreenSaverCanRun returned 22` still appears during targeted `xcodebuild`, but the blocking failure is the XCTest automation-mode initialization, not that warning

## Risk declaration
- Breaking change: yes
- Fallbacks: none
- Known gaps / follow-ups:
  - final real-surface UI evidence is still pending a host session where XCTest can actually enable automation mode

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required

## Latest Verdicts
- Previous `NO_GO` findings are now addressed in code:
  - bootstrap overlay no longer accepts collisions at one visible local pane location
  - same-session pane retarget no longer relies on a one-shot exact-client navigation attempt
- Fresh post-fix review is still pending.
