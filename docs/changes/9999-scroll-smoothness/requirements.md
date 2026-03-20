# Requirements

## Problem

Embedded Ghostty still feels visibly rougher than native Ghostty when the user
scrolls long Claude/Codex histories. Existing Gate-L parity only measures
`input -> tmux visible-line change`, so it can miss frame pacing regressions and
host-side scheduling stalls.

## Goals

- add a full-app continuous-scroll bench that uses transcript-like fixture data
- expose enough telemetry to tell whether scroll events hit host render/draw
  scheduling or bypass it entirely
- reduce host-side render callback latency for surfaces that do flow through
  `GHOSTTY_ACTION_RENDER`
- avoid visible black flashes when the active pane changes within the same tmux
  window and the existing Ghostty surface should remain attached
- document the current evidence, including the tests and perf runs from
  2026-03-18
- replan the remaining scroll work around native-cadence parity instead of
  continuing timer-by-timer host scheduler tuning
- make the accepted vendor-side Ghostty optimization reproducible from a fresh
  pinned upstream checkout instead of depending on an already-dirty local
  `vendor/ghostty`

## Non-Goals

- redesigning the entire SwiftUI workbench or polling architecture in this wave
- adding user-facing settings for scroll behavior
- forcing a `ghostty_surface_draw()` regression to synchronous drawing
- claiming native parity from the tmux visible-line proxy alone

## Acceptance

- [x] `scripts/perf/gate_l_trackpad_history_scroll_bench.sh` runs in full-app
      mode and emits burst latency plus host telemetry JSON
- [x] render-callback surfaces use a coalesced direct dirty-draw pass instead of
      always waiting for the next scheduled tick
- [x] integration tests cover direct-draw coalescing, background dirty retention,
      and scroll telemetry accumulation/reset
- [x] runbook and dated research capture the commands and results from the
      2026-03-18 investigation
- [x] same-window pane retarget logic preserves the existing surface path and
      has regression coverage for the pane-retarget refresh decision
- [x] the change pack is replanned around a native-cadence-led architecture for
      the remaining history-scroll gap
- [x] `prepare-ghosttykit.sh` can rebuild from a fresh pinned upstream Ghostty
      checkout using the checked-in aggregate patch that carries both the
      scroll optimization and any required build-fix drift
- [ ] embedded trackpad/history smoothness reaches native-like behavior in the
      real UI, not just proxy parity
