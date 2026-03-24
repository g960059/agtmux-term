# Tasks

- [x] durable docs rewrite for the terminal-first sidebar-overlay direction
- [x] add a superseding ADR for the mainline product boundary
- [x] write an implementation-ready design for the terminal-first mainline path
- [ ] define the minimal main-panel main-terminal model in code
- [ ] rewire visible mainline UI away from `WorkbenchTabBarV2` /
  `WorkbenchAreaV2`
- [ ] implement plain-shell startup and `New Shell` reset behavior
- [ ] implement session-row target resolution:
  `tmux active -> restore -> first listed`
- [ ] implement pane/window activation by reusing or retargeting the current
  terminal
- [ ] implement cross-session single-terminal reattach
- [ ] add attach, restore, and drift diagnostics for the thinner host model
- [ ] decide what generic workbench, browser, and document code remains as
  migration-only scaffolding
