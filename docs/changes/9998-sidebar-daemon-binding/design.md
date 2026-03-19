# Design

## Chosen Approach

Treat the visible tmux pane instance as the stable row identity for local
metadata overlay replacement. If a v3 upsert targets the same local visible
location and the same pane instance, allow the overlay row to replace its daemon
session key and provider truth even when the daemon session key changes from a
shell-owned identity to an agent-owned identity.

This keeps the exact pane-instance guard intact while admitting the real product
case where a shell pane launches Codex or Claude in place.

## Boundaries

- `LocalMetadataOverlayStore` replacement rules change for same-pane-instance
  local v3 upserts at one visible location
- local model/sidebar regression tests are added for shell to managed promotion
- conflicting upserts with a different pane instance remain rejected

## Failure Modes

- if daemon truth arrives for a different pane instance at the same visible
  location, the upsert is still dropped and the row stays on the existing truth
- if daemon metadata is missing entirely, the sidebar continues to show
  inventory-only unmanaged fallback
