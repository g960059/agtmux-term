# ADR-0008: Make the mainline product a terminal-first embedded Ghostty cockpit

- **Status**: Accepted
- **Date**: 2026-03-23
- **Supersedes**: ADR-0007 for the mainline product boundary

## Context

The product direction moved one step further than ADR-0007. Keeping the
terminal and the sidebar in one app window was correct, but the durable docs
still described the product as `session-first`.

The desired UX is stricter than that:

- the main panel should behave like a normal terminal first
- startup should land in a plain shell by default
- the sidebar should be a tmux and agent overlay, not the primary runtime
- clicking a session or pane should reuse or retarget the current embedded
  terminal in place
- generic workbench, browser, and document surfaces are not the mainline model

## Decision

The mainline product is a terminal-first cockpit with Ghostty hosted in the
app and a supplementary tmux/agent sidebar.

Specifically:

- the primary UX is one app window with a sidebar and one embedded terminal
- the terminal starts as a plain shell by default
- sidebar actions reuse or retarget that current terminal toward the chosen
  tmux session/window/pane
- tmux remains the source of truth for session and pane existence
- GhosttyKit/libghostty remains the source of truth for terminal rendering,
  input, IME, and runtime semantics
- agtmux-term owns sidebar inventory, restore hints, retarget orchestration,
  and diagnostics around the embedded host
- generic workbench, browser, and document surfaces are migration-only or
  secondary concerns, not the mainline product story

## Consequences

Positive:

- the terminal stays usable as a normal terminal outside tmux
- the product model becomes simpler: one visible terminal plus one sidebar
- the sidebar can stay focused on tmux and agent awareness instead of acting as
  a generic workspace shell

Tradeoffs:

- the app still owns host lifecycle around the embedded Ghostty surface
- same-terminal retarget behavior must be explicit and well-tested
- older workbench-era scaffolding still needs to be pruned or quarantined
