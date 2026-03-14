# Local-First Fast Path Architecture

## Purpose

This document adapts the March 13, 2026 local-first handover into the current
`agtmux-term` codebase.

It is an execution-order and hot-path architecture document. It does **not**
change the product truth already locked elsewhere:

- `tmux first`
- daemon `sync-v3` remains the product metadata truth for local overlays
- term remains the presentation consumer of that truth
- remote no-install support remains in scope, but only after the local parity gate

## Why The Focus Shifts Back To Local

Recent `T-PERF-P1` through `T-PERF-P13` work removed several first-order costs:

- Ghostty wakeup coalescing landed
- draw is now active-surface-only
- control-mode navigation exists for local and remote
- the 3-store split and AppKit island are already in place

The remaining hot-path gap is now outside libghostty itself:

- `main.swift` still performs startup `fetchAll()` and starts the 1-second poller
- `AppViewModel.startPolling()` still drives steady-state `fetchAll()`
- local inventory and local metadata still converge through one polling-oriented coordinator
- focused navigation still performs control-mode handling from the tile view on `@MainActor`
- draw is `active-only`, not yet `dirty-only`

The next useful optimization order is therefore:

1. make local behavior measurable
2. remove local steady-state dependence on global polling
3. move focused local navigation closer to control-mode authority
4. only then optimize the remote no-install path

## Fast Path Definitions

### Local fast path

The focused local terminal steady state should converge toward:

1. attach / PTY I/O
2. tmux control-mode observation and minimal apply
3. daemon diff apply (`bootstrap -> wait_for_changes -> apply`)
4. libghostty draw

The hot path should **not** depend on:

- app-wide 1-second `fetchAll()`
- terminal-unrelated sidebar churn
- one-shot tmux subprocess polling for focused navigation
- draw work for active but unchanged surfaces

### Remote fast path

Remote stays deferred until local parity is established. When resumed, the target
fast path is:

1. shared SSH transport
2. tmux control-mode on that transport
3. bootstrap-only inventory plus focused-host cache mutation

## Gates

### Gate-L: Local parity gate

Remote fast-path work must not begin until all of the following are satisfied on
the current host class:

- scroll p95 is within `1.25x` of native Ghostty + local tmux
- keypress-to-glyph p95 is within `1.15x`
- pane switch p95 is within `1.20x`
- idle CPU stays within `+3pt` of baseline
- `FetchAll` and `TmuxRunner` do not dominate the steady-state hot path

### Gate-R: Remote parity gate

After Gate-L, the remote follow-on target is:

- focused remote scroll p95 within `1.30x` of native Ghostty + ssh + remote tmux
- no fresh SSH handshake on the focused steady-state path
- no 1-second all-host polling while the focused remote tile is healthy
- focus and pane changes converge through control mode first, polling only when degraded

## PR Map Adapted To The Current Repo

The handover PR numbering remains useful, but some groundwork is already landed.

| PR | Topic | Repo status |
|---|---|---|
| `PR-00` | perf baseline / signpost fixed | `DONE` |
| `PR-01` | `LocalProjectionCoordinator` | `NEXT` |
| `PR-02` | startup/poll wiring: local off global hot path | `NEXT` |
| `PR-03` | remove terminal tile direct `AppViewModel` reads | equivalent work already landed in `T-PERF-P12` |
| `PR-04` | finish invalidation-domain split | equivalent groundwork already landed in `T-PERF-P12`; revisit only if `PR-01/02` expose drift |
| `PR-05` | `TerminalNavigationActor` and control-mode filtered path | `PLANNED` |
| `PR-06` | local fallback / command-broker hardening | `PLANNED` |
| `PR-07` | dirty-only draw | `PLANNED` |
| `PR-08` | render scheduler cleanup / multi-display audit | `PLANNED` |
| `Gate-L` | local parity gate | `BLOCKS PR-09+` |
| `PR-09` | `SSHConnectionBroker` | `DEFERRED` |
| `PR-10` | focused remote control-mode authority | `DEFERRED` |
| `PR-11` | remote inventory bootstrap-only + host QoS | `DEFERRED` |
| `PR-12` | tmux subscription path | `DEFERRED` |

## Kickoff Slice: PR-00

`PR-00` is intentionally infrastructure-first. The purpose is to make later
`fetchAll()` removal and authority migration measurable, not to claim the local
hot path is already fixed.

### Scope

- add missing signpost categories for navigation and remote SSH/control-mode work
- instrument the current control-mode send/connect path
- add feature-flagged SurfacePool count logging hooks for future dirty-only work
- add reproducible local perf artifacts under `docs/perf/` and `scripts/perf/`

### Non-goals

- no removal of the 1-second poller in this slice
- no truth-boundary change between daemon metadata and term presentation
- no remote transport redesign
- no helper-process or renderer swap

### Acceptance criteria

- `docs/60_tasks.md` and `docs/65_current.md` point to this track as the active phase
- perf artifacts exist and can be run locally without PR workflow assumptions
- the new signposts compile and appear in Instruments / `log stream --signpost`
- verification records a fresh `swift build` result before the task is considered done

## Follow-On Local Slices

### PR-01: LocalProjectionCoordinator

Create one local steady-state coordinator responsible for:

- `bootstrap -> waitForUIChangesV1 -> apply -> repeat`
- local health cadence
- store-oriented projection apply

The design constraint is explicit: this narrows the host architecture around the
daemon read model, but it does not demote daemon `sync-v3` truth.

### PR-02: Startup and polling rewiring

After `PR-01` exists:

- startup still performs one bounded initial sync
- local steady-state updates stop depending on the global `fetchAll()` loop
- remote fetch behavior may continue using the existing broad path until Gate-L

### PR-05 through PR-08

Only begin once `PR-01/02` verification is stable:

- move focused navigation handling out of the tile view lifecycle
- harden local fallback and command broker behavior
- introduce dirty-only draw
- polish render scheduling and multi-display behavior

## Guardrails

- If a future local-first change would alter `docs/40_design.md` product truth, escalate first.
- Do not describe local-first as a change from daemon truth to term truth; it is an implementation-order decision.
- Do not make `WorkbenchAreaV2.swift` a mandatory edit target for `PR-00`; that file currently carries unrelated uncommitted UI work.
