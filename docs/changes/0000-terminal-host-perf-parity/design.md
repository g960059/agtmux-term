# Design

## Chosen Approach

Treat terminal-host parity as a separate engineering track from the completed
terminal-first cockpit rewrite.

The product boundary stays the same:

- one app window
- one main embedded Ghostty terminal
- one tmux/agent sidebar overlay

The problem is now underneath that boundary:

- `next` still keeps phase-1 legacy hosting behavior
- `GhosttyApp` still owns too much render scheduling
- `GhosttyTerminalView` still owns too much steady-state scroll cadence
- the mainline one-terminal path still inherits generalized pane/surface
  lifecycle costs

## Workstreams

### 1. Benchmark hygiene

- force `AGTMUX_TERMINAL_HOST_MODE` explicitly in perf runs
- stop treating `legacy` defaults as a neutral baseline
- compare against native Ghostty on a matched upstream version

### 2. Hot-path telemetry

Add or harden measurement around five seams:

1. scroll input -> render request -> first draw -> layer present
2. render callback -> direct draw scheduling ownership
3. `ghostty_app_tick(...)` and dirty-draw pass duration
4. `syncSurfaceMetrics(...)` churn during resize
5. pane/surface retention churn in the one-main-terminal path

### 3. `next` hot-path thinning

Focus `next` on renderer-owned cadence rather than host-owned recovery:

- reduce or remove app-side direct-draw scheduling from steady-state scroll
- narrow immediate draw to the smallest justified escape hatches
- keep parity fixes for blank retarget frames separate from steady-state scroll

### 4. Main-terminal fast path

The mainline product no longer needs generic workspace behavior on the hot
path. The one-main-terminal path should be allowed to special-case:

- one visible controller
- one visible surface
- minimal retention beyond what measured retarget smoothness requires

## Boundaries

- no new ADR is needed unless the durable product boundary changes again
- this pack may update runbooks and research notes, but not product docs unless
  the product direction itself changes
- the current `legacy` default remains acceptable during the parity program
  only as an explicit migration boundary, not as proof that the work is done
