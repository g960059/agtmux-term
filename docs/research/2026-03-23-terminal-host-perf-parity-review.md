# Terminal Host Perf Parity Review

- **Date:** 2026-03-23
- **Snapshot:** `main` after `ace3440`

## One-Line Judgment

The product direction looks correct, but the current gap versus native Ghostty
is credible because the embedded host still owns too much cadence and lifecycle
on the hot path.

## What The Tree Currently Shows

### 1. `next` is still a transition path

- `TerminalHostModeRuntime` still falls back to `legacy` unless runtime
  override, env, or user defaults choose `next`.
- `TerminalHostContainer` explicitly labels `next` as a phase-1 boundary.
- `NextGhosttyIslandViewController` still retains pane controllers and keeps up
  to `4` of them alive.

## 2. The app still owns render scheduling

- `GhosttyApp.handleRender(...)` still receives render callbacks, bounces them
  to the main actor, marks surfaces dirty, and schedules direct draw passes.
- `tick()` still calls `ghostty_app_tick(...)` and then `runDirtyDrawPass()`.
- The dirty pass still iterates active surface views and calls back into the
  host view layer.

## 3. The terminal view still carries host-owned cadence

- `GhosttyTerminalView` still has `legacyHybrid` and `ghosttyOwned` cadence
  modes.
- The file still contains the host scroll draw pump, recovery probe, and
  immediate presentation draw paths.
- `ghostty_surface_draw(...)` still exists as a hot-path immediate draw.

## 4. Lifecycle remains more general than the mainline product needs

- `SurfacePool` still models `active -> backgrounded -> pendingGC -> defunct`
  with a timer-driven grace period.
- The mainline product is now one visible main terminal, but the underlying
  host path still carries generalized pane/surface retention logic.

## Benchmark Caveats

- The repo currently pins GhosttyKit to upstream Ghostty `v1.2.3` in
  `README.md`.
- Any native Ghostty comparison should use the same upstream version before
  concluding that the remaining gap is entirely host-side.
- Perf runs must also pin `AGTMUX_TERMINAL_HOST_MODE` explicitly. Too many
  local and test defaults still fall back to `legacy`.

## Recommended Measurement Points

1. Scroll input -> render request -> first draw -> layer present
2. Render callback count -> direct-draw scheduling count
3. `ghostty_app_tick(...)` and `runDirtyDrawPass()` p95/max on the main thread
4. `syncSurfaceMetrics(...)` churn during resize
5. Pane/surface retention churn in the one-main-terminal path

## Recommended Priority Order

1. Benchmark hygiene first:
   - match native and embedded Ghostty versions
   - force explicit `legacy` and `next` host modes during perf runs
2. Reduce app-owned cadence in `GhosttyApp`
3. Remove steady-state immediate draw and host scroll pumping from `next`
4. Special-case the one-main-terminal path to one visible controller/surface
5. Only then consider flipping the default host mode away from `legacy`

## First Deterministic Loaded-Viewport Finding

After the first counter pass, the loaded-viewport parity wrapper now surfaces
both app-side and view-side ownership counters. After the timing pass, the
same wrapper also surfaces app-side `ghostty_app_tick(...)` and
`runDirtyDrawPass()` summaries.

Single deterministic `legacy` vs `next` runs on 2026-03-23 have shown mixed
latency deltas, including one run where `next` lost by about `52.3ms` and a
later run where `next` won by about `63.7ms`. The stable narrowing from those
passes is not the single-run latency number; it is the ownership profile:

- app-side scheduler counters stayed flat on both sides:
  - `appRenderCallbackCount = 0`
  - `appScheduledDirectDrawPassCount = 0`
  - `appImmediateDirectDrawPassCount = 0`
  - `appDirtyDrawPassCount = 0`
- app-side timing summaries also stayed empty on both sides:
  - `appGhosttyAppTickSampleCount = 0`
  - `appDirtyDrawPassDurationSampleCount = 0`
- view-side render-request counters also stayed flat on both sides:
  - `scrollRenderRequestCount = 0`
  - `scrollRefreshDrawRequestCount = 0`
- the only ownership delta in that run was
  `scrollImmediatePresentationDrawCount`:
  - `legacy = 16`
  - `next = 0`

This does not prove root cause yet, but it does narrow the deterministic
loaded-viewport gap away from `GhosttyApp` direct-draw scheduling and tick
ownership and toward `GhosttyTerminalView`'s host scroll-presentation
behavior.

## Resize/Lifecycle Counter Follow-Up

The next counter pass extended the same loaded-viewport parity wrapper with:

- `syncSurfaceMetrics(...)` churn counters
- `SurfacePool` lifecycle counters
- next-host pane-retention counters

A later deterministic single run on 2026-03-23 still showed mixed latency,
with `next` winning that run by about `80.4ms` on
`first_changed_elapsed_ms`. But the new counters also stayed flat on both
sides:

- resize churn stayed idle:
  - `metricsSyncAppliedCount = 0`
  - `metricsSyncNoopCount = 0`
  - `metricsSyncMarkDirtyCount = 0`
  - `metricsSyncSizeUpdateCount = 0`
- `SurfacePool` lifecycle stayed idle:
  - `surfacePoolRegisterCount = 0`
  - `surfacePoolActivateCount = 0`
  - `surfacePoolBackgroundCount = 0`
  - `surfacePoolScheduleGCCount = 0`
  - `surfacePoolMarkDirtyCount = 0`
  - `surfacePoolMarkDirtyForDirectDrawCount = 0`
  - `surfacePoolDirtyActiveConsumedSurfaceCount = 0`
- next-host pane retention stayed idle:
  - `nextHostCreateCount = 0`
  - `nextHostPromoteCount = 0`
  - `nextHostEvictCount = 0`
  - `nextHostMaxRetainedPaneControllerCount = 0`

So the deterministic loaded path still is not exercising resize churn,
generalized surface lifecycle churn, or pane-retention churn. That narrows the
next measurement step further: these counters need to be driven from live
scroll, resize, or retarget scenarios before they can explain the native
parity gap.

## Live Host-Mode Readiness Recovery

The first live-host blocker turned out not to be a perf counter issue. It was
readiness churn across the file bridge:

- the shell-side perf helpers were issuing short synchronous requests and then
  forgetting late per-id results
- the UITest bridge was also spawning overlapping command-loop tasks during
  runtime-config reconciliation, so the same command file could be processed
  more than once

Those two fixes moved the live bench materially forward:

- the shell helpers now keep one async request alive until the overall
  readiness deadline instead of discarding late results
- `UITestTmuxBridge` now runs the command loop as a single-flight task, and a
  regression test locks that in
- `UITestTmuxBridge` now also atomically claims the command file before decode,
  so multiple bridge consumers cannot race the same request id and later write
  conflicting results

After those fixes, the direct live `legacy` run against
`gate-normal-scroll/%1` reached the measured burst again on 2026-03-24:

- `changed_sample_count = 12`
- `first_changed_elapsed_ms ≈ 739.4`
- stage log reached `viewport-primed`, `initial-bench-done`, and
  `initial-post-scroll-telemetry`
- the same run no longer showed duplicate request/response ids in the bridge
  log

That means the previous blocker was a false blocker in the live readiness
layer, not the underlying scroll path.

## Live `next` Recovery

The next live blocker on 2026-03-24 turned out to be harness isolation and
timeout budgeting, not the `next` scroll path itself.

### 1. Competing app instances were reading the same stable bridge paths

Repeated failing runs showed all of these at once:

- many leftover successful `__agtmux_dump_active_terminal_target__` payloads
- duplicate command-loop request ids in `bridge-debug.log`
- focus-host registration snapshots whose `mainTerminalSurfaceID` did not
  match the tile returned by `open_terminal_for_pane`

That combination is inconsistent with a single `MainTerminalStore`. The
practical root cause was a second `AgtmuxTerm` process: the already-running
installed app was still reading the same stable bridge defaults as the freshly
launched debug build.

Once the live harness terminated all `AgtmuxTerm` instances before a direct
bundle launch, the duplicate request ids disappeared and the registration
snapshot stopped drifting to a different main-terminal surface.

### 2. `focus_terminal_host` was budgeted below the registration wait

The live bench still invoked `__agtmux_focus_terminal_host__` with a fixed
`10s` timeout even when `AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS`
was configured to `15000`.

That meant a legitimate bridge-side registration wait could outlive the shell
timeout and be reported as a harness failure. The bench now derives its
focus-host timeout from the larger of the settle timeout and the registration
budget, plus a small cushion.

### 3. Result after both fixes

After the instance-isolation and timeout-budget fixes:

- direct live `next` launches against `gate-normal-scroll/%1` reached
  measurement again
- fresh-launch runs also stopped waiting for an impossible active target on the
  plain-shell startup path; the harness now opens the requested pane first and
  only falls back to active-target probing if that open fails
- one recovered direct run produced:
  - `changed_sample_count = 13`
  - `first_changed_elapsed_ms ≈ 536.6`
- the live `legacy` vs `next` parity wrapper passed again with:
  - `valid = true`
  - `passed = true`
  - `legacy.changed_sample_count = 13`
  - `next.changed_sample_count = 14`
  - `first_changed_elapsed_delta_ms ≈ -178.0`
- the recovered `next` bridge log no longer showed duplicate request ids

This means the old live `next` blocker was another readiness false blocker.
The next remaining work is the actual parity program against native Ghostty,
not more bridge-launch triage.

## First Matched-Version Native Table

The first combined `legacy` / `next` / native table ran on 2026-03-24 via
`scripts/perf/gate_l_terminal_host_scroll_parity_table.sh`.

That wrapper now:

- records embedded GhosttyKit metadata from `GhosttyKit/.ghostty-source-ref`
- records native Ghostty metadata from the selected `Ghostty.app`
- refuses version-mismatched runs by default
- combines:
  - the live `legacy` vs `next` host-mode parity result
  - the native-vs-embedded up-scroll step parity result for `legacy`
  - the native-vs-embedded up-scroll step parity result for `next`

The first measured table used vendored native Ghostty `1.2.3` to match the
embedded GhosttyKit `1.2.3`.

### Result

- version match: `true`
- live host-mode parity: `valid = true`, `passed = true`
- native-vs-embedded step parity:
  - `legacy.gate.passed = true`
  - `next.gate.passed = true`
- representative deltas:
  - `legacy first_changed_elapsed_p50_delta_ms ≈ -0.11`
  - `next first_changed_elapsed_p50_delta_ms ≈ -0.38`
  - `next_minus_legacy first_changed_elapsed_p95_delta_ms ≈ -13.6`
  - all coarse step and row-size deltas were `0`

### Interpretation

This is a useful benchmark-hygiene milestone, but it does **not** explain the
reported “native feels 60fps, embedded feels 5fps” complaint.

The reason is structural:

- the new table compares step granularity and first visible change
- it does not measure presentation cadence directly
- the native companion for this path still only exposes tmux-visible movement,
  not layer-present cadence inside Ghostty

So the first table narrows one class of defect:

- the current matched-version harness does not show a step-size or first-step
  regression versus native Ghostty

But it leaves the next question open:

- whether the remaining perceived gap is in continuous presentation cadence,
  not in step size or first visible movement

That makes the next measurement slice more specific: add a cadence-sensitive
parity table instead of overfitting the current step gate.

## Scope Boundary

This is a terminal-host performance investigation, not a product-direction
change. The terminal-first embedded Ghostty cockpit remains the intended
mainline UX.
