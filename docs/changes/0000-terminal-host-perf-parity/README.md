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
- the next work is a perf-parity program, not another UX rewrite
