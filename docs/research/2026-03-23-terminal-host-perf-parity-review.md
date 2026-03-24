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
both app-side and view-side ownership counters. One deterministic
`legacy` vs `next` run on 2026-03-23 produced this first narrowing:

- `next` lost to `legacy` by about `52.3ms` on `first_changed_elapsed_ms`
- app-side scheduler counters stayed flat on both sides:
  - `appRenderCallbackCount = 0`
  - `appScheduledDirectDrawPassCount = 0`
  - `appImmediateDirectDrawPassCount = 0`
  - `appDirtyDrawPassCount = 0`
- view-side render-request counters also stayed flat on both sides:
  - `scrollRenderRequestCount = 0`
  - `scrollRefreshDrawRequestCount = 0`
- the only ownership delta in that run was
  `scrollImmediatePresentationDrawCount`:
  - `legacy = 16`
  - `next = 0`

This does not prove root cause yet, but it does narrow the first deterministic
loaded-viewport gap away from `GhosttyApp` direct-draw scheduling and toward
`GhosttyTerminalView`'s host scroll-presentation behavior.

## Scope Boundary

This is a terminal-host performance investigation, not a product-direction
change. The terminal-first embedded Ghostty cockpit remains the intended
mainline UX.
