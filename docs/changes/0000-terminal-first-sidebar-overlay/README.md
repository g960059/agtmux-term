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
- generic workbench and companion surfaces still exist in the repository, but
  they are not the desired mainline product story
- follow-up cleanup still remains around richer diagnostics and removing or
  quarantining more migration-only workbench/document scaffolding
- `UITestTmuxBridge` and several UI tests still assume visible workbench state
  and need a later migration to the `MainTerminalStore` path
