# Change Pack

- **Issue:** none yet (`0000` pre-issue pack)
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0003-tmux-first-cockpit.md](../../decisions/ADR-0003-tmux-first-cockpit.md), [ADR-0007-session-first-embedded-ghostty-host.md](../../decisions/ADR-0007-session-first-embedded-ghostty-host.md)

This pack tracks the structural cleanup needed to make the mainline product a
session-first cockpit with Ghostty hosted in the app's main panel.

Current state:

- durable product docs now define the mainline UX as:
  - session-first sidebar
  - sidebar plus terminal in one main window
  - reveal an existing embedded session viewport first
  - otherwise open or retarget a viewport in the main panel
- generic workbench and companion surfaces still exist in the repository, but
  they are not the desired mainline product story
- implementation cleanup toward a thin embedded host has not started yet
