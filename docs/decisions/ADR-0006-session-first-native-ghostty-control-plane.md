# ADR-0006: Make the mainline product a session-first Ghostty control plane

- **Status**: Accepted
- **Date**: 2026-03-23
- **Supersedes**: the abandoned app-owned terminal-host rewrite as the
  mainline product direction, and ADR-0001 for the mainline terminal runtime
  choice

## Context

The repository already moved away from linked-session workspace truth in
ADR-0003, but the product still spent substantial effort trying to keep the
terminal runtime inside the app through embedded-host and next-host paths.

That approach kept running into the same structural problem:

- focus, scroll, and input behavior still depended on app lifecycle
- generic workbench / tile state still leaked into the user's terminal mental
  model
- the value users wanted most was already in sidebar observability, binding,
  and session control, not in app-owned terminal runtime

Native Ghostty already provides the runtime quality bar. The missing product
value is not "another terminal host" but "a session-first control plane that
opens, reveals, and diagnoses real Ghostty terminals correctly."

## Decision

The mainline product will not own terminal runtime behavior.

Instead:

- the primary UI is a session-first sidebar over local and remote tmux sessions
- Ghostty remains a normal terminal application outside tmux-attached flows
- clicking a session row first focuses an existing live Ghostty binding
- if no live binding exists, the app opens a new Ghostty tab or window and
  runs the attach command there
- agtmux-term owns binding registry, restore hints, diagnostics, metadata, and
  automation
- tmux remains the source of truth for session existence
- new Ghostty pane automation is explicitly deferred until the simpler
  tab/window model is proven reliable

Generic app-owned workbench / tile graphs are not the mainline product
surface. If retained during migration, they are transitional implementation
detail rather than product truth.

## Consequences

Positive:

- the product matches the user's natural mental model: tmux sessions in
  Ghostty
- terminal feel is delegated to native Ghostty instead of recreated inside the
  app
- focus / input / scroll bugs caused by app-owned terminal lifecycle become
  much less central to the product
- the app can concentrate on session discovery, metadata, restore, and
  diagnostics

Tradeoffs:

- the product depends more heavily on Ghostty launch / focus automation
- duplicate-binding and stale-binding handling become first-class product work
- existing embedded-host and workbench code becomes transitional or historical
- first-wave UX is intentionally limited to existing-binding focus plus new
  tab/window open; pane creation waits for later
