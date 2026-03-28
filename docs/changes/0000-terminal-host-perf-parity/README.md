# Change Pack

- **Issue:** none yet (`0000` pre-issue pack)
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0008-terminal-first-sidebar-overlay.md](../../decisions/ADR-0008-terminal-first-sidebar-overlay.md), [2026-03-23-terminal-host-perf-parity-review.md](../../research/2026-03-23-terminal-host-perf-parity-review.md)

This pack tracks the performance follow-up after the terminal-first cockpit
rewrite. The product boundary stays the same: one app window, one embedded main
terminal, one tmux/agent sidebar.

Current state:

- the runtime is now single-path: embedded main terminal only
- workbench runtime/tests and host-mode toggles are removed from the hot path
- normal launches stay on the local-inventory path and keep the bundled daemon
  and metadata lane off by default
- perf bridge payloads and diagnostics now use `surfaceID` / `viewportID`
  instead of stale tile/workbench vocabulary
- stale `legacy` / `next` comparison wrappers in `scripts/perf/` are deleted
  instead of being kept as broken compatibility seams
- GhosttyKit is now rebuilt with Ghostty's `ReleaseFast` optimize mode by
  default, and the repo-managed reinstall path now refuses to install a Debug
  app into `/Applications`; installed-app perf and live UX checks therefore
  target the same release-optimized runtime instead of a debug-heavy one
- the remaining perf entry points are:
  - embedded-only benches for live pane, loaded viewport, scroll, keypress,
    pane switch, and trackpad sampling
  - native baseline companions for the same paths
  - embedded-vs-native parity wrappers for history cadence, up-scroll step
    granularity, and frontmost live-client scrolling
- `gate_l_terminal_host_live_client_scroll_bench.sh` now resolves a single
  pane through active-target or `open_terminal_for_pane`, focuses that surface,
  and measures only the embedded main-terminal path
- `gate_l_terminal_host_loaded_viewport_bench.sh` follows the same embedded-only
  rule and no longer carries mode-selection CLI or payload fields
- the runbook now documents only the surviving embedded-vs-native perf matrix
- same-session pane retarget stays on one visible surface and now confirms that
  the pane-switch path repaints via an immediate presentation draw instead of
  recreating the Ghostty surface
- steady-state viewport scroll no longer schedules host-side presentation draws
  from `dispatchScrollInput(...)`; embedded scroll and post-bootstrap key input
  now stay on libghostty's renderer-owned redraw path, with host immediate
  draw reserved for dirty-draw override and explicit recovery seams only
- the real typing path no longer treats resettable scroll telemetry as the
  source of truth for "first visible layer completed"; that lifecycle state is
  now persistent across telemetry resets, so perf/UI harnesses do not
  accidentally shove later key input back onto the bootstrap recovery path
- visible render callbacks on the current main surface no longer bounce through
  the generic dirty-surface scheduler; after the first visible layer they stay
  on the renderer-owned refresh path instead of re-entering the old immediate
  presentation draw fallback
- post-first-layer key input now still arms layer/frame-complete observation
  plus a recovery-only probe, so renderer-owned typing remains the default but
  stalled input frames no longer sit invisible until an unrelated repaint
- the keypress perf harness now defaults to the installed app bundle and
  records both tmux-capture latency and viewport-visible latency, which exposed
  that tmux delivery is already near native while the remaining lag is mostly
  viewport presentation after tmux output arrives
- matched-version trackpad parity still passes on the tmux-visible proxy, but
  embedded telemetry continues to show `rendererFrameCompletedCount == 0`;
  scroll and typing are therefore still running on a host-pumped cadence
  rather than a native renderer-owned one
- normal viewport scroll no longer schedules extra app-thread Ghostty ticks on
  every follow-up frame; it now keeps the local surface mutation path but also
  allows one coalesced runtime tick right after fresh wheel input so embedded
  scroll does not wait for a later unrelated wake before renderer-owned
  presentation starts
- explicit typing paths in the vendored Ghostty surface now request
  `queueRenderAndDraw()` instead of a plain renderer wakeup, and
  `scrollToBottom()` follows the same immediate renderer-owned path so typed
  output does not wait for a later focus or pane change before becoming visible
- `GHOSTTY_ACTION_RENDER` still enters the host dirty-view scheduler, but the
  render-callback presentation path no longer issues a synchronous
  `ghostty_surface_draw(...)`; it routes back to the renderer-owned refresh
  path so the embedded host stops aborting during first-surface attach
- scroll and interactive continuation/recovery pumps no longer schedule a
  fresh `ghostty_app_tick(...)` for every follow-up frame; after the initial
  input-triggered wakeup, continuation frames stay on draw-only recovery so
  repeated main-thread runtime ticks stop competing with visible presentation
- the first pass of that tick-thinning accidentally removed the real-input
  immediate-draw entrypoint, the post-first-layer render-callback fallback,
  and the temporary layer observation gate; those are now restored so typing
  and scroll regain a live presentation path instead of waiting on unrelated
  pane/focus redraws
- after restoring those entrypoints, the March 26 AX keypress bench again sees
  `layer_present_timeout_count = 0` and non-zero
  `rendererFrameCompletedCount` / `immediatePresentationDrawCount`, confirming
  that visible presentation is happening on the current surface instead of
  stalling until a later repaint
- after arming recovery-only observation for post-bootstrap key input on March
  27, the installed-app bridge keypress lane now sees
  `layer_present_timeout_count = 0` with non-zero
  `rendererFrameCompletedCount` / `layerPresentCount`, so typed input once
  again has a concrete presentation-complete signal instead of only a viewport
  text change
- with the post-reset first-layer fix in place on March 26, the real XCUITest
  key-input regression now passes with `immediatePresentationDrawCount == 0`.
  The latest derived-build AX keypress bench records roughly
  `viewport_after_tmux_p50_ms = 99.3`,
  `layer_present_after_tmux_p50_ms = 375.2`, and
  `immediatePresentationDrawCount = 0`
- after removing the steady-state host scroll path on March 26, an internal
  bridge scroll burst now reports `refreshDrawRequestCount = 0`,
  `immediatePresentationDrawCount = 0`, and `scrollPresentationDrawCount = 0`
  with non-zero `rendererFrameCompletedCount`; `scroll_to_layer_present_p50_ms`
  stayed near `11.8 ms`, but `renderCallbackCount` is still `0` and
  `first_changed_elapsed_ms` is still around `173 ms` p50, so the remaining
  scroll/FPS gap has moved from host scroll pumping to renderer/frame cadence
  and viewport observation
- the latest derived-build trackpad/history bench still keeps
  `immediatePresentationDrawCount = 0` / `scrollPresentationDrawCount = 0`,
  and `scroll_to_layer_present_ms` stays renderer-owned with
  `p50 ≈ 14.7 ms`; the remaining gap is in cadence/jitter (`p95 ≈ 533 ms`),
  not a return to host scroll pumping
- the vendored Ghostty baseline is now `v1.3.1`, so the checked-in
  `GhosttyKit.xcframework` and perf baselines no longer depend on the old
  `v1.2.3` rebuild workaround
- UI/perf launch helpers now target the real `com.g960059.agtmux.term` bundle
  id and kill orphaned `AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm` processes by
  executable path before launching a fresh test instance
- the AX keypress harness no longer requires the app to already be key before
  the first helper click; it now waits for terminal geometry, lets the AX
  helper front the app, and only then enforces strict foreground focus
- normal launches now ignore stale `UITest*` defaults for tmux socket/config
  resolution unless an explicit UI-test env or the Gate-L enabled marker is
  active, so failed perf runs cannot redirect the installed app onto an old
  isolated tmux socket after the harness exits
- the custom `NSApplication` bootstrap now calls `finishLaunching()` before
  its first foreground push, which improved bundle-launch activation for the
  installed-app AX/perf helpers even though the real XCUITest lane still
  reports `Running Background` in this GUI session
- the embedded terminal now defers first Ghostty bootstrap / surface attach
  until the app is active and the host window is visible+key, so startup does
  not spend launch time inside libghostty/Metal before AppKit finishes the
  first foreground cycle
- bridge / automation runs are now exempt from that initial visibility gate, so
  perf and regression lanes can attach the first embedded surface before the
  host window becomes frontmost
- installed-app AX keypress benches can now reach `appIsActive = true`,
  `windowIsKey = true`, and `terminalIsFirstResponder = true`; the latest
  3-iteration run measured `viewport_after_tmux_p50_ms = 159.9` and
  `layer_present_after_tmux_p50_ms = 491.4`
- the installed-app March 27 trackpad/history bench now also runs with a
  frontmost terminal surface and keeps `scroll_to_layer_present_ms` near
  `10.3 ms` p50 / `37.2 ms` p95 while `renderCallbackCount` remains `0`, so
  the remaining FPS gap is still renderer-cadence jitter rather than focus
  loss or host scroll pumping
- after re-arming a renderer-owned recovery probe for post-first-layer wheel
  input on March 27, the installed-app trackpad/history bench now captures
  `scroll_to_first_draw_ms` again and drops to roughly
  `scroll_to_first_draw_ms p50 = 6.3`, `scroll_to_layer_present_ms p50 = 9.8`,
  `scroll_to_layer_present_ms p95 = 98.0`, and
  `layer_present_gap_p95 = 21.5`; steady-state host scroll pumping still stays
  off, but stalled wheel frames now get one bounded immediate-draw rescue
- the direct-local live-pane path no longer drops tmux socket identity during
  explicit pane attach. The perf bench no longer lands on a `can't find
  window` error page when the app itself is running on an isolated tmux socket
- fresh live-pane attach now seeds the embedded terminal's local scrollback
  with a bounded `tmux capture-pane -p -e -S -2000` prelude before the real
  `attach-session`. On March 28 this changed the real `%1` live-pane bench from
  zero effective viewport movement to `baseline_line = 260`,
  `final_visible_line = 281`, `upward_total_rows = 4`, and
  `first_changed_ms = 165.8`
- the remaining live-pane gap is no longer "fresh attach cannot scroll at
  all". It is now the smaller but still user-visible difference between loaded
  live scrollback and native Ghostty cadence / step accumulation after the
  first visible movement
- first-scroll stalls after same-window pane retarget now cancel stale
  pane-retarget recovery before arming scroll recovery, so a delayed
  retarget-only layer present can no longer falsely satisfy the first scroll's
  renderer-owned recovery path
- `GHOSTTY_ACTION_RENDER` dirty draws now follow the same resolved active
  terminal view that renderer frame telemetry uses. This closes the case where
  live panes could record render/layer callbacks on the visible surface while
  the host's draw-completion telemetry was still landing on a stale handle map
- the vendored embedded surface no longer treats an unavailable macOS display
  link as fatal during renderer init; surface attach now requires a real
  display attachment context and lazily retries display-link setup when the
  host later supplies a valid display id
- Gate-L bundle launches now drive automation through defaults-backed bridge
  config instead of env-only binary launch, and local tmux socket/config
  resolution now falls back to those defaults so installed-app perf runs stay
  on isolated tmux servers instead of silently falling back to `/private/tmp/tmux-*/default`
- Gate-L setup/cleanup now clears stale defaults up front so failed perf runs
  do not poison later XCUITest launches with leftover bridge paths or bootstrap
  scenarios
- the UITest bridge command loop is now long-lived instead of a one-shot
  command poll re-armed by the 250 ms activation monitor, so bench commands no
  longer inherit that extra scheduler latency or later-iteration stalls
- the app bundle now copies Ghostty runtime resources (`ghostty/`,
  `terminfo/`, `man/`, `locale/`) into `Contents/Resources`, so embedded
  surfaces no longer depend on missing terminfo or shell-integration assets
- focus-state snapshots now expose the terminal's screen-space frame, and the
  AX perf helper can continue after external activation failure and fall back
  from missing target-element frames to the containing window frame
- with the long-lived bridge loop in place on March 27, the installed-app
  bridge keypress bench no longer stalls on later iterations; the latest
  5-iteration run completed with `tmux_capture_p50_ms = 159.9`,
  `viewport_p50_ms = 316.1`, and `viewport_after_tmux_p50_ms = 160.6`
- AX shell benches still do not complete reliably in this GUI session. Even
  after switching to app-reported terminal click points and keeping the helper
  alive after external activation failure, the real `--delivery ax` keypress
  lane can still time out waiting for tmux-visible input
- `open_terminal_for_pane` no longer bundles foreground activation into its
  registration wait; perf lanes now treat terminal attach/registration and
  terminal-host focus as separate phases so a failed foreground grab does not
  masquerade as a stale-surface open failure
- the live client scroll bench can now run a frontmost-independent internal
  lane by bootstrapping its own isolated history fixture session; it no longer
  depends on `agtmuxd`, a pre-attached main terminal, or shell-driven window
  focus just to collect internal scroll samples
- bridge-side `measureTerminalScrollBurstForTesting` no longer schedules both
  sampling and injection on MainActor; sampling/injection now run from detached
  tasks and hop to MainActor only for the actual terminal snapshot/dispatch
  calls so the measurement lane does not self-starve on actor scheduling alone
- bootstrap scenarios now publish `tmux-bootstrap-result.json` before any
  post-bootstrap inventory refresh runs, so installed-app perf lanes do not
  mistake a slow refresh for bootstrap failure
- post-bootstrap bridge refresh is now local-inventory-only instead of a full
  `fetchAll()`, which keeps immediate follow-up perf commands off the heavier
  broad-refresh path
- Gate-L activation no longer falls back to bundle-id relaunch while an app
  pid already exists, which removed the March 27 stale-surface failures where
  a second app instance reused the same bridge defaults and restarted the
  bootstrap scenario mid-bench
- after removing that relaunch path, the remaining shell-driven AX blocker is
  explicit: strict `terminalHost` focus still reaches
  `terminalIsFirstResponder = true` but can remain stuck at
  `appIsActive = false` / `windowIsKey = false`, so the next activation work
  should target frontmost ownership directly rather than terminal registration
- the real XCUITest launch lane is still blocked in this environment:
  `XCUIApplication.launch()` continues to fail with
  `Failed to activate application ... (current state: Running Background)`
  even after the foreground-first surface bootstrap change
- user-perceived keyboard, scroll, and pane-switch smoothness still trail
  native Ghostty; the remaining work is real hot-path thinning and scheduler
  cleanup, not compatibility preservation
- same-window pane retarget now keeps first-scroll recovery from being masked
  by one late pane-retarget layer present, and a real preserved-surface UI
  regression now proves the first internal scroll burst moves the viewport on
  the retargeted pane without requiring a second gesture
- first real wheel input after a sidebar pane retarget now explicitly reclaims
  terminal first responder before dispatch so the gesture is not spent only on
  focus recovery after the sidebar button click
- same-session preserved-surface retarget now keeps the live navigation path on
  the rendered tmux client when `renderedClientTTY` is already known, instead
  of accidentally dropping back to session-global navigation before the first
  post-retarget scroll

Remaining engineering focus:

- reduce steady-state scroll/input latency in the embedded main terminal
- shrink the remaining layer-present gap on real typing after tmux output
- shrink bridge-side active-target observation and other non-visible hot-path
  costs that still dominate bench-only pane-switch numbers
- explain and reduce the remaining scroll cadence gap now that the steady-state
  host scroll presentation path is gone
- keep shrinking live-pane first-visible and follow-up scroll latency now that
  fresh attach enters real local scrollback instead of presenting a dead
  viewport
- explain why `open_terminal_for_pane(..., nowait)` can still leave the app-side
  bridge unable to claim the subsequent `focus_terminal_host` command on the
  real installed-app lane; the remaining freeze is after open/attach, not in
  bootstrap publication or broad refresh
- make foreground activation deterministic for both XCUITest and AX perf
  helpers; the current shell-driven GUI session still leaves some bundle
  launches in `Running Background`, and the AX lane still cannot rely on
  frontmost ownership after launch
- keep pane-retarget and blank-frame recovery fixes separate from steady-state
  cadence work
- continue validating against matched-version native Ghostty baselines
