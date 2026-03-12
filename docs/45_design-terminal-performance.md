# Terminal Performance Architecture

## Problem Statement

Terminal scrolling performance is degraded due to three independent bottlenecks that compete on the main thread:

1. **Ghostty wakeup fan-out** — `wakeup_cb` fires `DispatchQueue.main.async { tick() }` on every internal timer event. Multiple wakeups accumulate as separate queue items, and `tick()` calls `triggerDraw()` on **all** live surfaces, including backgrounded ones.

2. **AppViewModel 1-second global publish** — `publishFromSnapshotCache()` unconditionally assigns `panes = normalized` every second. No-op updates propagate to all subscribers including terminal tiles. `panesBySession` is a computed property that re-runs full grouping/sorting on every read.

3. **Navigation sync subprocess storm** — `runNavigationSyncLoop()` runs `@MainActor` and spawns a new `Process()` (via `TmuxCommandRunner.shared.run(["list-clients", ...])`) every 400ms for the focused terminal. `TmuxControlMode` already provides a persistent control-mode event stream but is not used here.

## Root Cause Diagram

```
libghostty timer thread
  └─ wakeup_cb x N times/sec
       └─ DispatchQueue.main.async (N items)
            └─ tick() → ghostty_app_tick + triggerDraw(ALL surfaces)
                                                  ↑
                                             main thread bandwidth contention
                                                  ↓
AppViewModel.startPolling() (1 sec interval)
  └─ fetchAll() → publishFromSnapshotCache()
       └─ panes = normalized (unconditional)
            └─ SwiftUI re-evaluates ALL subscribers:
                 ├─ SidebarView (panesBySession computed → full sort)
                 └─ WorkbenchTerminalTileViewV2 (reads viewModel.panes, offlineHosts, etc.)

runNavigationSyncLoop() (@MainActor, 400ms)
  └─ liveTarget() → TmuxCommandRunner.run(["list-clients", ...])
       └─ Process() spawn → shell fork + exec + parse
```

## Solution Phases

### Phase 1 — Wakeup Coalescing + Diff Publish (T-PERF-P1)

**GhosttyApp.swift changes:**
- Add `wakeupPending: Bool` atomic flag protected by `NSLock`
- `wakeup_cb` sets flag and schedules ONE `DispatchQueue.main.async` if not already pending
- `tick()` clears flag, calls `ghostty_app_tick`, then draws **only active surfaces** (cross-reference `SurfacePool.shared.pool` state == `.active`)
- Remove `print("[tick] #...")` log spam (runs every tick in all build configs)

**AppViewModel.swift changes (`publishFromSnapshotCache`):**
- Guard `panes = normalized` with `if normalized != panes`
- Guard `offlineHosts = newOffline` with `if newOffline != offlineHosts`
- Guard `pinnedPaneKeys` and `paneDisplayTitleOverrides` mutations

**SurfacePool.swift changes:**
- Add `activeSurfaceViewIDs: Set<ObjectIdentifier>` computed property returning ObjectIdentifiers of `.active` state views

**Acceptance criteria:**
- `swift build` passes
- `swift test` passes
- Instruments Time Profiler shows main thread CPU <20% during active scroll

### Phase 2 — panesBySession Caching + Terminal ViewModel Isolation (T-PERF-P2)

**AppViewModel.swift changes:**
- Convert `panesBySession` from computed property to `@Published private(set) var`
- Recompute on background Task when `panes` changes; publish to main when ready
- Extract `computePanesBySession(filteredPanes:sessionOrderBySource:) -> [(source:sessions:)]` as `static func` so it can run off-main

**WorkbenchAreaV2.swift changes:**
- Introduce `TerminalTileInventorySnapshot: Equatable` struct:
  ```swift
  struct TerminalTileInventorySnapshot: Equatable {
      let isOffline: Bool
      let hasCompletedInitialFetch: Bool
      let paneIsLive: Bool
      let localDaemonIssue: LocalDaemonIssue?
  }
  ```
- `WorkbenchTileViewV2` (or parent) computes snapshot from `viewModel`, passes as `let` to `WorkbenchTerminalTileViewV2`
- `WorkbenchTerminalTileViewV2` drops `@EnvironmentObject var viewModel: AppViewModel`; uses `let snapshot: TerminalTileInventorySnapshot` for `terminalState`

**Acceptance criteria:**
- Sidebar update (new pane arrives) does NOT trigger `WorkbenchTerminalTileViewV2.body` re-evaluation when pane inventory for that tile is unchanged (verify with `Self._printChanges()` in debug)

### Phase 3 — Navigation Sync Event-Driven (T-PERF-P3)

**WorkbenchAreaV2.swift changes:**
- `runNavigationSyncLoop()` checks for active `TmuxControlMode` via `TmuxControlModeRegistry.shared`
- If control mode available: subscribe to `events` AsyncStream; react on `.windowPaneChanged` / `.sessionChanged`; eliminate periodic `liveTarget()` subprocess call
- If control mode unavailable (remote host without control mode): fall back to polling at 1500ms (was 400ms) — 3.75x reduction in subprocess spawn rate
- The `applyNavigationIntent` path (switch-client) remains subprocess-based as it is write-path, not read-path

**TmuxControlModeRegistry.swift:**
- Ensure registry provides control mode for local target when `TmuxControlMode` for `"local"` is registered at app startup

**Acceptance criteria:**
- During active terminal use, `list-clients` subprocess spawns ≤1/sec (was 2.5/sec)
- Navigation sync still works correctly for session/window/pane changes

### Phase 4 — AppKit Island + Store Split (T-PERF-P4)

**AppKit Island (WorkbenchGhosttyIsland.swift — new file):**
- Replace `GhosttySurfaceHostView` (NSViewRepresentable inside SwiftUI tile body) with a dedicated `NSViewController` subclass
- The SwiftUI tile body becomes `NSViewControllerRepresentable` with protocol:
  ```swift
  struct GhosttyIslandRepresentable: NSViewControllerRepresentable {
      let surfaceID: UUID
      let poolKey: SurfacePoolKey
      let attachCommand: String?
      let isFocused: Bool
      // Nothing from AppViewModel, WorkbenchStoreV2, or any @EnvironmentObject
  }
  ```
- `GhosttyIslandViewController` owns the `GhosttyTerminalView` NSView lifecycle
- SwiftUI recomposition **never** triggers view hierarchy changes in the island

**AppViewModel → 3-store split:**

| Store | Type | Responsibilities |
|-------|------|-----------------|
| `SidebarInventoryStore` | `@Observable @MainActor` | panes, panesBySession, sessionOrder, filters, pinned |
| `TerminalRuntimeStore` | `@Observable @MainActor` | hostsConfig, per-tile pane selection, workbench routing |
| `HealthAndHooksStore` | `@Observable @MainActor` | daemon health, hookSetupStatus, offlineHosts |

- `AppViewModel` becomes a thin coordinator that owns all three stores and provides migration shims
- Terminal subtree environment chain provides only `TerminalRuntimeStore`
- `SidebarView` consumes only `SidebarInventoryStore`

**Acceptance criteria:**
- A `panes = normalized` publish in `SidebarInventoryStore` does NOT cause `GhosttyIslandViewController` or any Metal draw to be triggered
- `swift build` + `swift test` pass
- Instruments: main thread CPU ≤10% during active scroll with sidebar updates running

## Files Changed by Phase

| File | P1 | P2 | P3 | P4 |
|------|----|----|----|-----|
| `GhosttyApp.swift` | ✓ | | | |
| `SurfacePool.swift` | ✓ | | | |
| `AppViewModel.swift` | ✓ | ✓ | | ✓ |
| `WorkbenchAreaV2.swift` | | ✓ | ✓ | ✓ |
| `TmuxControlModeRegistry.swift` | | | ✓ | |
| `WorkbenchGhosttyIsland.swift` (new) | | | | ✓ |
| `SidebarInventoryStore.swift` (new) | | | | ✓ |
| `TerminalRuntimeStore.swift` (new) | | | | ✓ |
| `HealthAndHooksStore.swift` (new) | | | | ✓ |

## Non-Goals

- Changing Ghostty config (font rendering, GPU settings) — this is a host-side architecture problem
- Modifying `scrollWheel` delta coefficients — not the root cause
- Moving terminal to a helper process — deferred beyond Phase 4
