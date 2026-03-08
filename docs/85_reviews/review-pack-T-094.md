# Review Pack

## Objective
- Task: T-094
- User story: Sidebar integration and linked-session normal-path removal
- Acceptance criteria touched: sidebar can jump to existing V2 terminal tiles, normal path creates no linked sessions, obsolete linked-session filtering/title-leak behavior is removed from the main path

## Summary (3-7 lines)
- The visible cockpit composition now uses Workbench V2 as the default mainline path, without branching on `WorkbenchStoreV2.isFeatureEnabled()`.
- Sidebar session/window/pane open actions now route through `WorkbenchStoreV2.openTerminal(...)`, so default open/reopen behavior uses direct session refs and existing-tile reveal semantics.
- The default cockpit wiring no longer injects `WorkspaceStore` into the normal path, and UI tests no longer load persisted workbench snapshots during XCTest launches.
- `AppViewModel` no longer hides `agtmux-linked-*` names or canonicalizes sidebar identity through `session_group`; the normal sidebar path now preserves exact tmux session names and only dedupes exact duplicate rows.
- review then reopened one regression: exact-session alias rows were still sharing selection/highlight state via `source + window + pane` matching.
- the follow-up fix is now landed: `retainSelection(...)` and sidebar selected-row matching both preserve full pane identity including `sessionName`, and regression coverage now covers refresh-time retention plus exact selected-row marker behavior.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/CockpitView.swift`
- `Sources/AgtmuxTerm/TitlebarChromeView.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/main.swift`
- `Sources/AgtmuxTerm/WindowChromeController.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
- `Tests/AgtmuxTermCoreTests/PaneFilterTests.swift` (deleted)

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (17 tests)
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (4 tests)
  - `swift test -q --filter AppViewModelA0Tests` => PASS (17 tests)
  - `xcodegen generate` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct` => PASS
  - post-review fix rerun: `swift build` => PASS
  - post-review fix rerun: `swift test -q --filter AppViewModelA0Tests` => PASS (18 tests)
  - post-review fix rerun: `swift test -q --filter WorkbenchStoreV2Tests` => PASS (17 tests)
  - post-review fix rerun: `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (4 tests)
  - post-review fix rerun: `xcodegen generate` => PASS
  - post-review fix rerun: `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow` => PASS command / 6 SKIPs (`screenLocked=1`)
  - post-review fix rerun: `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow` => PASS command / 6 SKIPs (`screenLocked=1`)
  - unlocked rerun: `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow` => PASS (6 tests)
- Notes:
  - slice 1 needed orchestrator fallback after the real agent CLI stalled and the delegated Codex implementation tier did not return a timely usable handoff
  - the locked-session reruns above were environment-only evidence gaps; after the desktop was unlocked, the same 6 targeted UI proofs executed and passed on the current worktree
  - the duplicate-open proof initially flaked once during the first unlocked batch because the test re-queried the row before click; `AgtmuxTermUITests` now reuses the already-resolved row element, and the final full 6-test rerun passed
  - the usual multiple-destination warning and non-fatal `SACSetScreenSaverCanRun returned 22` were emitted by `xcodebuild`
  - build/test output still contains an existing unrelated warning in `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift:69` about a main-actor-isolated static property referenced from a nonisolated context

## Risk declaration
- Breaking change: yes; sidebar session visibility now follows exact tmux session names instead of collapsing `session_group` aliases or hiding linked-looking names
- Fallbacks: none in product behavior; sidebar identity now preserves exact session truth without silent retarget/filter rules
- Known gaps / follow-ups:
  - legacy linked-session implementation files and legacy-only tests still exist in the repo, but they are no longer on the normal product path
  - no additional follow-up is registered yet for physically deleting the entire V1 linked-session implementation surface

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Initial reviewer verdicts:
  - independent Codex review #1: `NO_GO`
  - independent Codex review #2: `GO_WITH_CONDITIONS`
- Initial blocking findings:
  - sidebar selected-row matching still collapsed sibling alias rows that shared `source + windowId + paneId`
  - `retainSelection(...)` could retarget `selectedPane` to the wrong alias session on refresh because it ignored `sessionName`
  - the alias-session UI proof only checked visibility, and selected-marker lookup was too coarse to distinguish exact session rows
- Remediation status:
  - `AppViewModel.retainSelection(...)` now preserves full pane identity (`source + sessionName + windowId + paneId`)
  - `SidebarView` selected-row matching now uses the same exact pane-identity contract
  - `AppViewModelA0Tests` now covers refresh-time retention of the exact selected alias session with reversed fetch ordering
  - `AgtmuxTermUITests` now includes exact selected-row marker coverage, and the helper keys markers by full `AccessibilityID.paneKey(...)`
- Final reviewer verdicts:
  - independent Codex review #1: `GO`
  - independent Codex review #2: `GO`
- Final note:
  - both final reviewers treated the earlier `screenLocked=1` UI skip as an environment evidence gap rather than a remaining code blocker; that evidence gap is now cleared by the unlocked rerun above
