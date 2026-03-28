# Performance Profiling

Use this runbook for local performance investigations on the single embedded
main-terminal path.

## Local Gate-L Prep

Gate-L benches now default to the installed app bundle at
`/Applications/AgtmuxTerm.app`. Rebuild and reinstall that bundle first when
you want to measure the user-facing runtime.

Use the repo helper so the installed app is always a Release build:

```bash
./scripts/dev/rebuild-reinstall-app.sh
```

If you intentionally want to benchmark a repo-local build instead, build it and
override `AGTMUX_PERF_APP_BIN`:

```bash
xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath .derived-perf-release build
export AGTMUX_PERF_APP_BIN="$PWD/.derived-perf-release/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm"
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

### Direct Embedded Benches

- `scripts/perf/gate_l_idle_parity.sh`
- `scripts/perf/gate_l_scroll_bench.sh`
- `scripts/perf/gate_l_keypress_bench.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_trackpad_upscroll_step_bench.sh`
- `scripts/perf/gate_l_trackpad_live_pane_bench.sh`
- `scripts/perf/gate_l_frontmost_live_client_scroll_bench.sh`
- `scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh`
- `scripts/perf/gate_l_terminal_host_loaded_viewport_bench.sh`

### Native Baselines

- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_keypress_bench.sh`
- `scripts/perf/gate_l_native_ghostty_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_trackpad_upscroll_step_bench.sh`

### Embedded vs Native Wrappers

- `scripts/perf/gate_l_trackpad_history_scroll_parity.sh`
- `scripts/perf/gate_l_trackpad_upscroll_step_parity.sh`
- `scripts/perf/gate_l_frontmost_live_client_scroll_parity.sh`
- `scripts/perf/gate_l_trackpad_live_curses_history_step_parity.sh`

The old `legacy` / `next` host-mode comparison wrappers are intentionally
deleted. The perf matrix is now embedded main terminal versus native Ghostty
only.

## Bench Rules

- Run AX-driven benches serially. Do not run embedded and native captures in parallel.
- Do not touch the mouse or keyboard while a capture is running.
- Compare embedded and native Ghostty on the same upstream version before drawing conclusions.
- Prefer repo-local harnesses over ad hoc manual sampling so the tmux-visible markers stay comparable.
- Native Ghostty baselines should preferably run with no pre-existing Ghostty processes. Use `--allow-existing` only when you intentionally accept ambiguous pid attribution.
- Perf benches already re-enable scroll telemetry via `__agtmux_reset_scroll_telemetry__`. Normal app launches should keep telemetry off unless you are explicitly profiling.
- Set `AGTMUX_PERF_KEEP_TMP=1` if you need the temp directory for failed captures or ad hoc inspection.

## Practical Entry Points

Use `gate_l_trackpad_upscroll_step_parity.sh` when the complaint is coarse or
delayed upward wheel steps:

```bash
scripts/perf/gate_l_trackpad_upscroll_step_parity.sh \
  --bursts 12 \
  --app "$PWD/vendor/ghostty/zig-out/Ghostty.app"
```

Use `gate_l_trackpad_history_scroll_parity.sh` when the complaint is visual
cadence on a loaded transcript:

```bash
scripts/perf/gate_l_trackpad_history_scroll_parity.sh \
  --iterations 8 \
  --app "$PWD/vendor/ghostty/zig-out/Ghostty.app"
```

Use `gate_l_terminal_host_live_client_scroll_bench.sh` when you want the
embedded main terminal on a real live tmux pane:

```bash
AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP=0 \
AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT=1 \
AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET=1 \
AGTMUX_PERF_LIVE_SESSION_NAME='gate-normal-scroll' \
AGTMUX_PERF_LIVE_PANE_ID='%2' \
scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh --timeout 25
```

Use `gate_l_terminal_host_loaded_viewport_bench.sh` when you want a
deterministic loaded-history fixture inside the embedded main terminal:

```bash
scripts/perf/gate_l_terminal_host_loaded_viewport_bench.sh --timeout 25
```

Use `gate_l_frontmost_live_client_scroll_parity.sh` when both agtmux-term and
native Ghostty are already open on the panes you want to compare. It measures
the real frontmost live client path and requires tmux `mouse` mode to be on.

## Measurement Notes

- `gate_l_trackpad_history_scroll_bench.sh` and its parity wrapper still use `tmux_visible_line_change_ms` as a proxy for native comparison. Treat `scroll_to_layer_present_ms` and `layer_present_gap_*` as the more useful embedded-only cadence signals.
- `gate_l_keypress_bench.sh` now reports both `tmux_capture_*` and
  `viewport_*` latency fields. Use `viewport_after_tmux_*` to isolate the
  remaining app-side presentation gap after tmux has already received the key,
  and `layer_present_after_tmux_*` to see whether the visible surface still
  trails the viewport state.
- If `tmux_capture_*` stays near native but `rendererFrameCompletedCount == 0` and
  `immediatePresentationDrawCount` climbs sharply, the embedded terminal is
  still running on the host draw pump rather than renderer-owned cadence. That
  is currently the main explanation for the remaining FPS gap versus native.
- `gate_l_trackpad_upscroll_step_bench.sh` samples visible pane rows, not just logical line numbers. Use it for “rows jump in chunks” complaints.
- `gate_l_trackpad_live_curses_history_step_parity.sh` is still only a proxy for live-pane history because it replays captured pane text through the repo-local `curses-history` fixture.
- `gate_l_terminal_host_live_client_scroll_bench.sh` and `gate_l_terminal_host_loaded_viewport_bench.sh` now target the single embedded main-terminal surface only. They do not accept `--host-mode`, do not switch runtime modes, and do not depend on removed bridge commands.
- A true image-diff visual parity bench still requires Screen Recording permission. If `/usr/sbin/screencapture` cannot sample the display, treat screen-diff work as blocked.

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
