# Tasks

- [x] retire the completed terminal-first sidebar-overlay change pack
- [x] capture a dated perf-parity review in `docs/research/`
- [x] create an active change pack for terminal-host perf parity
- [x] force explicit host-mode selection in the perf paths that still default
  to `legacy`
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
- [x] align pane-row open semantics with selected-window attach plus active-pane focus
- [x] produce the first measured parity table for `legacy` / `next` / native
- [x] add a cadence-sensitive parity table that can explain user-visible
  smoothness gaps beyond step granularity
- [x] remove always-on telemetry collection from the normal hot path
- [x] stop main-terminal steady-state tmux polling after navigation converges
- [x] remove per-row repeat-forever sidebar animation from the normal hot path
- [x] add explicit `next` host-mode E2E coverage for initial attach and preserved-surface viewport repaint
- [ ] thin the `next` cadence path further if matched-version cadence still
  trails native or user feel
