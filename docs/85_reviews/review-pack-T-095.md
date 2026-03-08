# Review Pack

## Objective
- Task: T-095
- User story: local health-strip offline/stale-data contract follow-up
- Acceptance criteria touched: the intended local health-strip behavior is documented, and regression coverage exists for the chosen contract

## Summary (3-7 lines)
- No product-code change was required for T-095; the task was to lock the already-implemented health-strip behavior into spec/architecture docs and confirm that existing regression coverage actually matches that contract.
- The final documented contract is narrow and explicit: local inventory offline does not clear the last published health strip, `ui.health.v1` polling continues while inventory is offline, and no health snapshot means no strip.
- `docs/20_spec.md` and `docs/30_architecture.md` now match the implemented `AppViewModel` / `SidebarView` behavior without overpromising extra coexistence rendering semantics.
- Existing coverage in `AppViewModelA0Tests` and `AgtmuxTermUITests` remains the enforcement surface for this contract.

## Change scope (max 10 files)
- `docs/20_spec.md`
- `docs/30_architecture.md`
- `docs/60_tasks.md`
- `docs/65_current.md`
- `docs/70_progress.md`

## Verification evidence (Tester output)
- Commands run:
  - `swift test -q --filter AppViewModelA0Tests` => PASS (18 tests)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` => PASS (2 tests)
- Relevant existing coverage:
  - `AppViewModelA0Tests.testLocalDaemonHealthPublishesEvenWhenInventoryFetchFails`
  - `AppViewModelA0Tests.testLocalInventoryOfflineDoesNotClearExistingHealthAndStillAllowsRefresh`
  - `AgtmuxTermUITests.testSidebarHealthStripShowsMixedHealthStates`
  - `AgtmuxTermUITests.testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
- Notes:
  - the fresh rerun above covers the model-side offline/stale-data contract on the current worktree
  - the UI strip presence/absence proofs now also have a fresh executed `xcodebuild` PASS from an unlocked desktop session; T-095 still did not require product-code or AX-contract changes

## Risk declaration
- Breaking change: none in product behavior
- Fallbacks: none; the task documents existing fail-loud, annotation-only behavior
- Known gaps / follow-ups:
  - no new gaps were introduced by T-095

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Initial sufficiency review:
  - independent Codex review #1: summary only / no usable verdict
  - independent Codex review #2: `NO_GO`
- Initial blocking finding:
  - the first doc wording overpromised an untested coexistence rendering case and the spec section accidentally absorbed unrelated incompatibility bullets
- Remediation status:
  - narrowed the documented contract to the behaviors already covered by tests
  - fixed the spec formatting so incompatibility handling and health-strip contract are separate sections
- Final reviewer verdicts:
  - independent Codex review #1: `GO`
  - independent Codex review #2: `GO`
