# sync-v3 Consumer Foundation

**Status**: Phase 1 landed in term repo; wire cutover not started  
**Scope**: term-side consumer foundation for the status-v3 rollout

## Intent

`agtmux-term` should stop treating daemon status as a single pre-collapsed dot state.

The daemon owns semantic truth.
The term app owns presentation.

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
- sync-v2 remains intact as the fallback path whenever bootstrap-v3 or changes-v3 is unsupported
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

## First UI Cutover Slice

The first UI cutover is intentionally small and additive.

- `AppViewModel` now keeps a parallel local `PanePresentationState` cache for v3-backed local overlays
- sidebar row presentation prefers that presentation cache for:
  - provider surfacing
  - primary activity state surfacing
  - freshness surfacing
  - AX row summary
- sidebar `managed` / `attention` filter and badge/count derivation also prefer the presentation cache
- sync-v2 remains the live fallback, and non-v3-backed rows still use legacy `AgtmuxPane` / `ActivityState`

This keeps the cutover reviewable:

- daemon remains the truth source
- term only adapts into a local presentation model
- broader UI surfaces are deferred until the sidebar-first slice is stable

## Next Small Consumer Slice

The next small cutover after sidebar rows/filter/count stays deliberately narrow.

- titlebar continues to consume shared presentation-derived `attentionCount` / filter state from `AppViewModel`
- UI-harness / diagnostic sidebar summaries should also prefer the same presentation-derived state when available
- this avoids a split world where visible UI uses `PanePresentationState` but diagnostics still report only legacy `ActivityState`
