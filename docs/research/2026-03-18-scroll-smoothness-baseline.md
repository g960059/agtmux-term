# 2026-03-18 Scroll Smoothness Baseline

## Summary

Embedded Ghostty still regresses against native Ghostty on the existing Gate-L
scroll proxy, and the new full-app trackpad/history bench shows the same
problem from a more realistic fixture. The investigation now has three
important phases:

- embedded Gate-L proxy on 2026-03-18 after the first-wave changes:
  `p50 342.710ms / p95 936.628ms / max 936.628ms`
- native Ghostty Gate-L proxy on 2026-03-18:
  `p50 347.378ms / p95 359.238ms / max 359.238ms`
- full-app trackpad/history bench on 2026-03-18:
  `tmux_visible_line_change_ms p50 593.254ms / p95 609.506ms / max 609.506ms`

The most important new finding is that the trackpad/history scroll path reaches
`GhosttyTerminalView.scrollWheel`, but the bench sees:

- `render_callback_captured = false`
- `first_draw_captured = false`
- `pendingScrollToRenderCount = 62`
- `pendingScrollToDrawCount = 62`

That means the direct-draw render-callback work added in this wave improves one
host path, but it is not yet the observed path for full-app history scroll.

The next two findings narrowed the real path:

- store publish and Ghostty island update churn stayed near zero during the
  4-second trackpad bench, so sidebar/runtime recomposition was not the primary
  limiter in the captured case
- `layer.contents` telemetry showed that the actual scroll path was updating the
  IOSurface layer directly, with bursty presentation cadence even when publish
  churn stayed quiet

After adding a coalesced synchronous scroll draw on the main run loop, the
trackpad/history bench improved on the presentation metric even though the old
tmux-visible proxy metric remained noisy:

- before coalesced scroll draw:
  `scroll_to_layer_present_ms p50 17.383 / p95 91.695 / max 344.594`
  and `layer_present_gap_p50 33.375ms`
- after coalesced scroll draw:
  `scroll_to_layer_present_ms p50 3.297 / p95 40.540 / max 46.660`
  and `layer_present_gap_p50 11.899ms`

After adding a short-lived active-scroll draw pump on top of that coalesced
draw, the best debug run tightened the active burst further:

- debug full-app trackpad/history after active-scroll draw pump:
  `scroll_to_layer_present_ms p50 6.057 / p95 20.330 / max 21.731`
- best-known installed-app result after restoring the non-regressed build:
  `scroll_to_layer_present_ms p50 2.485 / p95 15.514 / max 44.934`
- present-aware immediate-draw throttle on top of the draw pump:
  - debug: `p50 7.406 / p95 25.287 / max 26.414`
  - release bundle: `p50 7.239 / p95 23.345 / max 26.693`
  - installed app: `p50 2.624 / p95 22.626 / max 35.337`
- delayed-present recovery probe at `1/180s` on top of that throttle:
  - debug: `p50 7.020 / p95 22.023 / max 22.955`
  - release bundle: `p50 4.734 / p95 21.600 / max 27.223`
  - installed app reruns after reinstall:
    `p50 2.992 / p95 23.941 / max 44.818` and
    `p50 3.562 / p95 24.004 / max 35.325`

Two follow-up ideas were tested and rejected the same day:

- moving the draw pump to a `CFRunLoop` `commonModes` timer improved some debug
  runs but regressed or destabilized installed release behavior
- relaxing the immediate-draw throttle below the pump cadence improved some
  debug medians but regressed installed release `p95/max`
- moving the delayed-present recovery probe earlier to `1/240s` regressed the
  debug burst path to `p50 3.319 / p95 17.692 / max 35.651`

## Commands And Results

### AX helper trust

```bash
scripts/perf/gate_l_ax_key_sender.sh --dry-run
```

Result: `trusted=true`

### Historical baseline captured before this implementation wave

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_scroll_bench.sh --iterations 5
```

Result: `p50 352.784ms / p95 944.620ms / max 944.620ms`

```bash
scripts/perf/gate_l_native_ghostty_scroll_bench.sh --iterations 5
```

Result: `p50 342.761ms / p95 360.261ms / max 360.261ms`

```bash
AGTMUX_GHOSTTY_SCHEDULER_EXPERIMENT_DISABLED=1 \
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_scroll_bench.sh --iterations 5
```

Result: `p50 374.923ms / p95 1127.302ms / max 1127.302ms`

Disabling the main-runloop scheduler experiment alone did not fix the spikes.

### Current validation after the first-wave implementation

```bash
swift build -c debug --build-path .build-codex
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
```

Result: build succeeded; selected integration tests passed (`33` tests).

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights:

- `tmux_visible_line_change_ms`: `p50 593.254ms / p95 609.506ms / max 609.506ms`
- `empty_burst_count = 0`
- `render_callback_captured = false`
- `first_draw_captured = false`
- `draw_count = 0`
- only non-scroll signposts appeared during the capture:
  `MetadataSync`, `Publish`, `PublishAssemble`, `TmuxRunner`

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_scroll_bench.sh --iterations 5
```

Result: `p50 342.710ms / p95 936.628ms / max 936.628ms`

```bash
scripts/perf/gate_l_native_ghostty_scroll_bench.sh --iterations 5
```

Result: `p50 347.378ms / p95 359.238ms / max 359.238ms`

### Second-wave churn reduction

This wave also removed two likely sources of host-side churn:

- AppViewModel store sync helpers now skip same-value writes to the observable
  runtime/health/sidebar stores.
- `GhosttyIslandRepresentable` now keeps a stable identity per tile instead of
  remounting on `plan.command` drift, while still letting the controller
  recreate the surface when the command itself changes.

Validation:

```bash
swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|WorkbenchV2TerminalRestoreTests|WorkbenchV2TerminalAttachTests'
```

Result: selected tests passed (`60` tests).

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights after focus stabilization in the bench:

- `tmux_visible_line_change_ms`: `p50 585.982ms / p95 638.038ms / max 638.038ms`
- `empty_burst_count = 0`
- `render_callback_captured = false`
- `first_draw_captured = false`
- only light background signposts during the 4s capture:
  `MetadataSync` count `2`, `Publish` count `2`

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_scroll_bench.sh --iterations 5
```

Result: `p50 357.893ms / p95 968.674ms / max 968.674ms`

These churn reductions are still worth keeping, but they did not materially fix
the observed scroll regression by themselves.

### Third-wave layer telemetry and scroll-presentation pacing

This wave added `layer.contents` telemetry directly to `GhosttyTerminalView`,
confirmed that history scrolling reaches IOSurface presentation without
emitting `GHOSTTY_ACTION_RENDER`, and then added one coalesced
`ghostty_surface_draw()` per main-run-loop turn while scrolling.

Validation:

```bash
swift build -c debug --build-path .build-codex
swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|WorkbenchV2TerminalRestoreTests|WorkbenchV2TerminalAttachTests'
```

Result: build succeeded; selected integration tests passed (`61` tests).

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights before the coalesced scroll draw:

- `tmux_visible_line_change_ms`: `p50 612.088ms / p95 619.676ms / max 619.676ms`
- `scroll_to_layer_present_ms`: `p50 17.383ms / p95 91.695ms / max 344.594ms`
- `layer_present_gap_p50_ms = 33.375`
- `layer_present_count = 39`
- `publish_invocation_count = 1`
- `island_update_count = 4`

Result highlights after the coalesced scroll draw:

- `tmux_visible_line_change_ms`: `p50 618.988ms / p95 642.971ms / max 642.971ms`
- `scroll_to_layer_present_ms`: `p50 3.297ms / p95 40.540ms / max 46.660ms`
- `layer_present_gap_p50_ms = 11.899`
- `layer_present_count = 94`
- `publish_invocation_count = 2`
- `island_update_count = 4`

```bash
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_scroll_bench.sh --iterations 5
```

Result after the coalesced scroll draw:
`p50 363.085ms / p95 949.488ms / max 949.488ms`

Interpretation:

- the old tmux-visible proxy is still not a good measure of the user-facing
  history-scroll smoothness problem
- the full-app trackpad bench now captures the real presentation seam, and the
  coalesced synchronous scroll draw materially improved that seam
- the remaining work, if user perception is still not good enough, should focus
  on improving cadence during active bursts rather than on sidebar/store churn

### Fourth-wave active-scroll draw pump and rejected release regressions

This wave kept the coalesced synchronous scroll draw and added a short-lived
draw pump so active trackpad bursts do not fall back to a sparse cadence after
the first immediate draw.

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights for the accepted draw-pump version:

- debug:
  `scroll_to_layer_present_ms p50 6.057 / p95 20.330 / max 21.731`
- installed app after restoring the non-regressed build:
  `scroll_to_layer_present_ms p50 2.485 / p95 15.514 / max 44.934`

Rejected follow-ups on the same seam:

- `CFRunLoop` `commonModes` timer for the draw pump:
  - debug sample: `p50 7.771 / p95 23.657 / max 35.703`
  - installed release samples varied between
    `p50 9.676 / p95 42.333 / max 43.044` and
    `p50 9.713 / p95 16.147 / max 45.207`
  - verdict: rejected because release variance and worst-case latency were
    worse than the best-known build
- relaxed immediate-draw throttle below the pump cadence:
  - debug sample: `p50 3.609 / p95 20.515 / max 37.053`
  - installed release sample:
    `p50 3.989 / p95 38.372 / max 47.906`
  - verdict: rejected because installed release `p95/max` regressed

Interpretation:

- the active-scroll draw pump is worth keeping because it tightened the debug
  active burst materially without harming the good installed-app baseline
- release validation is mandatory for this work; debug-only wins were not
  predictive enough
- the remaining issue is now mostly worst-case spike control on installed
  release, not median latency

### Fifth-wave present-aware immediate-draw throttle

The previous throttle suppressed another immediate draw as soon as the host had
issued a draw call, even if the IOSurface layer had not visibly presented yet.
That created a path where a stalled present could still force the next precise
scroll input to wait behind the regular draw pump. The accepted change keeps the
same pump cadence, but only throttles another immediate draw after
`layer.contents` has advanced past the most recent scroll draw.

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights:

- debug:
  `scroll_to_layer_present_ms p50 7.406 / p95 25.287 / max 26.414`
- release bundle:
  `scroll_to_layer_present_ms p50 7.239 / p95 23.345 / max 26.693`
- installed app:
  `scroll_to_layer_present_ms p50 2.624 / p95 22.626 / max 35.337`

Interpretation:

- this is the first change in this investigation that improved installed-app
  worst-case latency without needing to relax the draw pump globally
- the improvement is targeted: healthy scroll bursts still run near the old
  median, while delayed layer presents no longer suppress the next immediate
  recovery draw
- the next target is still to pull installed-app `max` below one 30fps frame
  (`33.3ms`), but the prior `40ms+` class of spikes is materially reduced

### Sixth-wave delayed-present recovery probe

The immediate-draw throttle still left a gap when a scroll draw had been issued
but the IOSurface layer had not presented yet. This wave added one more
recovery step on that exact seam: after a scroll draw, schedule a one-shot
probe at `1/180s`, and only if the layer still has not advanced, issue a
single extra recovery draw and continue the existing pump.

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
swift build -c debug --build-path .build-codex
AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
cd ../agtmux && cargo build -p agtmux --release >/dev/null
cd ../agtmux-term && xcodegen generate --spec project.yml >/dev/null
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm \
  -configuration Release -derivedDataPath "$PWD/build" \
  CONFIGURATION_BUILD_DIR="$PWD/build/Release" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO AGTMUX_BIN="$PWD/../agtmux/target/release/agtmux" \
  build
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Result highlights:

- debug:
  `scroll_to_layer_present_ms p50 7.020 / p95 22.023 / max 22.955`
- release bundle:
  `scroll_to_layer_present_ms p50 4.734 / p95 21.600 / max 27.223`
- installed app reruns after reinstall:
  - `p50 2.992 / p95 23.941 / max 44.818`
  - `p50 3.562 / p95 24.004 / max 35.325`

Interpretation:

- the recovery probe is directionally right: the active-burst seam improved in
  debug and stayed within the same envelope in the release bundle
- installed-app behavior remains the noisiest environment; the first rerun
  still showed a `44.818ms` outlier, but a second rerun came back down to the
  same `~35ms` worst-case band as the prior best build
- a more aggressive probe at `1/240s` was rejected immediately because it
  brought the debug max back up into the `35ms` range instead of reducing it

## Code-Reading Cross-Checks

The current code still supports the user-facing suspicion that host-side work
around the surface may contribute to the roughness:

- `GhosttyTerminalView.scrollWheel(with:)` is thin and forwards scroll deltas to
  libghostty after a precise-scroll multiplier.
- `GhosttyTerminalView.triggerDraw()` explicitly prefers
  `ghostty_surface_refresh()` over `ghostty_surface_draw()` to avoid more main
  thread contention during steady-state scrolling.
- `GhosttyApp.handleRender(...)` and `runDirtyDrawPass()` still represent a
  host-owned scheduler for surfaces that emit `GHOSTTY_ACTION_RENDER`.
- `WorkbenchGhosttyIsland` protects the AppKit host hierarchy from SwiftUI
  recomposition, but `WorkbenchAreaV2` still places the terminal tile near
  inventory snapshots, active-pane context, and attach/navigation task updates.
- `AppViewModel` and `LocalProjectionCoordinator` still maintain steady-state
  metadata/health/polling activity around the workbench.

## Interpretation

The direct-draw path is still worth keeping because it reduces latency for
render-callback surfaces and now has integration coverage. The more important
finding from this investigation is that full-app history scrolling presents
through the IOSurface layer without going through `GHOSTTY_ACTION_RENDER`, and
that coalescing a synchronous draw during scroll materially improves layer
presentation cadence.

Open questions for the next wave:

1. whether the remaining roughness is still visible to users after the
   coalesced scroll draw change
2. whether the full-app trackpad bench should report an active-burst-only layer
   gap metric instead of whole-window p95 values that include pause time
3. whether the old Gate-L proxy should be retired or downgraded for history
   scroll acceptance, since it does not track the actual presentation seam

### Seventh-wave telemetry surfacing and longer-run stress check

The next accepted change did not alter pacing logic. Instead, it surfaced the
real scroll-presentation draw seam in `GhosttyTerminalView.ScrollTelemetrySnapshot`
and emitted the same values from the full-app trackpad bench:

- `scroll_presentation_draw_gap_p50_ms`
- `scroll_presentation_draw_gap_p95_ms`
- `scroll_presentation_draw_gap_max_ms`
- `scroll_presentation_draw_count`

That let us separate three seams during real history scroll:

1. input to the first coalesced scroll-presentation draw
2. cadence between scroll-presentation draws
3. draw to visible `layer.contents` presentation

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
cd ../agtmux && cargo build -p agtmux --release >/dev/null
cd ../agtmux-term && xcodegen generate --spec project.yml >/dev/null
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm \
  -configuration Release -derivedDataPath "$PWD/build" \
  CONFIGURATION_BUILD_DIR="$PWD/build/Release" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO AGTMUX_BIN="$PWD/../agtmux/target/release/agtmux" \
  build
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Result highlights:

- release bundle, 4 bursts:
  - `scroll_to_first_draw_ms p50 0.258 / p95 11.328 / max 14.881`
  - `scroll_to_layer_present_ms p50 6.619 / p95 13.405 / max 16.454`
  - `scroll_presentation_draw_gap_p50 11.010 / p95 18.838`
- installed app, 4 bursts:
  - `scroll_to_first_draw_ms p50 0.205 / p95 11.481 / max 16.815`
  - `scroll_to_layer_present_ms p50 1.936 / p95 12.991 / max 19.428`
  - `scroll_presentation_draw_gap_p50 11.215 / p95 21.107`
- installed app, 8 bursts:
  - `scroll_to_first_draw_ms p50 0.243 / p95 24.762 / max 54.035`
  - `scroll_to_layer_present_ms p50 2.107 / p95 26.922 / max 55.768`
  - `scroll_presentation_draw_gap_p50 11.287 / p95 26.308`

Interpretation:

- the default short-burst path is now materially better than the earlier
  `20-40ms` class of results and is close enough to native that the remaining
  differences are in tail behavior, not median cadence
- the longer 8-burst run shows the remaining problem more clearly: burst trains
  can still accumulate `25-55ms` spikes even when the first few bursts look
  smooth
- store/island churn remained low during the stress run
  (`publish_noop_count=4`, `publish_store_mutation_count=0`, `island_update_count=8`),
  so the remaining tail is still inside the host-side scroll-presentation path

### Rejected seventh-wave follow-ups

Two pacing tweaks were tried immediately after the telemetry expansion and both
regressed the longer burst train:

- shortening `scrollPresentationDrawPumpTailSeconds` from `0.18` to `0.12`
  - release bundle, 8 bursts:
    `scroll_to_layer_present_ms p50 2.277 / p95 30.084 / max 77.817`
  - this also failed
    `GhosttyCLIOSCBridgeTests/testScrollPresentationDrawPumpContinuesBrieflyAfterRecentInput`
- slowing `scrollPresentationDrawPumpIntervalSeconds` from `1/120s` to `1/100s`
  - release bundle, 8 bursts:
    `scroll_to_layer_present_ms p50 2.124 / p95 40.836 / max 123.922`

Interpretation:

- the pump is already close to the best stable cadence on this host
- the remaining long-run spikes are not fixed by simply making the pump shorter
  or slower
- the next useful investigation should target why extended burst trains still
  accumulate delayed first draws despite healthy median cadence

### Burst-level telemetry slices and rejected false wins

The next telemetry-only follow-up exposed the raw sample suffix for each burst
instead of only summarizing the whole run. The bench now records, per burst:

- `scroll_to_first_draw_samples_ms`
- `scroll_to_layer_present_samples_ms`
- `scroll_presentation_draw_gap_samples_ms`
- `layer_present_gap_samples_ms`

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
zsh -n scripts/perf/gate_l_trackpad_history_scroll_bench.sh
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Result highlights from the accepted baseline with those burst slices:

- release bundle, 4 bursts:
  - `scroll_to_first_draw_ms p50 0.214 / p95 8.993 / max 9.477`
  - `scroll_to_layer_present_ms p50 2.509 / p95 10.855 / max 11.174`
- release bundle, 8 bursts:
  - `scroll_to_first_draw_ms p50 0.232 / p95 58.921 / max 126.058`
  - `scroll_to_layer_present_ms p50 2.083 / p95 60.616 / max 127.624`
  - the worst samples clustered in the alternating `up` bursts, while the
    `down` bursts stayed near the earlier `~9-11ms` range

Three follow-up ideas were then measured and rejected:

- inline first-draw execution regressed both `4-burst` and `8-burst` release
  samples
- direction-change cadence resets produced apparently good `8-burst` numbers
  only by changing the visible-line path itself, so they were false wins
- backlog-aware recovery redraws regressed both the short and long release
  paths
- backlog-aware immediate-throttle bypass also split the tradeoff the wrong way:
  `0.85x`, `0.90x`, and `0.95x` frame-age thresholds each improved either the
  short path or the long path, but not both at once. The strongest long-burst
  variant (`0.85x`) brought release `8-burst`
  `scroll_to_layer_present_ms` to `p50 2.155 / p95 22.527 / max 49.470`, but
  its paired `4-burst` sample regressed to `p50 4.817 / p95 17.756 / max 24.291`,
  so it was rejected as another non-net-win pacing tweak.

Interpretation:

- the new per-burst slices are useful and should stay
- the remaining tail really is concentrated in specific burst phases, not
  evenly smeared across the whole train
- the next real fix should preserve the visible-line path and burst shape while
  reducing those `up`-burst tails; changes that alter the benchmark path should
  be treated as invalid, not improvements

### Scheduler-lateness telemetry follow-up

The next accepted change kept pacing behavior unchanged and only added
scheduler-specific slices to the full-app bench:

- `scroll_presentation_immediate_queue_delay_ms`
- `scroll_presentation_pump_wake_lateness_ms`
- `scroll_presentation_recovery_probe_wake_lateness_ms`

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
zsh -n scripts/perf/gate_l_trackpad_history_scroll_bench.sh
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Result highlights from the accepted telemetry-only build:

- release bundle, 4 bursts:
  - `scroll_to_layer_present_ms p50 8.507 / p95 14.948 / max 19.525`
  - `scroll_presentation_immediate_queue_delay_ms p50 0.179 / p95 0.296 / max 0.335`
  - `scroll_presentation_pump_wake_lateness_ms p50 1.275 / p95 9.257 / max 27.961`
  - `scroll_presentation_recovery_probe_wake_lateness_ms p50 3.387 / p95 15.544 / max 35.703`
- release bundle, 8 bursts:
  - `scroll_to_layer_present_ms p50 9.082 / p95 26.610 / max 55.803`
  - `scroll_presentation_immediate_queue_delay_ms p50 0.193 / p95 0.285 / max 0.296`
  - `scroll_presentation_pump_wake_lateness_ms p50 1.145 / p95 9.432 / max 206.878`
  - `scroll_presentation_recovery_probe_wake_lateness_ms p50 3.295 / p95 15.025 / max 210.987`
- per-burst slices showed the same pattern repeatedly:
  `down` bursts stayed near `~2-12ms`, while the bad `up` bursts were the ones
  that also carried `35-206ms` pump / recovery wake-lateness outliers

Interpretation:

- immediate queue delay is effectively white on this host; it does not explain
  the subjective jank
- the tail is now attributable to the scheduler wake path, not to the
  `CFRunLoopPerformBlock` immediate queue
- any next real fix should either reduce reliance on those wakeups during
  active input, or make the wake path itself more reliable without changing the
  benchmark's visible-line path

Measured-and-rejected follow-ups on top of that telemetry:

- overdue-pump immediate-draw bypass:
  - release `8-burst`
    `scroll_to_layer_present_ms p50 10.173 / p95 29.304 / max 55.283`
  - verdict: rejected; it did not improve the long path and made the aggregate
    tradeoff worse
- one-shot `RunLoop.main` `.common` timers for draw pump and recovery:
  - release `8-burst`
    `scroll_to_layer_present_ms p50 9.438 / p95 27.809 / max 160.401`
  - verdict: rejected; timer replacement made variance materially worse
- limiting delayed-present recovery probes to immediate draws only:
  - release `8-burst`
    `scroll_to_layer_present_ms p50 3.660 / p95 27.884 / max 36.810`
  - paired release `4-burst`
    `scroll_to_layer_present_ms p50 4.203 / p95 16.598 / max 38.696`
  - verdict: rejected; it improved some medians and long-burst max, but short
    bursts stayed too noisy and reruns were not stable enough
- bypassing the throttle after two pending scroll inputs:
  - release `8-burst`
    `scroll_to_layer_present_ms p50 1.937 / p95 28.526 / max 31.426`
  - paired release `4-burst`
    `scroll_to_layer_present_ms p50 2.363 / p95 28.538 / max 34.824`
  - verdict: rejected; it traded a better long-burst max for a clearly worse
    short-path `p95`

### Wake-path replacement dead ends

Three later experiments tried to replace or tighten the wake path itself rather
than changing throttle constants. All three were rejected.

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Measured-and-rejected variants:

- view-scoped `NSView.displayLink(...)` callbacks for the draw pump / recovery:
  - release `4-burst`
    `scroll_to_layer_present_ms p50 1.791 / p95 46.401 / max 48.806`
  - release `8-burst`
    `scroll_to_layer_present_ms p50 1.775 / p95 28.697 / max 57.809`
  - verdict: rejected; it materially increased short-path `p95`, and the
    immediate-queue slice itself also regressed
- background-queue timer wakeups that hopped back to the main run loop through
  `CFRunLoopPerformBlock(... commonModes ...)`:
  - release `4-burst`
    `scroll_to_layer_present_ms p50 7.957 / p95 17.734 / max 22.726`
  - release `8-burst`
    `scroll_to_layer_present_ms p50 8.224 / p95 44.481 / max 144.741`
  - verdict: rejected; wake-lateness metrics moved, but the user-visible seam
    regressed badly on longer burst trains
- draw-relative timer rescheduling after every successful scroll draw:
  - release `4-burst`
    `scroll_to_layer_present_ms p50 7.340 / p95 23.081 / max 23.868`
  - release `8-burst`
    `scroll_to_layer_present_ms p50 8.124 / p95 41.497 / max 90.814`
  - verdict: rejected; timer freshness alone is not the limiter, because the
    visible presentation path still regressed even when wake-lateness slices
    became much cleaner

Interpretation:

- reducing wake-lateness telemetry by itself is not sufficient; the best-known
  baseline still beats these replacements on the visible seam
- the current branch should stay on the existing main-queue draw pump /
  delayed-present recovery implementation until the next step is backed by
  deeper main-thread / present-path evidence

### 2026-03-19 same-input native proxy parity

To remove fixture drift from the embedded/native comparison, this wave added a
native companion script that reuses the same transcript-style `less -R -N`
fixture and the same pixel-burst trackpad input path:
`scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`

Validation:

```bash
zsh -n scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh
AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 \
  > /tmp/agtmux-embedded-trackpad-proxy-serial.json
scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh \
  --iterations 4 > /tmp/agtmux-native-trackpad-proxy-serial.json
```

Result highlights from the serial reruns:

- embedded same-input proxy:
  `tmux_visible_line_change_ms p50 567.724 / p95 583.263 / max 583.263`
- native same-input proxy:
  `tmux_visible_line_change_ms p50 575.531 / p95 578.756 / max 578.756`
- interpretation:
  the `tmux_visible_line_change_ms` proxy is effectively identical between
  embedded and native when the fixture and input path are actually matched, so
  it is not the metric that explains the remaining user-visible jank

An attempted apples-to-apples visual parity bench through screen capture was
blocked on this host. `/usr/sbin/screencapture` failed with
`could not create image from display`, so any native comparison that depends on
screen/image diffs still needs a Screen Recording-capable environment.

### 2026-03-19 phase-aware synthetic bursts and gesture-boundary invalidation

The next follow-up tried to make the synthetic trackpad input closer to real
AppKit gestures before touching the host scheduler again.

Changes:

- `scripts/perf/GateLAXKeySender.swift` gained
  `--scroll-phase-mode trackpad-burst`, which stamps pixel scroll bursts with
  `began -> changed -> ended` phase fields
- both transcript-style trackpad benches now use that mode
- `GhosttyTerminalView.scrollWheel(with:)` now treats only
  `event.phase == .began` as a scheduler boundary and invalidates stale pump /
  recovery timers there

Validation:

```bash
./scripts/perf/gate_l_ax_key_sender.sh --dry-run --scroll-pixels -24 --scroll-repeat 6 --scroll-phase-mode trackpad-burst
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Rejected first attempt:

- giving phase/momentum its own continuation deadline regressed release samples
  badly:
  - `4-burst scroll_to_layer_present_ms p50 3.338 / p95 43.484 / max 53.892`
  - `8-burst scroll_to_layer_present_ms p50 2.859 / p95 69.332 / max 146.293`

Accepted follow-up:

- keep the phase-aware sender
- use phase only to invalidate stale timers at gesture start

Measured release A/B with the same phase-aware harness:

- without `phase.began` invalidation:
  - `4-burst scroll_to_layer_present_ms p50 2.390 / p95 30.491 / max 52.183`
  - `8-burst scroll_to_layer_present_ms p50 4.686 / p95 51.290 / max 176.185`
- with `phase.began` invalidation:
  - `4-burst scroll_to_layer_present_ms p50 4.009 / p95 16.917 / max 24.102`
  - `8-burst scroll_to_layer_present_ms p50 3.991 / p95 49.586 / max 115.386`

Interpretation:

- phase-aware synthetic bursts are useful enough to keep; they expose a real
  scheduler seam that the old burst sender never modeled
- phase should not own continuation policy directly in this host path
- the low-risk win is killing stale timers at gesture boundaries, which cuts
  both short-burst `p95/max` and long-burst `max` without reopening the worse
  regressions from the deadline-based variant

### 2026-03-19 stale pending immediate-draw invalidation at gesture start

The next follow-up kept the phase-aware sender and the existing
`phase.began` timer invalidation, but expanded the gesture boundary to also
cancel a stale pending immediate draw. The goal was to stop an `up` burst from
waiting behind an older coalesced draw block that had been queued by the
previous gesture.

Changes:

- `GhosttyTerminalView` now versions/coalesces immediate scroll-presentation
  draws and treats `event.phase == .began` as a boundary for both:
  - pending immediate scroll-presentation draws
  - delayed pump / recovery timer callbacks

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh \
  --app /Applications/Ghostty.app --iterations 4
```

Accepted release samples from the serial reruns:

- embedded release `4-burst`
  `scroll_to_layer_present_ms p50 3.032 / p95 29.512 / max 46.259`
- embedded release `8-burst`
  `scroll_to_layer_present_ms p50 6.518 / p95 28.570 / max 69.155`
- native same-input proxy rerun stayed at
  `tmux_visible_line_change_ms p50 574.549 / p95 576.174 / max 576.174`

Temporary rollback check:

- a local A/B that removed the pending-draw invalidation again was not kept
- the focused scheduler regression test immediately failed because
  `phase.began` no longer cleared the pending immediate-draw state
- the ad-hoc benchmark reruns without that invalidation also became noisy
  enough to produce empty bursts / app-inactive samples, so the branch stayed
  on the pending-draw invalidation version

Interpretation:

- the remaining visible difference versus native is still a presentation-path
  tail, but a new burst should not have to inherit stale coalesced draw state
  from the previous gesture
- on this host the accepted follow-up materially improved the long-burst tail
  relative to the earlier phase-aware baseline without pending-draw
  invalidation (`8-burst p95 51.290 / max 176.185`)
- short-burst results still vary enough that future work should continue to use
  serial reruns and avoid overfitting one sample

### 2026-03-19 production-path scroll telemetry gating

This follow-up did not change the scheduler. It removed scroll benchmark
bookkeeping from normal app launches so the user path no longer pays for
per-event signposts and sample-array appends.

Implementation summary:

- `GhosttyTerminalView` now enables scroll telemetry only when one of these is
  true:
  - `AGTMUX_UITEST=1`
  - the process is running under XCTest
  - `AGTMUX_SCROLL_TELEMETRY=1`
- normal app launches therefore still track the functional
  `lastScrollInputUptime` / `lastLayerPresentUptime` state that the scheduler
  needs, but they no longer record `scrollToFirstDraw`, `scrollToLayerPresent`,
  queue-delay, wake-lateness, or signpost samples on every scroll event

Validation:

```bash
swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests
./scripts/dev/validate-docs.sh
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
AGTMUX_SCROLL_TELEMETRY=0 AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  ./scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  ./scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
```

Results:

- explicit telemetry-off release smoke:
  - `tmux_visible_line_change_ms p50 584.144 / p95 590.875 / max 590.875`
  - all scroll telemetry metrics dropped to `count: 0` as intended
- telemetry-enabled rerun on the same release build:
  - `tmux_visible_line_change_ms p50 568.004 / p95 576.575 / max 576.575`
  - `scroll_to_layer_present_ms p50 5.346 / p95 39.518 / max 53.005`

Interpretation:

- this is worth keeping because it removes benchmark-only work from the user
  hot path
- it is not a measured presentation-seam win by itself; the telemetry-enabled
  rerun remained noisy on this host
- the next scheduler iteration should treat this as cleanup that lowers
  production overhead, then continue to target the remaining
  `25-50ms` presentation tail directly

### 2026-03-19 native-cadence subset experiments

The next wave explicitly tried to reduce host-owned cadence during precise
trackpad scrolling, guided by a code review of native Ghostty and cmux. Both
codebases keep AppKit scroll input thin and let cadence stay with the renderer /
display-linked wake path rather than with extra host timers.

Three small subsets were measured on top of the current embedded baseline and
all three were rejected.

#### 1. Disable timer continuation during active precise gestures

This variant kept immediate draws on each scroll event, but stopped scheduling
the draw-pump continuation while `phase` or `momentumPhase` was active.

Validation:

```bash
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-native-cadence AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-native-cadence-release-4.json
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-native-cadence-release-8.json
```

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 4.721 / p95 10.828 / max 11.451`
  with `empty_burst_count 2`
- `8-burst`: `scroll_to_layer_present_ms p50 4.508 / p95 127.399 / max 240.782`

Verdict:

- rejected; the short path looked good in isolation, but the long path blew up
  and the empty bursts were not acceptable

#### 2. Defer all precise steady-state changed events to a single input recovery probe

This variant kept the immediate draw on `phase == .began`, but routed precise
`changed` / momentum-`changed` events through a single outstanding
input-recovery probe instead of an immediate host draw.

Validation:

```bash
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-phase-aware-4.json
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-phase-aware-8.json
```

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 7.453 / p95 24.636 / max 48.092`
- `8-burst`: `scroll_to_layer_present_ms p50 7.454 / p95 39.471 / max 57.612`
- per-burst slices still showed the same structure as before: `down` bursts
  stayed healthy, while alternating `up` bursts owned the tail

Verdict:

- rejected; this reduced some long-path spikes relative to experiment 1, but it
  clearly regressed the short path and still left the `up` bursts as the
  dominant failure mode

#### 3. Present-aware precise defer

This variant only deferred precise `changed` events once the previous scroll
draw had already produced a layer present, falling back to immediate draws when
presentation had not caught up.

Validation:

```bash
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-present-aware-4.json
AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-present-aware-8.json
```

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 5.262 / p95 10.579 / max 11.592`
  with `empty_burst_count 2`
- `8-burst`: `scroll_to_layer_present_ms p50 3.793 / p95 116.754 / max 157.261`
- per-burst slices made the asymmetry obvious:
  - `down` bursts stayed around `10-12ms`
  - alternating `up` bursts jumped into the `87-157ms` range

Verdict:

- rejected; even a present-aware defer path still regressed the long path
  sharply and reproduced the same `up`-burst asymmetry

Takeaway:

- the strong pattern across all three rejected native-cadence subsets is that
  `up` scrollback bursts still rely on host immediate draws much more than
  `down` bursts do
- blindly reducing host ownership helps some medians, but it does not yet
  produce a net win because the alternating `up` bursts collapse first
- the next structural investigation should target the actual `up` scrollback
  presentation seam inside the embedded Ghostty path rather than trying more
  timer-level policy tweaks

### 2026-03-20 stricter renderer-owned branches

After the subset experiments above, the next wave removed progressively more of
the custom embedded scroll cadence so the path would converge on native Ghostty
ownership rather than on host-side policy.

Validation:

```bash
./scripts/dev/prepare-ghosttykit.sh
swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests'
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-native-cadence AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
```

#### 1. Display-link active-session branch

This branch kept a renderer-owned scroll session alive across direct phase /
momentum and refreshed frame data on display-link ticks while the session was
active.

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 16.611 / p95 50.387 / max 71.750`
- `8-burst`: `scroll_to_layer_present_ms p50 25.430 / p95 124.453 / max 392.601`

Verdict:

- rejected; better than some later stricter branches, but still materially
  worse than the earlier hybrid best-known path and still dominated by
  alternating `up` bursts

#### 2. Renderer wakeup plus display-link fallback

This branch moved state preparation back onto the renderer wakeup path for each
precise scroll input and let display-link only catch up if a pending request
survived until draw time.

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 25.089 / p95 92.284 / max 395.373`
- `8-burst`: `scroll_to_layer_present_ms p50 17.730 / p95 94.427 / max 378.578`

Verdict:

- rejected; the `8-burst` median improved relative to the active-session path,
  but the short path regressed badly and `up` burst tails still remained far
  above the hybrid baseline

#### 3. Pure upstream scroll path

This branch removed the custom precision-scroll renderer path entirely and
returned to the upstream Ghostty shape: `scrollViewport -> queueRender()` on
input, then display-link draw cadence.

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 24.039 / p95 88.319 / max 117.684`
- `8-burst`: `scroll_to_layer_present_ms p50 26.922 / p95 270.136 / max 378.850`
- `8-burst down`: `p50 12.032 / p95 31.642 / max 108.994`
- `8-burst up`: `p50 74.245 / p95 327.194 / max 378.850`

Verdict:

- strongly rejected; this was the clearest proof that pure renderer ownership
  alone does not solve the embedded case on this host

Interpretation:

- the failure pattern across all three stricter branches is consistent:
  `down` bursts stay near frame budget, while alternating `up` bursts own the
  tail
- this now points away from host timer cadence as the dominant limiter and
  toward the cost of embedded Ghostty's `updateFrameData()` / viewport-change
  rebuild work during scrollback
- this last sentence is an inference from the measured asymmetry plus the
  renderer code paths, not a direct instrumented proof yet

### 2026-03-20 vendor update-frame no-op short-circuit

The next follow-up tested the new hypothesis directly inside embedded Ghostty's
renderer. Instead of changing cadence ownership again, it targeted repeated
host-driven draws that were still re-entering `rebuildCells(...)` even when the
viewport and presentation inputs had not changed.

Validation:

```bash
PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" \
  AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" \
  AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" \
  ./scripts/build-ghosttykit.sh
swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release \
  -derivedDataPath build-scroll-root \
  AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build
AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4
AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" \
  scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8
```

Rejected first attempt:

- relaxed the first-`up` viewport-shift fast-path guard
- replaced full-screen dirty clearing with fringe-row-only clearing

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 8.817 / p95 61.803 / max 82.141`
- `8-burst`: `scroll_to_layer_present_ms p50 9.657 / p95 60.814 / max 132.388`

Verdict:

- rejected; the lower `max` did not compensate for the much worse `p95`

Rejected second attempt:

- kept the first-`up` relaxation
- widened dirty clearing from fringe rows to viewport pages

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 8.891 / p95 62.591 / max 88.392`
- `8-burst`: `scroll_to_layer_present_ms p50 9.288 / p95 57.770 / max 114.206`

Verdict:

- rejected; still worse than the earlier live-screen/no-clone baseline on the
  tail that users actually feel

Accepted follow-up:

- keep the live-screen/no-clone viewport-shift path unchanged
- add cached mouse/cursor metadata to the renderer
- if all frame-affecting inputs are unchanged:
  - terminal dirty bits clear
  - screen dirty bits clear
  - viewport row unchanged
  - bottom/non-bottom state unchanged
  - selection/preedit absent
  - kitty/image paths inactive
  - cursor style unchanged
  - mouse state unchanged
  then skip `rebuildCells(...)` entirely and reuse the previous cell buffers

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 8.068 / p95 23.153 / max 24.423`
- `8-burst`: `scroll_to_layer_present_ms p50 9.407 / p95 28.712 / max 30.561`

Previous accepted baseline:

- `4-burst`: `scroll_to_layer_present_ms p50 8.561 / p95 37.247 / max 109.972`
- `8-burst`: `scroll_to_layer_present_ms p50 8.982 / p95 53.995 / max 146.282`

Interpretation:

- the first strong structural win after the rejected renderer-owned branches
  came from removing redundant renderer work, not from changing scheduler
  ownership again
- this is strong evidence that a meaningful part of the remaining hitch lived
  inside embedded Ghostty's repeated `updateFrame()` path itself
- it does not prove the renderer path is fully solved; the next likely seam is
  the expensive first `up`-scrollback transition and any remaining full-page
  dirty work, which were exactly the places where the two rejected variants
  regressed

### 2026-03-20 provenance repair and fresh rebuild

The accepted vendor-side win above originally existed only on the current dirty
`vendor/ghostty` checkout. This turn repaired that provenance so the same win
can be reproduced from a fresh upstream clone.

What changed:

- `prepare-ghosttykit.sh` is now pinned to upstream Ghostty `v1.2.3`, which is
  the actual base commit for the current vendor diff (`6d2dd585...`)
- the checked-in aggregate patch is now `scripts/patches/ghostty-agtmux.patch`
  and exactly matches the current vendor diff
- patch application switched from `git apply -p0` to plain `git apply` because
  the aggregate patch is standard `git diff` format
- the aggregate patch now also carries the minimal `build.zig.zon` refresh
  required because upstream `v1.2.3` points at an iTerm themes tarball that
  now returns `404 Not Found`

Fresh validation:

- fresh clone rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_GHOSTTYKIT_DIR="$tmp_root/GhosttyKit.xcframework" AGTMUX_GHOSTTYKIT_MARKER_FILE="$tmp_root/.ghostty-source-ref" ./scripts/dev/prepare-ghosttykit.sh`
- repo artifact rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" ./scripts/dev/prepare-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-root AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Fresh-provenance release results:

- `4-burst`: `scroll_to_layer_present_ms p50 9.830 / p95 22.510 / max 23.349`
- `8-burst`: `scroll_to_layer_present_ms p50 7.998 / p95 28.669 / max 50.843`

Interpretation:

- the earlier vendor-side renderer short-circuit win was real; it survives a
  clean upstream checkout and a true rebuild of `GhosttyKit`
- the remaining gap is no longer a provenance problem
- the next target remains the expensive first `up` / full-page dirty seam,
  because that is still where the long-burst tail shows up after the
  reproducible vendor optimization lands

### 2026-03-20 reusable viewport-shift row-set rebuild

The fresh-provenance baseline above confirmed that the earlier no-op frame
short-circuit was real, but it still left a reusable viewport-shift redraw path
that scanned every visible row on each shift. The next follow-up kept cadence
ownership unchanged and narrowed that redraw itself.

What changed:

- keep the accepted no-op identical-frame short-circuit intact
- keep the existing viewport-shift cache reuse via `self.cells.shiftRows(...)`
- replace the reusable viewport-shift O(visible_rows) scan with an explicit row
  set:
  - newly exposed fringe rows
  - the sentinel row and any `shift_extra_row`
  - current and previous mouse rows
  - rows still marked dirty in the viewport dirty bitset
- rebuild only those rows instead of iterating across the full visible
  viewport after every reusable shift

Validation:

- vendor rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-final AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-final/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-final/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 6.243 / p95 21.078 / max 42.474`
- `8-burst`: `scroll_to_layer_present_ms p50 4.393 / p95 24.264 / max 39.498`

Fresh-provenance baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 9.830 / p95 22.510 / max 23.349`
- `8-burst`: `scroll_to_layer_present_ms p50 7.998 / p95 28.669 / max 50.843`

Interpretation:

- this is the first accepted follow-up after provenance repair that improves
  the longer burst train itself rather than only identical-frame redraws
- the dominant remaining work is still likely the expensive first `up`
  scrollback transition, but the reusable viewport-shift visible-row scan was
  clearly part of the residual tail
- `4-burst max` remained noisier than the fresh-provenance baseline, so the
  short path still needs more reruns before claiming a universal win there

### 2026-03-20 rejected conditional full dirty-clear skip

The next experiment kept the accepted sparse viewport-shift row rebuild but
tried to avoid the full-screen dirty-bit clear when the viewport dirty-bit scan
found no dirty rows to consume.

What changed:

- keep the accepted sparse row-set rebuild in the reusable viewport-shift path
- keep `state.terminal.flags.dirty = .{}` and `state.terminal.screen.dirty = .{}`
  exactly as before
- only skip the global `pageIterator(...).dirtyBitSet().unsetAll()` sweep when
  the viewport dirty-bit scan rebuilt zero dirty rows

Why this looked plausible:

- on pure history scroll with no new terminal output, there are often no
  viewport dirty rows at all
- that made the unconditional full-screen dirty-bit clear look like a fixed
  extra cost in the common case

Validation:

- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-dirtyskip AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-dirtyskip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-dirtyskip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 5.921 / p95 24.784 / max 26.345`
- `8-burst`: `scroll_to_layer_present_ms p50 5.138 / p95 28.508 / max 68.647`

Accepted row-set baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 6.243 / p95 21.078 / max 42.474`
- `8-burst`: `scroll_to_layer_present_ms p50 4.393 / p95 24.264 / max 39.498`

Interpretation:

- the idea is semantically safe, but it is not a win on the user-visible seam
- the branch slightly improved `4-burst p50`, but it regressed `4-burst p95`
  and badly regressed `8-burst max`
- this is strong evidence that the remaining cost is not the unconditional
  dirty-bit clear itself
- the next likely seam stays the expensive first `up` transition:
  `leaving_bottom`, `shift_extra_row`, and old-cursor-row rebuild work

### 2026-03-20 accepted viewport-shift edge-padding recompute

The next follow-up kept the accepted sparse viewport-shift row set, but removed
the sentinel-row full rebuild that existed mainly to refresh padding heuristics
at the viewport edge.

What changed:

- keep the accepted reusable viewport-shift sparse row set for exposed fringe,
  `shift_extra_row`, mouse rows, and viewport dirty rows
- stop always appending the top/bottom sentinel row to that rebuild set
- after the partial row rebuild finishes, recompute
  `padding_extend.up/down` directly from the current viewport edge rows using
  `neverExtendBg(...)`

Why this looked plausible:

- `self.cells.shiftRows(viewport_row_shift)` already remaps cached row content
  to the new screen Y without reshaping glyphs
- for many shifts, the sentinel row did not need a full `rebuildCellRow(...)`
  for glyph correctness; it only needed updated padding-extension heuristics at
  the viewport edge
- that made the sentinel-row rebuild a good candidate for removing real
  renderer work from the expensive first `up` transition

Validation:

- vendor rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-edgepad AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 5.279 / p95 16.338 / max 22.517`
- `8-burst`: `scroll_to_layer_present_ms p50 4.307 / p95 23.698 / max 125.957`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.032 / p95 25.835 / max 72.321`

Accepted sparse-row baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 6.243 / p95 21.078 / max 42.474`
- `8-burst`: `scroll_to_layer_present_ms p50 4.393 / p95 24.264 / max 39.498`

Interpretation:

- this is a real renderer-side win on the short path; the first `up`
  transition got materially cheaper
- `8-burst p95` held roughly flat-to-better versus the accepted baseline, so
  removing the sentinel full rebuild did not regress the long train itself
- the bad `8-burst` reruns were not shaped like a pure renderer regression:
  the worst `up` burst lined up with very large
  `pump_wake_lateness` / `recovery_probe_wake_lateness` outliers rather than a
  broad degradation across all bursts
- that makes the current boundary clearer:
  first-`up` renderer work is now smaller, while the remaining worst-case tail
  is increasingly a later `up` burst wake/presentation problem

### 2026-03-20 accepted phase-aware host continuation suppression

The next step kept the accepted vendor-side renderer wins intact and changed the
host scheduler so that active precise trackpad contact no longer depends on the
host draw pump for steady-state cadence.

What changed:

- `GhosttyTerminalView.scrollWheel(with:)` now tracks:
  - direct gesture `event.phase`
  - `event.momentumPhase`
  - precise vertical direction across bursts
- direct finger-contact phases (`began/changed/stationary`) now bypass
  `shouldThrottleImmediateScrollPresentationDraw(...)`
- while direct contact is active, host pump/recovery continuation is suppressed
  and only the immediate coalesced draw remains
- precise direction flips invalidate scheduled pump/recovery wakeups so a new
  `up` burst does not inherit the prior burst's continuation state
- `GhosttyInput.toScrollMods(...)` now also packs direct gesture phase in bits
  `4..6`, matching the Ghostty core `input.ScrollMods` layout

Why this looked plausible:

- after the accepted edge-padding change, the worst remaining `8-burst` outlier
  aligned more strongly with host `pump_wake_lateness` /
  `recovery_probe_wake_lateness` than with broad renderer work
- the current host scheduler still throttled active precise scroll after the
  first present, which forced later changed events to wait for
  `DispatchQueue.main.asyncAfter` wakeups even while fingers were still on the
  trackpad
- shifting active contact back to input/run-loop ownership is closer to native
  Ghostty's cadence model than adding more timer variants

Validation:

- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-phase-aware AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 5.751 / p95 15.761 / max 18.422`
- `8-burst`: `scroll_to_layer_present_ms p50 5.395 / p95 29.695 / max 39.215`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.611 / p95 29.781 / max 33.833`

Accepted edge-padding baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 5.279 / p95 16.338 / max 22.517`
- `8-burst`: `scroll_to_layer_present_ms p50 4.307 / p95 23.698 / max 125.957`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.032 / p95 25.835 / max 72.321`

Interpretation:

- this is a real structural shift in cadence ownership:
  active precise contact is now input/run-loop owned, while host timers are
  reserved for momentum tail and delayed recovery
- short bursts improved again, and the late-`up` worst-case cap fell from
  `72-126ms` reruns to repeatable low-`30ms` spikes
- the tradeoff is visible in `8-burst p95`, which moved into the high-`20ms`
  band rather than staying near the earlier low-`20ms` result
- that means the dominant remaining issue is no longer catastrophic hitching
  from stale timer wakeups; it is a flatter later-`up` tail that still needs a
  follow-up if native parity is the goal

### 2026-03-20 accepted renderer shiftRows fast path

The next follow-up kept the accepted phase-aware host scheduler and the earlier
vendor renderer wins, but cut the fixed one-row viewport-shift copy cost inside
`Contents.shiftRows(...)` itself.

What changed:

- keep the accepted sparse viewport-shift row-set rebuild and edge-padding
  recompute
- keep the accepted phase-aware direct-gesture cadence ownership in
  `GhosttyTerminalView`
- special-case `Contents.shiftRows(...)` for `abs_shift == 1`
- use `fastmem.move(...)` to block-copy:
  - background cell rows
  - foreground row-list slices
- recycle the fallen-off edge row list into the newly exposed fringe row
  instead of swapping rows one-by-one
- keep the same semantic behavior:
  - the fringe row still clears
  - moved glyph rows still remap `grid_pos[1]`

Why this looked plausible:

- after the accepted sparse row-set and edge-padding work, the renderer had
  already stopped scanning or rebuilding most visible rows on a reusable
  viewport shift
- that left `Contents.shiftRows(...)` as the obvious remaining fixed-cost row
  walk on every one-row scrollback move
- the common case in this bench is a single-row viewport shift, so
  `abs_shift == 1` is the highest-value fast path

Validation:

- vendor rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-shiftrows AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 4.909 / p95 16.984 / max 18.636`
- `8-burst`: `scroll_to_layer_present_ms p50 4.303 / p95 26.875 / max 71.277`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.730 / p95 29.408 / max 31.928`

Accepted phase-aware baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 5.751 / p95 15.761 / max 18.422`
- `8-burst`: `scroll_to_layer_present_ms p50 5.395 / p95 29.695 / max 39.215`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.611 / p95 29.781 / max 33.833`

Interpretation:

- this is a real renderer-side reduction in fixed reusable-shift cost; the
  common one-row viewport move is cheaper now
- the short path stayed essentially flat on `max`, improved `p50`, and only
  nudged `p95` slightly upward
- the long-burst train improved where it matters most for the accepted path:
  `8-burst p95` and rerun `max` both moved down
- one first `8-burst` sample still hit a noisy `71.277ms` outlier, so the
  remaining tail is no longer best explained by row-shift copy cost alone
- that makes the current boundary clearer again:
  fixed renderer row-shift work is lower, and the next likely seam is later-`up`
  wake/presentation variance plus any remaining fixed per-frame work outside
  the row-shift copy itself

### 2026-03-20 rejected monotonic sparse-row walk

The next renderer follow-up tried to make the sparse viewport-shift row walk
more monotonic:

- sort the sparse viewport row set ascending
- walk rows with `Pin.down(...)` instead of re-pinning each row
- use `link.MatchSet.orderedContains(...)` on that sparse path

Validation:

- vendor rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-monotonic-sparse AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-monotonic-sparse/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-monotonic-sparse/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 5.523 / p95 24.295 / max 26.607`
- `8-burst`: `scroll_to_layer_present_ms p50 4.864 / p95 26.322 / max 79.141`

Verdict:

- reject
- the short path regressed too hard to justify the row-walk change
- `8-burst p95` moved only marginally while `max` remained noisy
- this means the next useful win was not in row ordering itself

### 2026-03-20 accepted sparse first-up seam reduction

The next accepted follow-up kept the accepted phase-aware host path and the
renderer `shiftRows` fast path, then reduced the remaining first-`up` fixed
renderer work inside `renderer/generic.zig`.

What changed:

- keep the accepted sparse viewport-shift row-set rebuild and one-row
  `Contents.shiftRows(...)` fast path
- when leaving the live bottom, stop rebuilding `shift_extra_row` for plain
  empty-tail cursor rows where clearing the cursor overlay is enough
- refresh `padding_extend.up/down` only for viewport edges that were not
  already rebuilt by the sparse row-set itself

Why this looked plausible:

- after the accepted `shiftRows` fast path, the remaining first-`up` fixed
  work was the unconditional old-cursor-row rebuild plus the redundant
  top/bottom edge padding refresh
- both pieces are narrow and deterministic, so they are better targets than
  changing cadence ownership again
- the short-path user-visible seam was already close enough that trimming this
  fixed first-`up` work had a credible chance to show up directly in `4-burst`

Validation:

- vendor rebuild:
  `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
- tests:
  `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
- release build:
  `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-shift-extra-skip AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- perf:
  `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`

Results:

- `4-burst`: `scroll_to_layer_present_ms p50 6.124 / p95 13.778 / max 21.418`
- `8-burst`: `scroll_to_layer_present_ms p50 3.849 / p95 29.281 / max 53.626`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 4.585 / p95 29.430 / max 38.933`

Accepted renderer `shiftRows` baseline for comparison:

- `4-burst`: `scroll_to_layer_present_ms p50 4.909 / p95 16.984 / max 18.636`
- `8-burst`: `scroll_to_layer_present_ms p50 4.303 / p95 26.875 / max 71.277`
- `8-burst rerun`: `scroll_to_layer_present_ms p50 5.730 / p95 29.408 / max 31.928`

Interpretation:

- the short path improved materially again, especially `4-burst p95`
- the long train held flat on `p95` while the first-run outlier dropped from
  `71.277ms` to `53.626ms`
- rerun `max` stayed in the same high-`30ms` band as the accepted baseline,
  which means first-`up` fixed renderer work is no longer the dominant gap
- the next remaining seam is later-`up` wake/presentation variance, not
  unconditional old-cursor-row or redundant edge-padding rebuild work
