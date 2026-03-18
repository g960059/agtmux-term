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
