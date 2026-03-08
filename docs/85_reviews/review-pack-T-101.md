# Review Pack

## Objective
- Task: T-101
- User story: tmux-first cockpit V2 app-side CLI bridge dispatch scaffold
- Acceptance criteria touched: bridge request model preserves MVP contract, terminal surfaces register enough metadata for future bridge dispatch, dispatcher can open browser/document tiles from an injected request without needing the final carrier

## Summary (3-7 lines)
- `WorkbenchV2BridgeRequest` now preserves the MVP placement contract as well as the resolved browser/document payload.
- `WorkbenchStoreV2` now keeps `.replace` replacement semantics but inserts split nodes for `.left/.right/.up/.down` instead of collapsing every open to replace-only behavior.
- `GhosttyTerminalSurfaceRegistry` is now keyed by a canonical `GhosttySurfaceHandle` derived from the real `ghostty_surface_t`, with `context(forTarget:)` available for the `GhosttyApp.handleAction(_, target: ghostty_target_s, ...)` seam.
- `GhosttySurfaceHostView` now unregisters stale handles on reattach/dismantle so the surface registry stays aligned with live Ghostty surfaces.
- `WorkbenchStoreV2` now normalizes valid non-empty workbenches that have no preset focus by selecting the first tile in traversal order before applying placement.
- Focused tests now cover handle-based routing, directional placement preservation, and unfocused-workbench normalization.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/GhosttyTerminalSurfaceRegistry.swift`
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BridgeDispatchTests.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyTerminalSurfaceRegistryTests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests` => PASS (7 tests)
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` => PASS (3 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (8 tests)
- Notes:
  - filtered `swift test` prints an extra Swift Testing footer (`0 tests in 0 suites passed`) after the normal XCTest summary; the actual filtered XCTest executions above are the relevant results

## Risk declaration
- Breaking change: no, guarded behind `AGTMUX_COCKPIT_WORKBENCH_V2=1`
- Fallbacks: none; the bridge remains explicit and carrier-boundary failure stays visible
- Known gaps / follow-ups:
  - `T-099` remains blocked on a host-visible custom OSC carrier in GhosttyKit

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Previous reviewer verdict: `NO_GO`
- Previous blocking findings:
  - surface-scoped dispatch was not implementable from the real Ghostty callback boundary because the registry was keyed by tile ID instead of `ghostty_target_s.target.surface`
  - bridge request/dispatch had dropped the documented placement contract and only exercised replace-style insertion
- Remediation status:
  both blocking findings are fixed on the current worktree
- Re-review status:
  one Codex reviewer returned `GO`, but another returned `NO_GO` on a remaining robustness gap: `dispatchBridgeRequest(_:)` could precondition-crash on a non-empty workbench whose `focusedTileID` is `nil`
- Crash-fix status:
  that remaining robustness gap is now fixed on the current worktree
- Claude CLI status:
  installed and authenticated, but unusable here because stdin raw mode is unsupported and repeated `claude -p` review attempts returned no usable output
- Final reviewer verdicts:
  - independent Codex review #1: `GO`
  - independent Codex review #2: `GO`
