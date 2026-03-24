# ADR-0007: Keep the mainline product a session-first embedded Ghostty cockpit

- **Status**: Accepted
- **Date**: 2026-03-23
- **Supersedes**: ADR-0006 for the mainline product boundary

## Context

The repository already has the UX shape users actually want: a sidebar and a
terminal in the same app window. The problem is not that Ghostty is embedded;
the problem is that generic workbench and tile abstractions have become too
prominent and the durable docs drifted toward a separate-window control-plane
story.

That separate-window story does not match the desired UX:

- the sidebar and the terminal should stay together in one main window
- clicking a session should reveal it in the app, not jump to another app
- the product should stay session-first, not tab/window-automation-first
- terminal behavior should still come from Ghostty, but the hosting shell can
  remain inside the app

The repo's mainline code still reflects this integrated shape more than the
brief external-control-plane detour.

## Decision

The mainline product remains a session-first cockpit with Ghostty hosted in the
main panel of the app.

Specifically:

- the primary UX is one app window with a sidebar and a terminal main panel
- session rows reveal an existing embedded session viewport first
- when a session is not yet visible, the app opens or retargets a terminal
  viewport in the main panel rather than opening a separate Ghostty app window
- tmux remains the source of truth for session and pane existence
- GhosttyKit/libghostty remains the source of truth for terminal rendering,
  input, IME, and runtime semantics
- agtmux-term owns session inventory, selection, restore, diagnostics, and the
  thin hosting shell around Ghostty surfaces
- generic workbench, browser, and document surfaces are migration-only or
  secondary concerns, not the mainline product story

External Ghostty launch/focus automation may still exist for diagnostics,
compatibility, or migration paths, but it is not the mainline UX.

## Consequences

Positive:

- the product matches the desired integrated UX: sidebar plus terminal in one
  place
- the app can keep using Ghostty-quality terminal behavior without turning
  separate-window automation into the center of the product
- implementation can simplify toward session viewports instead of generic
  workbench truth

Tradeoffs:

- the app still owns host lifecycle around embedded Ghostty surfaces
- workbench and migration-era code still needs explicit pruning
- the repo must keep a sharp boundary between Ghostty runtime behavior and
  app-owned session/view state
