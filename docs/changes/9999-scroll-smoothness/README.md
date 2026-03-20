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
- the latest accepted bench/runtime follow-up makes the synthetic trackpad
  sender phase-aware (`trackpad-burst`) and uses `event.phase == .began` to
  invalidate stale scroll pump / recovery timers at real gesture boundaries
- the latest accepted telemetry follow-up adds per-burst raw sample slices for
  `scroll_to_first_draw`, `scroll_to_layer_present`, and draw-gap metrics so
  long-burst tails can be attributed to specific bursts instead of only to the
  whole run
- the latest accepted telemetry follow-up also surfaces scheduler-specific
  latency slices for `scroll_presentation_immediate_queue_delay`,
  `scroll_presentation_pump_wake_lateness`, and
  `scroll_presentation_recovery_probe_wake_lateness` in both the aggregate and
  per-burst bench output
- the latest accepted UI-path follow-up treats same-window pane retargets as a
  presentation seam on the existing Ghostty surface: the island now schedules a
  coalesced immediate draw plus a short recovery probe when the visible pane
  target changes without an attach-command change, and the sidebar no longer
  animates its auto-scroll on pane-selection changes
- the current best-known installed-app result on this host for the default
  4-burst run is `scroll_to_layer_present_ms p50 1.936 / p95 12.991 / max 19.428`
- the current longer-run installed stress sample is still noisier at
  `scroll_to_layer_present_ms p50 2.107 / p95 26.922 / max 55.768`, so long
  burst trains still show `25-55ms` spikes even though the short-burst path is
  much closer to native
- on the accepted phase-aware release sample from 2026-03-19, the short path
  improved materially:
  `scroll_to_layer_present_ms p50 4.009 / p95 16.917 / max 24.102`
- the same accepted release sample still leaves a long-burst tail, but the
  `8-burst` stress path also improved modestly relative to the same phase-aware
  harness without gesture-boundary invalidation:
  `scroll_to_layer_present_ms p50 3.991 / p95 49.586 / max 115.386`
  vs. `p50 4.686 / p95 51.290 / max 176.185`
- a native Ghostty companion script now exists for the same transcript-style
  pixel-burst input path:
  `scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`
- on this host on 2026-03-19, that same-input `tmux_visible_line_change_ms`
  proxy was effectively identical between embedded and native:
  embedded `p50 567.724 / p95 583.263 / max 583.263`,
  native `p50 575.531 / p95 578.756 / max 578.756`
- that near-parity confirms again that the tmux-visible-line proxy is not the
  metric that matches the remaining user-visible jank
- an apples-to-apples screen/image-diff parity attempt was blocked on this host
  because `screencapture` failed with `could not create image from display`,
  which indicates missing Screen Recording capability for the current terminal
  environment
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
- three native-cadence subsets were also measured and rejected on 2026-03-19:
  removing timer continuation during active precise gestures,
  deferring all precise steady-state changed events to a single input-recovery
  probe, and a present-aware version of that same defer path. All three kept
  the `down` bursts healthy but regressed alternating `up` bursts or produced
  empty bursts, so the current evidence is that the `up` scrollback path still
  depends on host immediate draws more than the `down` path does
- a more aggressive phase-aware scheduler variant was also rejected on
  2026-03-19: giving phase/momentum its own continuation deadline regressed the
  release path to `4-burst p50 3.338 / p95 43.484 / max 53.892` and
  `8-burst p50 2.859 / p95 69.332 / max 146.293`
- the latest accepted follow-up keeps the phase-aware sender and broadens the
  gesture-boundary invalidation slightly: `event.phase == .began` now cancels
  stale pending immediate draws as well as stale pump/recovery timers, so a new
  burst does not wait behind an older coalesced draw request
- on this host's latest serial release sample after that change:
  `4-burst scroll_to_layer_present_ms p50 3.032 / p95 29.512 / max 46.259`
  and `8-burst p50 6.518 / p95 28.570 / max 69.155`
- the short path is still noisy run-to-run, but the long-burst tail on the
  accepted serial sample dropped well below the earlier phase-aware baseline
  without pending-draw invalidation
- the latest accepted production-path follow-up removes benchmark bookkeeping
  from normal app launches: scroll telemetry now defaults off unless the app is
  running under `AGTMUX_UITEST`, under XCTest, or with
  `AGTMUX_SCROLL_TELEMETRY=1`
- that change does not alter the scheduler itself; it strips per-event
  signposts and sample-array appends from the user hot path while preserving the
  full telemetry surface for perf benches and tests
- the next wave is now explicitly replanned around native-cadence parity:
  recent host-side pump/refresh mixing improved isolated seams but kept
  regressing long-burst tail behavior, so further timer-level tuning is no
  longer the primary strategy
- native Ghostty and cmux code review both reinforce that direction: their
  trackpad input paths are thin, while cadence stays with the renderer /
  display-linked wake path rather than with host-owned timers
- the release smoke run with `AGTMUX_SCROLL_TELEMETRY=0` still completes the
  full trackpad bench path and keeps the proxy metric stable at
  `tmux_visible_line_change_ms p50 584.144 / p95 590.875 / max 590.875`
- the corresponding telemetry-enabled release rerun remained noisy on this host
  at `scroll_to_layer_present_ms p50 5.346 / p95 39.518 / max 53.005`, so this
  follow-up is accepted as a production overhead reduction rather than as a
  measured bench win on the presentation seam
- a fuller renderer-owned structural wave was measured on 2026-03-20 and none
  of the stricter variants beat the best-known hybrid baseline:
  - display-link active-session path:
    `4-burst p50 16.611 / p95 50.387 / max 71.750`,
    `8-burst p50 25.430 / p95 124.453 / max 392.601`
  - renderer wakeup plus display-link fallback:
    `4-burst p50 25.089 / p95 92.284 / max 395.373`,
    `8-burst p50 17.730 / p95 94.427 / max 378.578`
  - pure upstream `scrollViewport -> queueRender -> display-link draw`:
    `4-burst p50 24.039 / p95 88.319 / max 117.684`,
    `8-burst p50 26.922 / p95 270.136 / max 378.850`
- those results mean the remaining gap is not explained by host timer cadence
  alone; the strongest current inference is that alternating `up` bursts are
  dominated by embedded Ghostty scrollback rebuild cost once viewport changes
  are renderer-owned
- the next vendor-side follow-up tested that inference directly inside
  Ghostty's renderer/update-frame path:
  - a first attempt that also relaxed the first-`up` fast-path guard and shrank
    dirty-bit clearing was rejected because it made `p95` worse even when `max`
    improved:
    `4-burst p50 8.817 / p95 61.803 / max 82.141`,
    `8-burst p50 9.657 / p95 60.814 / max 132.388`
  - a second dirty-clear variant was also rejected:
    `4-burst p50 8.891 / p95 62.591 / max 88.392`,
    `8-burst p50 9.288 / p95 57.770 / max 114.206`
- the accepted vendor-side win is narrower and cheaper:
  repeated host-driven draws now skip `rebuildCells(...)` entirely when the
  viewport, cursor style, and mouse state are unchanged, instead of rebuilding
  identical cells on every recovery/pump draw
- on the latest serial release sample from that branch:
  - `4-burst scroll_to_layer_present_ms p50 8.068 / p95 23.153 / max 24.423`
  - `8-burst scroll_to_layer_present_ms p50 9.407 / p95 28.712 / max 30.561`
- compared to the prior accepted live-screen/no-clone baseline:
  - `4-burst`: `p50 8.561 / p95 37.247 / max 109.972`
  - `8-burst`: `p50 8.982 / p95 53.995 / max 146.282`
- this is the first structural win that materially reduces both short-burst and
  long-burst tails after the stricter renderer-owned branches failed, which
  reinforces the newer hypothesis that redundant embedded `updateFrame()` work
  is the main remaining limiter
- the provenance mismatch behind that win is now repaired:
  `prepare-ghosttykit.sh` is repinned to upstream Ghostty `v1.2.3`, the checked-in
  aggregate patch now matches the current vendor diff exactly, and it also
  carries the minimal `build.zig.zon` dependency refresh needed because the
  upstream tag's original theme tarball URL now 404s
- a fresh-clone rebuild of `GhosttyKit` now succeeds again via the checked-in
  patch flow, so the vendor-side scroll win is reproducible instead of relying
  on an already-dirty local `vendor/ghostty`
- the latest fresh-provenance release rerun on this host kept the same broad
  win:
  - `4-burst scroll_to_layer_present_ms p50 9.830 / p95 22.510 / max 23.349`
  - `8-burst scroll_to_layer_present_ms p50 7.998 / p95 28.669 / max 50.843`
- the latest accepted vendor-side follow-up keeps the same provenance and
  cadence ownership but removes more reusable viewport-shift renderer work:
  after cached rows are shifted, Ghostty now rebuilds only the exposed
  fringe/sentinel/shift-extra rows, current or previous mouse rows, and rows
  still marked dirty instead of scanning every visible viewport row on each
  reusable viewport shift
- on the latest release sample from that branch:
  - `4-burst scroll_to_layer_present_ms p50 6.243 / p95 21.078 / max 42.474`
  - `8-burst scroll_to_layer_present_ms p50 4.393 / p95 24.264 / max 39.498`
- compared to the fresh-provenance baseline above:
  - `4-burst` median and `p95` improved, but `max` remained noisier
  - `8-burst` improved materially across `p50`, `p95`, and `max`
- this is the first accepted vendor-side win after provenance repair that
  improves the longer burst train itself, not just identical-frame redraws, so
  the next target remains the expensive first `up` / scrollback-transition seam
- the latest accepted follow-up narrows that same first-`up` seam further:
  viewport shifts no longer force a full top/bottom sentinel-row rebuild just
  to refresh padding heuristics; instead the renderer recomputes
  `padding_extend.up/down` directly from the current viewport edge rows after
  the sparse row-set rebuild
- on the latest release sample from that branch:
  - `4-burst scroll_to_layer_present_ms p50 5.279 / p95 16.338 / max 22.517`
  - `8-burst scroll_to_layer_present_ms p50 4.307 / p95 23.698 / max 125.957`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.032 / p95 25.835 / max 72.321`
- compared to the accepted sparse-row baseline above:
  - the short path improved clearly; `4-burst p95` and `max` both fell a lot
  - `8-burst p95` stayed around parity or slightly better, but worst-case
    reruns still showed late-`up` wake spikes
- this makes the current boundary clearer:
  removing sentinel full rebuilds cuts real renderer work from the first `up`
  transition, while the remaining worst-case tail is increasingly explained by
  host wake/presentation variance on later `up` bursts
- the latest accepted host-side follow-up keeps the renderer-side wins above,
  but changes cadence ownership during active precise gestures:
  - direct finger-contact scroll (`event.phase == began/changed/stationary`) now
    bypasses the host throttle and suppresses host pump/recovery continuation
  - the host timer path is reserved for post-contact momentum tail and delayed
    recovery only
  - direction flips inside an active precise gesture invalidate stale scheduled
    wakeups so a new `up` burst does not inherit the prior continuation state
- this same follow-up also fixes the embedded scroll-mod packing mismatch so the
  direct gesture phase is now sent to libghostty in bits `4..6`, matching the
  core `input.ScrollMods` layout even though upstream embedded scroll handling
  does not yet consume that field
- on the latest release sample from this branch:
  - `4-burst scroll_to_layer_present_ms p50 5.751 / p95 15.761 / max 18.422`
  - `8-burst scroll_to_layer_present_ms p50 5.395 / p95 29.695 / max 39.215`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.611 / p95 29.781 / max 33.833`
- compared to the accepted edge-padding baseline above:
  - `4-burst` improved again across `p50`, `p95`, and `max`
  - `8-burst p95` moved up into the high-20ms band, but the late-`up`
    outliers collapsed from `72-126ms` reruns down to repeatable low-30ms caps
- this is accepted as the next structural step because it finally makes active
  trackpad contact renderer/input-owned instead of timer-owned; the remaining
  long-burst issue is no longer catastrophic hitching, but a flatter `up`
  burst tail that still needs another pass
- the latest accepted vendor-side follow-up keeps that phase-aware host path
  but cuts fixed one-row viewport-shift copy cost inside
  `renderer/cell.zig:Contents.shiftRows(...)`:
  - `abs_shift == 1` shifts now use block `fastmem.move(...)` copies for
    background rows and foreground row-list slices instead of per-row swap
    loops
  - the newly exposed fringe row still clears as before, and moved glyphs still
    remap `grid_pos[1]`
- the checked-in aggregate Ghostty patch now carries that `cell.zig` fast path
  too, so fresh-provenance rebuilds stay aligned with the measured vendor tree
- on the latest release sample from that branch:
  - `4-burst scroll_to_layer_present_ms p50 4.909 / p95 16.984 / max 18.636`
  - `8-burst scroll_to_layer_present_ms p50 4.303 / p95 26.875 / max 71.277`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.730 / p95 29.408 / max 31.928`
- compared to the accepted phase-aware baseline above:
  - `4-burst` improved `p50`, held `max` essentially flat, and only moved
    `p95` slightly from `15.761` to `16.984`
  - `8-burst p95` improved from `29.695/29.781` to `26.875/29.408`, and the
    rerun `max` improved from `33.833` to `31.928`
  - one first `8-burst` sample still hit a noisy `71.277ms` outlier, so
    late-`up` wake/presentation variance is not gone yet
- this moves the boundary again:
  fixed renderer row-shift work is lower now, and the next likely seam is
  later-`up` wake/presentation variance plus any remaining fixed per-frame work
  outside the row-shift copy itself
- one follow-up monotonic sparse-row walk was measured and rejected:
  sorting the sparse viewport row set and walking it with `Pin.down(...)` plus
  `orderedContains(...)` regressed the short path to
  `4-burst p50 5.523 / p95 24.295 / max 26.607` and did not improve the long
  path enough to justify it (`8-burst p50 4.864 / p95 26.322 / max 79.141`)
- the latest accepted vendor-side follow-up narrows the first-`up` seam again
  without changing cadence ownership:
  - leaving the live bottom no longer forces `shift_extra_row` rebuilds for
    plain empty-tail cursor rows where clearing the cursor overlay is enough
  - reusable viewport shifts now recompute `padding_extend.up/down` only for
    edges that were not already rebuilt by the sparse row-set itself
- on the latest release sample from that branch:
  - `4-burst scroll_to_layer_present_ms p50 6.124 / p95 13.778 / max 21.418`
  - `8-burst scroll_to_layer_present_ms p50 3.849 / p95 29.281 / max 53.626`
  - `8-burst rerun scroll_to_layer_present_ms p50 4.585 / p95 29.430 / max 38.933`
- compared to the accepted renderer `shiftRows` baseline above:
  - the short path improved clearly again, especially `4-burst p95`
  - the long train stayed essentially flat on `p95` while keeping the rerun
    tail in the same low-`30ms`/high-`30ms` band instead of the earlier
    `70ms`-class first-run spike
- this moves the boundary one notch further:
  first-`up` fixed renderer work is lower again, and the next likely seam is
  now later-`up` wake/presentation variance rather than unconditional
  old-cursor-row or edge-padding rebuild work
- repo-local validation is green for `validate-macos-ci.sh` and
  `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
- the only broad SwiftPM failure on this host is the live Claude probe in
  `AppViewModelLiveManagedAgentTests`, where `claude -p` times out/returns
  non-zero without output before the app assertions begin
- after granting automation permission, the SSH-launched macOS UI E2E rerun
  reaches test execution again and returns to the expected single remaining
  failure: `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- the new metadata-enabled same-window pane-switch UI regression compiles and
  reaches the runner, but on this host the xcodebuild rerun still failed before
  test execution with `Timed out while enabling automation mode`
