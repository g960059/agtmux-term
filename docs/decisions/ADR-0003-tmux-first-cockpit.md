# ADR-0003: Pivot the mainline product to a tmux-first cockpit

- **Status**: Accepted
- **Date**: 2026-03-06

## Context

The older linked-session workspace model created product truth that diverged
from visible tmux reality and made the app harder to reason about.

## Decision

The mainline product is a tmux-first cockpit:

- real tmux sessions remain visible source of truth
- terminal tiles attach directly to real tmux sessions
- Workbench is app-owned saved layout state, not terminal runtime truth
- browser/document surfaces are companion views, not terminal substitutes
- hidden linked-session workflows are removed from normal product behavior

## Consequences

Positive:

- the app aligns with `tmux ls`
- the user mental model is simpler
- the app can focus on observability and control-plane value

Tradeoffs:

- some older linked-session work becomes historical only
- multi-view same-session behavior is intentionally constrained in MVP
