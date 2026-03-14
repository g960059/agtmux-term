# Review Pack

## Objective
- Task: `T-LF-06`
- User story: local-first `PR-06` fallback / command-broker hardening for focused navigation
- Acceptance criteria touched: remaining remote control-mode blur lifecycle no longer depends on the tile view; remote control-mode source drift restarts the focused navigation owner; fresh `swift build` + relevant tests + Xcode build green

## Summary
- Added `WorkbenchFocusedNavigationControlModeKey` so focused navigation snapshots carry the resolved control-mode source separately from `SessionRef`.
- `WorkbenchFocusedNavigationActor` now owns remote control-mode lifecycle hardening:
  - blur/disappear schedules the remote stop via actor-owned lifecycle reconciliation
  - re-focus cancels scheduled stop through the same owner
  - remote source changes schedule the previous remote control mode for stop before switching to the new source
- `WorkbenchAreaV2` no longer open-codes the remote `.onChange(of: isFocused)` blur-stop path.
- Focused navigation task identity now includes resolved control-mode source identity so remote host config drift reissues the actor snapshot even when the visible tmux session/pane stays the same.
- `WorkbenchAreaV2` now treats frozen terminal attach plans as `(identity, plan)` pairs instead of plan-only state:
  - remote attach-plan identity includes configured transport + `sshTarget`
  - stale frozen plans are bypassed as soon as remote host config drift changes that identity
  - same-target session-preserve still rewrites the frozen identity explicitly instead of leaking stale remote attach commands across host-config changes
- Added regression coverage for remote blur-stop scheduling, remote source-change scheduling, control-mode-source task identity drift, and remote `sshTarget` attach-plan drift.

## Change scope
- `Sources/AgtmuxTerm/WorkbenchFocusedNavigationActor.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchFocusedNavigationActorTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalAttachTests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `swift test --filter WorkbenchFocusedNavigationActorTests` => PASS (`11` tests)
  - `swift test --filter WorkbenchV2NavigationSyncResolverTests` => PASS (`3` tests)
  - `swift test --skip AppViewModelLiveManagedAgentTests` => PASS (`326` tests, `0` failures)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO` => PASS
- Notes:
  - Preserved the existing unrelated `WorkbenchAreaV2.swift` restore/accessibility UI edits already present in the worktree.
  - `T-LF-05` remains the extracted navigation-owner baseline; this slice hardens the remaining lifecycle/source edge cases and the terminal attach freeze contract on top.

## Risk declaration
- Breaking change: no
- Fallbacks: explicit; remote stop scheduling remains 30s delayed through `TmuxControlModeRegistry`
- Known gaps / follow-ups:
  - `T-LF-07` remains the next local parity slice for dirty-only draw.
  - local control-mode lifecycle is still intentionally not blur-scheduled; this slice only moved the remaining remote lifecycle seam behind the actor.

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Review outcome
- Prior Codex review sequence:
  - initial Codex CLI review: `GO`
  - follow-up Codex review: `NO_GO` because remote host-config `sshTarget` drift restarted focused navigation but did not invalidate the frozen terminal attach plan in `WorkbenchAreaV2`
- Current repaired-patch review:
  - Codex subagent re-review: `GO`
  - reviewer found no remaining blocker in scope after the frozen attach plan became identity-aware and remote attach identity started including `hostKey` + transport + `sshTarget`
