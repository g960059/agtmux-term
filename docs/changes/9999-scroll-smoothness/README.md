# Change Pack

- **Issue:** `#9999` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [2026-03-18-scroll-smoothness-baseline.md](../../research/2026-03-18-scroll-smoothness-baseline.md)

This pack tracks the current scroll-smoothness investigation and first-wave
implementation for embedded Ghostty history scrolling.

Current state:

- render-callback/direct-draw scheduling is in place for the
  `GHOSTTY_ACTION_RENDER` path
- store publish and island remount churn were reduced but were not the primary
  limiter in the captured history-scroll case
- the full-app trackpad bench now measures IOSurface layer presentation
  directly, and a coalesced synchronous scroll draw improved that presentation
  cadence materially
- repo-local validation is green for `validate-macos-ci.sh` and
  `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
- the only broad SwiftPM failure on this host is the live Claude probe in
  `AppViewModelLiveManagedAgentTests`, where `claude -p` times out/returns
  non-zero without output before the app assertions begin
- after granting automation permission, the SSH-launched macOS UI E2E rerun
  reaches test execution again and returns to the expected single remaining
  failure: `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
