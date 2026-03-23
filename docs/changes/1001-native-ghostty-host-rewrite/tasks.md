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
- [x] keep recent precise normal-screen render callbacks on the renderer-owned
  refresh path in `next`
- [x] installed-app host-mode override via app defaults for rewrite-branch
  trials
- [x] require true next-host leaf registration in the bridge instead of
  accepting stale tile-level views
- [x] treat host-mode remounts as new rendered generations in the surface
  registry
- [x] allow defaults-based bundle launches to activate the UITest bridge for
  same-app rewrite diagnostics
- [x] ignore blank persisted pane refs when deriving next-host visible-pane
  identity at startup
- [x] let next-host persisted local terminal tiles attach during bootstrap
  before the first inventory sync completes
- [x] promote the next-host bootstrap fallback controller to the first real
  pane identity instead of tearing it down during startup
- [x] keep the rewrite branch full UI suite green while `next` host work is in
  flight
- [x] forbid destructive default-local tmux bootstrap in live perf harnesses
- [x] add bridge-internal scroll burst measurement for same-app live diagnostics
- [x] rebind UITest bridge command-loop paths after runtime defaults changes
- [ ] realistic loaded live-pane parity gate for the next host
- [ ] durable-knowledge promotion
- [ ] remove `docs/changes/1001-native-ghostty-host-rewrite/` before merge
