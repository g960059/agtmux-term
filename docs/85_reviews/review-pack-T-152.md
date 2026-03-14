# Review Pack

## Objective
- Task: `T-152`
- User story: recover the user-requested live `AppViewModelLiveManagedAgentTests` full-lane rerun after the March 13, 2026 post-implementation regression signal
- Acceptance criteria touched: root cause identified with concrete live-harness evidence; the two previously persistent isolated reds pass on fresh rerun; full live AppViewModel lane is green again

## Summary
- The earlier red was not term-side consumer logic drift. The live harness launched interactive Codex inside a fresh git worktree, and Codex stopped on the repo trust prompt before the managed session could reach its expected running/completed state.
- The final fix is more specific than the first draft:
  - trust-prompt matching now searches deeper tmux scrollback
  - the matcher accepts wrapped `Do you trust the contents of this\s+directory` headings instead of generic `Press enter to continue` text
  - Codex-only live canaries no longer require sibling Claude startup to remain managed when that sibling is not the subject under test
- The dedicated Claude activity live proof now probes real `claude -p` execution up front and skips cleanly when the local Claude token is expired.
- This keeps the live suite aligned with real CLI/auth behavior without changing product code or daemon truth.

## Change scope
- `Tests/AgtmuxTermIntegrationTests/AppViewModelLiveManagedAgentTests.swift`

## Verification evidence
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter AppViewModelLiveManagedAgentTests/testTrustPromptMatcher` => PASS (`2` tests)
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveCodexInteractiveRunningSentinelStillSurfacesExactRunningTruth` => PASS
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveCodexCompletedIdleWithoutPendingRequestDoesNotSurfaceAttentionFilter` => PASS
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveCodexActivityTruthReachesExactAppRowWithoutBleed` => PASS
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed` => PASS (`1` skipped; explicit local Claude `401` auth expiry)
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` => PASS (`11` tests, `1` skipped, `0` failures)
- Notes:
  - manual tmux capture during investigation showed interactive Codex blocked on a wrapped `Do you trust the contents of this directory` prompt inside the fresh live-harness git repo
  - the live full suite now returns success, but one Claude-specific proof is skipped because the local environment currently fails real `claude -p` execution with expired OAuth credentials
  - existing unrelated dirty-worktree edits in `SidebarView.swift`, `TitlebarChromeView.swift`, and `WorkbenchAreaV2.swift` were preserved

## Risk declaration
- Breaking change: no
- Fallbacks: none; the helper is explicit and only triggers when the pane capture matches the distinctive wrapped trust-prompt heading
- Known gaps / follow-ups:
  - the live suite still depends on external Claude/Codex auth and CLI startup behavior, so future upstream prompt wording or auth behavior changes could require another harness update

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Focus on: false-green risk from the wrapped trust-prompt matcher, correctness of the Codex-only precondition relaxations, and whether the new Claude prompt-execution skip is scoped tightly enough

## Review outcome
- Initial Codex review: `NO_GO`
  - generic `Press enter to continue` matching could false-green unrelated prompts
- Fixes landed after review:
  - trust prompt detection is now heading-based, wrap-tolerant, and scrollback-aware
  - added negative/positive prompt-matcher tests
  - Codex-only canaries no longer wait on unrelated sibling Claude startup
  - the dedicated Claude activity proof now surfaces expired auth as an explicit skip instead of a misleading product failure
- Fresh Codex re-review A: `GO`
  - no findings
- Fresh Codex re-review B: `GO`
  - no findings
