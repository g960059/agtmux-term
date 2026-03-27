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
- the keypress perf harness now defaults to the installed app bundle and
  records both tmux-capture latency and viewport-visible latency, which exposed
  that tmux delivery is already near native while the remaining lag is mostly
  viewport presentation after tmux output arrives
- matched-version trackpad parity still passes on the tmux-visible proxy, but
  embedded telemetry continues to show `rendererFrameCompletedCount == 0`;
  scroll and typing are therefore still running on a host-pumped cadence
  rather than a native renderer-owned one
- normal viewport scroll no longer schedules extra app-thread Ghostty ticks;
  it now stays on the local surface mutation path and asks the renderer thread
  for an immediate draw on each accumulated scroll step
- explicit typing paths in the vendored Ghostty surface now request
  `queueRenderAndDraw()` instead of a plain renderer wakeup, and
  `scrollToBottom()` follows the same immediate renderer-owned path so typed
  output does not wait for a later focus or pane change before becoming visible
- visible render callbacks now re-enter the existing
  `triggerRendererOwnedRenderCallback(...)` path on the current main-actor turn
  instead of taking an extra run-loop hop before calling
  `ghostty_surface_refresh(...)`
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
- user-perceived keyboard, scroll, and pane-switch smoothness still trail
  native Ghostty; the remaining work is real hot-path thinning and scheduler
  cleanup, not compatibility preservation

Remaining engineering focus:

- reduce steady-state scroll/input latency in the embedded main terminal
- shrink the remaining layer-present gap on real typing after tmux output
- shrink bridge-side active-target observation and other non-visible hot-path
  costs that still dominate bench-only pane-switch numbers
- explain and reduce the remaining scroll cadence gap now that the steady-state
  host scroll presentation path is gone
- keep pane-retarget and blank-frame recovery fixes separate from steady-state
  cadence work
- continue validating against matched-version native Ghostty baselines
