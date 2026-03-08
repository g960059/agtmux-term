# Task Board

This file keeps the active task surface small.
Historical task detail lives in `docs/archive/tasks/2026-02-28_to_2026-03-06.md`.

## Current Phase

Mainline docs are aligned to the V2 tmux-first cockpit.
Commit closeout is clear; next implementation proceeds on the new Workbench path.

## Active / Next

### T-109 — Terminal-originated tmux session-switch reverse sync
- **Status**: IN_PROGRESS
- **Priority**: P0
- **Depends**: T-108
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - fresh March 8, 2026 user evidence reopens terminal reverse-sync at the session layer:
    - when the main terminal changes tmux session from inside the rendered client (for example via `repo` from `~/.config/zsh`), the sidebar remains pinned to the old session
    - the visible terminal continues to run on the new tmux session, so the app is now stale relative to rendered-client truth
  - current product root cause is narrower than metadata or same-session pane sync:
    - `WorkbenchV2TerminalNavigationResolver.liveTarget(sessionRef:renderedClientTTY:...)` filters `list-clients` by both `client_tty` and the tile's stored `sessionRef.sessionName`
    - once the rendered tmux client switches to another session, observation fails as `renderedClientUnavailable` instead of reporting the new session
    - `WorkbenchStoreV2.syncTerminalNavigation(...)` only updates window/pane on the existing stored session and has no path to rebind the tile's `SessionRef` from observed rendered-client truth
  - clean-break implementation direction:
    - rendered-client observation becomes authoritative for cross-session switch on the focused visible tile
    - the store gets an explicit observed-session rebind path that updates the tile's `SessionRef` and canonical active selection in place while preserving surface identity
    - duplicate-session collision on an observed session rebind must fail loudly instead of silently freezing the sidebar on stale identity
  - TDD order:
    - add failing store-level regression for rendered-client session switch rebasing the tile identity and active selection
    - add failing UI/E2E proof that switches the rendered tmux client to another session and expects sidebar/session highlight to follow
    - then land product code and rerun focused SPM + targeted UI verification
  - current implementation progress:
    - `WorkbenchStoreV2` now has an observed-session rebind path for rendered-client tmux session switches
    - rendered-client observation no longer filters `list-clients` by the tile's stored `sessionRef.sessionName`; it now observes the exact `client_tty` first and rebases session identity from that truth
    - same-surface cross-session rebases preserve rendered surface generation and client tty in `GhosttyTerminalSurfaceRegistry`
    - focused store/runtime regressions are green:
      - `testTerminalOriginatedSessionSwitchRebindsVisibleTileIdentityAndActiveSelection`
      - `testTerminalOriginatedSessionSwitchFailsLoudlyOnDuplicateVisibleDestinationSession`
      - `swift test -q --filter WorkbenchStoreV2Tests`
      - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests`
      - `swift test -q --filter WorkbenchV2TerminalAttachTests`
      - `swift build`
    - targeted real-surface UI proof exists, but the latest March 8, 2026 arm64 rerun did not execute because XCTest again failed before test start with `Timed out while enabling automation mode.`
- **Description**:
  - Make terminal-originated tmux session switches authoritative so the visible tile and sidebar follow the rendered client's actual session instead of freezing on the session that was originally attached.
- **Acceptance Criteria**:
  - [ ] terminal-originated tmux client session switch on the rendered visible tile updates sidebar session/pane highlight to the observed session
  - [ ] the current visible tile rebases its `SessionRef` in place to the observed session when no duplicate visible owner exists
  - [ ] the rebased tile preserves one Ghostty surface; session-switch reverse sync must not recreate a hidden clone or second visible tile
  - [ ] if the observed destination session is already owned by another visible tile, the app surfaces an explicit collision instead of silently keeping stale sidebar state
  - [ ] focused regression coverage proves rendered-client truth, tile identity, and sidebar selection all agree after a terminal-originated session switch

### T-108 — Active-pane single-source-of-truth and pane-instance identity recovery
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-107
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - live March 7, 2026 user evidence invalidates the earlier `T-107` closeout:
    - plain `zsh` panes are still surfaced as `codex`
    - idle Codex panes are still surfaced as `running`
    - sidebar pane clicks do not reliably retarget the visible terminal
    - terminal-originated pane changes do not update sidebar highlight
  - after the agtmux-side wire fix, fresh live March 7, 2026 evidence narrows the remaining metadata bug to the term consumer:
    - the previous `session_id` incompatibility is gone, but product logs now show `metadata overlay dropped for mismatched session identity ...`
    - the current consumer is still comparing opaque `session_key` values (UUID / rollout IDs) to visible tmux `session_name`
    - same-session pane selection on real local sessions (for example `utm-main`) is still reported as not retargeting the visible terminal in the normal app path
  - fresh code inspection after the proposal pass isolates two product-side gaps that still explain the user-visible regressions:
    - bootstrap merge and change replay still contain `session_key == session_name` assumptions, so valid managed rows with opaque session keys are dropped before they can enrich inventory
    - same-session pane retarget is still not trusted against the normal app path once live daemon overlay is present; the remaining gap must be proved against real rendered-client truth, not only the app-driven UITest harness
  - proposal comparison already converged on the same gaps:
    - local overlay is still vulnerable to stale bleed because cache/publish semantics are not epoch-gated exact-identity truth
    - active pane state is still not modeled as one reducer-owned runtime state with rendered-client binding plus desired/observed pane truth
    - current pane-sync UI proofs are still not strong enough when they mutate tmux from an out-of-band control path instead of the rendered client itself
  - execution strategy changed on March 7, 2026 user direction:
    - stop real-agent implementation delegation for this slice
    - continue with orchestrator-owned TDD and verification directly
  - selected remediation direction is now design-locked:
    - local managed/provider/activity overlay must be exact-identity keyed (`session_key` + `pane_instance_id`) and epoch-gated
    - `session_key` must be treated as opaque metadata identity, not as tmux `session_name`
    - bootstrap correlation uses visible location (`session_name + window_id + pane_id`); change replay uses bootstrap-established exact identity and cached alias knowledge
    - any invalid local sync-v2 row (`session_id`, missing `session_key`, missing `pane_instance_id`, missing `session_name`, missing `window_id`) invalidates the whole current local metadata epoch and clears stale overlay before the next publish
    - terminal tile identity remains session-scoped (`SessionRef = target + sessionName`)
    - runtime pane focus moves into one reducer-owned state carrying rendered client binding, desired `ActivePaneRef`, and observed `ActivePaneRef`
    - sidebar click / duplicate reveal update desired state only; rendered-client observation updates observed state only; stale observed state must not overwrite a newer desired selection
    - same-session navigation stays exact-client scoped with `switch-client -c <tty> -t <pane>` and must preserve one rendered Ghostty surface
    - same-session navigation must retry until the exact rendered client converges and must restore first responder to the visible terminal host after sidebar clicks
    - pane-sync E2E must assert exact rendered-client truth and must stimulate reverse-sync on that same rendered client tty
  - TDD execution order:
    - add failing regressions for bootstrap location-collision / invalid-epoch fail-closed behavior after previously valid metadata
    - add failing regressions for valid bootstrap/change payloads where `session_key != session_name`
    - add reducer/navigation tests for desired-vs-observed race, rendered-client retry, and same-session focus restoration
    - strengthen real-surface UI/E2E so reverse-sync no longer uses a generic control client as the stimulus and prove same-session retarget on the normal daemon-connected path
  - current implementation progress:
    - bootstrap location collisions now invalidate the whole local metadata epoch and surface `daemon incompatible`
    - exact-client navigation now retries until rendered tmux client truth converges instead of issuing a one-shot `switch-client`
    - same-session sidebar retarget now emits a focus-restore nonce so the focused Ghostty host reclaims first responder after sidebar clicks
    - existing failing-regression scaffolding is already present in `AppViewModelA0Tests` and `WorkbenchStoreV2Tests`, but product code still does not satisfy it
    - fresh March 7, 2026 investigation found a second testing gap: `AGTMUX_UITEST` currently conflates bridge enablement, inventory-only fetch behavior, daemon-supervisor disablement, and polling suppression, so it cannot exercise the true metadata-enabled normal app path
    - fresh March 7, 2026 live and targeted-UI reruns narrowed the pane-sync failure again:
      - sidebar click updates the selected row and creates the terminal tile
      - the rendered tmux client tty never resolves for that tile, so exact-client navigation and reverse sync never start
      - vendor Ghostty only forwards custom OSC `9911` into the host action seam, so the current `9912` tty telemetry path can never bind in product
    - next step is a clean break:
      - fold rendered-client tty bind into the existing structured `OSC 9911` host bridge instead of relying on a second private OSC number
      - add failing coverage for missing rendered-client tty and rerun same-session UI/E2E on that new binding path
      - keep a later harness split on the board once the current product path is trustworthy again
    - fresh March 7, 2026 current-code rerun narrows the remaining UI red again:
      - `testPaneSelectionWithMockDaemonAndRealTmux` is green
      - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux` is green
      - only `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux` is red
      - the failure is no longer initial attach or sidebar selection; after a same-session sidebar retarget under metadata-enabled launch, terminal-originated reverse sync back to the first pane is still overwritten and the rendered tmux client stays on the second pane
    - fresh live daemon/socket inspection also produced a reusable exact-identity sample:
      - `ui.bootstrap.v2` now emits opaque `session_key` values for `vm agtmux` / `vm agtmux-term` while local tmux inventory still contains unmanaged rows such as `utm-main` and extra unmanaged panes in `vm agtmux-term`
      - this sample should become a fixture regression that proves managed/provider/activity overlay does not leak onto unrelated inventory rows even when `session_key != session_name`
    - final app-side fix shape is now landed:
      - desired-pane convergence confirmation is no longer one global threshold
      - initial attach still requires stable confirmation
      - same-session retarget from an already observed rendered client clears desired state after the first matching observation, so a later rendered-client-originated pane change is not overwritten
      - live opaque-session-key bootstrap sample is now locked as a no-leak regression fixture
    - final focused verification is green on the current worktree:
      - `swift build`
      - `swift test -q --filter WorkbenchStoreV2Tests`
      - `swift test -q --filter AppViewModelA0Tests`
      - `swift test -q --filter WorkbenchV2NavigationSyncResolverTests`
      - targeted arm64 `xcodebuild` for:
        - `testPaneSelectionWithMockDaemonAndRealTmux`
        - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux`
        - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`
    - current app-side closeout boundary is explicit:
      - no open term-consumer blocker is tracked after the final green rerun
      - if fresh live status disagreements reappear, validate `ui.bootstrap.v2` / `ui.changes.v2` daemon truth before reopening the app consumer
- **Description**:
  - Replace the false-green `T-107` outcome with a clean-break fix for exact-pane identity, same-session pane retarget, and bidirectional sidebar/terminal selection sync.
- **Acceptance Criteria**:
  - [x] sync-v2 / XPC bootstrap rejects invalid local pane identity (`session_id`, missing `session_key`, missing `pane_instance_id`, missing `session_name`, missing `window_id`) as whole-payload incompatibility
  - [x] when an incompatible local bootstrap arrives after previously valid metadata, stale overlay cache is cleared before the next publish and sidebar truth becomes inventory-only immediately
  - [x] invalid/orphan local daemon managed rows never surface provider / activity / title bleed onto plain inventory rows
  - [x] bootstrap collisions or duplicate managed rows at one visible local pane location fail closed for the whole current metadata epoch instead of picking a “preferred” managed row
  - [x] valid local bootstrap rows still apply managed/provider/activity overlay when `session_key` is opaque and differs from visible `session_name`
  - [x] valid `ui.changes.v2` rows still update the matching inventory row when `session_key` is opaque and differs from visible `session_name`
  - [x] persisted terminal tile identity remains session-scoped only; reducer-owned runtime pane state is separate and non-persistent
  - [x] same-session sidebar click updates desired pane state, preserves tile/surface identity, and retargets the exact rendered tmux client tty
  - [x] same-session sidebar click keeps retrying exact-client navigation until observed rendered-client truth matches the requested pane/window and returns first responder to the visible terminal host
  - [x] same-session sidebar click and terminal-originated pane change still converge when the sidebar is showing inventory-only rows
  - [x] terminal-originated pane change on the rendered client updates observed pane state and sidebar highlight through the same reducer
  - [x] metadata-enabled normal app path also converges after a same-session sidebar retarget: once the rendered client has reached the requested pane, a later rendered-client-originated pane change must not be overwritten by stale desired state
  - [x] regression coverage proves exact rendered tmux client truth, reducer-resolved active pane state, sidebar highlight, and stable rendered-surface identity agree for sidebar -> terminal and terminal -> sidebar flows in both app-driven UITest and normal daemon-connected paths

### T-107 — Exact pane navigation and metadata isolation regressions
- **Status**: SUPERSEDED_BY_T-108
- **Priority**: P0
- **Depends**: T-106
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - this closeout is no longer treated as final product truth; later live user evidence on March 7, 2026 proved the remaining regressions were still present.
  - user-reported live regressions on March 7, 2026:
    - a plain `zsh` pane in `utm-main` is surfaced as `codex`
    - idle Codex panes are surfaced as `running`
    - selecting a different pane row within the same session does not change the main-panel terminal/cursor
  - root causes are now isolated:
    - local metadata overlay keyed by `source + paneId` was bleeding managed/provider/activity state across exact rows
    - duplicate-open reveal logic for same-session pane selection was dropping pane/window intent before `openTerminal(...)`
    - the remaining runner-side tmux UI smoke (`testPaneSelectionWithMockDaemonAndRealTmux`) was harness-fragile because it depended on the XCUITest runner creating a real tmux session itself
  - metadata-isolation product slice is landed:
    - `AgtmuxPane` now carries `metadataSessionKey` / `paneInstanceID`
    - `AppViewModel` correlates local metadata by exact row identity and drops ambiguous or mismatched changes
    - focused verification is green for `swift build` and `AppViewModelA0Tests`
  - same-session pane retarget product slice is now landed:
    - `SessionRef` carries explicit `preferredWindowID` / `preferredPaneID` hints while tile identity remains `target + sessionName`
    - duplicate-open reveal updates the stored terminal tile intent in place instead of dropping pane/window selection
    - direct tmux attach now preselects the requested window/pane before `attach-session`
    - sidebar pane-row open now passes exact pane/window intent into the V2 workbench path
  - focused verification for the pane-retarget slice is green in SPM:
    - `swift build`
    - `swift test -q --filter WorkbenchStoreV2Tests`
    - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - the flaky same-session smoke is now closed on the app-driven harness path:
    - tmux multi-field observation now uses a delimiter that tmux emits literally (`|`), not `\t`
    - pane/window observation polls app-driven `list-panes` results after `split-window` / `new-window`
    - the proof now reads active terminal retarget state from app-side `UITestTmuxBridge` snapshot output instead of AX `value`
    - targeted arm64 `xcodebuild` reruns for `testPaneSelectionWithMockDaemonAndRealTmux` and the duplicate-open proof are green
- **Description**:
  - Fix exact-pane metadata/status bleed and make same-session pane row selection drive the visible V2 terminal tile to the requested pane without reintroducing linked-session behavior.
- **Acceptance Criteria**:
  - [ ] superseded by `T-108`

### T-106 — Legacy linked-session path physical deletion
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-095
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - user clarification is explicit: V2 exists to eliminate linked-session / group-session creation from the shipped product path, not merely to stop using it by default.
  - dead runtime entry points are physically removed from the shipped target:
    - `WorkspaceStore`
    - `WorkspaceArea`
    - `LinkedSessionManager`
    - legacy-only core layout helpers/tests (`LayoutNode`, `TmuxLayoutConverter`, related tests) after extracting live `SplitAxis` and `TmuxCommandRunner`
  - `SurfacePool` and `GhosttySurfaceHostView` no longer carry linked-session-specific registration/indexing state.
  - linked-session-positive coverage is deleted:
    - `LinkedSessionIntegrationTests`
    - linked-session title/runtime UI proofs
  - current-path coverage is narrowed to V2 truths:
    - keep direct-attach open / duplicate-open proofs
    - keep exact-session identity regressions for linked-looking names and `session_group`
    - remove pane-level focus-sync / same-window fast-switch proofs that belonged to the old linked-session workspace model and are not current V2 contract
  - delegated verification closed successfully after one interrupted UI/test worker attempt; final focused build/test/UI evidence came from a second delegated verifier run.
- **Description**:
  - Physically remove the obsolete linked-session workspace implementation so the shipped app no longer contains code that can create `agtmux-linked-*` sessions through the legacy path.
- **Acceptance Criteria**:
  - [x] shipped app target no longer wires or compiles the legacy linked-session workspace path
  - [x] linked-session creation helpers and legacy workspace-only runtime types are removed unless still required by an explicitly retained non-product surface
  - [x] tests/docs no longer present linked-session or session-group behavior as an active product contract
  - [x] focused verification proves the V2 mainline still opens real sessions directly without linked-session regressions

### T-090 — Workbench V2 foundation path
- **Status**: DONE
- **Priority**: P0
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - V2 core/store/view foundation and feature-flagged top-level path landed on 2026-03-06.
  - Remote `TargetRef` mapping now resolves configured host keys rather than raw hostnames.
  - Fresh build, focused SPM tests, and the targeted flag-on UI test are green.
  - Review conditions from the earlier `GO_WITH_CONDITIONS` verdict were cleared by `T-096` and `T-097`.
  - Final review verdict is `GO`.
- **Description**:
  - Create an isolated V2 Workbench model and top-level view/store path.
  - Support `terminal`, `browser`, and `document` tile kinds without mixing with linked-session lifecycle.
- **Acceptance Criteria**:
  - [x] `Workbench`, `WorkbenchNode`, `WorkbenchTile`, and `TileKind` exist for V2
  - [x] V2 path can render empty or placeholder terminal/browser/document tiles
  - [x] V1 linked-session path remains isolated rather than interleaved with V2 semantics

### T-091 — Real-session terminal tile
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-090
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - V2 terminal tile path now builds direct tmux attach commands from exact `SessionRef`.
  - duplicate-session prevention is implemented app-wide in `WorkbenchStoreV2` with reveal/focus semantics.
  - sidebar V2 branch now calls the real terminal-open API instead of placeholder insertion.
  - Xcode verification exposed a stale generated project; `xcodegen generate` refreshed the Xcode target graph so the new V2 app sources and integration test are visible to `xcodebuild`.
  - a verification-only compile blocker in `WorkbenchV2DocumentLoader.swift` was fixed so the current worktree can reach the T-091 UI proof path again.
  - the V2 terminal tile now exposes a dedicated direct-attach status AX anchor, and the targeted single-open UI proof uses that explicit contract instead of the flaky tile `value`.
  - real Claude Code CLI review returned `GO_WITH_CONDITIONS`; the only blocking condition was explicit `missingRemoteHostKey` coverage in `WorkbenchV2DocumentLoaderTests`, and that condition is now cleared on the current worktree.
  - one Codex review returned `GO_WITH_CONDITIONS` and required `WorkbenchV2DocumentLoader` to disconnect child stdin; that condition is also cleared.
  - a later Codex review returned `NO_GO` on pipe-buffer deadlock risk in `WorkbenchV2DocumentLoader`, timing-based `Thread.sleep` in the duplicate-open UI proof, and stale reopen state in companion surfaces; all of those findings are fixed on the current worktree.
  - fresh focused verification is green for `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2DocumentLoaderTests`, and `WorkbenchStoreV2Tests`.
  - the March 6, 2026 09:28 PST rerun exposed an environment-only automation approval blocker, but that blocker was cleared by approving `Enable UI Automation` on-console.
  - final targeted rerun on March 6, 2026 executed both UI proofs on `platform=macOS,arch=arm64` and passed: single-open real-session attach and duplicate-open reveal/focus both produced executed PASS results.
  - T-091 closeout is now complete on code, verification, and review evidence.
- **Description**:
  - Replace linked-session placement with direct attach to real tmux sessions in the V2 path.
  - Add app-global duplicate-session prevention.
- **Acceptance Criteria**:
  - [x] sidebar selection places a `SessionRef` into a V2 terminal tile
  - [x] terminal tile attaches directly to the real tmux session
  - [x] duplicate open reveals/focuses the existing tile instead of creating a second visible terminal tile

### T-092 — CLI bridge plus browser/document companion surfaces
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-091
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - Implementation planning exposed two different boundaries: companion surface rendering is app-local, while `agt open` bridge transport depends on the Ghostty action/OSC boundary.
  - Execution is being split into `T-098` and `T-099` so the app-local surface work can proceed without guessing over the bridge carrier.
  - `T-098` is now closed on code, focused verification, and review for the companion-surface rendering half.
  - `T-099` is now closed through `T-102` + `T-103` on code, focused verification, and dual Codex `GO` verdicts for the bridge carrier plus app-side decode/dispatch half.
  - fresh umbrella verification is green for `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `GhosttyCLIOSCBridgeTests`, `WorkbenchV2BridgeDispatchTests`, and `GhosttyTerminalSurfaceRegistryTests`.
  - umbrella reconciliation also aligned the remaining bridge-routing wording from `active Workbench` to the implemented emitting-surface Workbench semantics in architecture/design/tracking docs.
  - umbrella closeout is now a tracking reconciliation only; no extra product diff was required beyond the already-reviewed split tasks.
- **Description**:
  - Deliver the full Phase D outcome: browser/document companion surfaces plus `agt open <url-or-file>` over the terminal-scoped bridge.
- **Acceptance Criteria**:
  - [x] `agt open` opens browser tiles for URLs
  - [x] `agt open` opens document tiles for files
  - [x] directory input fails explicitly in MVP
  - [x] bridge-unavailable failure is explicit

### T-098 — V2 browser/document companion surface rendering
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-091
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - placeholder-only `browser` / `document` tile rendering in `WorkbenchAreaV2` has been replaced with minimal real surfaces.
  - browser tiles now use `WKWebView` with a visible load-failure banner and external-open affordance.
  - document tiles now use `WorkbenchV2DocumentLoader` to fetch local/remote text content and surface explicit load/fetch failures in-tile.
  - browser navigation now ignores cancellation errors, clears stale failure state on fresh loads, and keys reload behavior by `tile.id` so reopening the same URL does not inherit stale state.
  - document load completion now routes through a `WorkbenchV2DocumentLoadCoordinator` that tracks the current token and ignores stale/cancelled completions, so an old fetch cannot repaint the replacement tile.
  - focused coverage in `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, and `WorkbenchV2DocumentLoaderTests` now directly holds late-completion overwrite, cancellation ignore, browser reload identity, and missing-host-key loud failure.
  - fresh `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2DocumentLoaderTests`, and `WorkbenchStoreV2Tests` are green for the final T-098 worktree.
  - short post-fix Codex re-review returned `GO`.
- **Description**:
  - Replace V2 browser/document placeholder tiles with actual companion surface views and explicit load/fetch failure states.
- **Acceptance Criteria**:
  - [x] browser tiles render the requested URL in the targeted Workbench
  - [x] document tiles render requested local or remote file content in the targeted Workbench
  - [x] load/fetch failures remain visible as explicit tile states
  - [x] focused coverage exists for the new browser/document tile behaviors

### T-099 — `agt open` terminal bridge transport
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - current codebase has no production agtmux custom-OSC parser or dispatcher yet.
  - the likely ingress is `GhosttyApp.handleAction(...)`, with per-surface routing registered from `GhosttySurfaceHostView`, `WorkbenchAreaV2`, and `main.swift`.
  - investigation confirmed the shipped `GhosttyKit.xcframework` still exposes only fixed runtime callbacks and typed `ghostty_action_s` payloads; it does not expose a raw/generic custom OSC callback.
  - the repo already contains vendored Ghostty source plus `scripts/build-ghosttykit.sh`, so the blocker is no longer external upstream access; it is a repo-local expansion to add one custom OSC host action through the existing `action_cb` seam.
  - execution is now split into `T-102` carrier exposure in vendored GhosttyKit and `T-103` app-side decode/dispatch wiring.
  - `T-102` is now closed on the current worktree: `OSC 9911` is exposed as a typed `custom_osc` action through the existing `action_cb`, parser/runtime coverage proves BEL and ST delivery into the host action seam with exact payload bytes, and GTK shared-source parity is explicit.
  - fresh verification is green for `zig build test -Dtest-filter='custom osc'`, `./scripts/build-ghosttykit.sh`, xcframework/header sync `cmp`, and `swift build`.
  - final re-review returned `GO` from two independent Codex reviewers.
  - investigation confirmed there is no `agt` CLI implementation in this repo; `agt open` remains a documented external emitter contract, not an in-tree binary target.
  - `T-103` is now closed on the current worktree: app-side decode/dispatch is landed, seam-level integration proof now exercises `GhosttyApp.handleAction(...)` itself, and dual Codex re-review returned `GO`.
  - the in-repo bridge path is now closed on code, focused verification, and review; the external `agt` emitter remains documented and out of tree.
- **Description**:
  - Implement the terminal-originated bridge request path for `agt open <url-or-file>` without silent fallback at the Ghostty/runtime boundary.
- **Acceptance Criteria**:
  - [x] terminal-originated open requests reach the emitting terminal's Workbench with source/cwd context
  - [x] directory input is rejected explicitly in MVP
  - [x] bridge-unavailable failure is explicit
  - [x] local and remote shells use the same explicit bridge path

### T-102 — GhosttyKit custom OSC host action exposure
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100, T-101
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `OSC 9911` carrier exposure is present in the embedded runtime, public header, and rebuilt `GhosttyKit.xcframework`.
  - automated coverage now proves BEL and ST terminated `OSC 9911` sequences preserve exact `osc` and payload bytes through parser, stream, surface, and embedded `action_cb` delivery.
  - GTK runtime parity is explicit via `.custom_osc` handling in `vendor/ghostty/src/apprt/gtk/class/application.zig`.
  - fresh verification is green for `zig build test -Dtest-filter='custom osc'`, `./scripts/build-ghosttykit.sh`, xcframework/header sync `cmp`, and `swift build`.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Description**:
  - Expand the vendored Ghostty embedded runtime so terminal-scoped custom OSC payloads become a typed host-visible `ghostty_action_s` case delivered through the existing `action_cb`.
- **Acceptance Criteria**:
  - [x] vendored Ghostty parses the chosen custom OSC bridge command and preserves its raw payload
  - [x] `ghostty_action_s` exposes a typed custom-OSC payload at the C boundary
  - [x] the rebuilt `GhosttyKit.xcframework` delivers that typed action through `GhosttyApp.handleAction(...)`
  - [x] GTK runtime handles `.custom_osc` consistently with the shared source contract
  - [x] automated proof shows BEL and ST terminated `OSC 9911` sequences reaching the runtime/host action seam with exact `osc` and payload bytes

### T-103 — App-side `agt open` bridge decode and dispatch
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-102
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - payload contract is now locked before code: `OSC 9911` carries strict UTF-8 JSON with `version`, `action`, `kind`, `target`, `cwd`, `argument`, `placement`, and `pin`.
  - host-side validation is fail-loud by design: malformed JSON, unsupported enum values, empty required fields, and relative file paths are not normalization paths.
  - app-side decode/dispatch is now landed on the current worktree in `GhosttyApp.handleAction(...)`, `GhosttyCLIOSCBridge`, `GhosttyTerminalSurfaceRegistry`, and `WorkbenchV2BridgeDispatch`.
  - focused `GhosttyCLIOSCBridgeTests` now cover malformed JSON, object-root enforcement, unsupported `version` / `action` / `kind` / `placement`, empty required fields, relative file path rejection, cross-workbench browser/document dispatch, explicit failures for unregistered or non-surface targets, and real `GhosttyApp.handleAction(...)` seam behavior from an off-main callback context.
  - fresh focused verification is green for `swift build`, `GhosttyCLIOSCBridgeTests`, `WorkbenchV2BridgeDispatchTests`, and `GhosttyTerminalSurfaceRegistryTests`.
  - initial re-review split on missing `GhosttyApp.handleAction(...)` proof, but the seam-level integration fix is now landed and final re-review returned `GO` from two independent Codex reviewers.
- **Description**:
  - Decode the custom OSC bridge payload, resolve source/cwd context, and dispatch browser/document opens into `WorkbenchStoreV2`.
- **Acceptance Criteria**:
  - [x] custom OSC payload decode/validation fails loudly for malformed or unsupported requests
  - [x] valid bridge requests resolve the emitting surface context and open the expected browser/document tile
  - [x] explicit failure remains visible when the payload cannot be resolved or dispatched
  - [x] in-repo tests prove the app-side decode/dispatch path even though the `agt` emitter itself is out of tree

### T-100 — Ghostty CLI-bridge carrier decision
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-098
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `docs/42_design-cli-bridge.md` now explicitly keeps terminal-scoped custom OSC as the carrier contract.
  - typed-action piggyback (`title`, `notification`, `open-url`, etc.) is explicitly rejected as a non-mainline fallback.
  - the required host capability is now documented: surface-scoped delivery, raw payload visibility, explicit consume/dispatch, and local/remote symmetry.
  - the verification strategy is now documented well enough for `T-099`: payload decode tests, dispatch tests, and product-level proof.
- **Description**:
  - Resolve the mismatch between the design-locked custom OSC bridge and the current GhosttyKit C API, which only exposes typed runtime actions.
- **Acceptance Criteria**:
  - [x] the bridge carrier is locked explicitly in `docs/42_design-cli-bridge.md`
  - [x] the chosen carrier preserves explicit failure semantics and local/remote symmetry
  - [x] the app-side ingress seam and verification strategy are documented well enough for `T-099` implementation

### T-101 — App-side CLI bridge dispatch scaffold
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `WorkbenchV2BridgeRequest` now preserves the design-locked placement contract (`--left|--right|--up|--down|--replace`) end to end.
  - `GhosttyTerminalSurfaceRegistry` is now keyed by a canonical `GhosttySurfaceHandle` derived from the real `ghostty_surface_t`, with `context(forTarget:)` available for the `GhosttyApp.handleAction(...)` seam.
  - `GhosttySurfaceHostView` now unregisters stale handles on reattach/dismantle so registry state stays aligned with live Ghostty surfaces.
  - the unfocused-workbench crash is now fixed on the current worktree: non-empty layouts without a preset focus normalize to the first tile in traversal order before placement is applied, while actually invalid states still fail loudly.
  - fresh final verification is green for `swift build`, `WorkbenchV2BridgeDispatchTests`, `GhosttyTerminalSurfaceRegistryTests`, and `WorkbenchStoreV2Tests`.
  - final re-review returned `GO` from two independent Codex reviewers on the crash-fixed worktree.
  - real Claude Code CLI was installed and authenticated, but unusable in this environment (`Raw mode is not supported on the current process.stdin`; repeated `claude -p` attempts returned no usable output), so the blocked Claude leg was compensated with extra Codex review coverage per repo policy.
- **Description**:
  - Implement the app-side bridge request model, surface registration metadata, and Workbench dispatch path so `T-099` is blocked only on carrier ingress, not on downstream plumbing.
- **Acceptance Criteria**:
  - [x] a bridge request model exists for browser/document open with placement plus source/cwd context
  - [x] terminal surfaces register enough identity/metadata for future bridge dispatch from the real Ghostty surface callback boundary
  - [x] the dispatcher can open browser/document tiles in the resolved emitting Workbench from an injected request without dropping placement semantics or crashing on a valid unfocused non-empty workbench
  - [x] focused tests exist for dispatch and surface-resolution behavior without requiring the final carrier

### T-093 — Workbench persistence and restore placeholders
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-092
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - phase start review shows two separable implementation surfaces: autosave/load plumbing and restore-failure affordances.
  - execution is now split into `T-104` and `T-105` so storage can land without mixing it into restore-action UI work.
  - `T-104` is now closed on code, focused verification, and dual Codex `GO`.
  - `T-105` is now closed on code, focused verification, targeted UI proof, and dual Codex `GO`.
  - fresh umbrella verification is green for `swift build`, `WorkbenchStoreV2PersistenceTests`, `WorkbenchStoreV2Tests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2TerminalRestoreTests`, `WorkbenchV2TerminalAttachTests`, and the targeted restore UI proof batch.
  - bounded Codex CLI closeout attempts on the umbrella pack did not return a usable final verdict in reasonable time; the final umbrella `GO` came from direct Codex fallback review over the already-reviewed split-task evidence.
  - umbrella closeout is now a tracking reconciliation only; no extra product diff was required beyond the already-reviewed split tasks.
- **Description**:
  - Persist Workbench layout and restore terminal plus pinned companion tiles.
  - Surface broken refs as explicit placeholder states.
- **Acceptance Criteria**:
  - [x] Workbenches autosave
  - [x] terminal tiles restore by `SessionRef`
  - [x] pinned browser/document tiles restore
  - [x] missing host/session/path surfaces remain visible with `Retry` / `Rebind` / `Remove Tile`

### T-104 — Workbench autosave/load snapshot plumbing
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-099
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Persist V2 Workbench state to app-owned storage, restore it on launch, and save only terminal tiles plus pinned companion tiles.
- **Progress**:
  - `WorkbenchStoreV2Persistence` now owns the fixed snapshot path, validated encode/decode, and atomic writes.
  - `WorkbenchStoreV2(env:)` restores persisted state when no fixture override is present; fixture JSON still wins for tests.
  - autosave now covers representative store mutations and the bridge-dispatch mutation path.
  - focused verification is green for `WorkbenchStoreV2PersistenceTests`, `WorkbenchStoreV2Tests`, and `WorkbenchV2BridgeDispatchTests`.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Acceptance Criteria**:
  - [x] app launch restores the last autosaved Workbench snapshot when no fixture override is active
  - [x] terminal tiles persist by exact `SessionRef`
  - [x] unpinned browser/document tiles are dropped from the persisted snapshot
  - [x] pinned browser/document tiles restore from the persisted snapshot

### T-105 — Restore failure placeholders and recovery actions
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-104
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Surface restore-time broken refs as explicit placeholder states with `Retry`, `Rebind`, and `Remove Tile`.
- **Notes**:
  - T-105 will not add a persisted `restoreStatus` field. Broken-state rendering is computed from the persisted tile ref plus live app state.
  - Initial scope is terminal `SessionRef` and document `DocumentRef` recovery. Browser navigation failures remain on their existing load-error path.
- **Progress**:
  - render-time restore resolution from persisted refs + live inventory/host-config truth is now design-locked in `docs/41_design-workbench.md`.
  - the active implementation surface is terminal/document placeholders plus exact-target `Rebind` and tree-safe `Remove Tile`.
  - store mutation support is landed: `WorkbenchStoreV2` now has tree-safe `Remove Tile` plus exact-target terminal/document `Rebind` APIs with autosave coverage.
  - execution fallback for the remaining UI slice is now locked: real agent CLI first, then Codex subagent, then orchestrator direct execution only if both delegated paths fail to return usable output.
  - document restore UI is landed with typed `Host missing` / `Host offline` / `Path missing` / `Access failed` states plus retry-token coverage.
  - terminal restore UI is landed via orchestrator direct execution after both delegated tiers failed to return usable edits; terminal tiles now resolve `Host missing` / `Host offline` / `tmux unavailable` / `Session missing` and local daemon issue placeholders from live inventory truth.
  - terminal/document startup races reopened the task in review; the final remediation added terminal `bootstrapping` state, deferred remote document load until reachability truth is ready, and removed document rebind's silent local fallback.
  - focused verification is green for `swift build`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2TerminalRestoreTests`, `WorkbenchStoreV2Tests`, `WorkbenchStoreV2PersistenceTests`, and `WorkbenchV2TerminalAttachTests`.
  - targeted UI proofs are green for both a broken restored terminal tile and a healthy restored terminal tile.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Acceptance Criteria**:
  - [x] broken terminal/document refs remain visible after restore instead of silently disappearing
  - [x] `Retry` re-attempts the failed attach/load path
  - [x] `Rebind` allows manual exact-target reassignment only
  - [x] `Remove Tile` removes the broken tile from the restored Workbench

### T-094 — Sidebar integration and linked-session normal-path removal
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-093
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Reconnect sidebar workflows to V2 and remove linked-session assumptions from the normal product path.
- **Progress**:
  - execution started after T-105 closeout.
  - the first slice is to make the visible cockpit surfaces (`SidebarView`, `CockpitView`, `TitlebarChromeView`) use the V2 workbench path as the default mainline composition instead of branching on the temporary feature flag.
  - slice 1 is landed: the visible cockpit surfaces now route the normal path through `WorkbenchAreaV2`, `WorkbenchTabBarV2`, and `WorkbenchStoreV2.openTerminal(...)` without `WorkbenchStoreV2.isFeatureEnabled()` branching.
  - focused verification is green for `swift build`, `WorkbenchStoreV2Tests`, `WorkbenchV2TerminalAttachTests`, and the targeted UI proofs `testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile` / `testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile` / `testEmptyStateOnLaunch`.
  - the fallback ladder was exercised during slice 1: the real agent CLI did not return a usable report in reasonable time, and the delegated Codex tier did not return a usable in-band handoff, so the orchestrator completed the remaining owned-file cleanup and UI-proof stabilization directly.
  - slice 2 is landed: `AppViewModel` no longer filters `agtmux-linked-*` session names or canonicalizes sidebar identity through `session_group`; the normal sidebar path now preserves exact tmux session names and only dedupes exact duplicate rows.
  - conflicting tests were rewritten to the real-session sidebar contract:
    - `AppViewModelA0Tests` now covers exact visibility for linked-looking session names and session-group aliases
    - `AgtmuxTermUITests` now proves linked-looking sessions remain visible and session-group aliases remain distinct
    - obsolete `PaneFilterTests` were removed because they only asserted the old prefix-filter contract and no longer exercised product code
  - focused verification is green for `swift build`, `AppViewModelA0Tests`, `WorkbenchStoreV2Tests`, and targeted UI proofs for linked-looking sessions plus session-group alias visibility.
  - dual Codex review reopened T-094 on an exact-session selection regression: sidebar highlight and `retainSelection` were still collapsing sibling alias rows back to `source + window + pane`.
  - the regression fix is now landed: `AppViewModel.retainSelection(...)` and `SidebarView` selection matching both use exact pane identity including `sessionName`, and the UI test helper now keys selected markers by full `AccessibilityID.paneKey(...)`.
  - regression coverage is added in `AppViewModelA0Tests` for refresh-time retention of the exact selected alias session, and in `AgtmuxTermUITests` for exact selected-row marker behavior across sibling aliases.
  - fresh post-fix verification is green for `swift build`, `swift test -q --filter AppViewModelA0Tests`, `swift test -q --filter WorkbenchStoreV2Tests`, `swift test -q --filter WorkbenchV2TerminalAttachTests`, and `xcodegen generate`.
  - a later unlocked-session rerun now executes all 6 selected UI proofs and passes on the current worktree.
  - the duplicate-open proof helper now reuses the already-resolved sidebar row element instead of re-querying before click, which removed the transient AX flake seen in the first unlocked batch.
  - final scoped Codex re-review returned `GO` from two independent reviewers; both treated the locked-session UI skip as an environment evidence gap rather than a remaining code blocker.
- **Acceptance Criteria**:
  - [x] sidebar can jump to existing V2 terminal tiles
  - [x] normal path creates no linked sessions
  - [x] obsolete linked-session filtering/title-leak behavior is removed from the main path

### T-095 — local health-strip offline contract follow-up
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Decide and lock the intended health-strip behavior when local inventory goes offline or stale data remains.
  - Add regression coverage once the contract is explicit.
- **Progress**:
  - current code/test behavior is now identified: local inventory offline marks `offlineHosts` for `local`, but does not clear `localDaemonHealth`; the app keeps polling `ui.health.v1`, and the health strip stays absent only when no health snapshot exists.
  - architecture/spec docs now record that contract explicitly.
  - existing regression coverage already exercises the chosen behavior in `AppViewModelA0Tests`:
    - `testLocalDaemonHealthPublishesEvenWhenInventoryFetchFails`
    - `testLocalInventoryOfflineDoesNotClearExistingHealthAndStillAllowsRefresh`
  - existing UI coverage already fixes the visible strip contract for presence/absence:
    - `testSidebarHealthStripShowsMixedHealthStates`
    - `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
  - fresh verification reran `swift test -q --filter AppViewModelA0Tests` and passed (18 tests).
  - a later unlocked-session targeted UI rerun executed `testSidebarHealthStripShowsMixedHealthStates` and `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` with PASS.
  - final scoped Codex re-review returned `GO` from two independent reviewers after the docs were narrowed to the actually covered contract.
- **Acceptance Criteria**:
  - [x] intended health-strip behavior on local inventory/offline failure is documented
  - [x] regression coverage exists for the chosen behavior

### T-096 — V2 remote `TargetRef` regression coverage
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Add focused regression coverage for `pane.source` hostname -> configured `RemoteHost.id` -> V2 `SessionRef.target`.
- **Implemented**:
  - added focused `WorkbenchStoreV2Tests` coverage for configured and unconfigured remote hostname mapping
- **Acceptance Criteria**:
  - [x] configured remote hostname maps to `TargetRef.remote(hostKey: <RemoteHost.id>)`
  - [x] unconfigured remote hostname remains explicit rather than silently remapped

### T-097 — V2 feature-flag sidebar-open live UI proof
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Rerun `AgtmuxTermUITests.testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` from an unlocked interactive macOS session and record executed proof in docs.
- **Implemented**:
  - reran the targeted UI test from an unlocked interactive macOS session and captured an executed PASS result
- **Acceptance Criteria**:
  - [x] targeted UI test executes rather than skipping
  - [x] executed PASS/FAIL result is recorded in `docs/70_progress.md`
  - [x] review evidence reflects the executed result

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
