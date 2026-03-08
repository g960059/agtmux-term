# Workbench Design Details

## Scope

This document defines the detailed MVP design for:

- Workbench model
- terminal tile behavior
- duplicate-session policy
- persistence and restore semantics

Read this after `docs/40_design.md`.

## Workbench Model

```swift
struct Workbench: Identifiable, Codable {
    let id: UUID
    var title: String
    var root: WorkbenchNode
    var focusedTileID: UUID?
}

indirect enum WorkbenchNode: Identifiable, Codable {
    case tile(WorkbenchTile)
    case split(SplitContainer)
}

struct WorkbenchTile: Identifiable, Codable {
    let id: UUID
    var kind: TileKind
    var pinned: Bool
}

enum TileKind: Codable {
    case terminal(sessionRef: SessionRef)
    case browser(url: URL, sourceContext: String?)
    case document(ref: DocumentRef)
}

struct SessionRef: Codable, Hashable {
    var target: TargetRef
    var sessionName: String
    var lastSeenSessionID: String?
    var lastSeenRepoRoot: String?
}

struct DocumentRef: Codable, Hashable {
    var target: TargetRef
    var path: String
}

enum TargetRef: Codable, Hashable {
    case local
    case remote(hostKey: String)
}
```

Key rules:

- `SessionRef = target + exact session name`
- terminal tile identity is session-scoped; exact pane selection is separate runtime-only active-pane state
- pane/window navigation is runtime intent owned by the active-pane reducer, not persisted tile identity
- `TargetRef` is app-owned identity, not prompt-derived guesswork
- `lastSeenSessionID` is hint-only
- terminal tiles do not use pinning
- companion tiles use pinning only for persistence
- a future directory tile must be additive to this model

## Sidebar Design

The sidebar is an observability and session-browser surface, not a tile palette.

Responsibilities:

- show real tmux sessions from local and remote sources
- surface pane/window-derived agent metadata
- show waiting/error/idle status quickly
- show where a session is already open
- provide lightweight entry points for companion surfaces

Non-goals:

- not a heavyweight project explorer
- not a general IDE file tree
- not the owner of tmux truth

Selection model:

- active pane selection is a canonical key, not a copied `AgtmuxPane` snapshot
- reducer state keeps three runtime-only values together:
  - rendered client binding (`client_tty` + surface generation)
  - desired `ActivePaneRef`
  - observed `ActivePaneRef`
- sidebar highlight resolves from current inventory against reducer-resolved active pane state
- matching order is `paneInstanceID` first, then exact pane location
- if a canonical active-pane key already carries `paneInstanceID` and current inventory has no exact instance match, selection resolves to nil rather than falling back to a reused pane location
- sidebar click proposes a new desired active pane through the reducer
- terminal-originated pane observation commits observed pane state through the same reducer
- terminal-originated pane observation is scoped to the rendered surface's exact tmux client, not generic session-level `pane_active` flags
- stale observed state must not overwrite a newer desired selection before exact-client navigation resolves
- exact-client navigation is retried until observed rendered-client truth converges; a one-shot `switch-client` attempt is not sufficient
- UI highlight follows reducer-committed selection, not local view state and not speculative copied pane snapshots
- pane-selection E2E must run against a real Ghostty surface for the focused tile; a `Color.clear` UITest placeholder is insufficient for this contract
- pane-selection E2E must prove four agreeing oracles: exact rendered tmux client truth, canonical `ActivePaneRef`, sidebar selection marker, and stable rendered-surface identity
- same-session sidebar retarget must restore AppKit first responder to the rendered terminal host after dispatch so keyboard focus returns to the visible terminal, not the sidebar button
- pane retarget and reverse sync must keep working when sidebar rows come from inventory-only truth rather than metadata-enriched rows

Metadata overlay gate:

- local managed/provider/activity overlay is valid only when the daemon supplies exact identity (`session_key` + `pane_instance_id`)
- `session_key` is an opaque metadata/session identity and must not be compared to visible tmux `session_name`
- overlay cache is keyed by exact identity, not by visible pane location
- bootstrap correlation uses visible location (`session_name + window_id + pane_id`); change correlation uses bootstrap-established exact identity
- rows that arrive without exact identity are not partially normalized into sidebar truth
- local managed rows that omit `session_name` or `window_id` are ingress-invalid and dropped
- any invalid local sync-v2 row invalidates the current local metadata epoch; the app clears stale overlay cache before the next publish
- if the local daemon omits exact identity, the app keeps local inventory visible but drops metadata overlay and surfaces `daemon incompatible`

## Terminal Tile Design

Identity:

- terminal tile identity is `SessionRef`
- duplicate detection is app-global in MVP
- duplicate detection keys off target + exact session name; pane/window hints are reveal/navigation intent, not tile identity

Header content:

- exact session name
- source / host
- repo/worktree if known
- branch if known
- agent status badge

Allowed actions:

- focus
- apply exact pane/window navigation when the sidebar selection names a different pane in the same session
- reflect terminal-originated pane/window changes back into sidebar selection on the same visible tile
- open externally
- rename session
- kill session
- reveal existing tile location

Forbidden in MVP:

- app-local tmux window switcher
- hidden same-session clone view
- linked-session-style extra-client focus-sync model carried over from the old workspace path
- custom terminal shortcut layer

## Real Session Attach Path

Attach strategy:

```text
tmux attach-session -t <exact-session-name>
```

Rules:

- attach directly to the real tmux session
- preserve exact source targeting
- keep terminal behavior normal
- terminal surface startup must report the rendered tmux client tty through the same structured host bridge channel that already carries `agt open`
- the tty bind payload is host-owned, versioned, and explicit; a second private OSC channel is not part of the contract
- silent fallback from missing rendered-client tty to session-wide active-pane guesses is forbidden
- initial attach stays session-scoped; live pane focus is corrected after bind using the exact rendered tmux client tty
- same-session retarget on an already visible tile is exact-client tmux navigation (`switch-client -c <tty> -t <pane>`), not attach-command mutation, not a second visible tile, and not a hidden clone
- same-session retarget keeps retrying on the currently rendered client until `list-clients` for that exact `client_tty` reports the requested pane/window
- reverse sync must read the current pane/window from the rendered surface's exact tmux client (`list-clients` filtered by client tty), not from generic session-wide `list-panes` active flags
- reverse-sync E2E must stimulate pane changes on that same rendered client tty; driving a separate control client is insufficient product evidence
- reverse sync also owns terminal-originated session switches on that rendered client: if `list-clients` reports a different `session_name` for the bound `client_tty`, the visible tile must rebind its `SessionRef` in place and refresh sidebar selection from that observed session
- if the observed destination session is already owned by another visible terminal tile, surface an explicit collision state; do not silently keep showing the stale old session in the sidebar

Tradeoff:

- current-window isolation across cloned same-session clients is intentionally lost in MVP

## Duplicate Session Policy

MVP rule:

- one real tmux session can be visible in only one terminal tile across the app

Duplicate open behavior:

- default: reveal/focus existing tile
- optional secondary action: `Move here`
- if the open request names a different pane/window in the same session, update canonical active-pane state and apply that exact pane/window intent to the existing tile before returning
- same-session pane/window retarget must preserve tile identity and must not persist pane/window selection as tile identity
- if a terminal-originated session switch rebases one tile to a new session, that rebased `SessionRef` becomes the new duplicate-ownership key for future opens
- terminal-originated session-switch collision with another visible tile is an explicit error path, not silent dual ownership

This intentionally prevents same-session multi-view ambiguity from re-entering through another path.

## Persistence and Restore

Autosave policy:

- Workbenches autosave
- terminal tiles are part of Workbench state by default
- terminal tile autosave persists session identity only; live active pane is recomputed after launch
- browser/document tiles restore only when pinned
- unpinned companion tiles are transient working context
- persisted snapshot lives at `~/Library/Application Support/AGTMUXDesktop/workbench-v2.json`
- test fixture override (`AGTMUX_WORKBENCH_V2_FIXTURE_JSON`) wins over the persisted snapshot at launch

Restore placeholder states:

- `daemon unavailable`
- `daemon incompatible`
- `Host missing`
- `Host offline`
- `tmux unavailable`
- `Session missing`
- `Path missing`
- `Access failed`

Restore issue source of truth:

- broken restore state is not persisted as separate model data
- persisted tile identity stays the source of truth
- placeholder/error rendering is computed from the current tile ref plus live app state
- terminal restore issues resolve from `TargetRef` + current source reachability + current tmux session inventory
- document restore issues resolve from the current `DocumentRef` load result
- browser HTTP/navigation failures stay on the companion-surface load path and are not part of T-105 restore-placeholder scope

Recovery actions:

- `Retry`
- `Rebind`
- `Remove Tile`

`Rebind` semantics:

- manual exact-target reassignment only
- no fuzzy matching
- no automatic fallback
- exact-target `Rebind` preserves tile identity so focus/layout anchors remain stable
- terminal `Rebind` changes session identity only; live pane focus remains runtime-only reducer state
- document `Rebind` keeps the tile pin flag intact

Implementation rule for recovery actions:

- `Retry` must re-evaluate live state and retry the failed attach/load path
- `Remove Tile` mutates the restored Workbench tree directly and autosaves the resulting layout

## Implementation Notes

The shipped Workbench path must not retain linked-session behavior as a hidden implementation detail.

Do not:

- reuse `linkedSession` as a hidden implementation detail for terminal tiles
- merge V1 and V2 tile semantics into a shared ambiguous state machine
- keep linked-session-specific runtime, tests, or docs as if they were still active product contract

Do:

- keep a Workbench-owned state path with direct attach to exact tmux sessions
- remove linked-session-specific runtime and positive coverage once the V2 path owns the product surface
- preserve only negative regressions that prove linked-looking names and `session_group` metadata do not rewrite exact session identity
- prove same-session pane navigation and reverse sync against four agreeing oracles: live tmux truth, canonical `ActivePaneRef`, sidebar selection marker, and rendered surface attach state
- the live tmux oracle for that proof must be the exact rendered tmux client bound to the visible surface, not a generic session snapshot
