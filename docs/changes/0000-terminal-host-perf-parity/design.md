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
- keep the vendored Ghostty baseline current enough that cadence fixes do not
  sit on top of a dead or unbuildable upstream tag

### 2. Hot-path telemetry

Add or harden measurement around five seams:

1. scroll input -> render request -> first draw -> layer present
2. render callback -> direct draw scheduling ownership
3. `ghostty_app_tick(...)` and dirty-draw pass duration
4. `syncSurfaceMetrics(...)` churn during resize
5. pane/surface retention churn in the one-main-terminal path

### 3. Main-terminal hot-path thinning

Use renderer-owned cadence where it actually fires, and keep host immediate
draw only for the seams where telemetry proves recovery is still necessary.

- after the first visible layer completes, keyboard input should stay on the
  renderer-owned redraw path; host immediate draw is now reserved for
  dirty-draw override or explicit recovery, not the default typing path
- steady-state viewport scroll no longer uses the host immediate-draw / draw
  pump path; `dispatchScrollInput(...)` now hands redraw ownership entirely to
  libghostty and only keeps frame-completion / layer-present telemetry in
  Swift
- post-cut internal bridge scroll bursts now show
  `refreshDrawRequestCount == 0`,
  `immediatePresentationDrawCount == 0`,
  `scrollPresentationDrawCount == 0`, and non-zero
  `rendererFrameCompletedCount`, so the hot path is no longer paying the old
  host scroll pump cost
- initial visible-presentation completion is lifecycle state, not resettable
  telemetry. `resetScrollTelemetry(...)` must not make later typing look like
  a brand-new bootstrap surface and re-enable the old recovery pump
- once the current visible surface has produced its first layer present, raw
  key input, text input, and visible render callbacks should all stay on the
  renderer-owned refresh path by default
- renderer-frame-completed is now a bootstrap/telemetry signal, not the steady
  typing hot path. The steady-state key-input regression should pass with
  `immediatePresentationDrawCount == 0`
- the keypress bench now measures both tmux-capture latency and
  viewport-visible latency, because tmux delivery alone was hiding the
  remaining user-visible lag
- matched-version AX typing now shows the input-side improvement from the armed
  pump, but trackpad/internal scroll still shows `renderCallbackCount == 0`
  and a visible cadence gap even after host scroll pumping is gone, so the
  remaining FPS problem is now downstream of that removed host seam
- the best current truth metrics are installed-app AX keypress
  `viewport_after_tmux_*` for typing and trackpad/history
  `scroll_to_layer_present_ms` plus `layer_present_gap_*` for scroll cadence;
  tmux-visible line changes remain useful as a proxy but are no longer enough
  to judge native-feel smoothness by themselves
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
- tick-thinning must not remove the real-input immediate-draw entrypoint, the
  after-first-layer render-callback immediate fallback, or the temporary layer
  observation gate; those seams are what keep delayed tmux/PTy echo from
  waiting on unrelated pane/focus repaint
- the host fast path remains a typing-only escape hatch, not a return to
  generalized multi-surface scheduling
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
