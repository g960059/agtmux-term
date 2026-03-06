# ADR-20260306: tmux-first cockpit への mainline pivot

## Status

Accepted

## Context

The repository had evolved toward a linked-session-based workspace model where the app created hidden tmux sessions in order to show multiple independent views.

That design solved a technical problem, but it created product-level issues:

- hidden tmux sessions leaked into external tmux tooling
- app-visible truth diverged from `tmux ls`
- tmux power users had to reason about app-invented tmux objects
- terminal behavior risked drifting away from normal Ghostty/tmux expectations

At the same time, the strongest assets of the product were already elsewhere:

- high-quality Ghostty terminal runtime
- strong sidebar observability
- local daemon metadata/health overlay
- interest in browser/document context beside terminals

## Decision

The mainline product direction is changed to a tmux-first cockpit model.

Core decisions:

- real tmux sessions remain the visible source of truth
- terminal tiles attach directly to real tmux sessions
- Workbench is app-owned saved layout state, not tmux state
- browser/document surfaces are explicit companion views
- terminal interaction remains normal Ghostty/tmux behavior
- hidden linked-session is not part of the normal product path
- same-session multi-view is excluded from MVP

## Consequences

### Positive

- `tmux ls` and app-visible session truth become aligned
- app/terminal/SSH mental model becomes simpler
- browser/document context can be added without abusing terminal panes
- the product remains lighter than an IDE-style workspace shell

### Negative / Tradeoffs

- current-window isolation for cloned same-session views is dropped in MVP
- some previously explored linked-session implementation work becomes historical rather than mainline
- main docs must be rewritten so linked-session is no longer described as product truth

## Follow-up

- update `docs/10_foundation.md` through `docs/50_plan.md` to the new mainline
- keep linked-session work only as implementation history, not as current architecture/design truth
- implement V2 as an isolated path within the same repository, then retire the old path after stabilization
