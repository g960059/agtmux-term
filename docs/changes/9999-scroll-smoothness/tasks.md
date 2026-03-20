# Tasks

- [x] implementation
- [x] tests
- [x] durable-knowledge promotion
- [ ] remove `docs/changes/9999-scroll-smoothness/` before merge

## 2026-03-18 verification

- `swift build -c debug --build-path .build-codex`
- `swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests`
- `swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|WorkbenchV2TerminalRestoreTests|WorkbenchV2TerminalAttachTests'`
- `swift test --build-path .build-codex --filter 'WorkbenchGhosttyIslandTests|WorkbenchV2TerminalAttachTests|GhosttyTerminalSurfaceRegistryTests|WorkbenchFocusedNavigationActorTests'`
- `./scripts/dev/validate-macos-ci.sh`
- `swift test --build-path .build-codex`
- `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AgtmuxTermUITests CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO`
- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:'AgtmuxTermUITests/AgtmuxTermUITests/testAppLaunchShowsSidebar' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO`
- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AgtmuxTermUITests CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO` after granting automation permission
- `scripts/perf/gate_l_ax_key_sender.sh --dry-run`
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding layer-present telemetry
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding coalesced synchronous scroll draw
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding the active-scroll draw pump
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` for the best-known installed app
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after surfacing scroll-presentation draw telemetry
- `zsh -n scripts/perf/gate_l_trackpad_history_scroll_bench.sh`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding burst-level telemetry slices
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` after adding burst-level telemetry slices
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding scheduler-lateness telemetry slices
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` after adding scheduler-lateness telemetry slices
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after reinstalling the telemetry-instrumented release app
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` to stress longer burst trains
- `cd ../agtmux && cargo build -p agtmux --release >/dev/null && cd ../agtmux-term && xcodegen generate --spec project.yml >/dev/null && xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath "$PWD/build" CONFIGURATION_BUILD_DIR="$PWD/build/Release" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=NO AGTMUX_BIN="$PWD/../agtmux/target/release/agtmux" build`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding the delayed-present recovery probe
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` twice after reinstalling the release app
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_scroll_bench.sh --iterations 5`
- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh --iterations 5`
- `zsh -n scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh`
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-embedded-trackpad-proxy-serial.json`
- `scripts/perf/gate_l_native_ghostty_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-native-trackpad-proxy-serial.json`
- `./scripts/perf/gate_l_ax_key_sender.sh --dry-run --scroll-pixels -24 --scroll-repeat 6 --scroll-phase-mode trackpad-burst`
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-release-phase-begin-4.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-release-phase-begin-8-serial.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-release-phaseoff-8.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-release-phaseoff-4.json`
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-native-cadence AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-native-cadence-release-4.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-native-cadence-release-8.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-phase-aware-4.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-phase-aware-8.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4 > /tmp/agtmux-present-aware-4.json`
- `AGTMUX_PERF_APP_BIN="$PWD/build-native-cadence/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8 > /tmp/agtmux-present-aware-8.json`

## 2026-03-18 validation notes

- `./scripts/dev/validate-macos-ci.sh` passed.
- `swift test --build-path .build-codex` executed 394 tests and failed only in
  `AppViewModelLiveManagedAgentTests/testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed`
  because `assertClaudePromptExecutionReady()` saw `claude -p` fail/timeout
  before the app assertions ran.
- `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
  passed with 383 tests and 0 failures.
- Both the full UI E2E rerun and a single-test rerun for
  `testAppLaunchShowsSidebar` failed before test execution with
  `Timed out while enabling automation mode`.
- The failing UI result bundles are:
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_06-56-52--0700.xcresult`
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_06-59-04--0700.xcresult`
- After granting automation permission, the same full UI E2E command executed
  successfully and returned to the expected repo state: 35 tests, 6 skipped,
  1 failure.
- The lone remaining UI failure is
  `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`,
  where the app row reaches `presence=managed, provider=codex, primary=running`
  but never surfaces freshness metadata after the Codex pane settles.
- The latest rerun bundle is:
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_07-06-04--0700.xcresult`
- An active-scroll draw pump improved the full-app debug bench to
  `scroll_to_layer_present_ms p50 6.057 / p95 20.330 / max 21.731`.
- The best-known installed-app result after restoring the non-regressed build is
  `scroll_to_layer_present_ms p50 2.485 / p95 15.514 / max 44.934`.
- A present-aware immediate-draw throttle then improved the installed app to
  `scroll_to_layer_present_ms p50 2.624 / p95 22.626 / max 35.337`, reducing
  the worst spike while keeping median latency low.
- A delayed-present recovery probe at `1/180s` tightened the active-burst path:
  - debug sample:
    `scroll_to_layer_present_ms p50 7.020 / p95 22.023 / max 22.955`
  - release bundle sample:
    `scroll_to_layer_present_ms p50 4.734 / p95 21.600 / max 27.223`
  - installed app reruns after reinstall:
    `p50 2.992 / p95 23.941 / max 44.818` and
    `p50 3.562 / p95 24.004 / max 35.325`
- The accepted telemetry-only follow-up now exposes
  `scroll_presentation_draw_gap_*` and `scroll_presentation_draw_count` in the
  full-app bench while leaving pacing behavior unchanged.
- On the accepted telemetry build, the current best-known short-burst numbers
  are:
  - release bundle:
    `scroll_to_first_draw_ms p50 0.258 / p95 11.328 / max 14.881`
    `scroll_to_layer_present_ms p50 6.619 / p95 13.405 / max 16.454`
  - installed app:
    `scroll_to_first_draw_ms p50 0.205 / p95 11.481 / max 16.815`
    `scroll_to_layer_present_ms p50 1.936 / p95 12.991 / max 19.428`
- A longer 8-burst installed stress run still shows tail spikes:
  `scroll_to_first_draw_ms p50 0.243 / p95 24.762 / max 54.035`
  `scroll_to_layer_present_ms p50 2.107 / p95 26.922 / max 55.768`
- Two additional experiments were rejected after measurement:
  - a `commonModes` run-loop timer for the draw pump regressed release cadence
  - a relaxed immediate-draw throttle regressed installed-app `p95/max`
  - moving the delayed-present recovery probe earlier to `1/240s` regressed the
    debug burst path to `p50 3.319 / p95 17.692 / max 35.651`
  - shortening the draw-pump tail to `0.12s` regressed the release-bundle
    8-burst sample to `scroll_to_layer_present_ms p50 2.277 / p95 30.084 / max 77.817`
  - slowing the draw-pump interval to `1/100s` regressed the release-bundle
    8-burst sample to `scroll_to_layer_present_ms p50 2.124 / p95 40.836 / max 123.922`
- Burst-level telemetry is now sliced per burst in the full-app bench, which
  exposed that the long-tail spikes in the accepted release path cluster in the
  alternating `up` bursts rather than spreading evenly across the train.
- Three later experiments were explicitly rejected after those burst slices were
  added:
  - inline first-draw execution regressed both `4-burst` and `8-burst`
    release-bundle samples
  - direction-change cadence resets produced apparently good `8-burst` numbers
    only by changing the visible-line path itself, so they were treated as
    false wins
  - backlog-aware recovery redraws regressed both `4-burst` and `8-burst`
    release-bundle samples
  - backlog-aware immediate-throttle bypass also failed to produce a clear net
    win: `0.85x`, `0.90x`, and `0.95x` frame-age thresholds each improved one
    side of the tradeoff while regressing the other. The best long-burst sample
    (`0.85x`) reached `scroll_to_layer_present_ms p50 2.155 / p95 22.527 / max 49.470`
    on release `8-burst`, but its paired `4-burst` run regressed to
    `p50 4.817 / p95 17.756 / max 24.291`, so the change was rejected.
- The accepted scheduler telemetry follow-up showed:
  - baseline release bundle, 8 bursts:
    `scroll_to_layer_present_ms p50 9.082 / p95 26.610 / max 55.803`
    `scroll_presentation_immediate_queue_delay_ms p50 0.193 / p95 0.285 / max 0.296`
    `scroll_presentation_pump_wake_lateness_ms p50 1.145 / p95 9.432 / max 206.878`
    `scroll_presentation_recovery_probe_wake_lateness_ms p50 3.295 / p95 15.025 / max 210.987`
  - interpretation:
    immediate queue delay stayed tiny while the worst `up` bursts lined up with
    very large pump/recovery wake-lateness spikes
- Four more pacing ideas were measured and rejected after that telemetry:
  - overdue-pump immediate-draw bypass:
    release `8-burst` moved to `p50 10.173 / p95 29.304 / max 55.283`
    and was rejected
  - one-shot `RunLoop.main` `.common` timers for draw pump / recovery:
    release `8-burst` regressed to `p50 9.438 / p95 27.809 / max 160.401`
  - limiting delayed-present recovery probes to immediate draws only:
    release `8-burst` improved `max` to `36.810` but `4-burst` stayed noisy at
    `p50 4.203 / p95 16.598 / max 38.696`, so it was rejected
  - bypassing the throttle after two pending scroll inputs:
    release `8-burst` reached `p50 1.937 / p95 28.526 / max 31.426`, but the
    paired `4-burst` sample regressed hard to
    `p50 2.363 / p95 28.538 / max 34.824`, so it was also rejected
- Three later wake-path experiments were also rejected after measurement:
  - replacing the timer wakeups with view-scoped `NSView.displayLink(...)`
    callbacks regressed release `4-burst` to
    `p50 1.791 / p95 46.401 / max 48.806`
  - moving the timer wakeups onto a background queue and hopping back to the
    main run loop via `CFRunLoopPerformBlock(... commonModes ...)` improved some
    wake-lateness slices but still regressed release `8-burst` to
    `p50 8.224 / p95 44.481 / max 144.741`
  - rescheduling pump / recovery timers after every successful draw also
    reduced wake-lateness telemetry but still regressed the user-visible path
    to release `4-burst p50 7.340 / p95 23.081 / max 23.868` and
    `8-burst p50 8.124 / p95 41.497 / max 90.814`
- A same-input native companion bench now exists for the transcript-style
  pixel-burst path, and fresh serial reruns on 2026-03-19 confirmed that the
  `tmux_visible_line_change_ms` proxy is effectively identical between
  embedded and native:
  - embedded `/Applications/AgtmuxTerm.app`:
    `p50 567.724 / p95 583.263 / max 583.263`
  - native `/Applications/Ghostty.app`:
    `p50 575.531 / p95 578.756 / max 578.756`
  - interpretation:
    the tmux-visible-line proxy is blind to the remaining user-visible jank,
    so future native parity work needs a presentation-path metric rather than
    more proxy tuning
- An attempted apples-to-apples screen/image-diff parity bench was blocked on
  this host because `screencapture` failed with
  `could not create image from display`, which indicates the current terminal
  environment does not have usable Screen Recording capability.
- A phase-aware synthetic trackpad sender (`--scroll-phase-mode trackpad-burst`)
  is now available, and the accepted runtime follow-up uses only the
  `event.phase == .began` edge to invalidate stale pump/recovery timers.
- A more aggressive phase/momentum continuation-deadline variant was measured
  and rejected. On release it regressed to:
  - `4-burst scroll_to_layer_present_ms p50 3.338 / p95 43.484 / max 53.892`
  - `8-burst scroll_to_layer_present_ms p50 2.859 / p95 69.332 / max 146.293`
- With the same phase-aware harness but without the runtime invalidation, the
  release comparison point was:
  - `4-burst scroll_to_layer_present_ms p50 2.390 / p95 30.491 / max 52.183`
  - `8-burst scroll_to_layer_present_ms p50 4.686 / p95 51.290 / max 176.185`
- The accepted `phase.began` invalidation improved that release A/B to:
  - `4-burst scroll_to_layer_present_ms p50 4.009 / p95 16.917 / max 24.102`
  - `8-burst scroll_to_layer_present_ms p50 3.991 / p95 49.586 / max 115.386`
- A later follow-up kept the phase-aware sender but also invalidated stale
  pending immediate draws at `event.phase == .began`, so a new burst can queue
  its own immediate draw instead of waiting behind an older coalesced block.
- The latest serial release samples on this host after that follow-up were:
  - `4-burst scroll_to_layer_present_ms p50 3.032 / p95 29.512 / max 46.259`
  - `8-burst scroll_to_layer_present_ms p50 6.518 / p95 28.570 / max 69.155`
- A temporary A/B that removed the pending-draw invalidation again was not
  kept. The focused scheduler regression test failed immediately, and the
  ad-hoc benchmark reruns produced empty bursts / worse variance, so the branch
  stays on the pending-draw invalidation version.
- Same-window pane-switch flicker mitigation is now in the worktree:
  - the Ghostty island schedules a pane-retarget presentation refresh on the
    existing surface when the visible pane target changes without an attach
    command change
  - the sidebar no longer animates its auto-scroll on pane-selection changes
- `swift test --build-path .build-codex --filter 'WorkbenchGhosttyIslandTests|WorkbenchV2TerminalAttachTests|GhosttyTerminalSurfaceRegistryTests|WorkbenchFocusedNavigationActorTests'`
  passed with 39 tests and 0 failures.
- A targeted metadata-enabled UI rerun for
  `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux` built the app and
  test bundle successfully but failed before test execution with
  `Timed out while enabling automation mode`.
- The latest UI rerun bundle is:
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.19_06-12-13--0700.xcresult`

## 2026-03-19 native-cadence replanning follow-up

- A vendor/code review of native Ghostty and cmux reinforced the same design
  direction: keep the AppKit scroll input path thin and push cadence ownership
  back toward the renderer / display-linked wake path instead of layering more
  host-side timers.
- The first active-gesture-only continuation cutoff was measured and rejected:
  - `4-burst`: `scroll_to_layer_present_ms p50 4.721 / p95 10.828 / max 11.451`
    but with `empty_burst_count 2`
  - `8-burst`: `scroll_to_layer_present_ms p50 4.508 / p95 127.399 / max 240.782`
- A second variant that deferred all precise steady-state changed events to a
  single input-recovery probe was also rejected:
  - `4-burst`: `scroll_to_layer_present_ms p50 7.453 / p95 24.636 / max 48.092`
  - `8-burst`: `scroll_to_layer_present_ms p50 7.454 / p95 39.471 / max 57.612`
  - alternating `up` bursts still dominated the tail
- A third present-aware defer variant improved the short path but regressed the
  long path badly, so it was also rejected:
  - `4-burst`: `scroll_to_layer_present_ms p50 5.262 / p95 10.579 / max 11.592`
    with `empty_burst_count 2`
  - `8-burst`: `scroll_to_layer_present_ms p50 3.793 / p95 116.754 / max 157.261`
- The common pattern across all three rejected native-cadence subsets is that
  `down` bursts stayed near `10-12ms`, while alternating `up` bursts exploded
  into `27-157ms` tails once host immediate draws were reduced too far.
- After rejecting those variants, runtime code was returned to the pre-experiment
  baseline and `swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests`
  was rerun green.

## 2026-03-19 production-path telemetry gating

- `GhosttyTerminalView` now keeps scroll telemetry disabled by default in normal
  app launches and only enables it under `AGTMUX_UITEST`, XCTest, or an
  explicit `AGTMUX_SCROLL_TELEMETRY=1` override.
- This keeps the full perf/UI harness intact while removing per-event
  signposts and sample-array appends from the user scroll hot path.
- Validation:
  - `swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests`
  - `./scripts/dev/validate-docs.sh`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- Production-mode smoke:
  - `AGTMUX_SCROLL_TELEMETRY=0 AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" ./scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - result:
    `tmux_visible_line_change_ms p50 584.144 / p95 590.875 / max 590.875`
  - expected effect:
    all scroll telemetry metrics drop to `count: 0` while the bench still
    completes and captures the proxy path
- Telemetry-enabled rerun on the same release build stayed noisy:
  - `AGTMUX_PERF_APP_BIN="$PWD/build/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" ./scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - result:
    `scroll_to_layer_present_ms p50 5.346 / p95 39.518 / max 53.005`
    `tmux_visible_line_change_ms p50 568.004 / p95 576.575 / max 576.575`
- This follow-up is therefore accepted as a production overhead reduction, not
  as a measured presentation-seam win.

## 2026-03-19 native-cadence replan

- The current branch has likely reached the limit of local host-scheduler
  tuning. Short bursts improved, but long-burst tail spikes still remain and
  recent mixed experiments that partially swapped forced draws for queued
  refreshes regressed the long path instead of converging on native parity.
- Replan decision:
  - keep the current host-side scheduler work as the fallback baseline
  - stop treating timer/pump tuning as the primary path to parity
  - make the next wave structural and native-cadence-led, with the host only
    compensating for explicit host-owned seams such as pane retarget, attach,
    activate, and delayed recovery
- Native Ghostty remains the reference shape:
  - thin AppKit scroll input path
  - precision/momentum forwarded into libghostty
  - renderer/display-link cadence ownership instead of host timer ownership
- The next implementation wave should be judged on user-visible presentation
  metrics first and the tmux visible-line proxy second, because the proxy has
  already reached near parity without matching the remaining real UI jank.

## 2026-03-20 renderer-owned structural wave

- Rebuilt GhosttyKit from a fresh `v1.2.3` checkout plus the current
  aggregate Ghostty patch
  temp checkout after each vendor change and revalidated clean patch
  applicability against a fresh upstream clone.
- Validation stayed green on each measured variant:
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-native-cadence AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- Three stricter renderer-owned variants were measured and all were rejected:
  - display-link active-session branch:
    `4-burst scroll_to_layer_present_ms p50 16.611 / p95 50.387 / max 71.750`
    `8-burst scroll_to_layer_present_ms p50 25.430 / p95 124.453 / max 392.601`
  - renderer wakeup plus display-link fallback branch:
    `4-burst scroll_to_layer_present_ms p50 25.089 / p95 92.284 / max 395.373`
    `8-burst scroll_to_layer_present_ms p50 17.730 / p95 94.427 / max 378.578`
  - pure upstream `scrollViewport -> queueRender -> display-link draw` branch:
    `4-burst scroll_to_layer_present_ms p50 24.039 / p95 88.319 / max 117.684`
    `8-burst scroll_to_layer_present_ms p50 26.922 / p95 270.136 / max 378.850`
- The pure upstream path was the clearest negative result:
  - `down` bursts stayed mostly healthy
  - `up` bursts exploded to `p50 74.245 / p95 327.194 / max 378.850` on `8-burst`
- Current inference:
  - removing host cadence ownership alone is not sufficient
  - the remaining limiter is more likely `up` scrollback rebuild cost inside
    embedded Ghostty's `updateFrameData()` / viewport-change path than host
    timer policy itself
- The next replan should therefore target renderer/update-frame cost on
  alternating `up` bursts instead of more scheduler ownership experiments.

## 2026-03-20 vendor update-frame follow-up

- Focused on the new dominant seam from the rejected renderer-owned branches:
  redundant `updateFrame()` / `rebuildCells(...)` work during repeated
  host-driven draws when the viewport itself has not changed.
- Validation remained green on the current vendor checkout:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-root AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
- First rejected attempt:
  - also relaxed the first-`up` viewport-shift guard and replaced full-screen
    dirty-bit clearing with fringe-row-only clearing
  - result:
    `4-burst scroll_to_layer_present_ms p50 8.817 / p95 61.803 / max 82.141`
    `8-burst scroll_to_layer_present_ms p50 9.657 / p95 60.814 / max 132.388`
- Second rejected attempt:
  - kept the first-`up` relaxation but widened dirty clearing to viewport pages
    instead of only the exposed fringe
  - result:
    `4-burst scroll_to_layer_present_ms p50 8.891 / p95 62.591 / max 88.392`
    `8-burst scroll_to_layer_present_ms p50 9.288 / p95 57.770 / max 114.206`
- Accepted follow-up:
  - keep the earlier live-screen/no-clone fast path
  - add a no-op short-circuit in `renderer/generic.zig` so repeated draws skip
    `rebuildCells(...)` entirely when all of these are unchanged:
    viewport row, bottom-ness, mouse state, cursor style, dirty bits,
    selection/preedit, and kitty/image state
  - store the last mouse/cursor state alongside the cached viewport
- Accepted serial release sample on this host:
  - `4-burst scroll_to_layer_present_ms p50 8.068 / p95 23.153 / max 24.423`
  - `8-burst scroll_to_layer_present_ms p50 9.407 / p95 28.712 / max 30.561`
- Baseline it beat:
  - `4-burst scroll_to_layer_present_ms p50 8.561 / p95 37.247 / max 109.972`
  - `8-burst scroll_to_layer_present_ms p50 8.982 / p95 53.995 / max 146.282`
- Current inference:
  - the previous renderer-owned replans were right that the remaining gap lived
    below the host scheduler
  - but the first real net win came from deleting redundant embedded renderer
    work on identical viewport redraws, not from changing cadence ownership

## 2026-03-20 provenance repair and fresh rebuild

- Normalized the accepted vendor win into a reproducible checked-in Ghostty
  provenance:
  - `scripts/dev/prepare-ghosttykit.sh` is now pinned to upstream `v1.2.3`
  - the checked-in aggregate patch is now
    `scripts/patches/ghostty-agtmux.patch`
  - `apply_required_patch()` now uses plain `git apply` instead of `-p0`,
    because the aggregate patch is `git diff` format with `a/` and `b/`
    prefixes
  - the aggregate patch now also carries the minimal `build.zig.zon` refresh
    required because upstream `v1.2.3` points at a theme tarball URL that now
    returns `404 Not Found`
- Fresh-clone and repo-local validation commands this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_GHOSTTYKIT_DIR="$tmp_root/GhosttyKit.xcframework" AGTMUX_GHOSTTYKIT_MARKER_FILE="$tmp_root/.ghostty-source-ref" ./scripts/dev/prepare-ghosttykit.sh`
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" ./scripts/dev/prepare-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-root AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-root/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
- Fresh-provenance release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 9.830 / p95 22.510 / max 23.349`
  - `8-burst scroll_to_layer_present_ms p50 7.998 / p95 28.669 / max 50.843`
- Current inference:
  - the vendor-side renderer short-circuit survives a true fresh-clone rebuild,
    so the earlier win was real and not an artifact of a dirty local checkout
  - `8-burst max` is noisier than the earlier best serial sample, but `p95`
    remains far below the pre-vendor baseline, so the next target stays the
    expensive first `up` / full-page dirty seam rather than patch provenance

## 2026-03-20 reusable viewport-shift row-set rebuild

- Followed up on the reproducible vendor baseline by narrowing the reusable
  viewport-shift redraw itself instead of changing scheduler ownership again:
  - after `self.cells.shiftRows(viewport_row_shift)`, `renderer/generic.zig`
    now rebuilds only the rows that can actually change on a reusable shift:
    newly exposed fringe rows, the sentinel/`shift_extra_row`, current or
    previous mouse rows, and rows still marked dirty in the viewport bitset
  - the earlier identical-frame short-circuit stays in place; this change only
    reduces work for redraws that still legitimately happen after a viewport
    move
- Validation this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-final AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-final/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-final/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 6.243 / p95 21.078 / max 42.474`
  - `8-burst scroll_to_layer_present_ms p50 4.393 / p95 24.264 / max 39.498`
- Compared to the fresh-provenance baseline:
  - baseline `4-burst`: `p50 9.830 / p95 22.510 / max 23.349`
  - baseline `8-burst`: `p50 7.998 / p95 28.669 / max 50.843`
- Current inference:
  - this is the first accepted vendor-side follow-up after provenance repair
    that improves the long burst train itself, not just identical-frame redraws
  - `4-burst max` remains noisier than the fresh-provenance baseline, so the
    short path still needs confirmation across more reruns
  - the next likely seam is still the expensive first `up` scrollback
    transition, but the reusable viewport-shift O(visible_rows) scan was
    clearly part of the remaining tail

## 2026-03-20 rejected conditional full dirty-clear skip

- Tried a narrower follow-up inside the accepted viewport-shift path:
  - keep the sparse row-set rebuild
  - after `rebuildCells(...)`, skip the full-screen `dirty_set.unsetAll()`
    sweep when the viewport dirty-bit scan found no dirty rows to rebuild
  - rationale: history scroll with no new output should often have zero
    viewport dirty rows, so avoid the pageIterator walk in that common case
- Validation this turn:
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-dirtyskip AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-dirtyskip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-dirtyskip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 5.921 / p95 24.784 / max 26.345`
  - `8-burst scroll_to_layer_present_ms p50 5.138 / p95 28.508 / max 68.647`
- Compared to the accepted row-set baseline:
  - baseline `4-burst`: `p50 6.243 / p95 21.078 / max 42.474`
  - baseline `8-burst`: `p50 4.393 / p95 24.264 / max 39.498`
- Verdict:
  - reject
  - the branch is semantically safe, but it does not improve the visible seam;
    `4-burst p95` regressed and `8-burst max` regressed badly
  - the next seam stays the expensive first `up` transition itself
    (`leaving_bottom` / `shift_extra_row` / old-cursor-row rebuild), not the
    unconditional dirty-bit clear

## 2026-03-20 accepted viewport-shift edge-padding recompute

- Kept the accepted sparse viewport-shift row-set rebuild, but removed the
  unconditional sentinel-row full rebuild:
  - reusable viewport shifts no longer force a bottom/top sentinel row through
    `rebuildCellRow(...)` just to refresh padding heuristics
  - instead, after shifted rows and exposed fringe rows are rebuilt, the
    renderer recomputes `padding_extend.up/down` directly from the current
    viewport edge rows via `neverExtendBg(...)`
- Rationale:
  - `self.cells.shiftRows(viewport_row_shift)` already remaps cached glyph/data
    rows to their new screen Y
  - the sentinel row existed mainly to refresh top/bottom padding extension
    state, not because the shifted row itself always needed reshaping
  - this targets the expensive first `up` transition directly without changing
    host cadence policy
- Validation this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-edgepad AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-edgepad/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` (rerun)
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 5.279 / p95 16.338 / max 22.517`
  - `8-burst scroll_to_layer_present_ms p50 4.307 / p95 23.698 / max 125.957`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.032 / p95 25.835 / max 72.321`
- Compared to the accepted sparse-row baseline:
  - baseline `4-burst`: `p50 6.243 / p95 21.078 / max 42.474`
  - baseline `8-burst`: `p50 4.393 / p95 24.264 / max 39.498`
- Verdict:
  - accept
  - the short path win is clear and repeatable: `4-burst p95` and `max` both
    dropped materially
  - `8-burst p95` stayed at or slightly better than the accepted baseline, but
    the bad reruns were dominated by late `up` bursts whose telemetry moved
    together with `pump_wake_lateness` / `recovery_probe_wake_lateness`, not
    with the renderer row-set itself
  - current inference: removing the sentinel full rebuild cut real renderer
    cost from the first `up` transition; the remaining worst-case tail is now
    more clearly host-wake variance on later `up` bursts

## 2026-03-20 accepted phase-aware host continuation suppression

- Kept the accepted vendor-side viewport-shift optimizations and changed the
  host scheduler around active precise trackpad contact:
  - `GhosttyTerminalView.scrollWheel(with:)` now tracks direct gesture
    `phase`, momentum phase, and precise vertical direction
  - direct finger-contact scroll (`phase == began/changed/stationary`) now
    bypasses `shouldThrottleImmediateScrollPresentationDraw(...)`
  - while that direct gesture is active, host pump/recovery continuation is
    suppressed; timers are only used for post-contact momentum tail and
    delayed recovery
  - precise direction flips inside an active gesture now invalidate scheduled
    pump/recovery wakeups so a new `up` burst does not inherit stale
    continuation state
- Also fixed the embedded scroll-mod packing mismatch:
  - `GhosttyInput.toScrollMods(...)` now packs direct gesture phase in bits
    `4..6`, matching Ghostty core `input.ScrollMods`
  - upstream embedded/vendor scroll handling still ignores that field today,
    so this is correctness/provenance alignment rather than the measured win
- Added regressions:
  - `GhosttyInputTests` for packed precision/momentum/phase bits
  - `GhosttyCLIOSCBridgeTests` for active precise throttle bypass and
    direct-gesture host-continuation suppression
- Validation this turn:
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-scroll-phase-aware AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-scroll-phase-aware/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` (rerun)
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 5.751 / p95 15.761 / max 18.422`
  - `8-burst scroll_to_layer_present_ms p50 5.395 / p95 29.695 / max 39.215`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.611 / p95 29.781 / max 33.833`
- Compared to the accepted edge-padding baseline:
  - baseline `4-burst`: `p50 5.279 / p95 16.338 / max 22.517`
  - baseline `8-burst`: `p50 4.307 / p95 23.698 / max 125.957`
  - baseline `8-burst rerun`: `p50 5.032 / p95 25.835 / max 72.321`
- Verdict:
  - accept
  - active precise scroll is now structurally closer to native cadence
    ownership: immediate coalesced draws are input/run-loop driven, not
    timer-driven
  - short bursts improved again, and the late-`up` worst-case tail collapsed
    from `70-126ms` down to repeatable low-`30ms` caps
  - `8-burst p95` regressed into the high-`20ms` band, so the remaining work
    is no longer catastrophic hitch removal but flattening the persistent
    later-`up` tail

## 2026-03-20 accepted renderer shiftRows fast path

- Kept the accepted phase-aware host scheduler and vendor renderer wins above,
  but cut fixed one-row viewport-shift work inside `renderer/cell.zig`:
  - `Contents.shiftRows(...)` now special-cases `abs_shift == 1`
  - those single-row shifts use `fastmem.move(...)` to block-copy background
    rows and foreground row-list slices instead of iterating through per-row
    swap loops
  - the exposed fringe row still clears as before, and moved glyph rows still
    remap `grid_pos[1]`
- Also synced the aggregate Ghostty patch so the checked-in patch stack matches
  the measured vendor checkout again.
- Rationale:
  - after the sparse viewport-row-set and edge-padding wins, `Contents.shiftRows`
    itself was the remaining fixed-cost row walk on every reusable viewport
    shift
  - the late `up` bursts were no longer dominated by full visible-row rebuilds,
    so the next safe win was to shrink the row-copy/move cost directly
  - the common case in this bench is a one-row scrollback shift, so `abs_shift == 1`
    is the highest-value fast path
- Validation this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-renderer-shiftrows AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-renderer-shiftrows/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` (rerun)
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 4.909 / p95 16.984 / max 18.636`
  - `8-burst scroll_to_layer_present_ms p50 4.303 / p95 26.875 / max 71.277`
  - `8-burst rerun scroll_to_layer_present_ms p50 5.730 / p95 29.408 / max 31.928`
- Compared to the accepted phase-aware baseline:
  - baseline `4-burst`: `p50 5.751 / p95 15.761 / max 18.422`
  - baseline `8-burst`: `p50 5.395 / p95 29.695 / max 39.215`
  - baseline `8-burst rerun`: `p50 5.611 / p95 29.781 / max 33.833`
- Verdict:
  - accept
  - this keeps the short path effectively at parity while improving `4-burst p50`
    and holding `max` flat
  - the long-burst train improves where it matters most for the accepted path:
    `8-burst p95` and rerun `max` both come down
  - one first `8-burst` run still hit a `71.277ms` outlier, so the remaining
    tail is no longer best explained by row-shift copy cost alone
  - current inference: fixed renderer row-shift work is lower now, and the next
    likely seam is later-`up` wake/presentation variance plus any remaining
    fixed per-frame work outside the row-shift copy itself

## 2026-03-20 rejected monotonic sparse-row walk

- Tried a monotonic sparse-row walk in `renderer/generic.zig`:
  - sort the sparse viewport-shift row set ascending
  - walk rows with `Pin.down(...)` instead of re-pinning each row
  - use `link.MatchSet.orderedContains(...)` on that sparse path
- Validation this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-monotonic-sparse AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-monotonic-sparse/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-monotonic-sparse/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 5.523 / p95 24.295 / max 26.607`
  - `8-burst scroll_to_layer_present_ms p50 4.864 / p95 26.322 / max 79.141`
- Verdict:
  - reject
  - `8-burst p95` moved only marginally while the short path regressed hard
  - the extra row ordering/walk machinery did not buy enough to offset the
    short-path loss, so the branch was reverted before the next experiment

## 2026-03-20 accepted sparse first-up seam reduction

- Kept the accepted phase-aware host path and renderer `shiftRows` fast path,
  then narrowed the remaining first-`up` renderer work inside
  `renderer/generic.zig`:
  - `shift_extra_row` is no longer rebuilt when leaving the live bottom if the
    previous cursor row is a plain unstyled empty-tail row and clearing the
    cursor overlay is sufficient
  - reusable viewport shifts now refresh `padding_extend.up/down` only for
    edges that were not already rebuilt by the sparse row-set
- Rationale:
  - after the accepted `shiftRows` fast path, the remaining first-`up` fixed
    work was the unconditional old-cursor-row rebuild plus the redundant
    top/bottom edge padding refresh
  - both are narrow enough to optimize without changing cadence ownership again
- Validation this turn:
  - `PATH="/opt/homebrew/opt/zig@0.14/bin:$PATH" AGTMUX_VENDOR_GHOSTTY_DIR="$PWD/vendor/ghostty" AGTMUX_GHOSTTYKIT_DIR="$PWD/GhosttyKit/GhosttyKit.xcframework" ./scripts/build-ghosttykit.sh`
  - `swift test --build-path .build-codex --filter 'GhosttyInputTests|GhosttyCLIOSCBridgeTests|GhosttyTerminalSurfaceRegistryTests'`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath build-shift-extra-skip AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux build`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8`
  - `AGTMUX_PERF_APP_BIN="$PWD/build-shift-extra-skip/Build/Products/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` (rerun)
- Release results on this host:
  - `4-burst scroll_to_layer_present_ms p50 6.124 / p95 13.778 / max 21.418`
  - `8-burst scroll_to_layer_present_ms p50 3.849 / p95 29.281 / max 53.626`
  - `8-burst rerun scroll_to_layer_present_ms p50 4.585 / p95 29.430 / max 38.933`
- Compared to the accepted renderer `shiftRows` baseline:
  - baseline `4-burst`: `p50 4.909 / p95 16.984 / max 18.636`
  - baseline `8-burst`: `p50 4.303 / p95 26.875 / max 71.277`
  - baseline `8-burst rerun`: `p50 5.730 / p95 29.408 / max 31.928`
- Verdict:
  - accept
  - the short path improved materially again, especially `4-burst p95`
  - the long train held essentially flat on `p95` while pulling the first-run
    outlier down from `71.277ms` to `53.626ms`
  - rerun `max` stayed in the same low/high-`30ms` band as the accepted
    baseline, so the remaining gap is no longer first-`up` fixed renderer work
    but later-`up` wake/presentation variance
