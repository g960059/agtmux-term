# Change Pack

- **Issue:** none yet (`0000` pre-issue pack)
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0008-terminal-first-sidebar-overlay.md](../../decisions/ADR-0008-terminal-first-sidebar-overlay.md), [2026-03-23-terminal-host-perf-parity-review.md](../../research/2026-03-23-terminal-host-perf-parity-review.md)

This pack tracks the next phase after the terminal-first cockpit rewrite:
bringing the embedded terminal host closer to native Ghostty smoothness without
changing the one-window product boundary.

Current state:

- the mainline product boundary is already terminal-first and in one window
- user-perceived keyboard and scroll smoothness still trails native Ghostty
- `next` host mode is still a phase-1 path with retained pane controllers and
  app-owned cadence on the hot path
- the host-mode-specific perf benches now require an explicit `legacy` or
  `next` selection, but broader perf and UI defaults still over-index on
  `legacy`
- the perf runbook now documents the matched-version native-vs-embedded
  comparison rule
- `__agtmux_dump_scroll_telemetry__` now exposes app-side render/direct-draw
  ownership counters and view-side refresh/immediate draw counters
- the host-mode parity wrappers now surface those counters in their diagnostics
- app-side timing summaries for `ghostty_app_tick(...)` and
  `runDirtyDrawPass()` now ride in the same telemetry snapshot
- resize churn counters for `syncSurfaceMetrics(...)`, `SurfacePool`
  lifecycle counters, and next-host pane-retention counters now ride in the
  same telemetry snapshot and parity diagnostics
- repeated deterministic loaded-viewport single passes are still mixed on
  latency delta, but the measured burst still shows no app-side scheduler or
  timing samples on either side; the persistent ownership gap remains
  `scrollImmediatePresentationDrawCount` (`legacy=16`, `next=0`)
- the first loaded-viewport run with resize/lifecycle counters also kept those
  new counters flat on both sides, so the deterministic loaded path still does
  not exercise resize churn, `SurfacePool` lifecycle churn, or next-host pane
  retention churn
- the live host-mode bench no longer loses late per-id bridge results, and the
  UITest bridge command loop no longer reprocesses the same request file in
  parallel under runtime-config churn
- the UITest bridge now atomically claims each command file before decode, so
  multiple bridge consumers cannot process the same request id
- after those fixes, the direct live `legacy` path reached measurement again on
  `gate-normal-scroll/%1` (`changed_sample_count=12`,
  `first_changed_elapsed_ms≈739.4ms`)
- the remaining live blocker turned out to be launch isolation and timeout
  mismatch, not the `next` scroll path itself:
  - another running `AgtmuxTerm` instance could read the same stable bridge
    defaults and race the debug build on the same command file
  - `__agtmux_focus_terminal_host__` was still capped at `10s` even when the
    bridge registration wait was configured to `15s`
- direct live launches now terminate competing `AgtmuxTerm` instances before
  opening the bundle, and the live bench derives its focus-host timeout from
  the registration budget
- fresh-launch direct live runs no longer wait for an impossible
  `active-terminal-target` on plain-shell startup; they open the selected
  session/window target first, focusing that window's active pane, and only
  fall back to active-target probing if the open path fails
- after those fixes, the direct live `next` path also reaches measurement again
  on `gate-normal-scroll/%1` (`changed_sample_count=13`,
  `first_changed_elapsed_ms≈536.6ms`)
- the live `legacy` vs `next` parity wrapper now passes again with both sides
  valid and scrolling, and the recovered `next` run no longer shows duplicate
  command-loop request ids in the bridge log
- a first matched-version `legacy` / `next` / native table now exists via
  `gate_l_terminal_host_scroll_parity_table.sh`
  - it records embedded GhosttyKit metadata, native Ghostty metadata, and the
    live host-mode parity result in one JSON payload
  - the first table used vendored native Ghostty `1.2.3` to match embedded
    GhosttyKit `1.2.3`
  - that run passed for both `legacy` and `next` on the current up-scroll step
    gate, and the live `legacy` vs `next` leg also passed
  - the measured deltas were effectively flat:
    - `mean_lines_per_step_p50_delta = 0`
    - `step_rows_p95_delta = 0`
    - `next_minus_legacy first_changed_elapsed_p95_delta_ms ≈ -13.6`
  - this table is still step- and first-change-oriented; it does not explain a
    user report like “native feels 60fps while embedded feels 5fps”
- a cadence-sensitive table now exists on top of the existing history-scroll
  benches:
  - `gate_l_trackpad_history_scroll_parity.sh` reuses the matched-version
    native-vs-embedded setup, but keeps the gate on tmux-visible latency while
    surfacing embedded-only `scroll_to_layer_present_ms` and
    `layer_present_gap_*` diagnostics
  - `gate_l_terminal_host_cadence_parity_table.sh` runs that wrapper for both
    `legacy` and `next` and summarizes `next_minus_legacy` proxy and embedded
    cadence deltas
  - the first short matched `1.2.3` cadence table passed on the native proxy
    gate for both `legacy` and `next`, but still showed `next` slightly worse
    on the embedded-only cadence diagnostics:
    - `next_minus_legacy tmux_visible_line_change_p50_delta_ms ≈ +21.6`
    - `next_minus_legacy scroll_to_layer_present_p95_delta_ms ≈ +4.1`
    - `next_minus_legacy layer_present_gap_p95_delta_ms ≈ +7.3`
  - so the perf program now has a measurement seam that is closer to the user
    complaint than the pure step table, even though it still is not a true FPS
    or image-diff capture
- the first hot-path thinning slice is now in:
  - app-side and view-side scroll telemetry collection defaults off in normal
    app runs instead of appending samples and signposts on every scroll event
  - bridge/perf/test `reset` commands still re-enable that telemetry before a
    measured run, and `AGTMUX_SCROLL_TELEMETRY_ENABLED=1` still forces it on
  - the first repeated short matched `1.2.3` cadence rerun after that change
    flipped the previously positive `next-minus-legacy` cadence deltas
    negative:
    - `tmux_visible_line_change_p50_delta_ms ≈ -18.4`
    - `scroll_to_layer_present_p95_delta_ms ≈ -13.4`
    - `layer_present_gap_p95_delta_ms ≈ -4.1`
  - this does not prove the whole native parity problem is solved, but it does
    show that always-on host telemetry itself was part of the hot path
- a follow-up steady-state slice is also in for normal app runs:
  - `next` no longer keeps `layer.contents` observation active when both of
    these are true:
    - scroll telemetry collection is off
    - no pane-retarget recovery probe is in flight
  - `legacy` still keeps that observation because its host scroll-presentation
    throttle/recovery logic depends on layer-present timing
  - `next` also re-enables the observation during pane-retarget recovery so the
    blank-frame guard still has layer-present truth
  - this slice is aimed at installed-app feel and is not directly visible in
    the current perf harness, because the harness explicitly re-enables scroll
    telemetry before each measured run
- measurement signposts are now default-off too:
  - the JSON telemetry benches still collect uptime/sample arrays, but they no
    longer emit host/scroll signpost intervals unless
    `AGTMUX_HOST_SIGNPOSTS_ENABLED=1`
  - a short cadence rerun after this change stayed mixed instead of cleanly
    improving, so signpost emission was not the dominant remaining tail
- the terminal-first mainline also had a separate steady-state churn issue:
  - `MainTerminalStore` kept polling tmux `list-clients` / `list-panes` even
    after the requested main-terminal target had already converged
  - that background loop kept waking the app, updating main-terminal state, and
    invalidating SwiftUI layout even while the terminal should have been idle
  - the current fix no longer keeps reapplying stale navigation intent after
    the visible pane matches the requested target
  - the loop now stays in a low-rate same-session drift watch so terminal-
    originated pane changes still retarget the sidebar and main-terminal
    selection without rebuilding the rendered surface
- another installed-app hot-path issue also surfaced after the tmux-poll fix:
  - each running managed pane row rendered a `repeatForever` SwiftUI spinner
  - idle installed-app samples still showed `NSHostingView.layout()` and
    `AnimatableAttribute.updateValue()` churn in the sidebar while the
    terminal was otherwise idle
  - the current fix keeps the running badge visible but static, so the sidebar
    no longer drives continuous animation work across every running pane row
- another correctness blind spot also showed up in regression coverage:
  - the installed app on this machine runs with `TerminalHostMode=next`, but
    the UI suite had been forcing `legacy` unless a test overrode it
  - that meant passing direct-attach E2Es still did not prove the real
    installed-app host path that users were actually running
  - the current fix keeps `legacy` as the suite default but preserves an
    explicit host-mode override, and the attach E2Es now include an explicit
    `next` proof plus a preserved-surface viewport-content assertion
- the next work is a perf-parity program, not another UX rewrite
