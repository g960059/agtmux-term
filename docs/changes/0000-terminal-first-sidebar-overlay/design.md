# Design

## Chosen Approach

Keep `agtmux-term` as a tmux-first cockpit and simplify the app around the UX
it already wants: a normal Ghostty terminal in the main panel and a sidebar on
the left.

The mainline boundary becomes:

- tmux for session existence and pane truth
- GhosttyKit/libghostty for terminal runtime behavior
- agtmux-term for sidebar inventory, in-place retargeting, thin host lifecycle,
  restore, and diagnostics

## First-Wave Interaction Model

When the user launches the app:

1. show one embedded Ghostty terminal
2. start in a plain shell by default
3. show tmux sessions and agent state in the sidebar when available

When the user activates a session or pane from the sidebar:

1. keep using the current embedded terminal
2. if the chosen target is in the same tmux session, retarget in place
3. if the chosen target is in another session, recreate or reattach the single
   embedded terminal
4. persist enough restore state to reopen the same target later

## Boundaries

App-owned:

- session inventory and metadata display
- terminal host lifecycle in the main panel
- terminal retarget orchestration and restore state
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
- generic workbench state disagrees with the visible terminal-first model:
  repair toward the visible terminal and sidebar state instead of preserving
  stale layout truth
