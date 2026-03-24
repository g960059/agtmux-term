# Change Pack

- **Issue:** none yet (`0000` pre-issue pack)
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0003-tmux-first-cockpit.md](../../decisions/ADR-0003-tmux-first-cockpit.md), [ADR-0008-terminal-first-sidebar-overlay.md](../../decisions/ADR-0008-terminal-first-sidebar-overlay.md)

This pack tracks the structural cleanup needed to make the mainline product a
terminal-first embedded Ghostty cockpit with a tmux and agent sidebar overlay.

Current state:

- durable product docs now define the mainline UX as:
  - plain shell startup by default
  - one embedded terminal plus one sidebar in one main window
  - sidebar actions reuse or retarget the current terminal in place
  - auto-launch session is advanced and default-off
- the code now has a first-wave implementation for:
  - `MainTerminalStore` as the mainline terminal state owner
  - visible UI rewiring away from `WorkbenchTabBarV2` / `WorkbenchAreaV2`
  - plain-shell startup and `New Shell` reset
  - same-session retarget via rendered-client truth
  - cross-session single-terminal reattach via session attach + post-attach
    retarget
- targeted integration coverage now exists for:
  - session/window/pane target resolution
  - same-session retarget
  - plain-shell startup defaults
- typed attach / restore / drift diagnostics now flow through
  `MainTerminalStore` and are surfaced in the titlebar, main terminal, and
  sidebar
- `UITestTmuxBridge` active-target and rendered-target snapshots now prefer
  `MainTerminalStore` and the single main-terminal surface
- generic workbench, browser, and document code still exists in the
  repository, but it is now explicitly migration-only scaffolding rather than
  visible mainline UI
- legacy workbench-shaped UI tests are quarantined with explicit skips while
  terminal-first smoke coverage moves to the single main-terminal contract
