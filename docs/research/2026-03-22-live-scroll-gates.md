# 2026-03-22 Live Scroll Gate Findings

## Summary

The old scrollback replay gates were not measuring the user's real complaint.
They replayed captured history into fresh clients or sleeping shells, which can
diverge from the loaded live-pane history path that users actually scroll.

Two newer conclusions are durable:

- the final realistic acceptance path must observe a live pane that is already
  displayed in the running app
- the most useful primary metric is still first visible movement latency, not
  only coarse-step parity

## Retired Gates

These gates should no longer be treated as acceptance:

- plain scrollback replay into a sleeping shell
- fresh direct-attach live-pane replay without preloaded scrollback state
- AX-only frontmost live text sampling without tmux client scroll ground truth

Reasons:

- tmux-attached wheel-up can become alternate-scroll cursor keys, so replaying
  into a sleeping shell just emits literal escape sequences
- a fresh client can receive scroll input and render/present activity without
  exposing the same older rows as the already-loaded live app
- AX text sampling alone is too sensitive to focus/target orchestration

## Current Useful Gates

### Live-captured `curses-history` proxy

`scripts/perf/gate_l_trackpad_live_curses_history_step_parity.sh`

Use this as an alternate-screen proxy only:

- it captures a real pane with `--no-join-wrapped`
- replays it through the repo-local reactive TUI fixture
- compares embedded/native first-changed latency and coarse-step metrics

This proxy is useful for regression hunting, but it is not the final proof for
loaded normal-screen live history.

### Frontmost live client-scroll parity

`scripts/perf/gate_l_frontmost_live_client_scroll_bench.sh`
`scripts/perf/gate_l_frontmost_live_client_scroll_parity.sh`

This is the current realistic gate for the live path:

- it measures the frontmost tmux client's `scroll_position`
- it primes copy mode before the run
- it compares embedded and native Ghostty on the same displayed pane path

Current limitation:

- when both apps share the same live pane, preconditioning still needs careful
  handling so both runs start from the same baseline

### Fresh host-mode live-client wrapper

`scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh`
`scripts/perf/gate_l_terminal_host_live_client_scroll_parity.sh`

This wrapper is useful for the rewrite branch because it launches fresh
`legacy` and `next` apps against the same live pane.

Latest durable finding:

- a fresh attached client can be primed into a scrollable state with a
  client-targeted `PageUp`
- on pane `%666`, the prime step moved `scroll_position` from `0 -> 14`
- the post-run `clientCommandProbe` moved the same fresh client again
  (`14 -> 28`)
- the measured wheel burst still left `changed_sample_count = 0`

Interpretation:

- the current blocker on the phase-1 host-mode wrapper is not "fresh client
  cannot scroll at all"
- it is specifically "wheel-up on the fresh live client is not producing tmux
  client scroll"
- host-mode parity on this wrapper is therefore invalid until both sides show
  non-zero wheel-driven movement

## Most Important Interpretation

As of 2026-03-22, the realistic live-pane signal is no longer "embedded sends
coarser input." The more consistent remaining signal is delayed first visible
movement on the embedded path, which points at terminal host / presentation
latency rather than at tmux step batching alone.
