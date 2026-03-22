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

### Deterministic loaded-TUI host-mode gate

`scripts/perf/gate_l_terminal_host_loaded_viewport_bench.sh`
`scripts/perf/gate_l_terminal_host_loaded_viewport_parity.sh`

This is now the phase-2 acceptance surface for `legacy` vs `next`:

- it launches a fresh UITest-enabled app in the selected host mode
- it boots an isolated tmux session that runs the repo-local
  `curses-history` viewer on a deterministic loaded fixture
- it compares first visible movement latency and step metrics through the same
  bridge viewport sampler used by the app-side perf harness

Durable findings:

- the original plain loaded-transcript version was diagnostic only because
  `baselineViewport.usesAlternateScroll == true` and wheel-up just emitted
  alternate-scroll cursor keys
- moving the deterministic gate onto the repo-local `curses-history` viewer
  made both `legacy` and `next` record real viewport movement
- the `next` host initially failed because bridge lookup still used workbench
  tile IDs; `TerminalHostActiveSurfaceRegistry` now resolves tile ID to the
  active pane-owned leaf ID for viewport/focus snapshots
- the first valid smoke run after that fix showed `legacy
  first_changed_elapsed_ms = 348.8586` vs `next = 385.7792`, so `next`
  initially trailed by about `36.9ms`
- subsequent reruns on the same deterministic gate passed with `next`
  leading instead:
  - one pass recorded `first_changed_elapsed_delta_ms = -25.4354`
  - another pass recorded `first_changed_elapsed_delta_ms = -41.8393`
- durable conclusion: the deterministic host-mode gate is now valid, but
  repeatability is the next problem to solve before returning to the loaded
  live-pane acceptance path
- the gate now supports `--iterations` and aggregates medians across repeated
  `legacy`/`next` pairs
  - a `2`-iteration smoke passed with median
    `first_changed_elapsed_delta_ms = +8.0781`
  - the same aggregate still showed zero `islandRetryCountDelta` and zero
    `islandApplyCommandCountDelta`, so next-host attach retries are not the
    obvious source of remaining variance
  - the harness now disables inherited shell xtrace because sporadic
    `output=''` prefixes were corrupting machine-readable JSON during
    repeatability runs

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

This wrapper is useful for rewrite diagnostics, but not for acceptance.

Latest durable finding:

- a fresh attached client can be primed into a scrollable state with a
  client-targeted `PageUp`
- on pane `%666`, the prime step moved `scroll_position` from `0 -> 14`
- the post-run `clientCommandProbe` moved the same fresh client again
  (`14 -> 28`)
- the measured wheel burst still left `changed_sample_count = 0`
- with `AGTMUX_SCROLL_TELEMETRY=1`, the same wheel burst still recorded
  non-zero `scrollInputCount`, `scrollPresentationDrawCount`, and
  `layerPresentCount`
- the terminal viewport text snapshot before and after the wheel burst was
  identical

Interpretation:

- the current blocker on the phase-1 host-mode wrapper is not "fresh client
  cannot scroll at all"
- it is specifically "wheel-up on the fresh live client reaches the terminal
  path, but changes neither tmux client scroll nor visible viewport state"
- host-mode parity on this wrapper is therefore invalid until both sides show
  non-zero wheel-driven movement

## Root Cause From Vendor Code

`vendor/ghostty/src/Surface.zig:scrollCallback` makes the fresh-client result
coherent:

- when `uses_alternate_scroll` is false
- and mouse reporting is off
- wheel input does not become tmux copy-mode writes
- it goes to Ghostty's local `terminal.scrollViewport(...)` path instead

That means a fresh attached client with little or no loaded local scrollback
can:

- receive wheel events
- queue renders
- present frames
- and still show no visible movement

So the fresh host-mode wrapper is diagnostic for input-path ownership, but it
is not the acceptance gate for the user's already-loaded live history path.

## Most Important Interpretation

As of 2026-03-22, the realistic live-pane signal is no longer "embedded sends
coarser input." The more consistent remaining signal is delayed first visible
movement on the embedded path, which points at terminal host / presentation
latency rather than at tmux step batching alone.
