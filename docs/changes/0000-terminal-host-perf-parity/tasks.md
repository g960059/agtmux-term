# Tasks

- [x] retire the completed terminal-first sidebar-overlay change pack
- [x] capture a dated perf-parity review in `docs/research/`
- [x] create an active change pack for terminal-host perf parity
- [x] remove explicit host-mode selection from the perf and regression paths
- [x] document the matched-version native-vs-embedded comparison rule in the
  perf workflow
- [x] add render-callback and direct-draw ownership counters
- [x] add main-thread tick/draw timing coverage for the current hot path
- [x] add resize churn and pane/surface lifecycle counters
- [x] stop losing late per-id bridge command results in live readiness probes
- [x] make the UITest bridge command loop single-flight under runtime-config churn
- [x] atomically claim bridge command files across competing consumers
- [x] isolate direct live launches from competing `AgtmuxTerm` bridge readers
- [x] align live focus-host timeout with the terminal registration budget
- [x] skip impossible fresh-launch active-target waits before opening the live pane
- [x] align pane-row open semantics with direct clicked-pane targeting
- [x] produce the first measured parity table for embedded / native baselines
- [x] add a cadence-sensitive parity table that can explain user-visible
  smoothness gaps beyond step granularity
- [x] remove always-on telemetry collection from the normal hot path
- [x] stop main-terminal steady-state tmux polling after navigation converges
- [x] remove per-row repeat-forever sidebar animation from the normal hot path
- [x] remove dead host-mode wiring from the UI harness and keep preserved-surface viewport repaint coverage
- [x] make UITest local tmux command refresh and targeted sidebar probes avoid full `fetchAll()` / bootstrap cost
- [x] move normal app launches to the inventory-first local fast path so daemon metadata and legacy workspace startup stay off the hot path by default
- [x] delete remaining workbench runtime/tests and align bridge payloads with the single embedded path
- [x] delete stale perf host-mode wrappers and align bench payloads/docs with surface-based embedded-only terminology
- [x] add a coalesced interactive immediate-draw fast path for keyboard and
  scroll input when renderer-owned callbacks fail to fire
- [x] route visible render callbacks back to the renderer-owned refresh path
  instead of issuing synchronous host draws
- [x] remove synchronous render-callback host draws from the initial attach
  path so first-surface startup cannot abort inside libghostty
- [x] bump the vendored Ghostty baseline to `v1.3.1` and regenerate the
  aggregate patch / xcframework from a clean checkout
- [x] teach the keypress perf harness to report viewport-visible latency in
  addition to tmux-capture latency
- [x] arm the real-input interactive draw pump on the first post-key draw so
  delayed tmux echo does not wait for a later pane or focus repaint
- [x] make Gate-L benches default to the installed app bundle and fail fast on
  empty async bridge JSON results
- [x] stop scheduling app-thread Ghostty ticks for normal scroll gestures and
  move embedded viewport scroll to renderer-owned immediate draw
- [x] move explicit keypress and scroll-to-bottom redraw paths onto
  `queueRenderAndDraw()` in the vendored Ghostty surface
- [x] remove the extra main-run-loop hop from visible render callbacks before
  they request `ghostty_surface_refresh(...)`
- [x] fix UI/perf launch helpers to target the real app bundle id and kill
  orphaned executable-path processes before starting a fresh test instance
- [x] stop scheduling `ghostty_app_tick(...)` from interactive and scroll
  continuation/recovery draw pumps so follow-up frames stay draw-only
- [x] let real scroll input schedule one coalesced `ghostty_app_tick(...)`
  so embedded wheel events do not wait on an unrelated later wakeup
- [x] restore the real-input immediate draw, after-first-layer render-callback
  fallback, and temporary layer observation gate after the cadence-thinning
  regression removed them together
- [x] remove steady-state host scroll presentation from `dispatchScrollInput`
  so embedded viewport scroll stays on libghostty's renderer-owned redraw path
- [x] separate first-visible-layer completion from resettable telemetry so
  perf/UI harnesses do not force post-bootstrap key input back onto the old
  recovery path
- [x] return post-bootstrap key input and visible render callbacks to the
  renderer-owned refresh path and make the real XCUITest key-input regression
  pass with zero host immediate draws
- [x] arm recovery-only layer/frame-complete observation after post-bootstrap
  key input so renderer-owned typing still gets a bounded rescue path when no
  presentation completes after the input edge
- [x] arm and reschedule a renderer-owned recovery probe for post-first-layer
  wheel input so stalled scroll frames get one bounded rescue draw without
  restoring the steady-state host scroll pump
- [x] finish the custom `NSApplication` launch path before the first
  foreground push so real XCUITest and AX perf helpers stop getting stuck in
  `Running Background`
- [x] make bundle-launched perf runs carry bridge bootstrap config and isolated
  tmux socket selection through defaults instead of env-only binary launch
- [x] clear stale perf bridge defaults before and after Gate-L runs so failed
  benches do not poison later XCUITest launches
- [x] ignore stale `UITest*` tmux socket/config defaults on normal launches
  unless the Gate-L enabled marker or `AGTMUX_UITEST=1` is active
- [x] make the AX keypress harness acquire terminal geometry before strict
  focus so helper-driven foreground clicks can recover installed-app runs that
  start with a visible surface but no key window yet
- [x] replace the one-shot UITest bridge command poll with a long-lived
  low-latency loop so later perf iterations do not stall behind the 250 ms
  activation monitor cadence
- [x] bundle Ghostty runtime resources into the app so embedded surfaces see
  the same terminfo and shell-integration assets as native Ghostty
- [x] export app-side terminal screen frames and let the AX helper continue
  after external activation failure so perf input lanes can fall back from AX
  tree targeting
- [x] defer first Ghostty runtime bootstrap / surface attach until the app is
  active and the host window is visible+key so launch does not spend its first
  foreground cycle inside libghostty
- [x] keep app-side `GHOSTTY_ACTION_RENDER` on the dirty-view scheduler, but
  make the render-callback presentation path request renderer-owned refresh
  instead of synchronous host draws
- [x] allow bridge / automation runs to bypass the normal first-surface
  visibility gate so perf and regression lanes can attach before frontmost
  ownership settles
- [x] split perf-harness terminal open/registration from foreground focus so
  shell-driven lanes no longer hide activation failures inside open-surface
  waits
- [x] stop shell-driven Gate-L activation fallbacks from relaunching the
  installed app while a target pid already exists
- [x] publish app-side tmux bootstrap results before any post-bootstrap
  inventory hydration so installed-app perf lanes do not time out on refresh
- [x] shrink post-bootstrap bridge refresh from `fetchAll()` to local inventory
  only on the app-driven tmux path
- [x] make the live client internal scroll bench self-contained by bootstrapping
  its own isolated history fixture session and waiting only for registration /
  viewport readiness instead of shell-driven focus
- [x] move bridge-side internal scroll sampling and injection off shared
  MainActor tasks so the measurement command itself does not serialize both
  loops on the UI actor
- [x] preserve direct-local pane socket identity through the main-terminal
  attach/navigation path so explicit live-pane opens do not reattach against
  the wrong tmux server
- [x] seed fresh tmux attaches with a bounded `capture-pane` history prelude so
  live-pane wheel input enters real local scrollback instead of staying on a
  dead fresh client viewport
- [ ] thin the embedded cadence path further if matched-version cadence still
  trails native or user feel
- [ ] explain why scroll cadence still trails native after the host scroll pump
  is removed, and cut that remaining gap without reintroducing host-owned draw
  loops
- [x] align `GHOSTTY_ACTION_RENDER` dirty-draw targeting with the resolved
  active terminal view so live-pane frame callbacks and draw completion land on
  the same `GhosttyTerminalView`
- [x] cancel stale pane-retarget recovery before arming first-scroll recovery
  so pane-switch layer presents cannot mask the first live scroll after a
  same-window retarget
- [x] ignore the first late pane-retarget layer present when arming preserved-
  surface scroll recovery so the first scroll burst after a sidebar pane switch
  still moves the viewport
- [x] add a real UI regression that retargets a preserved surface to a pane
  with history and proves the first internal trackpad burst changes the
  viewport immediately
- [x] reclaim first responder on the first real wheel event after sidebar pane
  retarget so the initial user scroll is not consumed only by focus handoff
- [x] keep same-session preserved-surface retarget on rendered-client
  navigation when `renderedClientTTY` is known so the first post-retarget
  scroll does not wait on an unnecessary session-global convergence hop
- [ ] shrink the remaining live-pane cadence gap now that fresh attach enters
  real local scrollback on the real `%1` session path
- [ ] make foreground activation deterministic across shell-driven AX helpers
  and real XCUITest launches; `Running Background` is still recurring in this
  environment
