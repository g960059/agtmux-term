# Implementation Plan

## Overview

V2 should be implemented as a **new mainline path inside the same repository**, not as incremental patches on top of the linked-session workspace model.

The key planning principle is:

- same repo
- separate V2 path
- replace old path only after V2 is stable

## Plan Shape

```
Phase A: Docs realignment
Phase B: Workbench V2 foundation
Phase C: Real-session terminal tile
Phase D: CLI bridge + companion surfaces
Phase E: Persistence + restore states
Phase F: Sidebar integration + old path removal
Phase G: Tests + polish
```

## Phase A: Docs realignment

Goal:

- make `docs/10_foundation.md` through `docs/50_plan.md` internally consistent with the V2 direction before code changes proceed

Exit criteria:

- Foundation, Spec, Architecture, Design, and Plan all describe the same V2 product
- linked-session path is no longer described as mainline truth

## Phase B: Workbench V2 foundation

Goal:

- introduce the new Workbench model and view path without mixing it into the old linked-session store

Deliverables:

- `Workbench`
- `WorkbenchNode`
- `WorkbenchTile`
- `TileKind.terminal / .browser / .document`
- V2 store and top-level Workbench UI entry path

Exit criteria:

- app can render placeholder terminal/browser/document tiles from saved layout state
- old linked-session path still exists but is isolated

## Phase C: Real-session terminal tile

Goal:

- replace linked-session terminal semantics with direct attach to real sessions in the V2 path

Deliverables:

- direct attach command path
- terminal tile header state
- duplicate-session prevention
- reveal/focus existing tile behavior

Exit criteria:

- selecting a session creates a terminal tile backed by a real tmux session
- one real session cannot appear in two visible terminal tiles in MVP

## Phase D: CLI bridge + companion surfaces

Goal:

- make browser/document views explicit companion surfaces opened from the terminal

Deliverables:

- `agt open <url-or-file>`
- terminal-scoped OSC bridge
- browser tile
- document tile
- explicit MVP rejection path for directory inputs

Current implementation note:

- the app-side companion surfaces are implemented, and the remaining CLI bridge work is now a repo-local vendored GhosttyKit expansion plus app-side decode/dispatch
- the narrowest implementation path is a new typed custom-OSC `ghostty_action_s` case delivered through the existing `action_cb`
- `T-100` exists to lock that carrier decision before `T-099` implementation proceeds

Exit criteria:

- browser/document tiles can be opened from local or remote shells inside agtmux-hosted terminals
- bridge failures surface explicitly

## Phase E: Persistence + restore states

Goal:

- make Workbench a reliable saved layout, not just an in-memory composition

Deliverables:

- autosave
- restore of terminal `SessionRef`s
- restore of pinned browser/document tiles
- placeholder states for broken refs
- `Retry` / `Rebind` / `Remove Tile`

Exit criteria:

- app restart restores Workbench state
- broken refs remain visible and actionable

## Phase F: Sidebar integration + old path removal

Goal:

- fully reconnect the new Workbench path to sidebar workflows and remove linked-session mainline code

Deliverables:

- sidebar jump-to-existing-session behavior
- sidebar entry points for companion surfaces as needed
- linked-session path deletion
- obsolete filtering/title rewrite removal

Exit criteria:

- normal product path contains no linked-session creation
- `tmux ls` and app session view remain aligned

## Phase G: Tests + polish

Goal:

- rewrite product truth in tests and finish the V2 transition cleanly

Deliverables:

- Workbench V2 tests
- duplicate-session tests
- exact pane instance identity coverage through sync-v2 / XPC
- inventory-only degrade coverage when sync-v2 omits exact identity
- stale-overlay eviction coverage when a new incompatible local bootstrap arrives after previously valid metadata
- single-source active-pane selection + reverse-sync coverage
- live tmux E2E oracles for same-session pane navigation
- exact-client reverse-sync E2E that stimulates pane changes on the rendered tmux client tty
- CLI bridge tests
- restore placeholder tests
- browser/document persistence tests
- UI polish consistent with `terminal stays terminal`

Exit criteria:

- tests no longer assert linked-session V1 behavior as mainline truth
- V2 path is stable enough to retire V1

## Delivery Strategy

### Recommended implementation strategy

1. Keep V1 and V2 isolated.
2. Do not interleave linked-session and Workbench semantics in one shared model.
3. Prefer replacing top-level composition paths over deeply branching existing linked-session code.

### Feature flag guidance

If rollout risk is high, a temporary flag is acceptable:

- `cockpit_workbench_v2=0`
  current linked-session path
- `cockpit_workbench_v2=1`
  new Workbench V2 path

This is acceptable only if the models remain isolated.

## Main Risks

| ID | Risk | Mitigation |
|----|------|------------|
| R-001 | old linked-session model and V2 model get interleaved | isolate the V2 store/view path completely |
| R-002 | terminal behavior is accidentally turned into custom IDE behavior | keep terminal tile plain Ghostty/tmux, no shortcut/right-click override |
| R-003 | Workbench persistence becomes underspecified | lock `SessionRef`, pinning, restore error states first |
| R-004 | remote bridge behavior becomes magical and confusing | keep OSC bridge explicit, no silent tunnel or rewrite |
| R-005 | directory-tile future work distorts MVP scope | keep directory tile post-MVP and additive only |

## Current Planning Status

- Docs realignment is complete
- V2 product baseline is locked
- reserved future directory-surface work stays out of the MVP schedule
- implementation should proceed only against the V2 docs, not the old linked-session mainline
