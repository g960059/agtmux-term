# Change Pack

- **Issue:** `#1002` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [ADR-0003-tmux-first-cockpit.md](../../decisions/ADR-0003-tmux-first-cockpit.md), [ADR-0006-session-first-native-ghostty-control-plane.md](../../decisions/ADR-0006-session-first-native-ghostty-control-plane.md)

This pack tracks the structural pivot from app-owned terminal hosting toward a
session-first control plane around native Ghostty.

Current state:

- durable product docs now define the mainline UX as:
  - session-first sidebar
  - focus existing Ghostty binding first
  - otherwise open a new Ghostty tab/window
- new Ghostty pane creation is intentionally deferred
- embedded-host and workbench code still exists in the repository, but it is
  no longer the mainline product story
- implementation work for the new binding-first model has not started yet
