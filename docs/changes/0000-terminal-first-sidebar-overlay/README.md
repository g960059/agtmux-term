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
- generic workbench and companion surfaces still exist in the repository, but
  they are not the desired mainline product story
- implementation cleanup toward a thinner terminal-first host has not started yet
