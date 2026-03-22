# ADR-0005: Rebuild terminal hosting around a Ghostty-owned host path

- **Status**: Accepted
- **Date**: 2026-03-22

## Context

`agtmux-term` has spent multiple waves tuning embedded Ghostty scroll behavior,
especially for long upward history scroll on live Claude/Codex panes. Those
waves improved median and short-burst behavior, but the product still does not
match native Ghostty on the user-visible "first move" and "sticky trackpad"
feel for loaded live pane history.

The core limitation is architectural:

- the app still owns part of terminal presentation cadence during scroll
- the same Ghostty surface can be retargeted across panes
- SwiftUI/workbench lifecycle still participates in terminal host ownership
- terminal rendering and control-plane work still share too much runtime
  surface

The product principles already say Ghostty should own rendering, input, IME,
and runtime terminal behavior. Preserving the current embedded-hosting model as
the mainline product path is also explicitly a non-goal.

## Decision

Rebuild terminal hosting in the same repository around a parallel "next host"
path with these boundaries:

- Ghostty-owned render cadence for the new host path
- persistent pane surfaces instead of same-surface pane retargeting
- AppKit-owned terminal host controllers, with SwiftUI limited to sidebar and
  chrome
- control-plane state and polling kept out of the terminal render path
- migration behind an internal host-mode switch until the new path proves out

The current legacy host remains only as a fallback during migration. New scroll
parity work targets the new host path, not further extension of the legacy
scroll-pump architecture.

## Consequences

Positive:

- terminal ownership aligns better with native Ghostty
- pane switching can become surface swap instead of surface retarget
- live-pane parity gates can measure the right boundary with less host noise
- the rewrite can reuse the same daemon, tmux, release, and UI test assets in
  this repository

Tradeoffs:

- the repo temporarily carries two terminal host paths
- memory use rises because pane surfaces stay alive longer
- migration requires stacked changes and deliberate gating before deleting the
  legacy path
