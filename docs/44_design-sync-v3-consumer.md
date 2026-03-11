# sync-v3 Consumer Foundation

**Status**: Phase 1 landed in term repo; wire cutover not started  
**Scope**: term-side consumer foundation for the status-v3 rollout

## Intent

`agtmux-term` should stop treating daemon status as a single pre-collapsed dot state.

The daemon owns semantic truth.
The term app owns presentation.

Product local metadata must therefore prefer daemon sync-v3 truth or fail closed to inventory-only.
It must not resurrect sync-v2, collapsed `ActivityState`, or `provider_raw` as fallback semantic truth.

This document records the term-side boundary before live `sync-v3` wiring begins.

## Responsibility Split

### Daemon truth

The daemon remains authoritative for:

- exact pane/session identity on the wire
- normalized multi-axis status
- pending request entities
- attention summary generation
- freshness summary
- provider-native raw state capture

### Term presentation

The term app remains authoritative for:

- exact-row correlation to visible inventory rows
- local presentation derivation for sidebar/title bar UI
- UI compression of structured state into dot/badge/filter/subtitle choices
- local accessibility summaries and row-level render contracts

The term app must not try to reconstruct daemon truth from `provider_raw`.
It consumes the normalized snapshot and derives presentation locally.
The remaining sync-v2 / legacy compat surfaces are explicitly non-product and should continue shrinking until they can be deleted.

## Exact-Row Correlation

`sync-v3` keeps the strict exact identity contract.

Required/non-null identity fields:

- `session_name`
- `window_id`
- `session_key`
- `pane_id`
- `pane_instance_id`

These are still ingress requirements for local managed rows.
The v3 semantic redesign must not weaken row identity strictness.

## v3 Consumer Shape

The term repo now carries two new layers:

1. `AgtmuxSyncV3Models`
   - raw consumer-side wire structs for the planned v3 snapshot
   - strict required exact identity fields
   - structured axes for:
     - `agent.lifecycle`
     - `thread.lifecycle`
     - `blocking`
     - `execution`
     - `flags`
     - `turn`
     - `pending_requests`
     - `attention`
     - `freshness`
     - `provider_raw`

2. `PanePresentationState`
   - local pure derivation from daemon snapshot to UI-ready state
   - views should bind to presentation state, not directly to raw v3 structs

## Attention Is Summary, Not Truth

`attention` exists to help the UI avoid re-implementing daemon priority rules.
It is not the source of truth for request identity.

Truth remains:

- `pending_requests[].request_id`
- `pending_requests[].kind`
- thread/agent error axes
- `thread.turn.outcome`

`attention.generation` is summary/update metadata only.
It must not be used as request identity or dedupe identity.

## Canonical Fixture Policy

Daemon-owned canonical v3 fixtures now live in the sibling `agtmux` repo at commit:

- `cb198cca7226666fbb26df34d4e17582a208c3e6`

Source-of-truth path:

- `/Users/virtualmachine/ghq/github.com/g960059/agtmux/fixtures/sync-v3/`

Term-side consumer tests read those fixtures directly.
The term repo should not mirror or reinterpret them independently unless the daemon repo changes the contract first.

Local negative tests that assert consumer fail-closed behavior may still use inline invalid payloads, but canonical positive scenarios must come from the daemon-owned fixtures.

## Current Limit

The current term rollout is additive bootstrap-v3 plus additive changes-v3.

- `AppViewModel` now prefers `ui.bootstrap.v3` when the daemon exposes it
- after bootstrap-v3 succeeds, the live replay path can also consume `ui.changes.v3`
- exact-row correlation still remains strict on:
  - `session_name`
  - `window_id`
  - `session_key`
  - `pane_id`
  - `pane_instance_id`
- the product `AppViewModel` local metadata path now requires sync-v3; unsupported bootstrap-v3 or changes-v3 clears overlay state and surfaces daemon incompatibility instead of silently falling back
- the product-facing issue identity for that path is now `LocalDaemonIssue.incompatibleMetadataProtocol`, not the older `incompatibleSyncV2` naming
- surfaced detail for that issue should describe metadata protocol / exact-identity failures first; factual RPC names may still appear when they are the real failing surface
- the product-facing metadata abstraction now also resets only sync-v3 replay state; sync-v2 reset APIs remain compatibility-only below that boundary
- the product-facing client/protocol surface is now explicitly `ProductLocalMetadataClient`; `LocalMetadataClient` remains a compat-only surface for low-level sync-v2 transport/XPC coverage
- remaining sync-v2 transport/service-boundary/workbench code is compatibility-only
- the current product UI still renders through legacy `AgtmuxPane` / `ActivityState`

The v3 bridge deliberately adapts daemon truth into the existing term-local row model without cutting views over yet.
That means:

- bootstrap-v3 improves initial exact-row truth
- changes-v3 can now update/remove the existing exact row through the same additive adapter
- `attention` remains a summary input, not request identity
- the full sidebar/titlebar/filter/count cutover waits for daemon `changes-v3`

Remaining rollout steps:

1. extend the first sidebar-only presentation cutover into the remaining titlebar / broader UI paths
2. live/UI coverage for the additive v3 delta lane
3. removal of active v2-only presentation dependencies

## Thin Live Gate

The first live gate for the additive v3 lane is intentionally not a broad XCUITest rewrite.

- use one real-daemon integration canary first
- prove:
  - `ui.bootstrap.v3` establishes the local presentation cache
  - `ui.changes.v3` updates the same exact local row
  - sync-v2 fallback stays unused while the daemon advertises sync-v3
- keep the existing XCUITest foreground-activation blocker as a separate harness deferral instead of folding it into the v3 consumer gate

## First UI Cutover Slice

The first UI cutover is intentionally small and additive.

- `AppViewModel` now keeps a parallel local `PanePresentationState` cache for v3-backed local overlays
- sidebar row presentation prefers that presentation cache for:
  - provider surfacing
  - primary activity state surfacing
  - freshness surfacing
  - AX row summary
- sidebar `managed` / `attention` filter and badge/count derivation also prefer the presentation cache
- non-v3-backed rows still use legacy `AgtmuxPane` / `ActivityState` only through compat/display adapters; product local metadata refresh itself no longer falls back to sync-v2

This keeps the cutover reviewable:

- daemon remains the truth source
- term only adapts into a local presentation model
- broader UI surfaces are deferred until the sidebar-first slice is stable

## Next Small Consumer Slice

The next small cutover after sidebar rows/filter/count stays deliberately narrow.

- titlebar continues to consume shared presentation-derived `attentionCount` / filter state from `AppViewModel`
- UI-harness / diagnostic sidebar summaries should also prefer the same presentation-derived state when available
- this avoids a split world where visible UI uses `PanePresentationState` but diagnostics still report only legacy `ActivityState`

## Shared Display Adapter Boundary

Before full compatibility cleanup, product-facing consumers should read one shared adapter rather than open-coding legacy fallback.

- `PaneDisplayState` is the current boundary for:
  - sidebar row presentation
  - badge/count derivation
  - row accessibility summaries
  - UI-test sidebar presentation snapshots
- `PaneDisplayCompatFallback` now owns the compatibility-only collapse from legacy `ActivityState` into `PanePresentationPrimaryState` / freshness text / attention when no v3 presentation is available
- `AgtmuxPane.needsAttention` is now just a compat delegate to that same helper; the product-facing truth remains presentation-first
- `PaneMetadataCompatFallback` now owns the compatibility-only collapse from `PanePresentationState` back into legacy `ActivityState` when sync-v3 overlays still have to materialize compat `AgtmuxPane` rows
- remaining compatibility fields still live behind that adapter:
  - `AgtmuxPane.activityState`
  - `AgtmuxPane.presence`
  - `AgtmuxSyncV2PaneInstanceID`

This keeps future v3 cleanup reviewable by shrinking the number of UI consumers that directly depend on collapsed legacy state.

## Local Metadata Transport Boundary

The transport seam is now narrowed to required sync-v3 bootstrap fetches only.

- `LocalMetadataTransportBridge` now owns:
  - the required `ui.bootstrap.v3` fetch entrypoint used by product refresh code
- the old sync-v3->v2 fallback selector has been deleted from the bridge because product code no longer consumes it
- `AppViewModel` still owns:
  - exact-row cache construction from bootstrap payloads
  - v2/v3 replay application into local overlay caches
  - bootstrap-not-ready defer logic
  - cache publish / clear timing

This keeps the next extraction target explicit without pretending the compatibility layer is already removed.

## Local Metadata Overlay Boundary

The next narrowed holdout after transport selection is the overlay/replay seam itself.

- `LocalMetadataOverlayStore` now owns:
  - strict bootstrap cache construction for `ui.bootstrap.v3`
  - strict pane-map construction for `ui.bootstrap.v2`
  - exact-row v2 replay application and base-pane resolution
  - exact-row v3 upsert/remove replay application
  - synchronized metadata-cache and presentation-cache mutation for v3 changes
- `AppViewModel` still owns:
  - bootstrap-not-ready defer / retry timing
  - publish / clear scheduling
  - task orchestration and replay reset flow

This keeps the remaining compatibility boundary explicit:

- transport selection remains in `LocalMetadataTransportBridge`
- overlay/replay semantics now live in one helper
- broader sync-v2/v3 compatibility and publish orchestration are still intentionally in `AppViewModel`

## Local Metadata Refresh Boundary

The next narrowed holdout after overlay/replay extraction is refresh-state transition handling.

- `LocalMetadataRefreshBoundary` now owns:
  - bootstrap-not-ready defer classification for `ui.bootstrap.v2` / `ui.bootstrap.v3`
  - shaping of bootstrap metadata payload/result before the async loop applies it
  - publish-state transitions after successful bootstrap/replay
  - clear-state transitions after refresh failure
  - sync-primed / transport-version / daemon-issue / next-refresh updates tied to those outcomes
- `AppViewModel` still owns:
  - the async refresh task loop and scheduling guards
  - replay reset calls against the daemon client
  - snapshot publication orchestration

This keeps the remaining seam explicit:

- transport selection remains in `LocalMetadataTransportBridge`
- exact-row replay/cache construction remains in `LocalMetadataOverlayStore`
- refresh-state shaping now lives in `LocalMetadataRefreshBoundary`
- the main async orchestration still intentionally lives in `AppViewModel`

## Local Metadata Async Coordinator Boundary

The next narrowed holdout after refresh-state shaping is the one-step async refresh decision body.

- `LocalMetadataRefreshCoordinator` now owns:
  - active replay reset selection
  - bootstrap fetch/result resolution
  - one-step refresh decisions for:
    - initial bootstrap
    - sync-v3 change polling/resync
    - sync-v3 unsupported-method failure propagation into explicit daemon-incompatible clear/reset execution
    - failure clear/reset execution shaping
- `AppViewModel` still owns:
  - `Task` allocation/cancellation
  - scheduling guards (`localMetadataRefreshTask == nil`, backoff deadlines)
  - applying coordinator executions
  - top-level inventory fetch / snapshot publication orchestration

This keeps the remaining seam explicit:

- transport selection stays in `LocalMetadataTransportBridge`
- exact-row replay/cache construction stays in `LocalMetadataOverlayStore`
- refresh-state shaping stays in `LocalMetadataRefreshBoundary`
- async decision orchestration now lives in `LocalMetadataRefreshCoordinator`
- product local metadata now requires sync-v3; the remaining sync-v2 helper surface is compat-only
- only the outer `Task` lifecycle and fetch/publish shell remain in `AppViewModel`

## Broad Product Test Alignment

The broad `AppViewModelA0Tests` suite now treats sync-v3 as the only product metadata path.

- unsupported `ui.bootstrap.v3` / `ui.changes.v3` is expected to surface daemon incompatibility and inventory-only rows
- exact-row bootstrap-v3 / changes-v3 behavior is the product truth in the broad suite
- legacy `conversationTitle` carry-over is no longer treated as normalized sync-v3 truth; remaining title assertions belong to compat-only sync-v2 transport coverage until daemon truth exposes a normalized v3 title field

## Live Product Suite Alignment

`AppViewModelLiveManagedAgentTests` now follows the same product truth boundary.

- the live managed-agent suite bootstraps and observes daemon truth through `ui.bootstrap.v3` / `ui.changes.v3`
- live product assertions prefer `PanePresentationState` / `PaneDisplayState` over raw legacy `ActivityState` when validating the visible row
- sync-v2 bootstrap/changes calls are still recorded only to prove that product fallback stays unused
- managed-exit shell demotion and same-session no-bleed are validated as sync-v3 exact-row updates on the same visible pane row

## UI Harness Diagnostics Alignment

`UITestTmuxBridge` sidebar dumps now follow the same diagnostic boundary.

- metadata-enabled bootstrap probes use `ui.bootstrap.v3`
- bootstrap target summaries expose sync-v3 presentation/identity fields (`primary state`, `freshness`, `session_key`, `pane_instance_id`)
- visible row summaries still include inventory-derived `current_cmd` when needed for shell readiness, but they no longer treat raw sync-v2 `activity_state` as daemon truth
- deterministic coverage for that diagnostic contract now lives in `UITestSidebarDiagnosticsTests`; targeted metadata-enabled XCUITest execution remains a foreground/automation harness concern rather than the primary verification lane
- the remaining live Codex UI proof now also consumes `primary=...` semantics and allows `completed_idle` as the canonical completion label
- UI sidebar dump payloads are now presentation-first:
  - bridge payloads carry `panePresentations` / `filteredPanePresentations` plus sync-v3 bootstrap summaries, not raw `AgtmuxPane` arrays
  - sidebar summary helpers and bootstrap-ready polling resolve exact rows from presentation snapshots and use `current_cmd` only as the final shell-readiness gate
- pane row accessibility summaries now match that same vocabulary:
  - row `accessibilityValue` uses `primary=...` labels from `PanePresentationPrimaryState`
  - raw `activity=...` wording is no longer the product-facing accessibility summary term
  - the AX identifier name `sidebar.pane.activity.*` stays stable for existing selectors even though the marker label/value now carries primary-state semantics
