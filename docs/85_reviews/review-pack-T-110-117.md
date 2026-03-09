# Review Pack

## Objective
- Tasks: T-110, T-112, T-114, T-115, T-116, T-117
- User story: harden tmux-first cockpit managed-pane surfacing, IME commit, daemon freshness, and metadata-enabled live UI proof
- Acceptance criteria touched:
  - managed pane provider/activity/freshness surface on the visible sidebar row
  - stale managed metadata clears on exit and does not bleed to sibling panes
  - metadata-enabled plain-zsh Codex live XCUITest passes against the rebuilt local daemon
  - app-owned daemon does not silently reuse stale producer truth after local `AGTMUX_BIN` rebuilds
  - Japanese IME commit reaches the terminal input path

## Summary
- Landed the remaining post-mainline hardening bundle that had been verified but not yet committed.
- Added process-aware managed-daemon freshness checks plus normalized daemon launch environment/runtime tracking.
- Fixed local metadata consumer readiness and row-level AX surfacing so managed provider/activity/freshness are visible and testable in live UI.
- Added live boundary canaries for managed entry/exit, plain-zsh agent launch, waiting-approval attention surfacing, and metadata-enabled plain-zsh Codex UI.
- Added IME-hosted terminal regression coverage and the pane-row accessibility summary contract.

## Change scope
- `Sources/AgtmuxTerm/GhosttyTerminalView.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/AgtmuxDaemonSupervisor.swift`
- `Sources/AgtmuxTerm/UITestTmuxBridge.swift`
- `Sources/AgtmuxTermCore/ManagedDaemonLaunchEnvironment.swift`
- `Sources/AgtmuxTermCore/AgtmuxManagedDaemonRuntime.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelLiveManagedAgentTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter PaneRowAccessibilityTests` => PASS
  - `swift test -q --filter AppViewModelA0Tests` => PASS
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` => PASS
  - `xcodegen generate` => PASS
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity` => PASS
- Notes:
  - `SACSetScreenSaverCanRun returned 22` appeared during targeted UI runs and was non-fatal.
  - Review diff snapshot prepared at `/tmp/agtmux-term-review-diff-T110-T117.patch`.

## Risk declaration
- Breaking change: yes
- Fallbacks: none; failures are surfaced explicitly
- Known gaps / follow-ups:
  - No new follow-up task is open in `docs/60_tasks.md` after `T-116` closeout.
  - Review should look for regressions caused by the managed-daemon freshness/runtime tracking bundle being committed together with the row-level AX contract.

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Prioritize:
  - stale/bleeding managed metadata risks
  - daemon freshness false positives/false negatives
  - live UI proof brittleness after switching from hidden child markers to row-level AX values
