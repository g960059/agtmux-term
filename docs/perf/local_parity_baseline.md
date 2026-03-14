# Local Parity Baseline

## Goal

Capture the same local-first baseline before and after each fast-path slice.

This document is the `Gate-L` measurement contract for the current machine class.
It is intentionally local-first and does not require PR workflow.

As of March 13, 2026, the current host does not have native Ghostty installed
under `/Applications`, but the repo does carry a vendored native bundle at
`vendor/ghostty/zig-out/Ghostty.app`.
That removes app availability as the blocker. The remaining question is
end-to-end unattended input proof against vendored native Ghostty on the same
host.

## Phase A Automation

The current Gate-L automation slice focuses on measurements that can be driven
from this repo without XCUITest automation mode:

- pane-switch latency on the local-focused path
- idle CPU sampling for the `agtmux-term` process
- unified-log signpost summaries for:
  - `GhosttyTick`
  - `SurfaceDraw`
  - `FetchAll`
  - `MetadataSync`
  - `NavigationSync`
  - `TmuxRunner`
  - `Publish`

These measurements are intended to prove or falsify the local hot-path changes
before the missing native Ghostty baseline is resolved on the same host class.

Current repo-local entry points:

- `scripts/perf/gate_l_signpost_summary.sh`
- `scripts/perf/gate_l_idle_sample.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_probe.sh`
- `scripts/perf/gate_l_native_ghostty_input_smoke.sh`
- `scripts/perf/gate_l_ax_key_sender.sh`

Current script semantics on March 13, 2026:

- idle CPU uses macOS `top` delta samples and ignores the known-invalid first sample
- signpost and pane-switch percentile summaries use nearest-rank selection so small sample counts do not under-report `p95`
- signpost extraction fails loudly when the requested pid/window has no matching signpost events
- `gate_l_pane_switch_bench.sh` is a Phase A proxy:
  - it creates a 2-pane session
  - it drives `workbenchStoreV2.openTerminal(...)` via `__agtmux_open_terminal_for_pane__`
  - it is useful for product red/green and hot-path signpost proof, but it is not the final 4-pane/sidebar-click contract below

Current repo-local status on March 13, 2026:

- the pane-switch bench now produces a valid latency sample on this host
- fresh result:
  - `scripts/perf/gate_l_pane_switch_bench.sh --iterations 4 --timeout 20` => PASS
  - latest proxy sample: `latencies_ms = [2326.994, 2339.612, 2274.681, 2257.631]`
  - `p95_ms = 2339.612`
- the term-side root cause that previously produced rendered `%1` / selected `%0` drift is fixed in code/test:
  - control-mode event payloads are no longer treated as canonical pane truth
  - the focused navigation actor now re-reads exact rendered-client state via `list-clients` on control-mode startup and non-output events
  - post-send readback now retries transient `renderedClientUnavailable` misses
- the vendored native Ghostty bundle is launchable on this host:
  - `scripts/perf/gate_l_native_ghostty_probe.sh` resolves `vendor/ghostty/zig-out/Ghostty.app`
  - `launch.ok = true`
  - `activation.ok = true`
- native input reachability is now green on this host:
  - `scripts/perf/gate_l_native_ghostty_probe.sh` now reports `key_injection.ok = true`
  - `scripts/perf/gate_l_ax_key_sender.sh --print-app-path` now resolves the stable helper app bundle:
    - `scripts/perf/.apps/GateLAXKeySender.app`
  - `scripts/perf/gate_l_ax_key_sender.sh --prompt --dry-run` => PASS (`trusted = true`)
  - `scripts/perf/gate_l_native_ghostty_input_smoke.sh --timeout 15` => PASS and matches the receive-marker pattern `__GATE_L_RECV__:\s*a`
- keypress / scroll / pane-switch parity is not yet claimed until the final same-host measurement numbers are captured

## Scenarios

### A. Scroll stress

- target: one local tmux session with one high-output pane
- setup: run `scripts/perf/local_scroll_bench.sh`
- measure:
  - Time Profiler main-thread cost
  - signpost frequency/duration for `GhosttyTick`, `SurfaceDraw`, `FetchAll`, `MetadataSync`, `NavigationSync`, `TmuxRunner`
  - steady-state CPU while actively scrolling

### B. Keypress to glyph

- target: focused local terminal tile with no remote hosts involved
- setup: attach to the benchmark session or a plain local tmux shell
- measure:
  - Event Profiler or screen recording timestamps
  - compare native Ghostty + local tmux vs `agtmux-term`

### C. Pane switch

- target: one local session with four panes
- setup:
  - create panes with `tmux split-window` until four panes exist
  - bind the visible tile to that session in `agtmux-term`
- measure:
  - sidebar click to visible pane convergence
  - signpost visibility for `NavigationSync`
  - confirm `FetchAll` is not dominating the focused path

### D. Idle

- target: local session left focused for at least 30 seconds with no user input
- measure:
  - CPU
  - memory
  - repeated `FetchAll` / `TmuxRunner` activity

## Capture Steps

1. Build the current app: `swift build`
2. Start the local scroll scenario:

```sh
scripts/perf/local_scroll_bench.sh
```

3. Launch `agtmux-term` and focus the benchmark session.
4. In Instruments, use the template from `docs/perf/instruments-template.md`.
5. For signposts, optionally stream them live:

```sh
log stream --style compact --predicate 'subsystem == "local.agtmux.term"'
```

6. Record the following in the task / review artifact:
  - date
  - commit or dirty-worktree note
  - host model and macOS version
  - scenario
  - before/after numbers
  - notable hot-path categories

## Environment Flags

- `AGTMUX_SURFACEPOOL_DEBUG_COUNTS=1`
  - emits active/background/pending/draw count logs from `SurfacePool`
  - use only during profiling; it is intentionally noisy

## Pass/Fail Lens

Baseline capture is acceptable when:

- the scenario is reproducible on the same machine
- the same signpost categories are visible in both before and after runs
- the result is fresh for the final patch being judged
