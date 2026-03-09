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

## Temporary Fixture Policy

Daemon-owned canonical v3 fixtures do not exist in this repo yet.
Until they do:

- local decode tests may use temporary inline JSON fixtures derived from the final design doc
- those fixtures must stay clearly marked as temporary scaffolds
- the term repo should be ready to swap to daemon-owned fixtures without changing presentation semantics

## Current Limit

This slice does not wire `sync-v3` into `AppViewModel` or replace the current v2 / `ActivityState` product path.

That cutover will happen later in three steps:

1. daemon-owned fixtures and wire contract freeze
2. term-side adapter/cutover onto v3 snapshot
3. removal of active v2-only presentation dependencies
