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
