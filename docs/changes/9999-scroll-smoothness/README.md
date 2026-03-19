# Change Pack

- **Issue:** `#9999` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [2026-03-18-scroll-smoothness-baseline.md](../../research/2026-03-18-scroll-smoothness-baseline.md)

This pack tracks the current scroll-smoothness investigation and first-wave
implementation for embedded Ghostty history scrolling.

Current state:

- render-callback/direct-draw scheduling is in place for the
  `GHOSTTY_ACTION_RENDER` path
- store publish and island remount churn were reduced but were not the primary
  limiter in the captured history-scroll case
- the full-app trackpad bench now measures IOSurface layer presentation
  directly, and the current best-known path is a coalesced synchronous scroll
  draw plus a short active-scroll draw pump on the main queue
- the latest accepted code change in this branch is telemetry-only: it surfaces
  scroll-presentation draw cadence and first-draw completion directly in the
  full-app bench without changing pacing behavior
- the latest accepted telemetry follow-up adds per-burst raw sample slices for
  `scroll_to_first_draw`, `scroll_to_layer_present`, and draw-gap metrics so
  long-burst tails can be attributed to specific bursts instead of only to the
  whole run
- the latest accepted telemetry follow-up also surfaces scheduler-specific
  latency slices for `scroll_presentation_immediate_queue_delay`,
  `scroll_presentation_pump_wake_lateness`, and
  `scroll_presentation_recovery_probe_wake_lateness` in both the aggregate and
  per-burst bench output
- the current best-known installed-app result on this host for the default
  4-burst run is `scroll_to_layer_present_ms p50 1.936 / p95 12.991 / max 19.428`
- the current longer-run installed stress sample is still noisier at
  `scroll_to_layer_present_ms p50 2.107 / p95 26.922 / max 55.768`, so long
  burst trains still show `25-55ms` spikes even though the short-burst path is
  much closer to native
- the latest accepted improvement is a present-aware immediate-draw throttle:
  it only suppresses another immediate draw once the previous scroll draw has
  actually produced a layer presentation
- the latest follow-up improvement adds a delayed-present recovery probe:
  after a scroll draw, a single extra recovery draw is scheduled only if the
  IOSurface layer still has not advanced after `1/180s`
- two follow-up experiments were explicitly rejected on 2026-03-18 because they
  regressed release behavior: moving the draw pump to a `commonModes`
  run-loop timer, relaxing the immediate-draw throttle below the pump cadence,
  moving the delayed-present recovery probe earlier to `1/240s`, shortening the
  draw-pump tail to `0.12s`, and slowing the draw-pump interval to `1/100s`
- three later experiments were also rejected after burst-level telemetry made
  the tails attributable: inline first-draw execution regressed both the short
  and long release paths, direction-change cadence resets produced false wins by
  altering the visible-line path itself, backlog-aware recovery redraws
  regressed both `4-burst` and `8-burst` release samples, and backlog-aware
  immediate-throttle bypass thresholds (`0.85x`, `0.90x`, `0.95x`) never
  improved both the short and long release paths at the same time
- the new scheduler telemetry shows that immediate queue delay is not the
  limiter on this host; the persistent long-burst tails line up with large
  `pump_wake_lateness` / `recovery_probe_wake_lateness` spikes in alternating
  `up` bursts
- four additional pacing ideas were measured and rejected after that telemetry:
  an overdue-pump immediate-draw bypass, moving the draw pump to one-shot
  `RunLoop.main` `.common` timers, limiting delayed-present recovery probes to
  immediate draws only, and bypassing the throttle after two pending scroll
  inputs. All four either regressed the short path, kept the long-path `p95`
  flat, or made variance worse despite isolated wins on `max`
- three wake-path follow-ups were also rejected after direct measurement:
  a view-scoped `NSView.displayLink(...)` pump/recovery replacement, a
  background-queue timer that hopped back through
  `CFRunLoopPerformBlock(... commonModes ...)`, and draw-relative timer
  rescheduling after every successful scroll draw. All three reduced some wake
  telemetry, but none beat the best-known baseline on user-visible
  `scroll_to_layer_present_ms`; the draw-relative reschedule variant still
  landed at release `4-burst p50 7.340 / p95 23.081 / max 23.868` and
  `8-burst p50 8.124 / p95 41.497 / max 90.814`
- repo-local validation is green for `validate-macos-ci.sh` and
  `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
- the only broad SwiftPM failure on this host is the live Claude probe in
  `AppViewModelLiveManagedAgentTests`, where `claude -p` times out/returns
  non-zero without output before the app assertions begin
- after granting automation permission, the SSH-launched macOS UI E2E rerun
  reaches test execution again and returns to the expected single remaining
  failure: `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
