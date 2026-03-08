# Review Pack

## Objective
- Task: T-092
- User story: CLI bridge plus browser/document companion surfaces umbrella
- Acceptance criteria touched: `agt open` opens browser tiles for URLs, `agt open` opens document tiles for files, directory input fails explicitly in MVP, bridge-unavailable failure is explicit

## Summary (3-7 lines)
- `T-092` was executed through `T-098` and `T-099`, because app-local companion rendering and Ghostty bridge transport were different implementation boundaries.
- The V2 workbench now renders real browser/document companion surfaces instead of placeholders, with explicit load/fetch failure states kept visible in-tile.
- The terminal-scoped bridge path is now live at the in-repo seam: `GhosttyApp.handleAction(...)` consumes only `OSC 9911` custom-OSC payloads, validates strict JSON, resolves the emitting surface context, and dispatches browser/document opens into the correct workbench.
- Directory inputs and unresolved bridge targets fail explicitly; there is no silent normalization path.
- The external `agt` emitter remains out of tree, but the in-repo carrier, decode, dispatch, and rendering surfaces are all implemented and covered.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2BrowserTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentLoader.swift`
- `Sources/AgtmuxTerm/GhosttyApp.swift`
- `Sources/AgtmuxTerm/GhosttyCLIOSCBridge.swift`
- `Sources/AgtmuxTerm/GhosttyTerminalSurfaceRegistry.swift`
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BrowserTileTests.swift`
- `Tests/AgtmuxTermIntegrationTests/GhosttyCLIOSCBridgeTests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2BrowserTileTests` => PASS (5 tests)
  - `swift test -q --filter WorkbenchV2DocumentTileTests` => PASS (13 tests)
  - `swift test -q --filter GhosttyCLIOSCBridgeTests` => PASS (16 tests)
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests` => PASS (7 tests)
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` => PASS (3 tests)
- Supporting closeout evidence already captured in split tasks:
  - `docs/85_reviews/review-pack-T-098.md` => `GO`
  - `docs/85_reviews/review-pack-T-102.md` => `GO` / `GO`
  - `docs/85_reviews/review-pack-T-103.md` => `GO` / `GO`
- Notes:
  - app-local rendering proof and bridge decode/dispatch proof were rerun fresh on the current worktree; the vendored Ghostty custom-OSC carrier remains covered by the executed `T-102` evidence
  - `GhosttyCLIOSCBridgeTests` covers malformed JSON, unsupported enums, empty required fields, relative file path rejection, non-`9911` ignore behavior, browser/document dispatch from the emitting surface context, and explicit failures for unregistered or non-surface targets
  - `WorkbenchV2BrowserTileTests` / `WorkbenchV2DocumentTileTests` keep the companion-surface half of the contract honest: real rendering, late-completion protection, cancellation ignore, and loud missing-host-key failure

## Risk declaration
- Breaking change: low but real; the app now consumes one additional Ghostty action path (`OSC 9911`) and treats invalid requests as explicit failures
- Fallbacks: none; malformed bridge payloads, directory input, and unresolved bridge targets all fail loudly
- Known gaps / follow-ups:
  - no in-repo executable `agt` binary exists; end-to-end emission from the external CLI remains an out-of-tree contract
  - no visible UI test currently injects a live `OSC 9911` sequence from a real terminal session; the executed proof is at the real `GhosttyApp.handleAction(...)` seam plus companion-surface rendering tests

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Review mode:
  - tracking-only umbrella closeout; no new product diff beyond the already-reviewed split tasks
- Bounded Codex CLI closeout attempts:
  - did not return a usable final verdict in reasonable time
- Inherited reviewer verdicts:
  - `T-098`: `GO`
  - `T-102`: `GO`, `GO`
  - `T-103`: `GO`, `GO`
- Final umbrella verdict:
  - direct Codex fallback review: `GO`
- Final note:
  - umbrella reconciliation also corrected the remaining bridge-routing wording from `active Workbench` to the implemented emitting-surface Workbench semantics; after syncing those docs and the parent task entry, no additional product-level blocker remained
