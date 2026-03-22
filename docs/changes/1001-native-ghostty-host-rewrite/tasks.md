# Tasks

- [x] phase-0 cleanup
- [x] phase-1 host-mode boundary
- [x] phase-1 persistent-surface ownership
- [x] phase-1 live-gate host-mode plumbing
- [x] next-host bridge tileID -> active leafID resolution for viewport/focus
  diagnostics
- [x] deterministic loaded-TUI host-mode acceptance gate for `legacy` vs `next`
- [x] machine-readable harness hardening for deterministic gate JSON output
- [x] fresh live-client wheel-up diagnosis; keep the wrapper as diagnostic-only
- [x] prove deterministic loaded-TUI parity repeatability across repeated
  `legacy` vs `next` runs
- [x] harden the fresh/live host-mode wrapper against stale tmux environment
  and stale pane IDs
- [x] remove measured-run dependence on tmux client scroll probes from the live
  host-mode wrapper
- [x] add local pane-id inventory fallback before session-only live open
- [x] add runtime terminal-host-mode override groundwork for same-app live
  parity
- [x] stop targeting tmux clients by `client_tty` in the live wrapper; resolve
  `client_name` before `switch-client`
- [x] phase-3 next-host scroll cadence wiring on the deterministic loaded-TUI
  gate
- [x] installed-app host-mode override via app defaults for rewrite-branch
  trials
- [ ] realistic loaded live-pane parity gate for the next host
- [ ] durable-knowledge promotion
- [ ] remove `docs/changes/1001-native-ghostty-host-rewrite/` before merge
