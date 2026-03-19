# Design

## Chosen Approach

The first wave keeps two tracks in parallel:

1. Improve the host-side render callback path by marking render-targeted active
   surfaces dirty and scheduling one coalesced direct draw pass on the main run
   loop, instead of always waiting for the next `tick()`.
2. Add a continuous trackpad-style bench in full-app mode with transcript-like
   history data. The bench reports both tmux-visible-line latency and host-side
   scroll telemetry.
3. Reduce SwiftUI-side churn around the terminal island by:
   - guarding AppViewModel store sync helpers against same-value writes
   - keeping the Ghostty island identity stable per tile instead of remounting
     on every `plan.command` change
   - letting `GhosttyIslandViewController.update(...)` handle command changes
     without controller teardown/recreation
4. Treat same-window pane retargets as another presentation seam on the
   existing surface instead of as an attach problem:
   - keep the attach plan frozen and the Ghostty island stable
   - when only the visible pane target changes, schedule one coalesced
     `ghostty_surface_draw()` on the existing surface plus a short recovery
     probe if the layer still has not advanced
   - stop animating the sidebar's auto-scroll on pane-selection changes so
     pane retargets do not add extra main-thread/compositing churn

The new evidence from 2026-03-18 changed one design assumption: trackpad
history scroll currently reaches `GhosttyTerminalView.scrollWheel`, but the
bench does not observe `GHOSTTY_ACTION_RENDER`, `runDirtyDrawPass()`, or any
`SurfaceDraw` signposts for that path. The bench therefore treats tmux-visible
line change as the primary metric and host telemetry as a secondary diagnostic
surface instead of failing when render callbacks stay at zero.

## Boundaries

- changed:
  - `GhosttyApp` direct-draw scheduling for render callbacks
  - `SurfacePool` dirty-surface consumption and direct-draw dirty marking
  - `GhosttyTerminalView` scroll telemetry capture and test seams
  - UITest bridge commands for resetting/dumping scroll telemetry
  - `AppViewModel` same-value store sync suppression
  - `SidebarView` pane-selection auto-scroll pacing
  - `WorkbenchAreaV2` stable Ghostty island identity
  - `WorkbenchGhosttyIsland` lower-overhead update path plus pane-retarget
    presentation refresh scheduling
  - perf harness support for pixel/trackpad bursts and transcript-history bench
- unchanged:
  - native Ghostty behavior
  - the existing Gate-L proxy benches
  - workbench architecture outside documentation and investigation notes

## Failure Modes

- If scroll path telemetry never completes, the bench still records burst
  latency and flags `render_callback_captured=false` / `first_draw_captured=false`
  so we do not mistake missing instrumentation for a clean result.
- If no burst changes tmux-visible content, the bench exits non-zero instead of
  silently emitting empty metrics.
- The direct-draw path stays coalesced and is skipped for backgrounded surfaces
  so render callbacks do not cause re-entrant or invisible draw work.

## Follow-On Risks

- `WorkbenchTerminalTileViewV2` still sits near runtime-store, health, and
  active-pane context updates plus attach/navigation tasks. If the real scroll
  path bypasses host render callbacks, those surrounding main-thread updates
  remain a leading next-wave suspect.
- `GhosttyIslandRepresentable(...).id("ghostty-island:...:\(plan.command)")`
  remains a watchpoint if attach-plan identity drifts more often than expected.
