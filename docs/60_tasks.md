# Task Board

This file keeps the active task surface small.
Historical task detail lives in `docs/archive/tasks/2026-02-28_to_2026-03-06.md`.

## Current Phase

Mainline docs are aligned to the V2 tmux-first cockpit.
Commit closeout is clear; next implementation proceeds on the new Workbench path.

## Active / Next

### T-090 — Workbench V2 foundation path
- **Status**: TODO
- **Priority**: P0
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Create an isolated V2 Workbench model and top-level view/store path.
  - Support `terminal`, `browser`, and `document` tile kinds without mixing with linked-session lifecycle.
- **Acceptance Criteria**:
  - [ ] `Workbench`, `WorkbenchNode`, `WorkbenchTile`, and `TileKind` exist for V2
  - [ ] V2 path can render empty or placeholder terminal/browser/document tiles
  - [ ] V1 linked-session path remains isolated rather than interleaved with V2 semantics

### T-091 — Real-session terminal tile
- **Status**: TODO
- **Priority**: P0
- **Depends**: T-090
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Replace linked-session placement with direct attach to real tmux sessions in the V2 path.
  - Add app-global duplicate-session prevention.
- **Acceptance Criteria**:
  - [ ] sidebar selection places a `SessionRef` into a V2 terminal tile
  - [ ] terminal tile attaches directly to the real tmux session
  - [ ] duplicate open reveals/focuses the existing tile instead of creating a second visible terminal tile

### T-092 — CLI bridge plus browser/document companion surfaces
- **Status**: TODO
- **Priority**: P0
- **Depends**: T-091
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Implement `agt open <url-or-file>` over terminal-scoped OSC.
  - Add browser and document tile creation in the active Workbench.
- **Acceptance Criteria**:
  - [ ] `agt open` opens browser tiles for URLs
  - [ ] `agt open` opens document tiles for files
  - [ ] directory input fails explicitly in MVP
  - [ ] bridge-unavailable failure is explicit

### T-093 — Workbench persistence and restore placeholders
- **Status**: TODO
- **Priority**: P0
- **Depends**: T-092
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Persist Workbench layout and restore terminal plus pinned companion tiles.
  - Surface broken refs as explicit placeholder states.
- **Acceptance Criteria**:
  - [ ] Workbenches autosave
  - [ ] terminal tiles restore by `SessionRef`
  - [ ] pinned browser/document tiles restore
  - [ ] missing host/session/path surfaces remain visible with `Retry` / `Rebind` / `Remove Tile`

### T-094 — Sidebar integration and linked-session normal-path removal
- **Status**: TODO
- **Priority**: P0
- **Depends**: T-093
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Reconnect sidebar workflows to V2 and remove linked-session assumptions from the normal product path.
- **Acceptance Criteria**:
  - [ ] sidebar can jump to existing V2 terminal tiles
  - [ ] normal path creates no linked sessions
  - [ ] obsolete linked-session filtering/title-leak behavior is removed from the main path

### T-095 — local health-strip offline contract follow-up
- **Status**: TODO
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Decide and lock the intended health-strip behavior when local inventory goes offline or stale data remains.
  - Add regression coverage once the contract is explicit.
- **Acceptance Criteria**:
  - [ ] intended health-strip behavior on local inventory/offline failure is documented
  - [ ] regression coverage exists for the chosen behavior

## Recently Done

### T-089 — sync-v2 XPC/service-boundary coverage gap closeout (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Closed the packaged-app sync-v2 XPC coverage gap found during commit review.
  - Added dedicated client/service-boundary tests for `fetchUIBootstrapV2` and `fetchUIChangesV2`.
  - Removed stale bundled-runtime README guidance about PATH/common install-location fallback.
- **Implemented**:
  - added injected-proxy decode/limit coverage in `AgtmuxDaemonXPCClientTests`
  - added anonymous service-boundary and actual service-endpoint coverage for sync-v2 bootstrap/changes
  - refreshed `Sources/AgtmuxTerm/Resources/Tools/README.md`
  - reran focused post-fix verification and cleared the prior `NO_GO` on re-review
- **Acceptance Criteria**:
  - [x] `AgtmuxDaemonXPCClientTests` has dedicated sync-v2 client coverage for bootstrap/changes
  - [x] `AgtmuxDaemonXPCServiceBoundaryTests` has service-boundary coverage for bootstrap/changes
  - [x] bundled runtime README matches the current resolver contract
  - [x] `NO_GO` review blocker is cleared and the worktree is ready for commit/push

### T-088 — Fresh verification rerun and review-pack prep (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Rerun the required final verification against the final worktree before commit and prepare a review pack using the fresh evidence.
- **Implemented**:
  - reran `swift build`
  - reran focused SPM tests for runtime hardening, sync-v2 decoding/session, AppViewModel, and XPC coverage
  - reran `AgtmuxDaemonServiceEndpointTests` via `xcrun xctest`
  - reran targeted sidebar health UI tests via `xcodebuild`
  - prepared a review pack under `docs/85_reviews/`
- **Acceptance Criteria**:
  - [x] fresh build verification recorded
  - [x] fresh focused tests recorded
  - [x] review pack created after build pass

### T-087 — Docs compaction for active-context efficiency (2026-03-06)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - Reduce everyday context load by introducing a current summary, compacting active tracking docs, and moving history into archive files.
- **Implemented**:
  - added `docs/65_current.md`
  - compacted `docs/60_tasks.md` to active/next tasks plus recent completions
  - compacted `docs/70_progress.md` to recent entries plus summary
  - split `docs/40_design.md` into summary plus detailed design files
  - updated `docs/00_router.md` and `docs/90_index.md` to the new read path
- **Acceptance Criteria**:
  - [x] active reading path starts with `docs/65_current.md`
  - [x] history is preserved under `docs/archive/`
  - [x] design detail is available without forcing every reader through one long file

### T-086 — V2 docs consistency pass: design-lock integration (2026-03-06)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - Integrated design-lock details into mainline docs.
- **Result**:
  - `TargetRef`, OSC bridge, autosave/pinning, duplicate open, manual `Rebind`, and directory-tile future scope are fixed in main docs.

### T-085 — V2 docs realignment: tmux-first cockpit baseline (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Rewrote foundation/spec/architecture/design/plan around the V2 tmux-first cockpit model.

### T-076 through T-084 — Local daemon runtime hardening and health observability
- **Status**: DONE
- **Priority**: P0/P1
- **Description**:
  - A1 and A2 local daemon/runtime/health work is complete.
  - See archive task board and progress ledger for full detail.

## Archive

- Full historical task board:
  `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
