# Design

## Chosen Approach

Treat terminal-host parity as a separate engineering track from the completed
terminal-first cockpit rewrite.

The product boundary stays the same:

- one app window
- one main embedded Ghostty terminal
- one tmux/agent sidebar overlay

The problem is now underneath that boundary:

- `GhosttyApp` still owns too much render scheduling
- `GhosttyTerminalView` still owns too much steady-state scroll cadence
- the mainline one-terminal path still inherits generalized pane/surface
  lifecycle costs
- the default local metadata lane still wakes too much background runtime for
  a main-terminal-first app, so normal launches should keep that lane opt-in
  until the daemon path is cheap enough again

## Workstreams

### 1. Benchmark hygiene

- stop treating removed host-mode knobs as part of the perf story
- compare the embedded main-terminal path against native Ghostty on a matched
  upstream version

### 2. Hot-path telemetry

Add or harden measurement around five seams:

1. scroll input -> render request -> first draw -> layer present
2. render callback -> direct draw scheduling ownership
3. `ghostty_app_tick(...)` and dirty-draw pass duration
4. `syncSurfaceMetrics(...)` churn during resize
5. pane/surface retention churn in the one-main-terminal path

### 3. Main-terminal hot-path thinning

Use renderer-owned cadence where it actually fires, but keep a narrow host-side
interactive draw fast path for the seams where telemetry proves it does not.

- internal scroll bursts currently show `rendererFrameCompletedCount == 0` and
  `renderRequestCount == 0` unless the host explicitly requests presentation
- keyboard input and precise scroll therefore keep a coalesced immediate draw
  path on the current visible surface
- the initial real-input path must also arm the interactive draw pump; without
  that, delayed tmux/PTy echo can sit in the viewport state until some later
  pane/focus repaint happens to redraw the preserved surface
- visible render callbacks also bypass the generic dirty-surface refresh path
  once the surface has produced its first visible layer present; before that
  bootstrap point they still fall back to `ghostty_surface_refresh(...)` so the
  initial attach path does not crash inside libghostty renderer metadata setup
- the keypress bench now measures both tmux-capture latency and
  viewport-visible latency, because tmux delivery alone was hiding the
  remaining user-visible lag
- matched-version AX typing now shows the input-side improvement from the armed
  pump, but the renderer-owned path is still absent on both typing and trackpad
  benches, so the remaining FPS gap is still a host-cadence problem
- normal viewport scroll should not schedule extra app-thread Ghostty ticks;
  embedded scrollback already mutates surface state synchronously and should
  hand presentation straight to the renderer thread
- explicit keypress and scroll-to-bottom redraw paths in vendored Ghostty
  should use `queueRenderAndDraw()` so typing does not rely on a later,
  unrelated repaint to make new output visible
- app-side render callbacks should request refresh on the current main-actor
  turn; an additional run-loop hop before `ghostty_surface_refresh(...)`
  directly adds visible presentation latency after tmux/PTy output arrives
- continuation and recovery draw pumps must not schedule a fresh
  `ghostty_app_tick(...)` for every frame; once input has handed work to
  libghostty, follow-up presentation should stay on draw-only recovery unless
  telemetry proves another runtime tick is required
- the host fast path remains an escape hatch, not a return to generalized
  multi-surface scheduling
- keep pane-retarget and blank-frame recovery fixes separate from steady-state
  scroll

### 4. Main-terminal fast path

The mainline product no longer needs generic workspace behavior on the hot
path. The one-main-terminal path should be allowed to special-case:

- one visible controller
- one visible surface
- direct pane targeting instead of window-active normalization
- no steady-state tmux drift watch after navigation converges
- minimal retention beyond what measured retarget smoothness requires
- UITest bridge refresh and targeted sidebar presence probes that stay on the
  local tmux path instead of paying full `fetchAll()` and daemon bootstrap cost
- no eager daemon or legacy workspace startup on the normal one-window path

## Boundaries

- no new ADR is needed unless the durable product boundary changes again
- this pack may update runbooks and research notes, but not product docs unless
  the product direction itself changes
- backward-compatibility host modes are not part of the target design
