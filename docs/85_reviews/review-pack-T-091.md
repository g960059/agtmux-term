# Review Pack

## Objective
- Task: T-091
- User story: tmux-first cockpit V2 real-session terminal tile
- Acceptance criteria touched: sidebar selection places a `SessionRef` into a V2 terminal tile, terminal tile attaches directly to the real tmux session, duplicate open reveals/focuses the existing tile instead of creating a second visible terminal tile

## Summary (3-7 lines)
- Replaced the V2 placeholder terminal-open path with real-session open by exact `SessionRef`.
- Added app-global duplicate-session prevention in `WorkbenchStoreV2` so reopening the same session reveals/focuses the existing tile across workbenches.
- Added a direct-attach resolver for local / ssh / mosh that fails loudly when `TargetRef.remote(hostKey:)` cannot be resolved back to a configured host.
- Extracted shared Ghostty surface hosting for V1/V2 and wired the V2 terminal tile to use it.
- Added focused store + attach-command coverage and updated targeted UI proofs for real-session open / duplicate reopen.
- During verification, refreshed the generated Xcode project with `xcodegen generate`, fixed a narrow compile blocker in `WorkbenchV2DocumentLoader`, stabilized the direct-attach UI proof with a dedicated terminal-status AX anchor, and cleared the real Claude review condition by adding explicit missing-host-key coverage in `WorkbenchV2DocumentLoaderTests`.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2TerminalAttach.swift`
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/RemoteHostsConfig.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentLoader.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalAttachTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2ModelsTests` => PASS (3 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (8 tests)
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` => PASS (4 tests)
  - `swift test -q --filter WorkbenchV2DocumentLoaderTests` => PASS (5 tests)
  - `xcodegen generate` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` => PASS (2 tests executed, 0 failures) on the earlier unlocked rerun
  - same targeted `xcodebuild` command => PASS as a command on March 6, 2026 07:40 PST, but the suite reported `Executed 2 tests, with 2 tests skipped and 0 failures` because the desktop session was locked
  - same targeted `xcodebuild` command => PASS as a command on March 6, 2026 07:55 PST, but no fresh executed PASS was produced because the first targeted test skipped with `screenLocked=1`
  - same targeted `xcodebuild` command => PASS as a command on March 6, 2026 08:19 PST, but the suite again reported `Executed 2 tests, with 2 tests skipped and 0 failures` because the desktop session was locked
  - same targeted `xcodebuild` command => FAIL before tests ran on March 6, 2026 09:28 PST because the generated Xcode project was stale; after `xcodegen generate`, the rerun still failed before either targeted test executed with `Timed out while enabling automation mode.`
  - `AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -resultBundlePath /tmp/T-091-ui-proof.xcresult -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` => PASS on March 6, 2026 after on-console automation approval; both targeted UI tests executed and passed (`2 / 0 / 0`)
- Notes:
  - The first targeted `xcodebuild` attempt exposed a stale generated Xcode project; `xcodegen generate` refreshed `AgtmuxTerm.xcodeproj` from `project.yml`.
  - A later rerun exposed a narrow compile blocker in `WorkbenchV2DocumentLoader.swift`; the initializer was split so the default path no longer references `Self` from a default argument.
  - The single-open UI proof was stabilized by adding a dedicated direct-attach status AX anchor on the V2 terminal tile and querying that explicit `.status` contract in the UI test.
  - A Codex `GO_WITH_CONDITIONS` review required `process.standardInput = FileHandle.nullDevice`; that condition is cleared in the current worktree.
  - A later Codex `NO_GO` review identified pipe-buffer deadlock risk in `WorkbenchV2DocumentLoader` and timing-based `Thread.sleep` in the duplicate-open UI proof; both findings are fixed, and `WorkbenchV2DocumentLoaderTests` were added to hold the loader contract.
  - Real Claude Code CLI review returned `GO_WITH_CONDITIONS`; the only blocking condition was explicit `missingRemoteHostKey` coverage in `WorkbenchV2DocumentLoaderTests`, and that condition is now cleared in the current worktree.
  - `xcodebuild` warned that it used the first of multiple matching macOS destinations (`arm64` / `x86_64`).
  - `SACSetScreenSaverCanRun returned 22` appeared during the xcodebuild runs and was non-fatal.

## Risk declaration
- Breaking change: no, guarded behind `AGTMUX_COCKPIT_WORKBENCH_V2=1`
- Fallbacks: none; missing remote host keys surface explicit attach failure instead of falling back
- Known gaps / follow-ups:
  - non-blocking Claude notes remain on synchronous `Data(contentsOf:)` inside the document loader actor and `attachResolution` recomputation per SwiftUI render pass

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Reviewer verdict: `GO_WITH_CONDITIONS` (real Claude Code CLI)
- Claude condition:
  explicit `missingRemoteHostKey` coverage in `WorkbenchV2DocumentLoaderTests`
  cleared on the current worktree
- Remaining closeout blocker:
  none; fresh executed UI proof was recovered on March 6, 2026 and the remaining closeout blocker is cleared
