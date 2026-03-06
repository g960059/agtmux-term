# Lessons

## 2026-03-06
- Runtime/protocol work in `agtmux-term` must be closed on fresh post-fix verification only. Focused tests are not enough if a later fix lands; rerun the relevant build/tests after the final patch and record only that fresh result in `docs/70_progress.md`.
- `SACSetScreenSaverCanRun returned 22` can appear during macOS targeted UI test runs even when the test passes. Treat it as a non-fatal environment warning unless accompanied by an actual test failure.
