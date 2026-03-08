# Review Pack

## Objective
- Task: T-098
- User story: tmux-first cockpit V2 browser/document companion surface rendering
- Acceptance criteria touched: browser tiles render requested URLs, document tiles render requested local/remote text content, failure states stay visible, focused coverage exists for the new browser/document behaviors

## Summary (3-7 lines)
- Replaced V2 placeholder browser/document tiles with real companion surfaces.
- Browser tiles now host `WKWebView`, keep load failures visible, ignore cancellation noise, and reload by `tile.id` so reopen does not inherit stale state.
- Document tiles now load through `WorkbenchV2DocumentLoader` and commit through a token-aware coordinator so late async completion cannot repaint a replacement tile.
- Added focused regression coverage for browser reload identity, document late completion/cancellation, and loud missing-host-key failure.

## Change scope (max 10 files)
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchV2BrowserTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
- `Sources/AgtmuxTerm/WorkbenchV2DocumentLoader.swift`
- `Package.swift`
- `project.yml`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BrowserTileTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentLoaderTests.swift`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2BrowserTileTests` => PASS (5 tests)
  - `swift test -q --filter WorkbenchV2DocumentTileTests` => PASS (4 tests)
  - `swift test -q --filter WorkbenchV2DocumentLoaderTests` => PASS (5 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (8 tests)
  - `xcodegen generate` => PASS
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` => PASS as a command; both targeted UI tests skipped because the desktop session reported `screenLocked=1`
- Notes:
  - the T-098 review scope does not depend on executed UI proof; the targeted UI run was used only as an integration compile/test sanity check on the current worktree
  - `SACSetScreenSaverCanRun returned 22` appeared during the targeted `xcodebuild` run and was non-fatal
  - `xcodebuild` warned that it used the first of multiple matching macOS destinations (`arm64` / `x86_64`)

## Risk declaration
- Breaking change: no, guarded behind `AGTMUX_COCKPIT_WORKBENCH_V2=1`
- Fallbacks: none; browser/document failures remain visible instead of silently degrading
- Known gaps / follow-ups:
  - `T-099` remains blocked on the Ghostty CLI-bridge carrier decision (`T-100`)

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Status
- Reviewer verdict: `GO`
- Reviewer source:
  independent Codex re-review after the document late-completion fix
