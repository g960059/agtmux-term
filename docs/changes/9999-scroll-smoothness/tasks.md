# Tasks

- [x] implementation
- [x] tests
- [x] durable-knowledge promotion
- [ ] remove `docs/changes/9999-scroll-smoothness/` before merge

## 2026-03-18 verification

- `swift build -c debug --build-path .build-codex`
- `swift test --build-path .build-codex --filter GhosttyCLIOSCBridgeTests`
- `swift test --build-path .build-codex --filter 'GhosttyCLIOSCBridgeTests|WorkbenchV2TerminalRestoreTests|WorkbenchV2TerminalAttachTests'`
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
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after reinstalling the telemetry-instrumented release app
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 8` to stress longer burst trains
- `cd ../agtmux && cargo build -p agtmux --release >/dev/null && cd ../agtmux-term && xcodegen generate --spec project.yml >/dev/null && xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Release -derivedDataPath "$PWD/build" CONFIGURATION_BUILD_DIR="$PWD/build/Release" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=NO AGTMUX_BIN="$PWD/../agtmux/target/release/agtmux" build`
- `AGTMUX_PERF_APP_BIN="$PWD/build/Release/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding the delayed-present recovery probe
- `AGTMUX_PERF_APP_BIN="/Applications/AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` twice after reinstalling the release app
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_scroll_bench.sh --iterations 5`
- `scripts/perf/gate_l_native_ghostty_scroll_bench.sh --iterations 5`

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
