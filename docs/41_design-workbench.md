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

## Terminal Tile Design

Identity:

- terminal tile identity is `SessionRef`
- duplicate detection is app-global in MVP

Header content:

- exact session name
- source / host
- repo/worktree if known
- branch if known
- agent status badge

Allowed actions:

- focus
- open externally
- rename session
- kill session
- reveal existing tile location

Forbidden in MVP:

- app-local tmux window switcher
- hidden same-session clone view
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

Tradeoff:

- current-window isolation across cloned same-session clients is intentionally lost in MVP

## Duplicate Session Policy

MVP rule:

- one real tmux session can be visible in only one terminal tile across the app

Duplicate open behavior:

- default: reveal/focus existing tile
- optional secondary action: `Move here`

This intentionally prevents same-session multi-view ambiguity from re-entering through another path.

## Persistence and Restore

Autosave policy:

- Workbenches autosave
- terminal tiles are part of Workbench state by default
- browser/document tiles restore only when pinned
- unpinned companion tiles are transient working context

Restore placeholder states:

- `daemon unavailable`
- `daemon incompatible`
- `Host offline`
- `tmux unavailable`
- `Session missing`
- `Path missing`
- `Access failed`

Recovery actions:

- `Retry`
- `Rebind`
- `Remove Tile`

`Rebind` semantics:

- manual exact-target reassignment only
- no fuzzy matching
- no automatic fallback

## Implementation Notes

The V2 Workbench path should be isolated from the linked-session model.

Do not:

- reuse `linkedSession` as a hidden implementation detail for terminal tiles
- merge V1 and V2 tile semantics into a shared ambiguous state machine

Do:

- create a new Workbench-owned state path
- retire linked-session assumptions only after V2 is stable
