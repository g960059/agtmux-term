# Requirements

## Problem

When a local pane starts as a plain shell and later becomes a managed agent
process in the same visible tmux pane, the daemon can publish managed
provider/activity truth but the sidebar continues showing the row as unmanaged.

## Goals

- preserve exact-pane identity guarantees while allowing legitimate shell to
  agent promotion on the same visible pane instance
- ensure sidebar-facing display state surfaces daemon provider/activity/freshness
  after promotion
- add regression coverage that fails if daemon truth reaches the app but is not
  reflected in sidebar-facing state

## Non-Goals

- changing remote pane behavior
- broad sidebar redesign or new UI affordances
- weakening exact-identity checks for conflicting pane-instance replacements

## Acceptance

- [ ] a same-pane-instance local shell to managed-agent promotion updates the
      local metadata overlay instead of being dropped as a conflicting upsert
- [ ] sidebar-facing display state reports the managed provider/activity for the
      promoted pane under fake-daemon test coverage
- [ ] conflicting upserts with a different pane instance continue to fail closed
