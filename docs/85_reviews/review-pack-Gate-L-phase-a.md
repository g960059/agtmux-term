# Review Pack

## Objective
- Task: `Gate-L` phase A
- User story: establish a reproducible repo-local measurement lane for local parity evidence before any remote fast-path follow-on
- Acceptance criteria touched:
  - `pane switch p95 is within 1.20x`
  - `idle CPU remains within +3pt of baseline`
  - `FetchAll and TmuxRunner are no longer dominant on the focused local steady-state path`

## Summary
- Added a repo-local measurement lane that does not depend on XCUITest automation mode.
- `UITestTmuxBridge` now exposes `__agtmux_open_terminal_for_pane__`, which drives the same `workbenchStoreV2.openTerminal(for:hostsConfig:)` path as a sidebar pane-row click.
- Added new perf scripts:
  - `gate_l_signpost_summary.sh`
  - `gate_l_idle_sample.sh`
  - `gate_l_pane_switch_bench.sh`
  - `gate_l_native_ghostty_probe.sh`
  - shared `gate_l_common.sh`
- Closed the two remaining false-green findings from the first review round:
  - idle CPU no longer averages decaying `ps %cpu`; it now uses `top` delta samples
  - signpost and pane-switch summaries now use nearest-rank `p95` instead of floor-biased indexing
- Closed the pane-switch product red in the same repo-local lane:
  - `WorkbenchFocusedNavigationActor` no longer treats session-scoped control-mode payloads as canonical pane truth
  - after a control-mode send, the focused path now re-reads exact rendered-client truth via `liveTarget(renderedClientTTY:...)`
  - post-send exact-client readback now retries transient `renderedClientUnavailable` misses
  - focused regression coverage locks startup seeding, transient reread miss, and post-send reconcile when no useful follow-up event arrives
- Fresh host evidence is now executable and green for the repo-local pane-switch proxy path:
  - idle CPU sample and unified-log signpost summary pass
  - pane-switch proxy bench now returns a valid latency sample (`p95_ms = 2339.612`) instead of timing out on rendered `%1` / selected `%0`
  - the proxy contract is now explicit:
    - it is a 2-pane internal-bridge harness, not the final 4-pane/sidebar-click Gate-L proof
- Gate-L is intentionally still open because the final same-host parity numbers are not captured yet, even though native Ghostty input automation is now green on this host

## Change scope
- `Sources/AgtmuxTerm/WorkbenchFocusedNavigationActor.swift`
- `Sources/AgtmuxTerm/UITestTmuxBridge.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchFocusedNavigationActorTests.swift`
- `scripts/perf/gate_l_common.sh`
- `scripts/perf/gate_l_signpost_summary.sh`
- `scripts/perf/gate_l_idle_sample.sh`
- `scripts/perf/gate_l_pane_switch_bench.sh`
- `scripts/perf/gate_l_native_ghostty_probe.sh`
- `scripts/perf/gate_l_native_ghostty_input_smoke.sh`
- `docs/60_tasks.md`
- `docs/65_current.md`
- `docs/70_progress.md`
- `docs/90_index.md`
- `docs/perf/local_parity_baseline.md`

## Verification evidence
- Commands run:
  - `zsh -n scripts/perf/gate_l_idle_sample.sh scripts/perf/gate_l_signpost_summary.sh scripts/perf/gate_l_pane_switch_bench.sh scripts/perf/gate_l_common.sh` => PASS
  - `HOME=$PWD/.codex-tmp/home CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/swiftpm-module-cache swift build --disable-sandbox` => PASS
  - `HOME=$PWD/.codex-tmp/home CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/swiftpm-module-cache swift test --disable-sandbox --filter WorkbenchFocusedNavigationActorTests` => PASS (`15` tests, `0` failures)
  - `HOME=$PWD/.codex-tmp/home CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/swiftpm-module-cache swift test --disable-sandbox --skip AppViewModelLiveManagedAgentTests` => PASS (`339` tests, `0` failures)
  - `scripts/perf/gate_l_idle_sample.sh --pid 49078 --duration 5 --interval 1` => PASS
    - CPU method: `top delta samples`
    - avg CPU `0.12%`, max CPU `0.2%`, avg memory `35 MiB`
  - `scripts/perf/gate_l_signpost_summary.sh --start 2026-03-13 04:43:29-0700 --end 2026-03-13 04:44:29-0700 --pid 49078` => PASS
    - non-empty interval summary returned for the current local app pid
    - this focused rerun validates the script path after the percentile fix; it is not a native-parity claim
  - `scripts/perf/gate_l_signpost_summary.sh --start 2026-03-13 04:43:29-0700 --end 2026-03-13 04:44:29-0700 --pid 999999` => FAIL LOUDLY
    - `No signpost events matched predicate: subsystem == "local.agtmux.term" and processID=999999`
  - `scripts/perf/gate_l_pane_switch_bench.sh --iterations 4 --timeout 20` => PASS
    - proxy contract only: 2-pane session + `__agtmux_open_terminal_for_pane__`; not final sidebar-click parity
    - `latencies_ms = [2326.994, 2339.612, 2274.681, 2257.631]`
    - `p50_ms = 2274.681`
    - `p95_ms = 2339.612`
    - `max_ms = 2339.612`
    - signpost window shows `NavigationSync` activity plus `TmuxRunner total_ms = 1.539`, `p95_ms = 0.144`
    - `FetchAll` is absent from the captured pane-switch signpost window
  - `zsh -n scripts/perf/gate_l_native_ghostty_probe.sh scripts/perf/gate_l_native_ghostty_input_smoke.sh` => PASS
  - `scripts/perf/gate_l_native_ghostty_probe.sh` => PASS
    - `app_path = vendor/ghostty/zig-out/Ghostty.app`
    - `launch.ok = true`
    - `activation.ok = true`
    - `key_injection.ok = true`
  - `scripts/perf/gate_l_native_ghostty_input_smoke.sh --timeout 15` => PASS
    - tmux capture matches the wrapped receive-marker pattern `__GATE_L_RECV__:\s*a`
    - helper send JSON records `trusted = true`, `sent = true` for both `a` and `Return`
- Notes:
  - there is still no `/Applications` Ghostty install on this host, but the vendored native bundle is launchable and sufficient for same-host baseline sourcing
  - `xcodebuild` macOS UI automation remains blocked by `Timed out while enabling automation mode`, so this slice intentionally avoids XCUITest as the measurement runner

## Risk declaration
- Breaking change: no
- Fallbacks: none; the pane-switch bench fails loudly on non-convergence
- Known gaps / follow-ups:
  - capture scroll / keypress / idle side-by-side against the vendored native Ghostty baseline now that native input automation is available

## Reviewer request
- Provide verdict: `GO` / `GO_WITH_CONDITIONS` / `NO_GO` / `NEED_INFO`
- Review for:
  - false-green risk in the new measurement scripts
  - correctness of the new `UITestTmuxBridge` internal command as a sidebar-click proxy
  - regression risk in the post-send exact-client readback added to `WorkbenchFocusedNavigationActor`
  - whether the documented Gate-L state matches the executed evidence

## Review outcome
- Codex re-review 1: `GO`
- Codex re-review 2: `GO_WITH_CONDITIONS`
  - conditions were:
    - retry transient post-send reread misses in `WorkbenchFocusedNavigationActor`
    - document the pane-switch harness as a proxy instead of a final sidebar-click parity proof
- Codex re-review 3: `GO`
  - prior conditions are now closed on code, tests, and docs
