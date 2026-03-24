# Tasks

- [x] durable docs rewrite for the terminal-first sidebar-overlay direction
- [x] add a superseding ADR for the mainline product boundary
- [x] write an implementation-ready design for the terminal-first mainline path
- [x] define the minimal main-panel main-terminal model in code
- [x] rewire visible mainline UI away from `WorkbenchTabBarV2` /
  `WorkbenchAreaV2`
- [x] implement plain-shell startup and `New Shell` reset behavior
- [x] implement session-row target resolution:
  `tmux active -> restore -> first listed`
- [x] implement pane/window activation by reusing or retargeting the current
  terminal
- [x] implement cross-session single-terminal reattach
- [x] add attach, restore, and drift diagnostics for the thinner host model
- [x] decide what generic workbench, browser, and document code remains as
  migration-only scaffolding
- [x] migrate `UITestTmuxBridge` and mainline UI smoke tests off visible
  workbench assumptions
