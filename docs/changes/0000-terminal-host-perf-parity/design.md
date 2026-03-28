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
- post-bootstrap key input should still arm layer/frame-complete observation
  plus a recovery-only probe. That keeps typing renderer-owned in the common
  case while still giving the host one bounded rescue path if no new
  presentation arrives after the input edge
- post-first-layer wheel input should arm the same kind of recovery-only probe
  on the latest scroll edge. The host must not go back to a steady-state scroll
  draw pump, but the probe has to reschedule to the newest wheel event so a
  stale timer cannot silently drop the only bounded rescue draw
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
- the custom `NSApplication` entrypoint must finish launching before its first
  foreground push; otherwise XCUITest and AX helpers can leave the bundle in
  `Running Background` even though the process and window tree exist
- first-surface Ghostty bootstrap must not start until the host window is
  visible and key on normal launches; bridge / automation runs are allowed to
  bypass that gate so perf and regression lanes do not deadlock on frontmost
  ownership before the first surface exists
- perf harnesses that target the installed app bundle cannot rely on env-only
  bridge config or tmux socket selection. Bundle launch has to carry bootstrap
  scenario, bridge paths, and isolated local tmux socket/config through durable
  defaults so the app enters automation mode without falling back to the
  user's default tmux server
- perf harness cleanup must clear those defaults before and after each run;
  otherwise later XCUITest launches inherit stale bridge/bootstrap settings and
  fail for reasons unrelated to the code under test
- the app/runtime side must also ignore those defaults unless UI-test mode is
  explicitly active. Normal launches cannot let a leftover `UITestTmuxSocket*`
  or `UITestTmuxConfigPath` override local tmux discovery on its own
- the app-side tmux bridge must stay in a long-lived low-latency command loop
  once bridge paths are configured; a one-shot poll re-armed by a slow
  background monitor directly inflates bench latency and can starve later
  command iterations
- Gate-L AX helpers should not require external app activation to succeed
  before they can resolve a click target. They must be able to use app-reported
  terminal screen frames or window fallbacks so focus/input benches are not
  blocked on `NSRunningApplication.activate(...)`
- shell-driven activation must never relaunch the installed app while a target
  pid already exists. Open/registration and foreground focus are separate
  phases, and perf helpers should fail on frontmost ownership directly instead
  of silently restarting the bridge/bootstrap process and measuring the wrong
  surface
- the internal live-scroll lane should be self-contained: it must be able to
  bootstrap an isolated tmux history fixture, open that surface directly, and
  wait only for terminal registration/viewport readiness. It should not depend
  on an existing active target, a running daemon, or shell-driven foreground
  focus before collecting app-side telemetry
- direct-local pane attach must preserve the tmux socket it resolved against.
  A fallback pane found on the default tmux server cannot later attach or
  navigate through the app's isolated perf socket without rendering the wrong
  session or a `can't find window` error page
- fresh tmux attach needs a bounded local-scrollback seed if we want live-pane
  wheel-up to behave like an already-loaded terminal. A brand-new Ghostty
  client can render and present wheel input without exposing older rows unless
  the attach path preloads pane history into terminal scrollback first
- bootstrap publication and post-bootstrap inventory refresh are separate
  phases. Perf lanes need the tmux result file as soon as session/window/pane
  identity is known; any later inventory hydration must not sit on the critical
  path to the next bridge command
- after app-driven tmux bootstrap, the bridge should refresh only the local
  inventory needed for immediate pane targeting. Full `fetchAll()` is too heavy
  for the installed-app perf hot path and can delay the next attach/focus step
- bridge-side internal scroll measurement must not put both sampling and event
  injection on MainActor tasks. Sampling/injection should stay detached and
  hop to MainActor only for snapshot/dispatch work so the measurement tool
  does not create its own artificial scheduler bottleneck
- the app bundle must ship Ghostty runtime resources (`ghostty`,
  `terminfo`, shell integration, man/locale siblings) because missing bundled
  terminfo or integration assets change the runtime away from matched native
  behavior before cadence work even starts
- normal viewport scroll should not schedule extra app-thread Ghostty ticks
  for every follow-up frame; embedded scrollback may schedule one coalesced
  runtime tick immediately after new wheel input so libghostty drains the
  scroll mutation promptly, but steady-state presentation still belongs to the
  renderer thread
- explicit keypress and scroll-to-bottom redraw paths in vendored Ghostty
  should use `queueRenderAndDraw()` so typing does not rely on a later,
  unrelated repaint to make new output visible
- app-side `GHOSTTY_ACTION_RENDER` should map to one direct draw pass on the
  active embedded surface, not a recursive `ghostty_surface_refresh(...)`
  request. Upstream apprt semantics are redraw/present, so the host should use
  the dirty/direct-draw seam instead of asking libghostty to refresh again
- render-callback telemetry and dirty-draw ownership must resolve to the same
  `GhosttyTerminalView`; if renderer frame callbacks follow the active surface
  registry while dirty draws still follow a stale surface-handle mapping, live
  panes can report layer presents without ever closing `scrollToFirstDraw`
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
