# Review Pack

## Objective
- Task: `T-LF-07`
- User story: local-first `PR-07` dirty-only draw for embedded Ghostty surfaces
- Acceptance criteria touched: active surfaces redraw only when marked dirty or explicitly scheduled; local perf hooks remain usable after the draw-path change; fresh SwiftPM + Xcode verification green

## Summary
- `GhosttyApp` now consumes `GHOSTTY_ACTION_RENDER` as a host-side dirty signal and draws from `SurfacePool`’s active-dirty queue rather than a separate weak `activeSurfaces` table.
- `SurfacePool` now owns the dirty/render-routing invariants by registered `GhosttySurfaceHandle`:
  - newly registered active surfaces request one initial host tick
  - `markDirty(surfaceHandle:)` requests a host tick only when the surface is both dirty and drawable
  - backgrounded dirty surfaces retain their dirty bit and request a host tick when they reactivate
- stale async teardown is now guarded by `expectedViewID`, so an old wrapper release cannot push a replacement view for the same `leafID` into pending GC.
- `GhosttyTerminalView` teardown no longer depends on `GhosttyApp` bookkeeping; freeing a surface does not mutate app-side draw membership.
- new scheduler/handle-lifecycle tests cover register, render, background/reactivate, re-register, and stale-release races through the host draw path.

## Change scope
- `Sources/AgtmuxTerm/SurfacePool.swift`
- `Sources/AgtmuxTerm/GhosttyApp.swift`
- `Sources/AgtmuxTerm/GhosttyTerminalView.swift`
- `Sources/AgtmuxTerm/WorkbenchGhosttyIsland.swift`
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyCLIOSCBridgeTests.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyTerminalViewIMETests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `scripts/perf/local_scroll_bench.sh` => PASS
  - `swift test --filter GhosttyCLIOSCBridgeTests` => PASS (`25` tests)
  - `swift test --filter GhosttyTerminalViewIMETests` => PASS (`2` tests)
  - `swift test --skip AppViewModelLiveManagedAgentTests` => PASS (`331` tests, `0` failures)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO` => PASS
- Notes:
  - existing unrelated dirty-worktree edits in `SidebarView.swift`, `TitlebarChromeView.swift`, and `WorkbenchAreaV2.swift` were preserved
  - the perf bench remains the same operator-facing entry point; this slice only changes the host draw scheduler underneath it

## Risk declaration
- Breaking change: no
- Fallbacks: explicit; there is still no silent libghostty wakeup fallback, so dirty work must request a host tick through the scheduler seam or stay visible in tests/review
- Known gaps / follow-ups:
  - `T-LF-08` remains the next slice for render scheduler cleanup / multi-display audit
  - this slice does not redesign libghostty wakeups; it makes host-side wake scheduling explicit for `active ∩ dirty`

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Focus on: stale/missed draws, dirty-bit loss across background/activation, surface-handle lifecycle safety, and test sufficiency after the scheduler rewrite

## Review outcome
- Prior Codex review 1: `NO_GO`
  - reattached surfaces could drop out of the draw scheduler because draw iteration still depended on `GhosttyApp.activeSurfaces`
  - stale async wrapper teardown could schedule GC for a replacement view because `release` keyed only on `leafID`
- Prior Codex review 2: `NO_GO`
  - dirty active work did not explicitly request a host tick on `register` / `activate`
  - tests covered set math but not the actual host scheduler path or surface-handle replacement lifecycle
- Fresh Codex CLI review: blocked in this environment
  - `codex review --uncommitted` failed on March 13, 2026 with websocket/DNS lookup failure for `chatgpt.com` and HTTPS fallback request-send failure
- Fresh Codex subagent review A: `GO`
  - no findings
- Fresh Codex subagent review B: `GO`
  - no findings
  - residual non-blocking gaps:
    - focused tests do not run the full async `DispatchQueue.main.async -> tick()` wakeup path end to end
    - stale-release protection is covered directly at `SurfacePool.release(...)`, not through the wrapper async teardown entrypoints
