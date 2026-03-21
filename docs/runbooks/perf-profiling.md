# Performance Profiling

Use this runbook for local performance investigations such as Gate-L parity.

## Local Gate-L Prep

Build the embedded app binary first:

```bash
swift build -c debug --build-path .build-codex
export AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm"
```

Confirm the AX helper is trusted before running any input-driven bench:

```bash
scripts/perf/gate_l_ax_key_sender.sh --dry-run
```

## Recommended Instruments

- Time Profiler
- Points of Interest
- System Trace when scheduler behavior matters

## Useful Capture Windows

- 10s idle
- 10s active scroll
- repeated pane switches or navigation actions

## Gate-L Bench Scripts

- `scripts/perf/gate_l_idle_parity.sh`
- `scripts/perf/gate_l_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh`
- `scripts/perf/gate_l_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_keypress_bench.sh`
- `scripts/perf/gate_l_native_ghostty_keypress_bench.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_pane_switch_bench.sh`
- `scripts/perf/gate_l_ax_key_sender.sh --dry-run` to confirm AX trust before running input benches

## Bench Rules

- Run AX-driven benches serially. Do not run embedded and native captures in parallel.
- Do not touch the mouse or keyboard while a capture is running.
- For short-keypress and scroll probes, prefer the repo-local harnesses over ad hoc manual sampling so the tmux-visible markers stay comparable.
- Native Ghostty baselines should preferably run with no pre-existing Ghostty processes. Use `--allow-existing` only when you intentionally accept ambiguous pid attribution.
- The current scroll proof uses a `less -N` proxy observed through `tmux capture-pane`; do not treat it as a true image-diff measurement of terminal-local scrollback.
- `gate_l_trackpad_history_scroll_bench.sh` runs in full-app mode with a
  transcript-style `less -R -N` fixture and pixel-burst scroll input. Treat
  `tmux_visible_line_change_ms` as a legacy proxy only. Prefer
  `scroll_to_layer_present_ms` and `layer_present_gap_*` for the actual
  presentation path. `scroll_to_render_request_ms`, `scroll_to_first_draw_ms`,
  and `draw_gap_*` remain diagnostic for the `GHOSTTY_ACTION_RENDER` host path
  and may legitimately stay empty when the scroll path bypasses that callback.
  The default injector mode is now
  `AGTMUX_PERF_TRACKPAD_PHASE_MODE=trackpad-burst-momentum`, which keeps the
  same burst size but splits it into direct-touch and inertial momentum phases.
  Override it with `AGTMUX_PERF_TRACKPAD_PHASE_MODE=trackpad-burst` when you
  need the older direct-touch-only sender for A/B comparison.
- `gate_l_native_ghostty_trackpad_history_scroll_bench.sh` is the native
  companion for the same transcript fixture and pixel-burst input path. Use it
  when you need the exact same `tmux_visible_line_change_ms` proxy against
  `/Applications/Ghostty.app`, but do not confuse that proxy with the actual
  user-visible presentation seam.
- A true screen/image-diff native parity bench requires Screen Recording
  capability for the current terminal environment. If `/usr/sbin/screencapture`
  fails with `could not create image from display`, treat visual parity work as
  blocked until that permission path is fixed.
- Set `AGTMUX_PERF_KEEP_TMP=1` if you need the bench temp directory for failed
  captures or ad hoc inspection.

## Signpost Categories

- `GhosttyTick`
- `SurfaceDraw`
- `FetchAll`
- `LocalInventory`
- `RemoteInventory`
- `MetadataSync`
- `NavigationSync`
- `TmuxRunner`
- `Publish`
- `PublishAssemble`
- `GhosttyBridge`

## Storage Rule

Store binary traces outside `docs/` and link them from the relevant Issue or PR.
Keep this runbook procedural; keep dated conclusions in `docs/research/`.
