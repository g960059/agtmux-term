# Review Pack

## Objective
- Task: T-SM02
- User story: managed sidebar rows should show useful session identity and freshness without repeating provider identity already conveyed by the icon
- Acceptance criteria touched:
  - managed pane title fallback uses working-directory leaf name before `paneId`
  - managed pane freshness text stays visible while running
  - `AgtmuxPane` decodes and carries `session_subtitle`
  - managed pane rows render an optional subtitle line without layout jump; unmanaged rows stay single-line

## Summary
- Replaced the managed-row title fallback from provider raw value to working-directory leaf name so rows identify the workspace rather than repeating `codex`/`claude`.
- Kept managed freshness text visible while running by removing the running-state suppression in both compat and presentation-backed display paths.
- Added `sessionSubtitle` to `AgtmuxPane`, raw snapshot decoding, and sync-v3 snapshot decoding, then threaded it through local metadata overlay merge logic.
- Updated sidebar pane rows to a 2-line layout for managed panes, with an optional subtitle line and fixed managed-row minimum height to avoid jumpy layout.
- Added focused regression coverage for raw snapshot decode, sync-v3 decode, freshness behavior, and AppViewModel overlay/display behavior.

## Change scope
- `Sources/AgtmuxTermCore/CoreModels.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV3Models.swift`
- `Sources/AgtmuxTermCore/PaneDisplayCompatFallback.swift`
- `Sources/AgtmuxTermCore/PaneDisplayState.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/LocalMetadataOverlayStore.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Tests/AgtmuxTermCoreTests/{AgtmuxSnapshotDecodeCompatibilityTests,AgtmuxSyncV3DecodingTests,PaneDisplayCompatFallbackTests,PaneDisplayStateTests}.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`

## Verification evidence
- Commands run:
  - `HOME=$PWD/.swiftpm-home XDG_CACHE_HOME=$PWD/.swiftpm-home/.cache CLANG_MODULE_CACHE_PATH=$PWD/.swiftpm-home/.cache/clang/ModuleCache swift build --disable-sandbox` => PASS
  - `HOME=$PWD/.swiftpm-home XDG_CACHE_HOME=$PWD/.swiftpm-home/.cache CLANG_MODULE_CACHE_PATH=$PWD/.swiftpm-home/.cache/clang/ModuleCache swift test --disable-sandbox --skip AppViewModelLiveManagedAgentTests` => PASS
- Notes:
  - deterministic suite passed with 299 tests and 2 expected skips from sandbox/socket constraints
  - live managed-agent tests were intentionally skipped for this task per user instruction to verify deterministic coverage only

## Risk declaration
- Breaking change: yes
- Fallbacks: none; invalid metadata or decode failures still surface explicitly
- Known gaps / follow-ups:
  - `session_subtitle` is now decoded and carried through product paths, but there is no dedicated UI automation assertion on the second text line yet
  - managed row height is intentionally normalized even when subtitle is absent; review should confirm the visual tradeoff is acceptable

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Prioritize:
  - title fallback regressions when managed panes have blank titles or missing paths
  - subtitle propagation through sync-v3 overlay merge paths
  - sidebar layout regressions from the fixed managed-row height

## Review execution note
- Attempted `codex review --uncommitted` on 2026-03-11 after green local verification.
- The review CLI could not reach the Codex backend in this network-restricted sandbox (`failed to lookup address information` / HTTPS request failure), so no external verdict was returned.
