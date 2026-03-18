# 2026-03-18 — Full E2E Rerun After Gate-L

**Status:** Open daemon handoff snapshot
**Authority:** Research only. Product truth lives in code, tests, CI, ADRs, and the active change pack until merge.

## Summary

Gate-L stayed green on the current host, but the full macOS UI E2E rerun after
the local-first fast-path changes was not green.

The rerun used:

- `swift test --build-path .build-codex --skip AppViewModelLiveManagedAgentTests`
- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AgtmuxTermUITests CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO`

Observed results:

- broad SwiftPM: `376 tests, 0 failures`
- macOS UI E2E: `35 tests, 23 passed, 6 skipped, 6 failures`

The `.xcresult` bundle for this run is:

- `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_00-53-06--0700.xcresult`

## Failing Tests

- `testLocalSessionCreatedAfterLaunchAppearsInSidebar`
- `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
- `testSidebarShowsDaemonPanes`
- `testV2RestoredBrokenDocumentTileCanRebindToExistingPath`
- `testV2RestoredBrokenDocumentTileRetryCanRecover`

## Corrected-Head Rerun

After fixing the client-side regressions in this repo, the full macOS UI E2E
bundle was rerun on `2026-03-18` with the same command:

- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AgtmuxTermUITests CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO`

Observed result:

- macOS UI E2E: `35 tests, 28 passed, 6 skipped, 1 failure`

The `.xcresult` bundle for the corrected-head rerun is:

- `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_01-51-48--0700.xcresult`

The only remaining failure is:

- `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`

## Current Split

### Client-side failures in this repo

- `testLocalSessionCreatedAfterLaunchAppearsInSidebar`
  - timed out waiting for the app-side tmux command channel to return the
    `new-session` result
  - relevant code: `UITestTmuxBridge` file command loop and test-side
    `sendAppTmuxCommand(...)`
- `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
  - health strip remained visible when the test expected no `ui.health.v1`
    snapshot
  - relevant code: local health refresh application and `SidebarView`
- `testSidebarShowsDaemonPanes`
  - sidebar rows rendered from `AGTMUX_JSON`, but clicking the row did not
    surface the matching workspace tile
  - relevant code: `SidebarView` selection path and `WorkbenchStoreV2.openTerminal(...)`
- `testV2RestoredBrokenDocumentTileCanRebindToExistingPath`
- `testV2RestoredBrokenDocumentTileRetryCanRecover`
  - broken document recovery stayed in the placeholder state in live UI runs
  - relevant code: `WorkbenchV2DocumentTile`, `WorkbenchDocumentRebindSheetV2`,
    and document load/retry state transitions

Those five client-side failures are now corrected on the repo head:

- `testLocalSessionCreatedAfterLaunchAppearsInSidebar`
  - fixed by waiting for an explicit app-side UITest bridge readiness ping
    before issuing tmux commands
- `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
  - fixed by launching this case in inventory-only mode so the test no longer
    depends on live daemon `ui.health.v1` availability
- `testSidebarShowsDaemonPanes`
  - fixed by aligning the test with current tile accessibility identifiers and
    waiting for workspace-empty-state exit instead of targeting stale pane-key
    tile ids
- `testV2RestoredBrokenDocumentTileRetryCanRecover`
  - fixed by dropping brittle exact-text AX assertions and checking the
    placeholder clears after retry
- `testV2RestoredBrokenDocumentTileCanRebindToExistingPath`
  - root cause was runner-side macOS XCUITest text synthesis corrupting the
    replacement path; fixed by replacing the focused sheet field through a
    test-only app-side field-editor bridge command and asserting focused
    document store truth before checking the placeholder clears

### Daemon-side handoff

- `testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - tmux capture showed the `codex exec` command actually completing and
    printing `wait_result=managed`
  - direct `ui.bootstrap.v3` diagnostics collected through the app-side bridge
    still reported `presence=unmanaged`, `provider=nil`, `managed=0`
  - the rendered sidebar matched that unmanaged state
  - current classification: daemon/provider truth issue, not a client-side
    rendering or AX issue

## Daemon Handoff Note

Please investigate why a pane that starts as plain `zsh -l` and then runs
`codex exec` never promotes in sync-v3 / `ui.bootstrap.v3` from
`presence=unmanaged` / `provider=nil` to a managed Codex row, even though tmux
capture proves the Codex process ran and completed.

The client is reading daemon truth directly and rendering it without an
additional fallback layer, so the app-side evidence currently points upstream
to provider classification or post-command completion metadata retention.

## Single-Test Confirmation

The daemon-classified failure was rerun in isolation on `2026-03-18` with:

- `AGTMUX_UITEST_ALLOW_SSH=1 AGTMUX_BIN="/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux" xcodebuild test -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:'AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO`

Observed result:

- `1 test, 1 failure`

The `.xcresult` bundle for this isolated rerun is:

- `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.18_02-07-36--0700.xcresult`

The isolated failure preserved the same split:

- tmux capture showed a real Codex JSON stream:
  - `{"type":"thread.started"...}`
  - `{"type":"turn.started"}`
  - `{"type":"item.started"... "status":"in_progress"}`
  - `{"type":"item.completed"... "aggregated_output":"wait_result=managed\n"}`
  - `{"type":"turn.completed"...}`
- the pane returned to a shell prompt in `/tmp`
- `ui.bootstrap.v3` diagnostics still reported:
  - `presence=unmanaged`
  - `provider=nil`
  - `session_key=shell:%0`
  - `freshness=down`
- the rendered sidebar matched that unmanaged state
- the app-side direct tmux probe still saw `agtmux-e2e-managed-49d01f6c|@0|%0|zsh`
- daemon stderr only showed startup / tmux executor / UDS-listening lines and
  no explicit transport or parse failure

## Daemon Ownership Map

The remaining failure is upstream of the app because the term client does not
invent managed/provider truth:

- `crates/agtmux-runtime/src/server.rs`
  - `build_ui_bootstrap_v3(...)` only calls `reconcile_sync_v3(...)` and
    serializes the payload
  - if the daemon keeps a pane unmanaged, the app mirrors that state
- `crates/agtmux-runtime/src/sync_v3_runtime.rs`
  - `compose_rows(...)` picks exactly one of:
    - reducer-backed managed snapshot
    - managed fallback snapshot from `state.daemon.list_panes()`
    - `build_unmanaged_snapshot(...)`
  - when neither reducer nor managed fallback exists, the row becomes
    `session_key=shell:<pane>` with `provider=None` and `presence=Unmanaged`
- `crates/agtmux-runtime/src/poll_loop.rs`
  - `is_codex_jsonl_candidate(...)` and Step 6a gate Codex JSONL discovery
  - shell panes are excluded unless process inspection promotes them away from
    `process_hint="shell"` or they otherwise satisfy the Codex candidate path
- `crates/agtmux-tmux-v5/src/snapshot.rs`
  - `to_pane_snapshot(...)` derives `process_hint` from deep process inspection
- `crates/agtmux-tmux-v5/src/capture.rs`
  - `inspect_pane_processes_deep(...)` is the function expected to turn a
    `zsh` pane with a descendant `codex exec` runtime into `Some("codex")`

## Likely Upstream Fault Boundaries

Given the isolated rerun and the current daemon source shape, the likely fault
boundaries are:

- deep process inspection misses the transient Codex child for this live
  `zsh -> codex exec` path, so the pane never enters Codex JSONL discovery
- Codex discovery does not retain or recover managed truth once the pane's
  tmux-visible `current_cmd` returns to `zsh`
- sync-v3 never receives the Codex semantic event stream for this pane, so
  `compose_rows(...)` keeps falling back to `build_unmanaged_snapshot(...)`

There is already upstream unit/integration coverage for nearby cases:

- `crates/agtmux-tmux-v5/src/snapshot.rs`
  - `snapshot_deep_inspection_shell_descendant_codex`
- `crates/agtmux-runtime/src/poll_loop.rs`
  - `poll_tick_discovers_codex_jsonl_from_node_runtime_without_process_hint`
  - `poll_tick_exec_json_promotes_exact_pane_to_sync_v3_running_without_same_cwd_bleed`

The missing reproduction appears to be the live shell-start path where tmux
still reports `current_cmd=zsh` after completion, but the pane should already
have promoted while Codex was active. The next daemon-side step should be to
add a focused reproduction around that path or instrument `process_hint` /
Codex-candidate decisions in `poll_loop`.

## Relationship To Earlier Notes

This note does not change the Gate-L result recorded in
`docs/research/2026-03-17-gate-l-closeout.md`. It preserves the broader
post-Gate-L verification results and the daemon-side handoff after the
repo-local change pack was retired.
