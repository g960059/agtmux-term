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
