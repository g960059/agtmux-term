# 2026-03-17 — Gate-L Closeout Snapshot

**Status:** Closed snapshot  
**Authority:** Research only. Product truth lives in code, tests, CI, ADRs, and the active change pack until merge.

## Summary

Gate-L is green on the current host after the local-first fast-path closeout.

The same-host evidence on `2026-03-17` is:

- scroll: embedded p95 `485.808ms`, native Ghostty p95 `482.161ms`, ratio `1.008x`
- keypress-to-glyph: embedded p95 `415.557ms`, native Ghostty p95 `422.673ms`, ratio `0.983x`
- pane switch: embedded p95 `324.578ms`, native Ghostty p95 `608.910ms`, ratio `0.533x`
- focused idle steady state: green, with no `FetchAll` / `TmuxRunner` dominance in the 10s local-only window
- broad SwiftPM verification: green when the unrelated live managed-agent harness suite is excluded

## Scripts Used

- `scripts/perf/gate_l_scroll_bench.sh`
- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh`
- `scripts/perf/gate_l_keypress_bench.sh`
- `scripts/perf/gate_l_native_ghostty_keypress_bench.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_pane_switch_bench.sh`
- `scripts/perf/gate_l_signpost_summary.sh`
- `scripts/perf/gate_l_ax_key_sender.sh`

## Notes

- The scroll proof uses a wheel-driven `less -N` proxy observed through `tmux capture-pane`. This host could not provide reliable display/window image capture for true terminal-local scrollback image diffing.
- The keypress harness reuses a resolved click point between iterations and writes marker lines with `\r\n` from the raw-tty driver so `capture-pane` matching stays stable across longer runs.
- AX-driven benches should be run serially and without touching the mouse or keyboard during capture.

## Relationship To Earlier Notes

This note supersedes the open-state snapshot in
`docs/research/2026-03-14-local-parity-baseline.md`.

The app-side Gate-L closeout is complete in this repo. The only remaining
follow-up from the broader rerun is the daemon/provider handoff recorded in
`docs/research/2026-03-18-full-e2e-rerun-after-gate-l.md`.
