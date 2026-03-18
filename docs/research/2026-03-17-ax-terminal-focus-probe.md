# 2026-03-17 — AX Terminal Focus Probe

**Status:** Historical research, later resolved; superseded by `docs/research/2026-03-17-gate-l-closeout.md`  
**Authority:** Research only. Gate decisions come from current code, tests, CI, and the active change pack.

## Summary

The embedded Ghostty terminal host in `agtmux-term` was exposed in the AX tree
with a stable tile-based identifier, and the local perf helper could resolve
that node deterministically.

At the time of this probe, the unresolved items were:

- synthetic pane-switch key delivery through the embedded Ghostty path did not
  switch tmux panes during perf-harness verification
- final Gate-L pane-switch parity was therefore not yet closed in this snapshot

## Landed Changes

- `GhosttyTerminalView` now exposes explicit accessibility metadata for the
  embedded terminal host
- `WorkbenchGhosttyIsland` assigns a stable host identifier based on tile UUID
- `GateLAXKeySender` can locate a target element through the front-window AX
  tree and click it by identifier
- `UITestTmuxBridge` has an internal focus command for the active terminal host

## Verification Snapshot

- AX debug traversal of a live app window showed:
  - `workspace.terminalHost.<tile-id>`
  - `workspace.tile.<tile-id>`
- direct helper click against `workspace.terminalHost.<tile-id>` returned
  success
- one-iteration `gate_l_pane_switch_bench.sh --mode key` still timed out with
  rendered and selected pane remaining `%0`
- direct tmux inspection after the failed run confirmed tmux active pane stayed
  `%0`

## Interpretation

AX tree targeting was not the blocker. The blocker at the time was synthetic
keypress delivery through the embedded Ghostty path, not element discovery.

That later resolved as two separate issues:

- embedded accumulated `keyDown` text needed to be replayed through
  `ghostty_surface_key(..., text: ...)` instead of the paste-oriented
  `ghostty_surface_text`
- the keypress harness needed stable point-based focus reuse and CRLF marker
  emission so `tmux capture-pane` would not lose markers to line wrapping
