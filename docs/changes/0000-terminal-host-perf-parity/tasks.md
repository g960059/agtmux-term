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
- [x] route visible render callbacks straight to a coalesced immediate
  presentation draw instead of bouncing through the generic dirty refresh path
- [x] guard render-callback immediate draws behind first-layer presentation so
  the initial attach path cannot crash inside libghostty
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
- [ ] thin the embedded cadence path further if matched-version cadence still
  trails native or user feel
- [ ] explain why scroll cadence still trails native after the host scroll pump
  is removed, and cut that remaining gap without reintroducing host-owned draw
  loops
