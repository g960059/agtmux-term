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
- `ProductLocalMetadataClient` / XPC-backed daemon client
- `AppViewModel`
- `SidebarView`

Local consumer state model:

- local inventory and local metadata are separate caches
- local visible rows are derived from those two caches at publish time
- `fetchAll()` owns inventory refresh only; background metadata tasks own metadata refresh only
- stale local merged snapshots are not allowed to write back over a newer metadata-derived publish
- recovery from `daemon incompatible` to healthy bootstrap must happen in the same app instance without relaunch
- when daemon truth changes an exact row back to unmanaged shell state, the next publish must clear stale provider/activity/title overlay instead of keeping the previous managed decoration alive
- metadata-enabled app-driven XCUITest must isolate both the local tmux socket and the daemon socket; reusing the persistent app-owned daemon socket is architecturally invalid because it can observe a different tmux universe than the test inventory path
- managed-daemon child launch must normalize its environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `XDG_CONFIG_HOME`, `CODEX_HOME`) and pass an explicit `TMUX_BIN` when resolvable so app/XCUITest-launched daemon probes see the same tmux runtime as shell-launched probes

Planned sync-v3 consumer split:

- daemon remains the semantic truth producer for normalized multi-axis status, pending requests, attention summary, freshness, and provider-native raw state
- term keeps exact-row correlation strict and derives a local presentation model from the raw v3 snapshot before views consume it
- `attention` is treated as a daemon-generated summary, not as request-identity truth; request identity remains `pending_requests[].request_id`
- daemon-owned canonical fixture truth currently comes from `agtmux` commit `cb198cca7226666fbb26df34d4e17582a208c3e6` under `fixtures/sync-v3/`
- additive v3 consumer wiring now drives the product AppViewModel local metadata path through `ui.bootstrap.v3` and `ui.changes.v3`
- product local metadata no longer falls back to sync-v2 when bootstrap-v3 or changes-v3 is unsupported; it degrades to inventory-only plus explicit daemon incompatibility
- remaining sync-v2 transport/service-boundary/workbench code is compatibility-only until later deletion
- the current v2 / `ActivityState` render path remains live until the v3 presentation cutover lands
- the first presentation cutover slice is now sidebar-first:
  - local v3-backed rows keep a parallel `PanePresentationState` cache
  - sidebar row provider/activity/freshness surfacing plus `managed` / `attention` filter-count derivation now prefer that presentation cache
  - broader render surfaces still intentionally defer to legacy state in the current slice
- titlebar stays on the shared presentation-derived `attentionCount` / filter path; the next low-risk consumer step is to align diagnostics/UI harness summaries with the same local presentation layer

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

Terminal input contract:

- `GhosttyTerminalView` must follow Ghostty's AppKit IME ordering, not a simplified terminal-first path
- `keyDown` must let AppKit `interpretKeyEvents` / `NSTextInputClient` drive preedit and commit before final terminal key encoding
- preedit clearing must be explicitly synchronized to libghostty when marked text ends
- command selectors emitted by AppKit during text input must be handled explicitly (`doCommand(by:)`) so IME commit and command-key paths are not dropped or reinterpreted as raw terminal input

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
- opening browser/document tiles in the emitting terminal's Workbench

Primary modules:

- `agt open`
- terminal-scoped OSC transport
- bridge decoder / dispatch layer

Current implementation seam:

- vendored Ghostty will surface the custom OSC carrier to the app by adding a typed custom-OSC `ghostty_action_s` case through the existing `action_cb`
- `GhosttyApp.handleAction(...)` is the host ingress
- `GhosttyTerminalSurfaceRegistry` provides surface-scoped routing to the emitting Workbench terminal tile
- `WorkbenchStoreV2.dispatchBridgeRequest(...)` is the downstream open path once payload decode succeeds

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

struct ActivePaneRef {
    var target: TargetRef
    var sessionName: String
    var windowID: String
    var paneID: String
    var paneInstanceID: AgtmuxSyncV2PaneInstanceID?
}
```

Key semantics:

- `SessionRef = target + exact session name`
- terminal tile identity is session-scoped; live pane selection is a separate runtime-only `ActivePaneRef`
- terminal-originated cross-session switch is observation-authoritative: when the rendered tmux client moves to another session, the current tile's `SessionRef` must rebase to that observed session unless doing so would collide with another visible tile
- canonical runtime selection state also carries the rendered tmux client binding plus split `desired` / `observed` pane refs; this reducer state is the only owner of pane focus truth
- when `ActivePaneRef.paneInstanceID` is present, inventory reconciliation is fail-closed on exact-instance mismatch and does not fall back to pane location reuse
- `TargetRef` is app-owned identity (`local` or configured remote host key)
- `TargetRef` is not guessed from prompt text, `user@host`, or ad-hoc hostname parsing
- `lastSeenSessionID` is a hint only
- one `SessionRef` may appear in only one visible terminal tile in MVP
- Workbench persistence stores layout plus session identity, not live pane focus
- future directory tile must be additive to this model, not a redesign trigger

## Data Flows

### Flow-001: Local Inventory + Metadata Overlay

```
LocalTmuxInventoryClient
  → tmux list-panes
  → inventory rows (session / window / pane existence)
  → AppViewModel inventory merge

ProductLocalMetadataClient
  → app-owned daemon socket
  → ui.bootstrap.v3 / ui.changes.v3
  → pane metadata overlay
  → derive local visible rows from `inventory + metadata state`
  → AppViewModel sidebar model
```

Role split:

- inventory decides what exists
- metadata enriches what exists
- `session_key` is opaque overlay identity, not visible tmux `session_name`
- bootstrap merge correlates metadata rows to visible inventory by `source + session_name + window_id + pane_id`; it must not reject a valid row only because `session_key != session_name`
- change replay correlates by bootstrap-learned exact identity (`session_key + pane_instance_id`) and must not fall back to `sessionName == session_key`
- local managed rows that lack `session_name` or `window_id` are ingress-invalid and dropped before merge
- metadata overlay cache must prefer exact pane instance identity (`source + session_key + pane_instance_id`) and must not silently normalize invalid local managed rows by pane location
- missing exact-identity fields on the sync-v2/XPC path are explicit protocol failures, not normalization paths
- legacy identity field `session_id` in local sync-v2 pane payload is also an explicit protocol failure; the app rejects the whole local metadata payload instead of partially accepting mixed-era rows
- missing exact-identity fields or orphan managed rows cause the app to clear stale overlay cache for the active daemon epoch and publish inventory-only rows rather than surface guessed managed/provider/activity state
- inventory refresh never writes a stale local merged snapshot back over a newer metadata-derived local publish
- once daemon truth becomes healthy again, the next successful bootstrap/changes publish must restore provider/activity/title surfacing on the exact local rows without app relaunch
- failure in metadata must not invent or delete tmux objects
- `agtmux` owns producer-side semantic truth for real provider sessions; `agtmux-term` owns the consumer boundary from daemon payload to exact visible sidebar row
- terminal-repo live tests must treat daemon exact-row payload truth as the primary oracle; sidebar/UI proof is secondary and tmux capture is diagnostic only
- pane-selection UI/E2E coverage must not stub away the Ghostty terminal surface when the contract under test includes visible main-panel retargeting
- the render-path oracle for same-session pane retarget must include the focused tile's exact tmux client tty plus rendered client pane/window truth, not store intent alone
- metadata-enabled app-driven UI tests must hand the exact bootstrap-resolved tmux `#{socket_path}` into managed-daemon startup; re-resolving `AGTMUX_TMUX_SOCKET_NAME` later inside the supervisor is not a trusted oracle under XCUITest

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

Local health-strip contract:

- local tmux inventory remains the source of truth for pane/session existence
- a local inventory failure marks `offlineHosts` for `local`, but does not clear the last published `ui.health.v1` snapshot
- while local inventory is offline, the app keeps polling `ui.health.v1` and replaces the strip with newer health snapshots when available
- if no health snapshot has ever been published, the health strip stays absent instead of synthesizing stale or guessed health UI

### Flow-003: Real Session Attach

```
User selects session or pane row
  → Workbench intent dispatcher emits `selectPane`
  → Workbench active-pane reducer updates desired `ActivePaneRef`
  → WorkbenchStore reveals existing terminal tile by session identity or creates one on first open
  → exact pane/window selection is applied to the visible session tile without changing tile identity
  → initial open uses direct attach to the real tmux session
  → terminal surface startup emits a host-owned `bind_client` payload over `OSC 9911` so the app can bind that tile to one exact tmux client tty
  → same-session retarget uses exact-client tmux navigation (`switch-client -c <tty> -t <pane>`) against that rendered client, not surface recreation
  → terminal-originated pane changes are observed from the rendered surface's exact tmux client state and committed as observed `ActivePaneRef`
  → terminal-originated session switches are also observed from that exact tmux client state and committed by rebasing the visible tile's `SessionRef` plus active selection to the observed session
  → reducer resolves desired vs observed state without letting stale observation overwrite a newer desired selection
  → sidebar highlight is projected from current inventory + reducer-resolved active pane, not from an independent copied pane snapshot
```

Important behavior:

- terminal tile attaches to the real tmux session directly
- no hidden linked session is created in the normal path
- the terminal tile must preserve normal terminal interaction
- same-session pane changes are live navigation on the one visible session tile, not hidden clone creation
- terminal-originated cross-session switch is also live navigation on that one visible session tile; the app must not leave the sidebar pinned to the stale pre-switch session
- if a terminal-originated cross-session switch would collide with another visible tile already owning the destination session, the app must fail loudly instead of silently inventing dual ownership
- same-session pane navigation and reverse sync must still work when the visible sidebar rows are inventory-only (for example when local metadata overlay is absent or degraded)
- pane-selection proof is incomplete unless four oracles agree:
  - exact tmux client pane/window for the rendered surface
  - canonical `ActivePaneRef`
  - sidebar selected-row marker
  - rendered Ghostty surface attach state for the visible tile
- reverse-sync proof must drive pane changes on the rendered client itself or by exact-client tty, not by mutating an unrelated tmux control client

### Flow-004: CLI Open Bridge

```
User or agent runs `agt open <url-or-file>` inside terminal tile
  → command resolves cwd + source context
  → command emits `OSC 9911` UTF-8 JSON payload
  → app bridge receives payload
  → emitting terminal's Workbench opens browser/document tile
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
- current vendored GhosttyKit must expose that custom OSC carrier to the host app by extending the existing `action_cb` typed-action surface; piggybacking on unrelated existing actions is not the mainline architecture

## Key Architectural Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| ADR-001 | libghostty を SwiftTerm の代替として採用 | GPU/IME/precision |
| ADR-002 | local state は inventory-first + sync-v2 metadata overlay で取得 | existence と metadata を分離するため |
| ADR-003 | tmux / SSH を real session truth とする | app-local synthetic tmux reality を作らないため |
| ADR-004 | Workbench は app-owned saved layout とする | tmux state と layout state を分離するため |
| ADR-005 | CLI bridge は terminal-scoped custom OSC を第一経路にする | local/remote をまたいで explicit に扱えるため |
| ADR-006 | hidden linked-session を normal product path から外す | tmux power user の mental model と整合させるため |
| ADR-007 | active pane selection は one visible session tile + canonical reducer で扱う | sidebar state / workbench state / live tmux state の split-brain を防ぐため |

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
