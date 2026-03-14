# Review Pack

## Objective
- Task: `T-LF-01` + `T-LF-02`
- User story: local-first fast path follow-on
- Acceptance criteria touched:
  - `T-LF-01`: local steady-state projection ownership, health cadence ownership, AppViewModel orchestration reduction, fresh build/tests
  - `T-LF-02`: bounded startup sync preserved, local steady-state off app-wide 1-second poll, remote broad path preserved, fresh build/tests

## Summary
- `LocalProjectionCoordinator` now owns the local steady-state metadata and health loops.
- The metadata lane now runs `bootstrap -> waitForUIChangesV1/fetchUIChangesV3 -> apply -> repeat` without depending on the app-wide 1-second `fetchAll()` loop.
- `AppViewModel.startPolling()` now starts three separate lanes: coordinator-owned local metadata/health steady state, automatic local inventory convergence, and the existing remote-only broad poll.
- Explicit/manual `fetchAll()` still performs bounded local inventory refresh so tests and explicit refresh surfaces keep their existing entry point.
- `main.swift` now kicks off managed-daemon bring-up without inheriting `MainActor` blocking behavior: the supervisor path uses `startIfNeededAsync()`, while the XPC path uses `Task.detached(...)`.
- Startup orchestration now only kicks bring-up off, then runs the bounded initial sync immediately, preserving startup publication while avoiding the earlier startup race.
- `AppViewModel.performInitialSync()` makes the startup/manual boundary explicit without changing the manual `fetchAll()` surface.

## Change scope
- `Sources/AgtmuxTerm/main.swift`
- `Sources/AgtmuxTerm/LocalProjectionCoordinator.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Tests/AgtmuxTermIntegrationTests/LocalProjectionCoordinatorTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test --filter LocalProjectionCoordinatorTests` => PASS (`9` tests)
  - relevant `AppViewModelA0Tests` => PASS (`7` focused tests)
  - `swift test --skip AppViewModelLiveManagedAgentTests` => PASS (`313` tests, `0` failures)
  - `xcodegen generate` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO` => PASS
- Notes:
  - startup sequence now keeps initial sync non-blocking with respect to managed-daemon bring-up on both the supervisor and XPC paths
  - local inventory convergence is automatic again, but it is no longer routed through the global `fetchAll()` loop
  - no excluded UI files were touched

## Risk declaration
- Breaking change: no product-truth change; internal execution-order change only
- Fallbacks: none
- Known gaps / follow-ups:
  - this slice does not attempt Gate-L perf proof yet
  - `T-LF-05` focused navigation extraction remains next

## Reviewer request
- Provide verdict: `GO` / `GO_WITH_CONDITIONS` / `NO_GO` / `NEED_INFO`
- If `NEED_INFO`: list up to 3 concrete missing items + why required
