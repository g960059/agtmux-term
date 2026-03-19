# Tasks

- [x] implement the same-pane-instance local overlay promotion fix
- [x] add regression tests for overlay cache and sidebar-facing display state
- [ ] update durable knowledge only if the implementation changes a lasting
      operator/developer workflow
- [ ] remove `docs/changes/9998-sidebar-daemon-binding/` before merge

Validation:

- `swift test --build-path .build-codex --filter 'LocalMetadataOverlayStoreTests/testApplyV3ChangesAllowsManagedPromotionUpsertAtSameLocationWhenPaneInstanceMatches|AppViewModelA0Tests/testBootstrapV3ChangesV3ManagedPromotionAtSameVisibleLocationSurfacesSidebarDisplayState'`
- `xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarShowsDaemonPanes`
- `xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity'`

Open follow-up:

- live `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  still fails on this host because the app's sync-v3 bootstrap probe continues
  to report `managed=0` and `provider=nil` after the real Codex command
  completes, which points at daemon-side truth emission rather than sidebar-only
  binding
- daemon handoff note:
  - `/tmp/2026-03-18-daemon-sidebar-provider-handoff.md`
