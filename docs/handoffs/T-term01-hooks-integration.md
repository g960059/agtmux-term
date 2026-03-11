# T-term01 Handoff: agtmux-term Hooks Integration

## Goal
Add startup hook-status check + Register/Unregister UI to agtmux-term.

## Why
`agtmux setup-hooks` must be run once per Claude Code project to receive real-time events.
If hooks are not registered, all activity detection falls back to polling (less accurate).
The app should detect this situation and guide the user.

## Binary Access Pattern
`AgtmuxBinaryResolver.resolveBinaryURL()` → `URL?` of the agtmux binary.
Run subprocess via `Foundation.Process`:
```swift
let proc = Process()
proc.executableURL = binaryURL
proc.arguments = ["setup-hooks", "--check"]
// capture stdout/stderr via Pipe, call proc.run(), waitUntilExit()
// proc.terminationStatus == 0 → all registered, == 1 → missing hooks
```

## HookSetupStatus enum (new, define in AppViewModel.swift or a new Types file)
```swift
public enum HookSetupStatus: Equatable, Sendable {
    case unknown       // not checked yet
    case checking      // subprocess in flight
    case registered    // exit 0 (all 11 hook types present)
    case missing       // exit 1 (some missing)
    case unavailable   // binary not found or process error
}
```

## AppViewModel.swift changes

Add near `localDaemonHealth`:
```swift
@Published private(set) var hookSetupStatus: HookSetupStatus = .unknown
```

Add async methods:
```swift
// Called once during startPolling() or first health poll
func performStartupHookCheck() async {
    guard let binaryURL = AgtmuxBinaryResolver.resolveBinaryURL() else {
        await MainActor.run { hookSetupStatus = .unavailable }
        return
    }
    await MainActor.run { hookSetupStatus = .checking }
    let exitCode = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--check"])
    await MainActor.run { hookSetupStatus = exitCode == 0 ? .registered : .missing }
}

// Register hooks (scope: project)
func registerHooks() async {
    guard let binaryURL = AgtmuxBinaryResolver.resolveBinaryURL() else { return }
    await MainActor.run { hookSetupStatus = .checking }
    _ = await runAgtmuxCommand(binaryURL, args: ["setup-hooks"])
    await performStartupHookCheck()  // re-check after register
}

// Unregister hooks
func unregisterHooks() async {
    guard let binaryURL = AgtmuxBinaryResolver.resolveBinaryURL() else { return }
    _ = await runAgtmuxCommand(binaryURL, args: ["setup-hooks", "--unregister"])
    await performStartupHookCheck()  // re-check after unregister
}

// Private helper
private func runAgtmuxCommand(_ binaryURL: URL, args: [String]) async -> Int32 {
    await withCheckedContinuation { continuation in
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        proc.terminationHandler = { p in
            continuation.resume(returning: p.terminationStatus)
        }
        do { try proc.run() } catch {
            continuation.resume(returning: -1)
        }
    }
}
```

Call site in `startPolling()` or at end of first successful health fetch:
```swift
Task { await performStartupHookCheck() }
```

## SidebarView.swift changes

### Hook warning banner (add above or below LocalDaemonHealthStrip)
Copy the `isOffline` orange circle badge pattern. Show a small warning when hooks are missing:

```swift
// Near LocalDaemonHealthStrip usage (around line 1287):
if viewModel.hookSetupStatus == .missing || viewModel.hookSetupStatus == .unavailable {
    HookWarningBanner(status: viewModel.hookSetupStatus) {
        Task { await viewModel.registerHooks() }
    }
}
```

`HookWarningBanner` — compact strip (similar to `LocalDaemonHealthStrip`):
- ⚠ icon (yellow/orange) + text "Claude hooks not registered"
- [Register] button that calls the closure
- Only shown when `.missing` or `.unavailable`

### Settings popover or sheet (minimal)
Add a "Hooks" section in whatever settings/info UI exists, or add a popover accessible from the warning banner.

Three actions:
- **[Verify]**: calls `performStartupHookCheck()`
- **[Register]**: calls `registerHooks()`
- **[Unregister]**: calls `unregisterHooks()`

If there is no existing settings panel, a simple popover attached to the warning banner is sufficient.

## Tests
Unit tests for `runAgtmuxCommand` are not needed (it's a thin wrapper).
Add 1 unit test verifying `HookSetupStatus` transitions:
- Start `.unknown` → `performStartupHookCheck` with a fake binary that exits 0 → `.registered`
- Start `.unknown` → `performStartupHookCheck` with a fake binary that exits 1 → `.missing`

Or if testing the subprocess is complex, just ensure it compiles and `swift build` passes.

## Acceptance Criteria
- [x] `hookSetupStatus: @Published HookSetupStatus` in AppViewModel
- [x] `performStartupHookCheck()` / `registerHooks()` / `unregisterHooks()` implemented
- [x] `performStartupHookCheck()` called automatically during startup polling
- [x] SidebarView shows ⚠ warning when status is `.missing` or `.unavailable`
- [x] [Register Hooks] button visible in warning banner
- [x] Settings: [Verify] [Register] [Unregister] actions accessible
- [x] `swift build` + `swift test` PASS

## Files to change
- `Sources/AgtmuxTerm/AppViewModel.swift` — hookSetupStatus + methods
- `Sources/AgtmuxTerm/SidebarView.swift` — HookWarningBanner + settings actions
- Optionally a new `Sources/AgtmuxTerm/HookSetupStatus.swift` for the enum
