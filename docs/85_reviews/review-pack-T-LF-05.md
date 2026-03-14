# Review Pack

## Objective
- Task: `T-LF-05`
- User story: local-first `PR-05` focused navigation actor extraction
- Acceptance criteria touched: focused navigation owner extracted from tile view lifecycle; exact-client control-mode retry/send behavior preserved; fresh `swift build` + relevant tests + Xcode build green

## Summary
- Added `WorkbenchFocusedNavigationActor` as the owner of focused navigation polling/control-mode loops.
- `WorkbenchAreaV2` now hands a snapshot into that owner and keeps only UI-facing state plus the existing remote blur stop hook.
- The extracted owner preserves stale-run suppression against current focused tile/runtime context before store writes.
- Control-mode sends now re-read the latest rendered client tty on every send attempt, retry transient `control mode not connected` races, and fall back to `select-pane -t` only when no tty is currently bound.
- The handoff identity now includes desired/observed exact-row state so convergence updates re-issue the owner snapshot even when pane/window IDs stay the same.
- Added focused integration coverage for stale-run suppression, transient control-mode connect races, and exact-row task-identity refresh.

## Change scope
- `Sources/AgtmuxTerm/WorkbenchFocusedNavigationActor.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchFocusedNavigationActorTests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `swift test --filter WorkbenchFocusedNavigationActorTests` => PASS (`8` tests)
  - `swift test --filter WorkbenchV2NavigationSyncResolverTests` => PASS (`3` tests)
  - `swift test --skip AppViewModelLiveManagedAgentTests` => PASS (`321` tests, `0` failures)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO` => PASS
- Notes:
  - Preserved the existing unrelated `WorkbenchAreaV2.swift` restore/accessibility UI edits already present in the worktree.
  - Implementation delegation was attempted twice but did not produce a usable patch; orchestrator direct fallback was used for this slice after that failure mode.
  - Initial Codex reviews returned `NO_GO` for the control-mode connection race and snapshot/task-identity drift; this revision addresses both before re-review.

## Risk declaration
- Breaking change: no
- Fallbacks: minimal; remote blur stop lifecycle remains view-owned in this slice by design
- Known gaps / follow-ups:
  - `T-LF-06` should decide whether remaining view-owned remote blur lifecycle also moves behind the navigation owner or a broader command broker.
  - The extracted owner now treats only `control mode not connected` as a transient retry; other send failures still surface explicitly.

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Review outcome
- Initial Codex review rounds returned `NO_GO` for the control-mode connection race and snapshot/task-identity drift.
- Post-fix Codex CLI re-review returned `GO`.
- Reviewer assumption: `WorkbenchAreaV2.swift` `.task` / `.onDisappear` continue to deliver the latest snapshot to the actor and call `navigationActor.stop()` on view teardown.
