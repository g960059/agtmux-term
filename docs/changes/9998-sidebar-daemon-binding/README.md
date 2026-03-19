# Change Pack

- **Issue:** `#9998` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** none

This pack tracks the sidebar daemon-binding regression where daemon-managed
provider/activity truth exists but does not surface on the visible local row.

Current state:

- local v3 overlay replacement now treats the visible pane instance as the row
  identity, so `shell:%pane -> codex:%pane` promotion on the same pane instance
  is no longer dropped just because the daemon session key changes
- a fake-daemon model test now asserts that the promoted pane reaches
  sidebar-facing display state with managed provider/activity truth
- a mock-daemon UI test now asserts that the visible sidebar row summary
  includes managed provider/activity metadata
- the real Codex UI repro on this host still fails, but its diagnostics now
  point at daemon truth remaining `managed=0/provider=nil` all the way through
  the app bootstrap probe instead of at a sidebar-only binding loss
- the latest daemon handoff with exact repro evidence lives in
  `/tmp/2026-03-18-daemon-sidebar-provider-handoff.md`
