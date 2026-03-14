# Review Pack

## Objective
- Task: `T-LF-08`
- User story: local-first `PR-08` render scheduler cleanup / multi-display audit for embedded Ghostty surfaces
- Acceptance criteria touched: render scheduling no longer fans out redundant work across display/update paths; focus and multi-display transitions preserve correct active-surface ownership without stale draws; fresh SwiftPM + Xcode verification green

## Summary
- `GhosttyApp` now keeps the wakeup coalescing contract but schedules host ticks on the main run loop common modes by default, with explicit rollback via `AGTMUX_GHOSTTY_SCHEDULER_EXPERIMENT_DISABLED=1`.
- libghostty `GHOSTTY_ACTION_RENDER` still marks the registered surface dirty, but render scheduling is now centralized so metric drift and render actions share the same `SurfacePool` dirty-routing path instead of fanning out ad hoc draw requests.
- `GhosttyTerminalView` now owns surface metric reconciliation for size, content scale, and display ID:
  - it observes window/screen/backing changes
  - computes backing-space metrics once
  - updates libghostty only on actual drift
  - requests a host draw only when the registered view really became dirty
- `GhosttyApp.newSurface(...)` now prefers the window/screen backing scale before falling back to `NSScreen.main`, so first attach is less likely to pick the wrong display scale on multi-display setups.
- hot-path attach/draw `print(...)` logging was removed from the AppKit host wrappers.

## Change scope
- `Sources/AgtmuxTerm/GhosttyApp.swift`
- `Sources/AgtmuxTerm/SurfacePool.swift`
- `Sources/AgtmuxTerm/GhosttyTerminalView.swift`
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
- `Sources/AgtmuxTerm/WorkbenchGhosttyIsland.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyCLIOSCBridgeTests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `scripts/perf/local_scroll_bench.sh` => PASS
  - `swift test --filter GhosttyCLIOSCBridgeTests` => PASS (`29` tests)
  - `swift test --filter GhosttyTerminalViewIMETests` => PASS (`2` tests)
  - `swift test --skip AppViewModelLiveManagedAgentTests` => PASS (`335` tests, `0` failures)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO` => PASS
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` => FAIL (`9` tests, `3` failures)
  - focused live rerun `.../testLiveCodexCompletedIdleWithoutPendingRequestDoesNotSurfaceAttentionFilter` => FAIL
  - focused live rerun `.../testLiveCodexInteractiveRunningSentinelStillSurfacesExactRunningTruth` => FAIL
  - focused live rerun `.../testLiveSyncV3BootstrapAndChangesUpdateExactCodexRowWithoutFallingBackToV2` => PASS
- Notes:
  - existing unrelated dirty-worktree edits in `SidebarView.swift`, `TitlebarChromeView.swift`, and `WorkbenchAreaV2.swift` were preserved
  - this slice does not change daemon-vs-term truth; it only narrows host draw scheduling and display-metric application
  - the live full-lane failures are outside the changed T-LF-08 files and persisted after isolated reruns on the two Codex-managed cases above; they are recorded as separate live-suite signal, not as a blocker on the render-scheduler diff review

## Risk declaration
- Breaking change: no
- Fallbacks: explicit rollback only; scheduler rollback is `AGTMUX_GHOSTTY_SCHEDULER_EXPERIMENT_DISABLED=1`, and there is no silent fallback for display/dirty drift
- Known gaps / follow-ups:
  - focused tests exercise the dirty scheduler and metric-drift logic directly, but there is still no full async end-to-end assertion for the run-loop scheduled wakeup path
  - Gate-L parity measurement remains open after this slice closes

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Focus on: run-loop scheduling correctness, multi-display/content-scale drift safety, stale draw ownership across background/reactivate, and missing regression coverage around the new scheduler path

## Review outcome
- Prior Codex review A: `NO_GO`
  - `GhosttyTerminalView.viewDidMoveToWindow()` force-applied fallback metrics when `window == nil`, so detach/reparent paths could write bogus scale/display values and schedule an unnecessary draw
- Prior Codex review B: `NO_GO`
  - render actions emitted during `ghostty_app_tick()` still queued a redundant follow-up tick, so the new scheduler path kept the churn this slice was supposed to remove
- Fixes landed:
  - `GhosttyTerminalView` now skips metric sync when detached and requires a real window for backing/display metrics
  - `GhosttyApp.scheduleTickIfInitialized()` now suppresses schedule requests while a tick is already executing
  - regression tests now cover in-tick render scheduling suppression and no-window detach behavior
- Fresh Codex re-review A: `GO`
  - no in-scope findings; stale verification counts in this review pack were noted and corrected
- Fresh Codex re-review B: `GO`
  - no in-scope findings; prior scheduler churn and detach-metric regressions are fixed and directly covered
