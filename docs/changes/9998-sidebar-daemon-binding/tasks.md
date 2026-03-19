# Tasks

- [x] implement the same-pane-instance local overlay promotion fix
- [x] add regression tests for overlay cache and sidebar-facing display state
- [x] restore managed-row provider badge / ring / trailing freshness semantics
- [x] add a fake-daemon UI regression test for managed Codex row rendering
- [x] route pane row title/subtitle fallback through `PaneDisplayState` so
      presentation-managed rows do not regress to `current_cmd=node`
- [x] update durable product knowledge for the restored managed-row sidebar
      contract
- [ ] remove `docs/changes/9998-sidebar-daemon-binding/` before merge

Validation:

- `swift test --build-path .build-codex --filter 'LocalMetadataOverlayStoreTests/testApplyV3ChangesAllowsManagedPromotionUpsertAtSameLocationWhenPaneInstanceMatches|AppViewModelA0Tests/testBootstrapV3ChangesV3ManagedPromotionAtSameVisibleLocationSurfacesSidebarDisplayState'`
- `swift test --build-path .build-codex --filter 'PaneDisplayStateTests|PaneRowAccessibilityTests|PreferredLocalMetadataClientTests|RuntimeHardeningTests/testEmbeddedXPCServiceNameMatchesBundledServiceIdentifier'`
- `xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarShowsDaemonPanes`
- `xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarManagedPaneRowsShowProviderBadgeRingAndTrailingTimestamp`
- `xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity'`
- installed release verification on 2026-03-19:
  - bundle daemon SHA-256 matches `/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/release/agtmux`
  - AX tree shows `%298` as `sidebar.pane.local_vm_agtmux_term__298`
    with title/description equal to the Codex conversation title while the
    `1: node, 1` text remains the separate window header element

Open follow-up:

- live `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  still fails on this host because the app's sync-v3 bootstrap probe continues
  to report `managed=0` and `provider=nil` after the real Codex command
  completes, which points at daemon-side truth emission rather than sidebar-only
  binding; reran on 2026-03-19 after the sidebar visual fix and saw the same
  daemon-truth failure
- daemon handoff note:
  - `/tmp/2026-03-18-daemon-sidebar-provider-handoff.md`
