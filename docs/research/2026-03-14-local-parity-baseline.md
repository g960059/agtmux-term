# 2026-03-14 — Local Parity Baseline Notes

**Status:** Historical snapshot; superseded by `docs/research/2026-03-17-gate-l-closeout.md`  
**Authority:** Research only. Gate decisions come from current code, tests, CI, and the active change pack.

## Summary

At the time of this snapshot, local parity work compared `agtmux-term` against
same-host native Ghostty + tmux using repo-local scripts.

The signal at this point in the work was:

- native Ghostty launch, activation, and input reachability are automated
- idle parity is within the `+3pt` budget on the current host class
- pane-switch proxy proof is green
- scroll, keypress-to-glyph, and final pane-switch parity were not yet closed
  in this snapshot

## Scripts At That Time

- `scripts/perf/gate_l_signpost_summary.sh`
- `scripts/perf/gate_l_idle_sample.sh`
- `scripts/perf/gate_l_idle_parity.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_probe.sh`
- `scripts/perf/gate_l_native_ghostty_input_smoke.sh`
- `scripts/perf/gate_l_ax_key_sender.sh`

## Observations At That Time

- native Ghostty baseline scripts now fail loudly when pre-existing vendored
  Ghostty processes would make pid/focus attribution ambiguous
- helper-based native input smoke is green
- focused idle parity is green on the current host class
- the unfinished measurement work at the time was scroll / keypress / final
  pane-switch parity

Treat this file as a dated pre-closeout snapshot. The final Gate-L result for
this wave lives in `docs/research/2026-03-17-gate-l-closeout.md`, and the live
implementation contract for in-flight work belongs in the active change pack
until merge.
