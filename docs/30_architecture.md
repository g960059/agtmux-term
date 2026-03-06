# Architecture

## System Context

`agtmux-term` is a tmux-first macOS cockpit.
Its job is not to replace tmux, but to compose real tmux sessions with lightweight companion surfaces while preserving normal terminal behavior.

```
┌──────────────────────────────────────────────────────────┐
│                     macOS Developer                     │
└─────────────────────────────┬────────────────────────────┘
                              │ uses
                              ▼
┌──────────────────────────────────────────────────────────┐
│                      agtmux-term                         │
│  ┌──────────────────┐  ┌──────────────────────────────┐ │
│  │ Sidebar / Status │  │ Workbench Area               │ │
│  │ session browser  │  │ terminal/browser/document    │ │
│  │ agent metadata   │  │ saved layout                 │ │
│  └────────┬─────────┘  └──────────────┬───────────────┘ │
└───────────┼────────────────────────────┼─────────────────┘
            │                            │
            │ inventory / metadata       │ terminal surface
            ▼                            ▼
┌──────────────────────┐      ┌──────────────────────────┐
│ tmux / SSH           │      │ GhosttyKit.xcframework   │
│ real sessions        │      │ libghostty C API         │
└──────────┬───────────┘      └──────────────────────────┘
           │
           ▼
┌──────────────────────┐
│ agtmux daemon        │
│ local metadata       │
│ health overlay       │
└──────────────────────┘
```

## Architectural Intent

The architecture follows these rules:

- tmux / SSH remain the source of truth for real session existence
- agtmux daemon provides metadata and observability, not session truth
- terminal tiles are plain Ghostty/tmux views attached to real sessions
- Workbench is app-owned saved layout state
- browser / document surfaces are explicit companion views
- hidden linked-session creation is not part of the normal product path

## Main Components

### 1. Session Inventory and Observability

Responsible for:

- local tmux inventory
- remote tmux inventory
- local daemon metadata overlay
- sidebar grouping and filtering
- agent status surfacing

Primary modules:

- `LocalTmuxInventoryClient`
- `RemoteTmuxClient`
- `LocalMetadataClient` / XPC-backed daemon client
- `AppViewModel`
- `SidebarView`

### 2. Terminal Runtime

Responsible for:

- Ghostty app lifecycle
- Ghostty surface lifecycle
- IME and terminal rendering
- command-based attach to real tmux sessions

Primary modules:

- `GhosttyApp`
- `GhosttyTerminalView`
- `GhosttyInput`
- terminal-tile hosting layer

### 3. Workbench Runtime

Responsible for:

- split tree layout
- tile identity and persistence
- terminal tile placement
- companion surface placement
- duplicate-session prevention
- restore / placeholder states

Primary modules:

- `WorkbenchStore` or equivalent V2 store
- Workbench view hierarchy
- tile renderers

### 4. Companion Surface Runtime

Responsible for:

- browser tile state
- document tile state
- explicit open from UI or CLI bridge
- pinning / restore behavior

Primary modules:

- browser tile host
- document tile host
- future additive extension point for directory tile

### 5. CLI Bridge

Responsible for:

- receiving explicit open requests from terminals
- preserving source / cwd context
- opening browser/document tiles in the active Workbench

Primary modules:

- `agt open`
- terminal-scoped OSC transport
- bridge decoder / dispatch layer

## Domain Model

### Source of Truth Split

Two kinds of truth intentionally coexist:

1. **tmux truth**
   - real sessions
   - real windows
   - real panes
   - session existence

2. **app truth**
   - Workbench layout
   - tile placement
   - pinned companion surfaces
   - restore placeholders

This separation is the core of the V2 architecture.

### Core Entities

```swift
struct Workbench {
    let id: UUID
    var title: String
    var root: WorkbenchNode
    var focusedTileID: UUID?
}

indirect enum WorkbenchNode {
    case tile(WorkbenchTile)
    case split(SplitContainer)
}

struct WorkbenchTile {
    let id: UUID
    var kind: TileKind
    var pinned: Bool
}

enum TileKind {
    case terminal(sessionRef: SessionRef)
    case browser(url: URL, sourceContext: String?)
    case document(ref: DocumentRef)
}

enum TargetRef {
    case local
    case remote(hostKey: String)
}

struct SessionRef {
    var target: TargetRef
    var sessionName: String
    var lastSeenSessionID: String?
    var lastSeenRepoRoot: String?
}
```

Key semantics:

- `SessionRef = target + exact session name`
- `TargetRef` is app-owned identity (`local` or configured remote host key)
- `TargetRef` is not guessed from prompt text, `user@host`, or ad-hoc hostname parsing
- `lastSeenSessionID` is a hint only
- one `SessionRef` may appear in only one visible terminal tile in MVP
- future directory tile must be additive to this model, not a redesign trigger

## Data Flows

### Flow-001: Local Inventory + Metadata Overlay

```
LocalTmuxInventoryClient
  → tmux list-panes
  → inventory rows (session / window / pane existence)
  → AppViewModel inventory merge

LocalMetadataClient
  → app-owned daemon socket
  → ui.bootstrap.v2 / ui.changes.v2
  → pane metadata overlay
  → AppViewModel merged sidebar model
```

Role split:

- inventory decides what exists
- metadata enriches what exists
- failure in metadata must not invent or delete tmux objects

### Flow-002: Health Observability

```
LocalHealthClient
  → app-owned daemon socket
  → ui.health.v1
  → runtime / replay / overlay / focus health
  → sidebar health strip / banner / empty-state annotation
```

Health is annotation only.
It does not alter tmux object existence.

### Flow-003: Real Session Attach

```
User selects session
  → WorkbenchStore places SessionRef in terminal tile
  → terminal host builds attach command
  → GhosttyApp.newSurface(command: "tmux attach-session -t <exact-session>")
  → GhosttyTerminalView attaches surface
```

Important behavior:

- terminal tile attaches to the real tmux session directly
- no hidden linked session is created in the normal path
- the terminal tile must preserve normal terminal interaction

### Flow-004: CLI Open Bridge

```
User or agent runs `agt open <url-or-file>` inside terminal tile
  → command resolves cwd + source context
  → command emits custom OSC payload
  → app bridge receives payload
  → active Workbench opens browser/document tile
```

Why this architecture:

- works for local and remote shells
- does not require remote shells to reach a local Unix socket
- stays explicit and terminal-native

### Flow-005: Restore

```
App launch
  → load autosaved Workbenches
  → restore split tree + focused tile
  → terminal tiles restore by SessionRef
  → browser/document restore only if pinned
  → unpinned browser/document context is dropped
  → broken refs surface placeholder states
```

Broken refs are not auto-rebound.

## Runtime Boundaries

### Boundary A: tmux / SSH

- source of truth for session existence
- remote execution boundary
- explicit exact session targeting

### Boundary B: agtmux daemon

- local metadata overlay
- local health observability
- not the owner of tmux session truth

### Boundary C: app-owned Workbench state

- persistent app state
- autosave
- split layout
- companion surface pinning

### Boundary D: terminal-scoped bridge

- receives explicit open requests
- carries source/cwd context
- bridges shell actions to app-level Workbench composition
- is driven by explicit terminal-originated OSC payloads, not by remote shells calling a local app socket directly

## Key Architectural Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| ADR-001 | libghostty を SwiftTerm の代替として採用 | GPU/IME/precision |
| ADR-002 | local state は inventory-first + sync-v2 metadata overlay で取得 | existence と metadata を分離するため |
| ADR-003 | tmux / SSH を real session truth とする | app-local synthetic tmux reality を作らないため |
| ADR-004 | Workbench は app-owned saved layout とする | tmux state と layout state を分離するため |
| ADR-005 | CLI bridge は terminal-scoped custom OSC を第一経路にする | local/remote をまたいで explicit に扱えるため |
| ADR-006 | hidden linked-session を normal product path から外す | tmux power user の mental model と整合させるため |

## Deprecated Mainline Direction

The following is no longer the mainline architecture:

- linked-session-backed same-session multi-view
- app-local tmux window switching model
- Phase 3 BSP workspace as the primary product truth

That work remains useful as implementation history, but not as current architecture truth.

## Post-MVP Reserved Surface

The architecture intentionally leaves room for a future lightweight directory surface.

- it must reuse `TargetRef` and source-aware path semantics
- it must stay additive to `WorkbenchTile`
- a future CLI such as `agt reveal <dir>` may target this surface
- it is not part of the V2 MVP implementation plan
