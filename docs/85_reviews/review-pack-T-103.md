# Review Pack

## Objective
- Task: T-103
- User story: app-side `agt open` bridge decode and dispatch
- Acceptance criteria touched: custom OSC payload decode/validation fails loudly for malformed or unsupported requests, valid bridge requests resolve the emitting surface context and open the expected browser/document tile, explicit failure remains visible when payload cannot be resolved or dispatched

## Summary (3-7 lines)
- `GhosttyApp.handleAction(...)` now consumes only `GHOSTTY_ACTION_CUSTOM_OSC` with `osc == 9911` and leaves unrelated Ghostty actions alone.
- New `GhosttyCLIOSCBridge` decodes strict UTF-8 JSON payloads, validates version/action/kind/placement plus required fields, and rejects relative file paths instead of normalizing them.
- Browser requests preserve `target + cwd` as source metadata; file requests become `DocumentRef(target:path:)`.
- Surface routing now resolves the emitting terminal tile/workbench from `GhosttyTerminalSurfaceRegistry` and dispatches relative to that source tile rather than the currently focused tile in another workbench.
- Failure surfacing is explicit: malformed payloads, unsupported targets, missing surface registration, and dispatch failures are reported via stderr plus `assertionFailure`.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/GhosttyApp.swift`
- `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift`
- `Sources/AgtmuxTerm/GhosttyTerminalSurfaceRegistry.swift`
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyCLIOSCBridgeTests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test --filter GhosttyCLIOSCBridgeTests` => PASS (16 tests)
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests` => PASS (7 tests)
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` => PASS (3 tests)
- Notes:
  - focused coverage exercises malformed JSON, non-object payloads, unsupported `version` / `action` / `kind` / `placement`, empty required fields, relative file path rejection, non-9911 ignore behavior, browser/document dispatch from the emitting surface context, and explicit failures for unregistered or non-surface targets
  - seam-level integration tests now call `GhosttyApp.handleAction(...)` itself from a background queue and prove: valid `osc == 9911` is consumed and opens the expected tile, non-`9911` custom OSC is not consumed, and unregistered-surface failure is surfaced through the app callback reporter on main

## Risk declaration
- Breaking change: low but real; `GhosttyApp` now actively consumes one additional Ghostty action tag (`CUSTOM_OSC`) for `osc == 9911`
- Fallbacks: none; invalid bridge payloads and unresolved source surfaces are explicit failures
- Known gaps / follow-ups:
  - no executed UI proof yet; the current closeout evidence is integration-level at the real app callback seam rather than a visible app run

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Reviewer verdicts so far:
  - initial Codex review #1: `GO`
  - initial Codex review #2: `NO_GO`
- Previous blocking finding from the `NO_GO` review:
  - current executed tests did not prove the real `GhosttyApp.handleAction(...)` callback seam, including consume/passthrough behavior, main-thread hop, and failure surfacing
- Remediation status:
  - `GhosttyApp` now exposes a narrow test hook wrapper and the current worktree includes executed seam-level tests through `handleAction(...)` itself
  - the review-pack verification evidence above now includes the post-fix `GhosttyCLIOSCBridgeTests` rerun
- Re-review status:
  - final Codex re-review #1: `GO`
  - final Codex re-review #2: `GO`
