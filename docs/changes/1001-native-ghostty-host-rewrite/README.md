# Change Pack

- **Issue:** `#1001` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0005-native-ghostty-host-rewrite.md](../../decisions/ADR-0005-native-ghostty-host-rewrite.md), [2026-03-18-scroll-smoothness-baseline.md](../../research/2026-03-18-scroll-smoothness-baseline.md), [2026-03-22-live-scroll-gates.md](../../research/2026-03-22-live-scroll-gates.md)

This pack tracks the structural rewrite that moves terminal hosting away from
the legacy embedded scroll-pump path and toward a Ghostty-owned host model in
the same repository.

Current state:

- the old scroll investigation pack is retired; its accepted findings now live
  in the research note and perf runbook
- completed packs for unsigned release fallback and sidebar daemon binding are
  retired from `docs/changes/`
- phase 1 now has an explicit `TerminalHostMode` boundary:
  - `legacy` routes through `GhosttyIslandRepresentable`
  - `next` routes through a separate next-host controller boundary
- phase 1 next-host ownership now keeps pane-keyed child controllers with a
  capped retention set, so same-tile pane switches can move toward controller
  swap instead of same-surface reattach
- the UITest tmux bridge and perf app launcher now surface
  `AGTMUX_TERMINAL_HOST_MODE`, so realistic live gates can target `legacy`
  and `next` explicitly instead of inferring host ownership from the app build
- the realistic live client-scroll gate now has a host-mode wrapper:
  - `gate_l_terminal_host_live_client_scroll_bench.sh` launches a fresh app in
    either `legacy` or `next` mode and measures the live pane path
  - `gate_l_terminal_host_live_client_scroll_parity.sh` compares those two
    modes on the same live pane before the rewrite is judged against native
- fresh live-client investigation has now isolated a stricter boundary:
  - client-targeted `PageUp` successfully primes a fresh attached client from
    `scroll_position 0 -> 14` and a post-run probe can move it again
    (`14 -> 28`)
  - the same fresh client still records `changed_sample_count = 0` for the
    injected wheel burst
  - therefore the current phase-1 blocker is not "fresh client cannot scroll"
    but "fresh live client wheel-up is not producing tmux client scroll"
- the obsolete replay/frontmost-AX scroll gates are retired in favor of:
  - the live-captured `curses-history` proxy
  - the frontmost live client-scroll parity gate
