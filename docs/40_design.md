# Design

## Main (MVP Slice)

This document is the compact entry point for the V2 design.

The mainline product truth is:

- `tmux first`
- `terminal stays terminal`
- `Workbench = saved app layout`
- `1 terminal tile = 1 real tmux session`
- browser/document companion surfaces are explicit and lightweight

The old linked-session workspace path is not mainline truth anymore.

## Product Interaction Model

User-facing objects:

- `tmux session`
  Real execution context
- `Workbench`
  Saved app layout, not a tmux tab/window
- `terminal tile`
  Plain Ghostty/tmux session view
- `browser tile`
  Explicit URL view
- `document tile`
  Explicit local/remote file view

Hard UX rules:

- one real tmux session may appear in only one visible terminal tile across the app in MVP
- close terminal tile does not kill session
- kill session is explicit
- same-session multi-view is out of MVP
- terminal tiles do not override right-click or core shortcuts
- target identity is stable app-owned identity, not prompt-derived guesswork
- remote failures remain visible; no silent fallback

## Main Design Rules

### Workbench

- Workbench is app-owned saved layout state
- terminal, browser, and document tiles share one split-layout model
- terminal tiles are always part of saved state
- browser/document tiles restore only when pinned

Detailed model and restore semantics:

- `docs/41_design-workbench.md`

### Terminal Tile

- terminal tile identity is `SessionRef`
- terminal tile attaches directly to a real tmux session
- duplicate detection is app-global in MVP
- duplicate open reveals/focuses the existing tile by default

Detailed terminal and duplicate rules:

- `docs/41_design-workbench.md`

### CLI Bridge

- users and agents open companion surfaces explicitly from the terminal
- MVP command is `agt open <url-or-file>`
- bridge transport is terminal-scoped custom OSC
- `agt open` directory input is rejected in MVP
- reserved future command: `agt reveal <dir>`

Detailed CLI and remote behavior:

- `docs/42_design-cli-bridge.md`

### Companion Surfaces

- browser and document are first-class companion surfaces in MVP
- both are explicit and lightweight
- both may duplicate
- directory tile is post-MVP additive extension only

Detailed companion-surface behavior:

- `docs/43_design-companion-surfaces.md`

## Remote and Failure Model

- `TargetRef = local or configured remote-host key`
- URLs open exactly as requested
- no implicit localhost rewrite
- no implicit SSH tunnel
- missing target/path/host remains visible as a placeholder state
- `Rebind` means manual exact-target reassignment only

## Sidebar and Observability

The sidebar is an observability and session-browser surface, not a project explorer.

It should:

- show real tmux sessions from local and remote sources
- surface pane/window-derived agent metadata
- keep pane rows compact and single-line; managed rows use a left-aligned provider badge whose ring carries primary-state truth, while freshness stays on the right
- show where a session is already open
- remain lightweight

## Daemon Overlay Rule

Session existence comes from tmux inventory, not daemon metadata.

Daemon metadata and `ui.health.v1` remain additive overlays only.
They may annotate state, but they do not create or delete tmux truth.

## Performance Guardrails

The design must stay closer to a terminal cockpit than an IDE.

- no project indexer
- no heavyweight file explorer subsystem
- no always-on global search engine
- no background crawl as a default behavior
- companion surfaces load lazily

## Stable Technical Notes

- `ghostty_surface_config_s.command` is a single shell command string
- `ghostty_platform_macos_s.nsview` is the NSView host hook
- wakeups are driven through `ghostty_app_tick()`
- packaged app uses bundled `agtmux`
- local socket is app-owned
- `AGTMUX_BIN` is the explicit development override
- PATH fallback is not supported for managed local daemon runtime
