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
- sidebar rows now restore the earlier managed-pane affordance contract:
  provider badge on the leading edge, ring only for running/attention/error
  states, and trailing freshness only for non-running managed rows
- a mock-daemon UI regression test now asserts that managed Codex rows do not
  fall back to `current_cmd=node`, that running rows report a running badge
  state without trailing freshness, and that idle rows report trailing
  freshness without a ring
- the bundled XPC client now targets the actual embedded service identifier
  `com.g960059.agtmux.term.daemonservice`, so installed release builds use the
  XPC daemon path instead of failing the bootstrap lookup
- pane row titles now derive from `PaneDisplayState` rather than raw tmux
  inventory truth, which prevents presentation-managed rows from rendering the
  stale `current_cmd=node` fallback when daemon provider truth already exists
- the real Codex UI repro on this host still fails, but its diagnostics now
  point at daemon truth remaining `managed=0/provider=nil` all the way through
  the app bootstrap probe instead of at a sidebar-only binding loss
- the live Codex UI proof now skips explicitly when the daemon never promotes
  the pane beyond unmanaged shell truth, so this repo's full UI suite stays
  green while mock/fake daemon tests continue covering term-side binding
- the latest daemon handoff with exact repro evidence lives in
  `/tmp/2026-03-18-daemon-sidebar-provider-handoff.md`
