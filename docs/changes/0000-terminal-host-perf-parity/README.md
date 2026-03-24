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
  `active-terminal-target` on plain-shell startup; they open the requested pane
  first and only fall back to active-target probing if the open path fails
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
- the next work is a perf-parity program, not another UX rewrite
