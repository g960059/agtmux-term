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
  - sender targeting is now part of the repeatability story:
    - `identifier + point` passed a `3`-iteration aggregate at about
      `-14.036ms`
    - `front-window + point` lost at about `+60.225ms`
  - durable conclusion: keep the deterministic gate on
    `focusMode=identifier` and `scrollMode=point`; `front-window` delivery is
    diagnostic-only for loaded-TUI repeatability
  - phase-3 rewrite wiring is now live on this same gate:
    - `next` host threads `terminalHostMode` into `GhosttyTerminalView`
    - normal-screen wheel input on `next` disables the legacy host
      scroll-presentation pump and leaves cadence to Ghostty
    - recent precise normal-screen render callbacks on `next` now stay on the
      renderer-owned refresh path instead of re-entering the direct-draw
      scheduler
    - a fresh `--iterations 2` deterministic parity run passed with median
      `first_changed_elapsed_delta_ms = -18.8639`
    - the same run still showed zero `islandRetryCountDelta` and zero
      `islandApplyCommandCountDelta`
  - durable conclusion: phase-3 next-host cadence wiring is at least not a
    regression on the deterministic gate and is ready for installed-app trials

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
- the host-mode live wrapper itself needed more hardening before it was usable:
  - stale `%pane` IDs can disappear during the user's normal workflow, so the
    wrapper now resolves the target pane dynamically from the session using
    title/command/active-pane fallback
  - plain `tmux` calls were reading the invoking shell's `TMUX` environment;
    the wrapper and sampler now force `env -u TMUX -u TMUX_PANE tmux` so they
    always talk to the intended server
  - `open_terminal_for_pane` could return before the tile registered a terminal
    view; the bridge now waits for view registration before returning
  - even after those fixes, the fresh/live wrapper is still diagnostic only
    until the loaded-pane viewport sampler produces stable, non-zero movement
  - a more serious harness bug surfaced during live investigation:
    - using a UITest app plus `AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX=1` could
      bootstrap a `sleep 600` scenario on the user's default tmux server
    - this path is now considered invalid for live work
    - destructive default-server scenario bootstrap is now forbidden in the
      shared harness; default-local live runs must use bundle/defaults launch
      instead of env-driven UITest scenario launch

### Fresh host-mode live-client wrapper

`scripts/perf/gate_l_terminal_host_live_client_scroll_bench.sh`
`scripts/perf/gate_l_terminal_host_live_client_scroll_parity.sh`

This wrapper is useful for rewrite diagnostics, but not for acceptance.

Latest durable finding:

- tmux client `scroll_position` is no longer a required truth source for the
  measured run, because the user's default tmux server can block `list-clients`
  and `display-message`
- the wrapper now mounts, focuses, samples bridge viewport text, sends the
  wheel burst directly, and returns complete JSON on both `legacy` and `next`
- even with that viewport-only path, the fresh app still renders only the new
  login shell and records `changed_sample_count = 0`
- with `AGTMUX_SCROLL_TELEMETRY=1`, the same wheel burst still records
  non-zero `scrollInputCount`, `scrollPresentationDrawCount`, and
  `layerPresentCount`
- the terminal viewport text snapshot before and after the wheel burst remains
  identical on both `legacy` and `next`
- adding a local `paneID` inventory fallback in the bridge did not change that
  conclusion; the fresh wrapper still lands on the new-login shell path rather
  than the user's already-loaded live history path
- therefore the next useful step is not more fresh-wrapper tuning but same-app
  live parity, which now has groundwork via a runtime terminal-host-mode
  override inside the app
- while hardening that wrapper, a separate tmux targeting bug surfaced:
  - the bridge was trying `switch-client -c <renderedClientTTY> -t %pane`
  - tmux rejects that form with `can't find client`, so `client_tty` is not a
    valid `target-client` identifier for this path
  - the bridge now resolves `client_name` from `list-clients` before
    `switch-client`
  - this fixes one false blocker in the wrapper, but the overall gate is still
    diagnostic-only because fresh mounts can stall before `open_terminal` or
    before reaching the already-loaded live pane path

Interpretation:

- the current blocker on the phase-2 host-mode wrapper is not "the live gate
  hangs on tmux client probes"
- it is now specifically "fresh app mounting does not reproduce the already
  loaded live history path, so wheel-up reaches the terminal path without
  changing visible viewport state"
- host-mode parity on this wrapper is therefore still invalid until the gate
  can observe a genuinely loaded live pane
- the bridge and rendered-surface registry also needed stricter host-mode
  semantics for rewrite work:
  - `next` host terminal-view lookups now require a published active leaf
    instead of silently falling back to the tile UUID
  - same-command `legacy <-> next` remounts on the same tile now advance
    rendered generation and drop preserved `clientTTY`
  - durable conclusion: loaded-tile host-mode switches cannot be evaluated
    correctly unless the bridge and registry distinguish tile-level legacy
    views from pane-owned next-host leaves
- two additional rewrite preconditions are now in place:
  - defaults-based bundle launches now instantiate `UITestTmuxBridge`, so the
    same-app live host-mode experiments no longer depend on env-driven UITest
    startup to create the bridge object
  - persisted local tiles on `next` now promote the bootstrap fallback
    controller to the first real pane key instead of tearing down the fallback
    and mounting a second controller, removing one startup blanking seam from
    loaded local workbenches

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

## Rewrite Branch Test Boundary

While the rewrite branch is in flight, the durable app-level safety boundary is
now:

- full `AgtmuxTermUITests` remains green on the branch
- those UI launches pin `AGTMUX_TERMINAL_HOST_MODE=legacy`
- `legacy` vs `next` acceptance lives in the dedicated host-mode parity gates

Reason:

- the rewrite branch can set `TerminalHostMode=next` through runtime overrides
  and app defaults for installed-app trials
- allowing the broad UI suite to inherit that state would mix structural host
  experiments with unrelated product regressions
- the branch therefore uses two complementary surfaces:
  - legacy full-suite coverage for product safety
  - host-mode parity gates for rewrite progress
