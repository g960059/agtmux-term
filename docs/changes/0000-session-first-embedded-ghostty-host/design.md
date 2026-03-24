# Design

## Chosen Approach

Keep `agtmux-term` as a tmux-first cockpit and simplify the app around the UX
it already wants: sidebar on the left, Ghostty in the main panel.

The mainline boundary becomes:

- tmux for session existence and pane truth
- GhosttyKit/libghostty for terminal runtime behavior
- agtmux-term for sidebar inventory, session reveal, thin host lifecycle,
  restore, and diagnostics

## First-Wave Interaction Model

When the user activates a session row:

1. resolve whether that logical session is already visible in the main panel
2. if yes, reveal and focus that terminal viewport
3. if not, create or retarget a main-panel Ghostty viewport for the session
4. attach directly to the desired tmux session or pane
5. persist enough restore state to reopen the same session-centric layout later

## Boundaries

App-owned:

- session inventory and metadata display
- terminal host lifecycle in the main panel
- session reveal and restore state
- restore hints and diagnostics

Not app-owned:

- terminal rendering and terminal protocol semantics
- keyboard / scroll / IME behavior beyond what GhosttyKit exposes
- tmux session and pane truth
- generic workbench / tile graphs as product truth

## Deferred

- how much generic workbench infrastructure survives as internal scaffolding
- browser/document companions as anything more than secondary surfaces
- any fallback that guesses a session target without explicit evidence

## Failure Modes

- requested session is missing:
  surface it explicitly instead of inventing a replacement
- embedded attach or retarget fails:
  surface the failure explicitly instead of silently opening another host
- generic workbench state disagrees with visible session state:
  repair toward the visible session-centric model instead of preserving stale
  layout truth
