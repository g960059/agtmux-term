# Design

## Chosen Approach

Keep the same repository and app bundle, but introduce a parallel terminal host
path that is structurally closer to native Ghostty:

- AppKit-owned terminal host controllers
- persistent pane-surface ownership
- Ghostty-owned scroll/render cadence
- explicit host seams only for attach, activation, and pane swap

The legacy host remains available during migration so the rewrite can be proven
with the same live-pane gates before cutover.

## Boundaries

Changes:

- terminal host ownership and pane-surface lifecycle
- workbench-to-terminal boundary
- scroll parity gates used for acceptance

Unchanged in this wave:

- tmux-first product model
- daemon/sidebar truth model
- release packaging and app identity
- existing legacy host path while migration is in progress

## Failure Modes

- next-host attach fails:
  surface the failure explicitly and keep the legacy path available while the
  rewrite is incomplete
- persistent surfaces leak or grow unbounded:
  cap ownership to visible/recent panes and measure memory before widening
- parity gate drifts from the real complaint:
  stop and re-plan before interpreting timing wins as user-visible wins
