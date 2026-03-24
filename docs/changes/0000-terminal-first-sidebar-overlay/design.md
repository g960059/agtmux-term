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

## Current Code Seams

The implementation should build on these existing seams instead of inventing a
new terminal runtime:

- `GhosttyApp.newSurface(command:nil)` already supports plain-shell startup
- `CockpitView` and `TitlebarChromeView` are still wired around visible
  `Workbench*` surfaces and tabs
- `SidebarView` currently opens terminals through `WorkbenchStoreV2`
- `WorkbenchStoreV2` already carries useful session/pane normalization and
  same-session navigation concepts, but its visible model is too broad
- `AppViewModel.maybeAutoLaunchSession()` already owns the optional tmux
  auto-launch behavior

So the design should not replace Ghostty hosting, but it should move the
mainline UI and state model away from visible Workbench ownership.

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
4. in first wave, cross-session attach stays session-scoped and reaches the
   requested pane through post-attach retarget
5. persist enough restore state to reopen the same target later

## Mainline State Model

Introduce a dedicated mainline state model that represents one visible
terminal, not a generic workspace graph.

Proposed shape:

- `MainTerminalStore`
  - `mode`
    - `.plainShell`
    - `.tmux(sessionRef, requestedPaneRef, resolvedPaneRef)`
  - `surfaceID`
  - `focusRequestNonce`
  - `diagnostic`
  - `lastRestoreTargetBySession`

First wave keeps coordination inside `MainTerminalStore` rather than splitting
out a separate coordinator type. The split can happen later if the thinner
mainline path grows new responsibilities.

Why this boundary:

- the user-facing model is one terminal, not multiple viewports
- startup, retarget, and reset-to-shell become explicit state transitions
- `WorkbenchStoreV2` can remain in-tree temporarily without staying on the
  critical path of the mainline UI

## Startup Behavior

Default startup:

1. launch one embedded Ghostty surface
2. pass `command:nil` so Ghostty opens the user's normal shell
3. do not auto-attach to tmux
4. show sidebar inventory if tmux and daemon data are available

Optional startup:

- if the user configured auto-launch, `AppViewModel` may create the session
- the terminal still starts from the mainline model, then transitions into a
  tmux target explicitly

This keeps terminal behavior predictable and makes `plain shell` the default
truth instead of a special fallback.

## Sidebar Activation Rules

Session row:

1. ask tmux for the active pane in that session
2. if unavailable, use `lastRestoreTargetBySession`
3. if unavailable, use the first listed pane in the sidebar inventory

Window row:

1. prefer the active pane in that tmux window when available
2. else use the last restored pane in that window
3. else use the first listed pane in that window

Pane row:

1. use the exact pane the user clicked

Failure rule:

- if the requested session or pane no longer exists, surface the failure in the
  sidebar/main-terminal status instead of silently inventing another target

## Retarget Versus Reattach

Same-session navigation:

- keep the current Ghostty surface alive
- use tmux client navigation to move to the requested pane
- update `resolvedPaneRef` from rendered-client truth after navigation

Cross-session navigation:

- allow the single visible terminal to recreate or reattach
- the app may reuse the same UI container, but the tmux attach command remains
  session-scoped in first wave
- if a more specific pane or window was requested, reconcile to it after attach
- restore the sidebar highlight and diagnostic state around the new session

Reset to shell:

- `New Shell` transitions the main terminal back to `.plainShell`
- this is the official way to leave tmux in first wave

## UI Rewiring

Mainline visible UI should become:

- sidebar
- single main terminal view
- titlebar controls

Visible mainline UI should no longer expose:

- `WorkbenchTabBarV2`
- browser/document companion surfaces
- generic empty-workspace placeholders
- “new workbench” style actions

Migration strategy:

- keep `WorkbenchStoreV2` compiling
- remove it from the visible main window path first
- prune dead or migration-only paths in later slices once the new path is
  stable

## Diagnostics

Diagnostics should follow the terminal-first model, not workbench terminology.

First-wave diagnostics:

- `sessionMissing`
- `paneMissing`
- `attachFailed`
- `retargetFailed`
- `restoreFallbackUsed`
- `terminalSidebarDrift`

Presentation:

- short inline status in the main terminal chrome
- fuller detail in sidebar warnings or developer diagnostics

## Tests

Unit/integration coverage should prove:

- default startup is plain shell
- auto-launch remains optional
- session-row target resolution uses `tmux active -> restore -> first listed`
- pane-row selection targets the exact pane
- same-session navigation reuses the existing terminal surface
- cross-session navigation reattaches the single terminal correctly
- `New Shell` returns the app to plain-shell mode
- visible mainline UI no longer exposes workbench tabs or browser/document
  surfaces

## Staged Implementation

Stage 1:

- define `MainTerminalStore`
- wire `CockpitView` and `SidebarView` to one visible terminal
- remove visible workbench tab UI

Stage 2:

- make plain-shell startup real
- implement session/pane target resolution
- implement same-session retarget and cross-session reattach

Stage 3:

- add diagnostics and restore-state hardening
- quarantine browser/document/workbench paths from the mainline UI

Stage 4:

- prune or refactor the remaining workbench scaffolding once replacement paths
  are stable

Current implementation status:

- `MainTerminalStore` exists and owns first-wave coordination
- `CockpitView`, `SidebarView`, and titlebar chrome are rewired to the single
  main terminal path
- plain-shell startup and `New Shell` reset are implemented
- same-session retarget now refreshes from rendered-client truth instead of
  session-wide active-pane truth
- cross-session navigation currently means session attach plus post-attach
  retarget, not a pane-specific initial attach command
- richer drift/attach diagnostics and broader scaffold removal still remain

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
- multi-terminal tabs/panes inside the app
- external Ghostty launch/focus automation as a mainline UX

## Failure Modes

- requested session is missing:
  surface it explicitly instead of inventing a replacement
- embedded attach or retarget fails:
  surface the failure explicitly instead of silently opening another host
- generic workbench state disagrees with the visible terminal-first model:
  repair toward the visible terminal and sidebar state instead of preserving
  stale layout truth
