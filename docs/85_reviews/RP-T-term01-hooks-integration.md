# Review Pack — T-term01: agtmux-term hooks integration

## Objective
Add startup hook-status check + Register/Unregister UI to agtmux-term.
When `agtmux setup-hooks` has not been run, activity detection falls back to polling.
The app now detects this and guides the user.

## Change scope (5 source files, +363 lines)

| ファイル | 変更内容 |
|---------|---------|
| `Sources/AgtmuxTerm/AppViewModel.swift` | `HookSetupStatus` enum + `hookSetupStatus @Published` + `performStartupHookCheck()` / `registerHooks()` / `unregisterHooks()` + injectable `binaryURLResolver` + startup call from `startPolling()` |
| `Sources/AgtmuxTerm/SidebarView.swift` | `HookWarningBanner` struct — ⚠ banner with [Register] button + popover with [Verify]/[Register]/[Unregister] |
| `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift` | 2 new tests: exit-0 → `.registered`, exit-1 → `.missing` |
| `Tests/AgtmuxTermCoreTests/RuntimeHardeningTests.swift` | Harden 2 UNIX socket tests with shorter temp paths |
| `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCServiceBoundaryTests.swift` | Same shorter temp path hardening |

## Design decisions

### Binary resolution
`AgtmuxBinaryResolver.resolveBinaryURL()` — already used by the supervisor to launch the daemon. Hook checks reuse the same resolved path. No new binary discovery logic.

### Injectable resolver
`init(binaryURLResolver: @escaping () -> URL? = AgtmuxBinaryResolver.resolveBinaryURL)` — enables unit testing with a fake script binary without mocking `Process`.

### Status transitions
```
.unknown → .checking → .registered  (exit 0)
                     → .missing      (exit 1)
                     → .unavailable  (binary not found or error)
```

### UI placement
`HookWarningBanner` shown in sidebar below `LocalDaemonHealthStrip` when status is `.missing` or `.unavailable`. Only visible when hooks need attention — no UI clutter when registered.

## Verification evidence

- `swift build` PASS
- `swift test`: 296/296 deterministic tests PASS
  - 8 pre-existing live failures in `AppViewModelLiveManagedAgentTests` — require actual running Codex/Claude processes; confirmed pre-existing on prior commit (same failure before T-term01 changes)
- T-term01 acceptance criteria all satisfied:
  - [x] `HookSetupStatus` enum with 5 states
  - [x] `AppViewModel` publishes hook status + verify/register/unregister via resolved binary
  - [x] Startup polling triggers initial hook check automatically
  - [x] Sidebar shows ⚠ warning with [Register] + popover actions when missing/unavailable
  - [x] `swift build` + `swift test` (deterministic) PASS

## NOT changed (intentional)
- XPC/RPC layer — hook check runs as direct subprocess, no daemon involvement needed
- `AgtmuxBinaryResolver` — unchanged, reused as-is
- Wire format / sync-v3 path — unaffected

## Review Verdict — GO

- Clean injectable design with proper testability
- Binary resolution reuses existing `AgtmuxBinaryResolver` (no new discovery logic)
- Sidebar banner follows established `isOffline`/`LocalDaemonHealthStrip` visual pattern
- 296 deterministic tests PASS; 8 live failures are pre-existing environment-dependent tests
- T-term01 ready to commit and push
