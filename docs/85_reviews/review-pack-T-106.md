# Review Pack

## Objective
- Task: T-106
- User story: remove the obsolete linked-session workspace implementation so the shipped V2 product path no longer compiles or documents linked-session creation as active behavior
- Acceptance criteria touched:
  - shipped app target no longer wires or compiles the legacy linked-session workspace path
  - linked-session creation helpers and legacy workspace-only runtime types are removed unless still required by an explicitly retained non-product surface
  - tests/docs no longer present linked-session or session-group behavior as an active product contract
  - focused verification proves the V2 mainline still opens real sessions directly without linked-session regressions

## Summary
- Deleted the dead linked-session workspace runtime from shipped targets: `WorkspaceArea`, `WorkspaceStore`, and `LinkedSessionManager`.
- Removed the legacy-only core layout layer (`LayoutNode`, `TmuxLayoutConverter`, and related tests) after extracting the still-live shared pieces into `SplitAxis.swift` and `TmuxCommandRunner.swift`.
- Trimmed linked-session-specific indexing from `SurfacePool` so the remaining V2 terminal surface lifecycle no longer carries hidden linked-session state.
- Deleted linked-session-positive integration/UI proofs and narrowed the surviving UI contract to V2 direct attach plus exact-session identity behavior.
- Updated tracking/design docs and the UITest README so linked-session creation/title rewriting is no longer described as active product behavior.

## Change scope
- `Sources/AgtmuxTerm/LinkedSessionManager.swift`
- `Sources/AgtmuxTerm/WorkspaceArea.swift`
- `Sources/AgtmuxTerm/WorkspaceStore.swift`
- `Sources/AgtmuxTerm/TmuxCommandRunner.swift`
- `Sources/AgtmuxTerm/SurfacePool.swift`
- `Sources/AgtmuxTermCore/SplitAxis.swift`
- `Sources/AgtmuxTermCore/LayoutNode.swift`
- `Sources/AgtmuxTermCore/TmuxLayoutConverter.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
- `Tests/AgtmuxTermUITests/README.md`

## Verification evidence
- Commands run:
  - `xcodegen generate` => PASS
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2ModelsTests` => PASS
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests` => PASS
  - `swift test -q --filter PaneFilterTests` => PASS
  - `swift test -q --filter AppViewModelA0Tests` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile` => PASS with `testPaneSelectionWithMockDaemonAndRealTmux` skipped because the runner could not keep a tmux session alive
- Notes:
  - `SACSetScreenSaverCanRun returned 22` appeared during targeted UI runs but did not cause failure.
  - `GhosttyCLIOSCBridge.shared` actor-isolation warning remains pre-existing and non-fatal for this slice.

## Risk declaration
- Breaking change: yes, intentionally removes the obsolete linked-session workspace implementation and its positive coverage
- Fallbacks: none; deletion is explicit and fail-loud
- Known gaps / follow-ups:
  - `testPaneSelectionWithMockDaemonAndRealTmux` still depends on runner-side tmux viability and can skip in sandboxed sessions
  - no review verdict has been recorded for this pack yet

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required
