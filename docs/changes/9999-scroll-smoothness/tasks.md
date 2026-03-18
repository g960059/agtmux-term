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
- `scripts/perf/gate_l_ax_key_sender.sh --dry-run`
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4`
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding layer-present telemetry
- `AGTMUX_PERF_APP_BIN="$PWD/.build-codex/arm64-apple-macosx/debug/AgtmuxTerm" scripts/perf/gate_l_trackpad_history_scroll_bench.sh --iterations 4` after adding coalesced synchronous scroll draw
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
