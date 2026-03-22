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

## Current Phase-1 Shape

- `TerminalHostMode` selects `legacy` or `next`
- `legacy` keeps the current single-controller `GhosttyIslandRepresentable`
- `next` now goes through a dedicated `NextGhosttyIslandViewController`
  boundary that retains pane-keyed child controllers with a small recent-pane
  cache
- the retained next-host controllers still reuse the current single-pane
  `GhosttyIslandViewController` internally; later phases replace that inner
  controller and move cadence ownership fully out of the legacy path

## Current Phase-2 Acceptance Surface

- fresh live-client wrappers remain diagnostic-only because normal-screen wheel
  input can reach Ghostty's local `scrollViewport` path without changing tmux
  client `scroll_position` or visible viewport state on a freshly attached
  client
- the current acceptance surface for `legacy` vs `next` is therefore the
  deterministic loaded-TUI gate:
  - launch a fresh app in a selected host mode
  - open an isolated tmux session that runs the repo-local `curses-history`
    viewer on a deterministic loaded fixture
  - sample visible viewport movement through the bridge and compare
    `first_changed_elapsed_ms`, changed sample count, and total upward rows
- once `next` wins or matches `legacy` there, phase 3 can return to the more
  variable loaded live-pane gate

## Current Phase-3 Shape

- `GhosttyTerminalSurfaceContext` now carries `terminalHostMode` into the
  terminal view layer
- `GhosttyTerminalView` now chooses between:
  - `legacyHybrid`: the existing host scroll-presentation scheduler
  - `ghosttyOwned`: no host scroll-presentation pump for normal-screen wheel
    input
- `next` host selects `ghosttyOwned`, while `legacy` keeps `legacyHybrid`
- runtime selection is no longer launch-env only; the app also honors the
  `TerminalHostMode` user default so rewrite-branch installs can be switched to
  `next` without changing the default branch behavior

## Failure Modes

- next-host attach fails:
  surface the failure explicitly and keep the legacy path available while the
  rewrite is incomplete
- persistent surfaces leak or grow unbounded:
  cap ownership to visible/recent panes and measure memory before widening
- parity gate drifts from the real complaint:
  stop and re-plan before interpreting timing wins as user-visible wins
