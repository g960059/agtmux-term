# Review Pack

## Objective
- Task: T-090
- User story: tmux-first cockpit V2 foundation slice
- Acceptance criteria touched: Workbench V2 model exists, V2 path can render empty/placeholder terminal/browser/document tiles, linked-session path stays isolated

## Summary (3-7 lines)
- Added isolated V2 Workbench model types in `AgtmuxTermCore`.
- Added `WorkbenchStoreV2`, `WorkbenchAreaV2`, and `WorkbenchTabBarV2` for empty/placeholder rendering.
- Integrated the V2 path behind `AGTMUX_COCKPIT_WORKBENCH_V2=1` so the visible workspace/titlebar/sidebar-open path can switch to V2 without touching linked-session lifecycle.
- Sidebar open actions now branch to `SessionRef` placeholder insertion when the V2 flag is enabled; remote `TargetRef` now resolves configured host keys instead of raw hostnames; V1 behavior remains unchanged when the flag is off.
- Added focused model/store coverage for codable round-trips, pin semantics, placeholder insertion, fixture bootstrap, and remote hostname -> host-key mapping.
- Added a targeted feature-flag UI test for sidebar-open -> placeholder terminal and reran it from an unlocked interactive macOS session with an executed PASS result.

## Change scope (max 10 files)
- `Sources/AgtmuxTermCore/WorkbenchV2Models.swift`
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
- `Sources/AgtmuxTerm/WorkbenchTabBarV2.swift`
- `Sources/AgtmuxTerm/main.swift`
- `Sources/AgtmuxTerm/CockpitView.swift`
- `Sources/AgtmuxTerm/TitlebarChromeView.swift`
- `Sources/AgtmuxTerm/WindowChromeController.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/RemoteHostsConfig.swift`

## Verification evidence (Tester output)
- Commands run:
  - `swift build` => PASS
  - `swift test -q --filter WorkbenchV2ModelsTests` => PASS (3 tests)
  - `swift test -q --filter WorkbenchStoreV2Tests` => PASS (6 tests)
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` => PASS (1 test)
- Notes:
  - `Tests/AgtmuxTermCoreTests/WorkbenchV2ModelsTests.swift` was added and covered by the focused test command above.
  - `SACSetScreenSaverCanRun returned 22` appeared during the xcodebuild run and was non-fatal.

## Risk declaration
- Breaking change: no, guarded behind `AGTMUX_COCKPIT_WORKBENCH_V2=1`
- Fallbacks: none; invalid V2 fixture JSON fails loudly during store initialization
- Known gaps / follow-ups:
  - T-091 still needs real-session attach and duplicate-session handling on top of this foundation.

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- If NEED_INFO: list up to 3 concrete missing items + why required (no broad exploration)

## Verdict
- Previous reviewer verdict: `GO_WITH_CONDITIONS`
- Condition closeout evidence:
  - `T-096` added focused regression coverage for `pane.source` hostname -> configured `RemoteHost.id` -> V2 `SessionRef.target`
  - `T-097` reran `AgtmuxTermUITests.testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` from an unlocked interactive macOS session with an executed PASS result
- Final reviewer verdict: `GO`
