# Remote Navigation & Phase 5–7 Architecture

## Context

tmux's primary purpose is **session persistence**, and the main production use case is
**remote operation over SSH** — especially agent-driven sandbox/24h development scenarios.
The goal is to make the remote experience approach native ghostty+tmux quality.

After Phase 1–4 (local perf) and the P5–P8 fixes, the current state is:

| Path | Navigation latency | Notes |
|---|---|---|
| Local, control mode up | ~0ms event-driven | P3 + P8 fix |
| Local, control mode down | 1500ms polling | P3 fallback |
| **Remote (any)** | **1500ms polling** | ← primary gap |

Remote sessions never get a control mode because `resolveControlMode` for `.remote` only
calls `existingMode()` — which is never populated, so it always falls back to polling.

---

## Phase 5 — Remote Control Mode Transport + Navigation Precision

### P9: SSH-backed TmuxControlMode

`TmuxControlMode` gains an optional SSH transport:

```swift
// New: SSH variant
init(sessionName: String, sshTarget: String, source: String)
```

Subprocess when `sshTarget` is set:
```sh
ssh -o BatchMode=yes -o ConnectTimeout=5 <sshTarget> tmux -C attach-session -t <session>
```

Versus the existing local subprocess:
```sh
tmux [-S <socket>] -C attach-session -t <session>
```

The reconnect backoff schedule (1 s → 2 s → 4 s → 8 s → 16 s) stays the same.
SSH-specific: a `ConnectTimeout=5` means each reconnect attempt times out in 5s, not
blocking the backoff schedule. After 5 failed attempts, state transitions to `.degraded`
and the navigation loop falls back to polling.

**Mosh note**: control mode over mosh is NOT supported. If `host.transport == .mosh`,
`resolveControlMode` creates the SSH-backed mode regardless (requires SSH key access to
the host, which mosh users typically have). If SSH is not available, the mode degrades
gracefully.

### P9b: Remote control mode lifecycle

`resolveControlMode` for `.remote` must start (not just return existing) modes.
Lifecycle rules:

| Event | Action |
|---|---|
| Tile focused + ready | `startMonitoring` (get-or-create SSH mode) |
| Tile loses focus | Schedule `stopMonitoring` after 30s |
| Tile re-focused before 30s | Cancel scheduled stop |
| Control mode → `.degraded` | Fall back to polling; retry on next focus |

`TmuxControlModeRegistry` gains:
```swift
func startMonitoringRemote(sessionName: String, sshTarget: String, source: String)
func scheduleStop(sessionName: String, source: String, afterDelay: TimeInterval)
func cancelScheduledStop(sessionName: String, source: String)
```

The 30s blur delay avoids connection churn on quick tab switches. Local modes keep their
current behavior (start eagerly, no automatic stop).

### P10: `switch-client -c <tty>` precision

Current control mode sends:
```
select-pane -t %N
```

This changes the **global** active pane for the session — all attached clients are
affected. The correct command for targeting only the specific rendered Ghostty client is:
```
switch-client -c <renderedClientTTY> -t %N
```

This matches the subprocess path in `WorkbenchV2TerminalNavigationResolver.navigationCommand`.

`runNavigationSyncLoopControlMode` needs `renderedClientTTY` from
`activePaneRuntimeContext?.renderedClientTTY`. When TTY is available, use
`switch-client -c <tty> -t <paneID>`; when not (e.g., initial attach before bind_client
fires), fall back to `select-pane -t <paneID>`.

---

## Phase 6 — Event Coalescing + Store Migration

### P11: Latest-only navigation event delivery

Between MainActor wakeups, several `windowPaneChanged` / `sessionWindowChanged` events
may arrive from the control mode stream. Only the latest matters. The current loop
processes all of them on MainActor.

Fix: lightweight coalescing in the for-await loop using an async sequence operator or
simple in-loop skip:

```swift
var latestNavEvent: ControlModeEvent? = nil

for await event in controlMode.events {
    switch event {
    case .windowPaneChanged, .sessionWindowChanged, .sessionChanged:
        latestNavEvent = event
        // Check if more events are immediately available; if so, skip this one
        // (simplified: process only when event queue is momentarily empty)
    case .output:
        continue  // already skipped (P8b)
    default:
        break
    }
    // ... process latestNavEvent
}
```

A practical approach without a custom AsyncSequence: check
`Task.isCancelled` between events and yield once to let more events arrive.

### P12: AppViewModel property migration (finish P4b)

P4b created `SidebarInventoryStore`, `TerminalRuntimeStore`, `HealthAndHooksStore` as
`@Observable @MainActor` skeletons. The actual property migration is done here.

#### Architecture decision

**Keep `AppViewModel` as `ObservableObject`**. Add the 3 stores as `let` properties.
Inject them via `.environment()` alongside `viewModel`. Views migrate their reads to
store environment access. `AppViewModel` retains `selectedPane`, `autoLaunchSessionName`,
all daemon tasks / orchestration, and derived helpers (`attentionCount`, `filteredPanes`).

Reason: converting `AppViewModel` itself to `@Observable` would require changing all
`@EnvironmentObject` call sites in one shot — high blast radius. Keeping it as
`ObservableObject` + delegating storage to `@Observable` sub-stores achieves the same
SwiftUI isolation with lower risk.

#### Property distribution

| Property | Target store | Why |
|---|---|---|
| `panes` | `SidebarInventoryStore` | sidebar primary consumer |
| `panesBySession` | `SidebarInventoryStore` | sidebar grouped view |
| `sessionOrderBySource` | `SidebarInventoryStore` | DnD ordering |
| `pinnedPaneKeys` | `SidebarInventoryStore` | pin state |
| `paneDisplayTitleOverrides` | `SidebarInventoryStore` | title editing |
| `statusFilter` | `SidebarInventoryStore` | filter pill |
| `showAgentsOnly` | `SidebarInventoryStore` | filter toggle |
| `showPinnedOnly` | `SidebarInventoryStore` | filter toggle |
| `offlineHosts` | `TerminalRuntimeStore` | workbench tile routing |
| `hasCompletedInitialFetch` | `TerminalRuntimeStore` | workbench tile readiness |
| `livePaneSessionKeys` | `TerminalRuntimeStore` | workbench tile live check |
| `hostsConfig` | `TerminalRuntimeStore` | remote host routing |
| `localDaemonIssue` | `HealthAndHooksStore` | daemon error banner |
| `localDaemonHealth` | `HealthAndHooksStore` | daemon health strip |
| `hookSetupStatus` | `HealthAndHooksStore` | hooks setup banner |

**Critical**: `offlineHosts`/`hasCompletedInitialFetch`/`livePaneSessionKeys` go into
`TerminalRuntimeStore`, NOT `SidebarInventoryStore`. Placing them in `SidebarInventoryStore`
would drag workbench tile evaluation into sidebar invalidation — defeating the purpose.

#### Pre-conditions (address Codex plan-review Critical/High findings)

Before migrating any reads, two structural changes must land:

1. **Centralize AppViewModel write sites** — introduce private store-sync helpers in
   `AppViewModel` so that all writes go through one call and mirror to the store atomically.
   Example:
   ```swift
   private func setOfflineHosts(_ v: Set<String>) { offlineHosts = v; runtimeStore.offlineHosts = v }
   ```
   This prevents mirror-write drift when properties are scattered across
   `publishFromSnapshotCache`, host add/remove, hook/health updates, etc.

2. **Add `paneIdentityIndex` to `TerminalRuntimeStore`** — a dictionary
   `[String: AgtmuxSyncV2PaneInstanceID]` keyed on `"source:sessionName:windowID:paneID"`
   updated whenever `runtimeStore.offlineHosts` / panes publish fires.
   This replaces the `WorkbenchAreaV2.livePaneInstanceID(for:)` → `viewModel.panes` read.

#### Migration phases

**Phase A — stores injected + mirror writes centralized**
- Add stores as `let` public properties on `AppViewModel`: `sidebarStore`, `runtimeStore`, `healthStore`
- Add `livePaneSessionKeys` to `TerminalRuntimeStore`; add `paneIdentityIndex` to `TerminalRuntimeStore`
- Replace all raw write sites in `AppViewModel` with private store-sync helpers
- Inject all three into SwiftUI environment in `main.swift` and `WindowChromeController.swift`
- `swift build` + `swift test` green

**Phase B — repo-wide consumer read switch**
All SwiftUI consumers switch to store reads in one sweep (not two sub-phases — Codex
finding: file-list sub-phases leave `@EnvironmentObject AppViewModel` in terminal
subtree which still subscribes to `objectWillChange`).

Target files and the store(s) each reads:
- `SidebarView` → `SidebarInventoryStore` (panes, panesBySession, statusFilter, showAgentsOnly, showPinnedOnly, pinnedPaneKeys, paneDisplayTitleOverrides) + `TerminalRuntimeStore` (hostsConfig) + `HealthAndHooksStore` (localDaemonIssue)
- `CockpitView` → `SidebarInventoryStore` (statusFilter, attentionCount)
- `TitlebarChromeView` → `SidebarInventoryStore` / `HealthAndHooksStore`
- `HostsManagementView` → `TerminalRuntimeStore` (hostsConfig)
- **`SettingsView`** → `TerminalRuntimeStore` (hostsConfig) + `HealthAndHooksStore` (hookSetupStatus) — *(previously missed)*
- `WorkbenchAreaV2` / `WorkbenchTileViewV2` → remove `@EnvironmentObject AppViewModel`; pass only `TerminalRuntimeStore` + `HealthAndHooksStore` + action closures (`onRetry: () -> Void`) — *(critical: must remove @EnvironmentObject entirely)*
- `WorkbenchV2TerminalRestore`, `WorkbenchV2DocumentTile` → `TerminalRuntimeStore` (hostsConfig)

Gate before proceeding: `rg '@EnvironmentObject.*AppViewModel' Sources/AgtmuxTerm/Workbench*.swift` must return zero matches.

- `swift build` + `swift test` green

**Phase C — remove @Published storage**
- Replace `@Published var panes: [AgtmuxPane]` etc. with computed forwarders:
  ```swift
  var panes: [AgtmuxPane] {
      get { sidebarStore.panes }
      set { sidebarStore.panes = newValue }
  }
  ```
- Tests and UITest bridge continue to work via forwarders
- `rg 'viewModel\.(panes|panesBySession|offlineHosts|livePaneSessionKeys|localDaemonIssue|hookSetupStatus|hostsConfig|statusFilter|showAgentsOnly|showPinnedOnly)' Sources/AgtmuxTerm` → zero matches in SwiftUI body files
- `swift build` + `swift test` green

#### Verification
- `rg '@EnvironmentObject.*AppViewModel' Sources/AgtmuxTerm/Workbench*.swift` → zero (Phase B gate)
- `rg 'viewModel\.(panes|offlineHosts|livePaneSessionKeys|localDaemonIssue|hookSetupStatus|hostsConfig|statusFilter|showAgentsOnly|showPinnedOnly)' Sources/AgtmuxTerm` → zero in body files (Phase C gate)
- `_printChanges()` on `WorkbenchTerminalTileViewV2`: `statusFilter`/pin change must NOT fire body

### P13: SurfacePool active set (minor)

`tick()` currently rebuilds `Set<ObjectIdentifier>` on every tick to filter active
surfaces. Convert to maintained set updated on surface state transitions.

---

## Phase 7 (Long-term) — Daemon as tmux Navigation Authority

The long-term architecture moves control mode subprocess ownership to the agtmux daemon:

```
agtmux daemon
  ├─ local: tmux -C attach-session (one per session)
  └─ remote: ssh <host> tmux -C attach-session (one per remote session)
       → produces ControlModeEvent stream
       → exposes via new RPC: tmux.nav.events.v1 (long-poll or SSE)

agtmux-term
  └─ subscribes to tmux.nav.events.v1 via XPC
  └─ sends nav commands via tmux.nav.command.v1
```

Benefits:
- Eliminates per-session SSH subprocess management from the app
- Daemon can aggregate events across all sessions
- Remote navigation events are available even when the terminal tile is not focused
- Single SSH connection per remote host instead of one per (session, tile)

This is a significant daemon change. The term-side XPC contract can be modeled after
the existing `ui.wait_for_changes.v1` long-poll pattern.

---

## Decision Record

| Decision | Rationale |
|---|---|
| SSH control mode in Phase 5, daemon in Phase 7 | Phase 5 delivers the remote experience gap fast without daemon protocol changes |
| 30s blur delay | Avoids SSH connection churn on normal tab switching while reclaiming resources on genuine navigation away |
| `switch-client -c <tty>` | More precise than `select-pane`: targets one client, doesn't affect other attached sessions |
| Mosh: SSH control mode anyway | Mosh users almost always have SSH key access; mosh only handles the interactive terminal, not control-plane |
| P12 store migration: no AppViewModel public API changes | Term codebase has many `viewModel.` call sites; forwarding props avoids a massive sweep |
