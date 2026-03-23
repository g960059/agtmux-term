# Design

## Chosen Approach

Keep `agtmux-term` as a tmux-first control plane, but stop treating app-owned
terminal hosting as the mainline product architecture.

The mainline boundary becomes:

- tmux for session existence and pane truth
- Ghostty for terminal runtime behavior
- agtmux-term for sidebar inventory, metadata, bindings, restore, diagnostics,
  and launch/focus automation

## First-Wave Interaction Model

When the user activates a session row:

1. resolve whether a live Ghostty binding already exists for that logical
   session
2. if yes, focus that Ghostty tab/window
3. if not, open a new Ghostty tab or window
4. run the attach command on that newly created terminal surface
5. record or refresh the binding so later clicks reveal the same session

## Boundaries

App-owned:

- session inventory and metadata display
- binding identity and lifecycle
- restore hints and diagnostics
- launch/focus automation for Ghostty

Not app-owned:

- terminal rendering
- keyboard / scroll / IME behavior
- shell behavior outside tmux-attached flows
- Ghostty pane graph as product truth

## Deferred

- new Ghostty pane creation
- generic workbench / tile UX as a mainline user-facing surface
- any fallback that guesses a binding without explicit evidence

## Failure Modes

- stale binding:
  detect it, clear it, and surface the reason explicitly
- Ghostty focus or launch automation fails:
  surface the failure explicitly instead of silently opening duplicates
- multiple competing bindings appear:
  choose one primary binding deliberately and surface the conflict for later
  cleanup
