# Design

## Chosen Approach

The first wave validated a useful baseline:

1. keep the full-app transcript-style trackpad bench and presentation telemetry
2. reduce surrounding SwiftUI/store churn and pane-retarget flashes
3. use coalesced host-side draws only where the host truly owns the seam
   already (`GHOSTTY_ACTION_RENDER`, pane retarget refresh, attach/activate)

That work improved short bursts, but it also changed the main design
assumption:

- the remaining difference versus native Ghostty is no longer explained by the
  old tmux visible-line proxy
- full-app history scroll still mostly bypasses `GHOSTTY_ACTION_RENDER`
- the worst remaining hitches line up with host-owned wake/pump behavior during
  long bursts
- mixed experiments that partially replaced forced draws with queued refreshes
  or alternative timer implementations regressed the long path instead of
  converging on native behavior

The replanned direction is therefore structural rather than incremental:

1. keep the existing host-side scheduler as the fallback baseline, but stop
   treating it as the target architecture for history scroll
2. introduce a native-cadence-led branch for history scroll where the host:
   - forwards scroll input, precision, and momentum to libghostty
   - does not own per-burst cadence with a synthetic draw pump during the main
     direct-touch path
   - only injects host-side recovery draws for explicit host seams
3. treat pane-retarget / attach presentation as separate seams from continuous
   history scroll so those compensations do not dictate the steady-state scroll
   cadence
4. expand parity validation around the user-visible presentation seam, not the
   tmux visible-line proxy alone

Native Ghostty remains the reference: its AppKit scroll path is thin and hands
precision + momentum through to libghostty, while pacing is primarily
renderer/display-link-led rather than host-timer-led.

The latest accepted implementation result updates that plan in one important
way: the first material structural win did not come from making the embedded
path fully renderer-owned. It came from deleting redundant work inside
Ghostty's repeated `updateFrame()` / `rebuildCells(...)` path when the host
asks for another draw without any viewport, mouse, or cursor change. That
vendor-side optimization is now part of the checked-in aggregate Ghostty patch,
and the build provenance is normalized around upstream `v1.2.3` plus that
patch because the tag's original `build.zig.zon` theme tarball URL now 404s.
The latest accepted follow-up keeps that same direction: once a viewport shift
does require a redraw, Ghostty now rebuilds only the explicit row set that can
actually change on a reusable shift instead of scanning every visible row. That
means the next wave should keep attacking embedded renderer/update-frame cost
directly, not return to host-owned timer policy. The newest accepted refinement
cuts the fixed `abs_shift == 1` row-copy cost inside `Contents.shiftRows(...)`
itself by switching those single-row shifts from swap loops to block moves with
recycled row lists. That reduces the first `up` transition further and shifts
the remaining boundary toward later-`up` wake/presentation variance plus any
fixed per-frame work that still survives after the row copy.
The newest accepted refinement carries that same strategy into the foreground
GPU upload. On compatible Metal viewport shifts, the renderer now keeps moved
foreground rows in viewport-shift-relative coordinates, shifts the packed GPU
instance block in place, and re-uploads only the rebuilt row set. The current
in-progress refinement relaxes the two biggest conservative guards around that
path:

1. previous-frame cursor overlay lists are now tracked separately as
   prefix/suffix counts, so sparse sync can shift only the visible-row block
   instead of declining immediately after a bottom frame
2. rebuilt rows inside the moved block no longer force an immediate full
   visible upload when their packed item count changes; the unchanged prefix
   still shifts in place and the suffix from the first count-change row onward
   is re-synced contiguously

The latest in-worktree follow-up narrows that second guard again: rebuilt moved
rows are now compared against their pre-shift source row, not against the same
viewport row index, before the sparse path decides it must fall back. That
keeps sparse foreground sync active across alternating `up` bursts where
adjacent rows legitimately have different packed counts. A parallel host-side
attempt to invalidate stale pending immediate draws at gesture boundaries was
measured and rejected because it made the long-burst path unstable again. The
remaining seam is therefore no longer broad sparse-foreground fallback; it is
the residual isolated `40-60ms` later-`up` outlier that survives even when the
sparse path stays active.

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
  - `scripts/dev/prepare-ghosttykit.sh` pin/patch provenance
  - `scripts/patches/ghostty-agtmux.patch`
  - Ghostty renderer background upload policy on compatible viewport shifts:
    Metal frames now reuse and shift the already-uploaded background grid and
    upload only exposed/mouse rows when the upload chain and viewport metadata
    still match
  - Ghostty renderer foreground upload policy on compatible viewport shifts:
    Metal frames now reuse and shift the already-uploaded packed foreground
    instance block and upload only rebuilt rows when the cursor/fallback guards
    allow it
  - the next wave will likely change `GhosttyTerminalView` scroll ownership
    boundaries more substantially than the earlier tuning-only passes
- unchanged:
  - native Ghostty behavior
  - the existing Gate-L proxy benches
  - workbench architecture outside documentation and investigation notes

## Failure Modes

- If we keep mixing host-forced draws with renderer-queued refreshes in the
  same burst path, we risk improving one run-loop seam while making cadence
  variance worse overall. Recent rejected experiments hit exactly that failure
  mode.
- If native parity work is judged only by tmux-visible-line latency, we can
  declare false wins while the user-visible presentation seam remains worse
  than native Ghostty.
- If host-owned recovery logic bleeds back into the direct-touch path, the
  design collapses into another timer-tuning loop instead of actually reducing
  host cadence ownership.

## Follow-On Risks

- A native-cadence-led branch may expose new bugs around when the host is
  allowed to call `ghostty_surface_draw()` versus `ghostty_surface_refresh()`,
  especially across activation, pane retarget, and background/foreground
  transitions.
- Native Ghostty parity still lacks a perfect apples-to-apples presentation
  benchmark on this host, so the bench strategy must continue to improve in
  parallel with runtime changes.
- Runtime-store or SwiftUI churn may still be secondary contributors, but they
  are no longer the primary design center for the next wave.
