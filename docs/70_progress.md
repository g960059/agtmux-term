# Progress Ledger

This file keeps the recent progress surface small.
Historical progress detail lives in `docs/archive/progress/2026-02-28_to_2026-03-06.md`.

## Current Summary

- V2 mainline docs are aligned and design-locked for MVP
- V2 Workbench sidebar/mainline integration is closed on code, focused verification, and dual Codex review
- local daemon runtime hardening and A2 health observability are complete
- `T-108` is now closed on app-side code, focused verification, and executed real-surface UI proof
- current follow-up boundary is explicit: if a fresh live disagreement appears, validate daemon payload truth before reopening the term consumer

## Recent Entries

## 2026-03-09 — T-123 landed: additive `ui.changes.v3` consumer path now keeps the exact local row current without cutting over the live render path

### What landed
- extended the term-side v3 wire model to match the daemon `ui.changes.v3` contract from `agtmux` commit:
  - `f37b5ad71c617e9396d71068de6b355d9afa1e28`
- added additive v3 replay session state in `AgtmuxSyncV3Session`
- extended direct/XPC daemon clients plus bundled service boundary with:
  - `fetchUIChangesV3(limit:)`
  - `resetUIChangesV3()`
- `AppViewModel` now carries a minimal transport-version adapter:
  - bootstrap-v3 establishes a v3 replay epoch
  - changes-v3 upsert/remove mutate the existing exact-row overlay cache without weakening identity
  - sync-v2 remains the intact fallback when bootstrap-v3 or changes-v3 is unsupported
- exact-row correlation stayed strict on:
  - `session_name`
  - `window_id`
  - `session_key`
  - `pane_id`
  - `pane_instance_id`
- current UI/render path still intentionally stays on legacy `AgtmuxPane` / `ActivityState`

### Focused coverage
- added core decode coverage for `ui.changes.v3`:
  - valid upsert batch
  - invalid remove-with-pane payload
  - invalid resync + batch metadata mixture
- added `AgtmuxSyncV3SessionTests`
  - bootstrap-required gate
  - cursor advance
  - resync reset
- added direct/XPC transport coverage for `fetchUIChangesV3()`
- added AppViewModel exact-row coverage for:
  - v3 upsert updates existing exact row
  - v3 remove clears overlay back to inventory truth
  - unsupported `ui.changes.v3` falls back to sync-v2 after bootstrap-v3

### Verification
- `swift build`
- `swift test -q --filter AgtmuxSyncV3DecodingTests`
- `swift test -q --filter AgtmuxSyncV3SessionTests`
- `swift test -q --filter RuntimeHardeningTests/testDaemonClientFetchUIChangesV3DecodesInlineOverride`
- `swift test -q --filter AgtmuxDaemonXPCClientTests`
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests`
- `swift test -q --filter AppViewModelA0Tests`
- result: all passed

## 2026-03-09 — T-121 landed: term-side v3 tests now consume daemon-owned canonical fixtures

### Fixture source of truth
- switched the v3 consumer tests away from local ad hoc positive fixtures
- canonical source is now the sibling `agtmux` repo at commit:
  - `cb198cca7226666fbb26df34d4e17582a208c3e6`
- fixture root:
  - `/Users/virtualmachine/ghq/github.com/g960059/agtmux/fixtures/sync-v3/`
- added a reusable loader so term tests read daemon-owned snapshots directly, with an env override only for alternate local checkouts

### Consumer coverage now fixed to canonical scenarios
- decode coverage explicitly includes:
  - `codex-running`
  - `codex-waiting-approval`
  - `codex-completed-idle`
  - `claude-approval`
  - `claude-stop-idle`
  - `unmanaged-demotion`
  - `error`
  - `freshness-degraded`
- presentation derivation coverage now uses the same daemon-owned fixtures for those scenarios
- local inline payloads remain only for consumer fail-closed negatives:
  - missing exact identity field
  - mismatched `pane_id` vs `pane_instance_id.pane_id`

### Additive client surface
- added a non-wired `fetchUIBootstrapV3()` decode surface to `AgtmuxDaemonClient`
- added `AGTMUX_UI_BOOTSTRAP_V3_JSON` inline override coverage so the v3 bootstrap decoder can be exercised without live wire cutover
- this is intentionally additive only:
  - no `AppViewModel` migration
  - no live UI path changes
  - no sync-v2 removal

### Verification
- `swift build`
- `swift test -q --filter AgtmuxSyncV3DecodingTests`
- `swift test -q --filter PanePresentationStateTests`
- `swift test -q --filter RuntimeHardeningTests/testDaemonClientFetchUIBootstrapV3DecodesDaemonOwnedFixtureFromInlineOverride`
- result: all passed

## 2026-03-09 — T-120 landed: term-side sync-v3 consumer foundation is in place without disturbing the live v2 path

### What landed
- added new core v3 consumer models in `Sources/AgtmuxTermCore/AgtmuxSyncV3Models.swift`
  - strict exact identity requirements remain explicit for:
    - `session_name`
    - `window_id`
    - `session_key`
    - `pane_id`
    - `pane_instance_id`
  - the new consumer model now has room for:
    - `agent.lifecycle`
    - `thread.lifecycle`
    - `blocking`
    - `execution`
    - `flags`
    - `turn`
    - `pending_requests`
    - `attention`
    - `freshness`
    - `provider_raw`
- added `Sources/AgtmuxTermCore/PanePresentationState.swift`
  - the term repo now has a local pure presentation derivation layer for v3 snapshots
  - this keeps future sidebar/titlebar work decoupled from raw daemon wire structs
  - `attention` is preserved as summary only; request identity truth remains `pending_requests[].request_id`
- added temporary local fixture-first tests derived from the final design doc:
  - `Tests/AgtmuxTermCoreTests/AgtmuxSyncV3DecodingTests.swift`
  - `Tests/AgtmuxTermCoreTests/PanePresentationStateTests.swift`
  - fixtures are explicitly marked as temporary until daemon-owned canonical fixtures arrive
- added local design notes in `docs/44_design-sync-v3-consumer.md`

### Verification
- `swift test -q --filter AgtmuxSyncV3DecodingTests`
- `swift test -q --filter PanePresentationStateTests`
- result: both passed

### Boundary notes
- this slice does not wire v3 into `AppViewModel`
- it does not remove `ActivityState`
- it does not alter the live sync-v2 product path
- the point of this slice is to let daemon-vs-term implementation proceed in parallel:
  - daemon can keep freezing canonical fixtures and wire shape
  - term can already build decode/presentation work against the agreed design
## 2026-03-09 — T-118 narrowed again: fresh desktop daemon shows same-session no-bleed is fixed, but shell demotion still fails when a non-agent child remains under the shell

### Fresh verification
- updated the term-side live canaries to the current producer contract:
  - `testLiveCodexActivityTruthReachesExactAppRowWithoutBleed` now accepts current daemon truth after `running` leaves the row
  - `testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed` does the same for Claude
  - new thin live canaries now exist for:
    - exact-row Codex managed-exit demotion
    - same-session same-provider Codex no-bleed after sibling demotion
- verification:
  - `swift test -q --filter AppViewModelA0Tests/testWaitingInputManagedRowSurfacesAttentionCountAndFilterWithoutBleed`
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests`
  - result: live suite passed with the new managed-exit / no-bleed canaries green and the old Codex `waiting_input` live canary explicitly skipped for recalibration

### Fresh desktop probe after restart
- launched the normal app path with `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift run AgtmuxTerm`
- the in-process supervisor now logs:
  - `restarting stale app-managed daemon ...`
  - `started managed daemon ...`
- direct probe against `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` is now a fresh oracle again
- fresh desktop truth is narrower than the original report:
  - same-session Codex `running` bleed no longer reproduces (`%2=running`, `%5=waiting_input`, `%6=waiting_input`)
  - but `vm agtmux-term %6` still reports `current_cmd=zsh presence=managed provider=codex activity=waiting_input`
- tmux process inspection shows `%6` is not agent-owned anymore:
  - shell pid `35774`
  - only child process `37202 chezmoi cd`
- conclusion:
  - the remaining live desktop mismatch is upstream semantic truth, but only for `shell + non-agent child` demotion
  - the original same-session no-bleed slice is closed at the term boundary

### Follow-up split
- `T-119` opened to recalibrate a real-Codex `waiting_input` live canary after the upstream immediate shell-demotion change
- deterministic consumer coverage for `waiting_input` attention/filter now lives in `AppViewModelA0Tests`

## 2026-03-09 — T-118 narrowed again: upstream fix landed, desktop daemon is stale, and Codex completion oracle must accept shell demotion

### Fresh validation
- upstream reported producer-side fixes for:
  - immediate exact-row shell demotion
  - same-session Codex no-bleed
  - new upstream online E2E for `managed-exit` and `same-session-codex-no-bleed`
- direct desktop-owned socket probing still shows the old bad truth:
  - `vm agtmux-term %6` remains `presence=managed provider=codex activity=Running current_cmd=zsh`
  - `%2`, `%5`, `%6` still all report `provider=codex activity=Running`
- the current desktop socket is stale relative to the rebuilt upstream binary:
  - app-owned socket mtime is older than `/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux`

### New downstream implication
- rerunning `AppViewModelLiveManagedAgentTests` against the rebuilt binary shows the Codex canaries are now too strict:
  - Codex `exec` can complete by immediately demoting back to unmanaged shell truth
  - existing tests still require managed completion as `waiting_input|idle`
- this is not evidence that the upstream fix failed; it means the terminal repo now needs to accept `managed completion or shell demotion` for one-shot Codex exec flows and add the exact live canaries that were previously missing

## 2026-03-09 — T-118 reopened immediately after T-116 closeout: direct daemon truth shows stale managed exit and same-session Codex bleed

### Fresh live evidence
- user reported that:
  - a Codex/Claude pane can return to `zsh` after `Ctrl-C`, yet the sidebar still shows the pane as managed/provider-tagged
  - when one Codex pane in the same session becomes `running`, sibling Codex panes can also surface as `running`
- direct probe against the app-owned daemon socket confirms this is producer truth, not just terminal rendering:
  - `vm agtmux-term %6` currently reports `presence=managed provider=codex activity=Running current_cmd=zsh`
  - the same session reports `%2`, `%5`, and `%6` all as `provider=codex activity=Running`

### Coverage gap
- terminal-repo coverage is not sufficient for these exact live symptoms:
  - model-layer `managed -> unmanaged` clearing exists
  - upstream `managed-exit.sh` exists
  - but there is no terminal-side live canary for exact-row managed-exit demotion
  - and there is no upstream/downstream live canary for same-session same-provider no-bleed across multiple Codex panes

### Result
- reopened tracking as `T-118`
- the issue is handed back upstream as semantic truth / producer correlation, not a row-rendering bug

## 2026-03-09 — T-116 closed on row-level AX surfacing and live plain-zsh Codex proof

### Term-side fix
- replaced the fragile pane-row AX contract:
  - pane rows no longer rely on hidden provider/activity overlay descendants beneath a `.combine` wrapper as the primary live-test oracle
  - the visible row button now carries an explicit accessibility label/value summary with `selection`, `presence`, `provider`, `activity`, and `freshness`
- kept provider/activity visual rendering on the row and made template-rendered provider icons explicit, so Codex/Copilot marks do not rely on default template coloring
- added pure regression coverage:
  - `PaneRowAccessibilityTests`
  - verifies managed rows expose provider/activity/freshness and unmanaged rows fail closed to `none`

### Live verification
- reran:
  - `swift build`
  - `swift test -q --filter PaneRowAccessibilityTests`
  - `swift test -q --filter AppViewModelA0Tests`
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests`
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- result:
  - all focused verification is green
  - the metadata-enabled plain-zsh Codex UI lane now passes end to end
  - the UI proof also waits for completion-state freshness on the managed row, covering the prior user-visible “provider mark / updated-at” gap

## 2026-03-09 — T-116 narrowed again: producer truth is green, remaining red is pane-row AX surfacing

### Upstream outcome
- the explicit-socket app-child producer fix is now landed upstream and green on its own focused repros
- in the same downstream metadata-enabled plain-zsh Codex UI lane:
  - live probing sees `ui.bootstrap.v2` surfacing the target row as managed Codex with `running|waiting_input`
  - the app-side sidebar snapshot also reports the exact target pane as `presence=managed, provider=codex, activity=waiting_input`

### New conclusion
- the remaining `T-116` failure is no longer daemon truth or bootstrap readiness
- the current red is terminal-side accessibility surfacing:
  - the UI proof still times out on `paneProviderMarker` / `paneActivityMarker`
  - pane rows currently expose those markers as tiny hidden overlay children underneath a `.combine` wrapper on the row button
  - this makes the AppViewModel/sidebar snapshot green while the XCUITest descendant search still fails

### Next step
- replace the fragile hidden-marker contract with a stable pane-row accessibility contract on the visible row itself
- keep the metadata-enabled plain-zsh Codex XCUITest as the live canary that proves the real row exposes provider/activity after promotion

## 2026-03-09 — T-116 root cause corrected again: empty bootstrap is not a ready sync-v2 epoch when inventory already exists

### Live repro
- reproduced the focused UI failure outside XCUITest with the same essential launch shape:
  - isolated `tmux -f /dev/null -L <name>`
  - explicit daemon launch `agtmux --socket-path <custom.sock> daemon --tmux-socket <resolved socket path>`
  - plain `zsh -l` pane
  - real `codex exec --json --model gpt-5.4`
- result:
  - tick 1: `ui.bootstrap.v2` returned `snapshot_seq=0 panes=[] sessions=[]`
  - tick 2+: the same isolated daemon/runtime returned the expected pane rows
  - direct `tmux -S <resolved socket path> list-panes` was healthy throughout, so the transient empty bootstrap was not tmux inventory loss

### Conclusion
- the remaining T-116 red is not purely “upstream producer still empty forever”
- term also had a real readiness bug:
  - `AppViewModel` primed sync-v2 ownership on the first successful bootstrap even when local inventory was already non-empty
  - an empty bootstrap carries no visible `session_name` / `window_id` mapping, so later exact-row change replay cannot recover managed overlay from that primed epoch
- next patch is term-side:
  - do not mark local sync-v2 ready on `inventory present + bootstrap panes=[]`
  - keep retrying until a non-empty bootstrap arrives
  - make the focused metadata-enabled XCUITest wait for that non-empty isolated bootstrap before it launches the real Codex proof

## 2026-03-09 — T-116 term-side empty-bootstrap hardening landed; remaining red is upstream app-child daemon bootstrap

### Term-side fix
- changed `AppViewModel` so `inventory present + ui.bootstrap.v2 panes=[]` is treated as startup-not-ready instead of a primed sync-v2 epoch
- this explicitly resets sync-v2 ownership, keeps local rows inventory-only, and retries bootstrap later
- added regression:
  - `swift test -q --filter AppViewModelA0Tests/testEmptyBootstrapWithLiveInventoryDoesNotPrimeSyncOwnershipAndLaterHealthyBootstrapRecovers`
  - PASS
- full focused integration verification:
  - `swift test -q --filter AppViewModelA0Tests`
  - PASS (41/41)

### Focused UI rerun
- reran:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- result:
  - the lane now fails before launching the live Codex proof
  - readiness gate times out with:
    - `probe=ok total=0 managed=0 probeTarget=nil`
    - visible app inventory row still present as unmanaged `zsh`
  - new daemon stdout/stderr capture shows only:
    - `agtmux daemon starting`
    - `UDS server listening on /Users/virtualmachine/.agt/uit-<token>.sock`
  - there is still no app-child bootstrap progress after daemon listen
  - stronger same-process evidence now also exists:
    - app-side direct socket probe reports `agtmux-e2e-managed-<token>|@0|%0|zsh`
    - so the same app process can run `tmux -S <resolved socket path> list-panes` and see the isolated pane
    - only the app-child daemon stays stuck at `ui.bootstrap.v2 total=0`

### Conclusion
- term-side readiness bug is fixed
- remaining T-116 blocker is upstream again:
  - app process inventory sees the isolated tmux pane
  - app-child daemon starts and listens on the custom socket
  - the same daemon never reaches a non-empty `ui.bootstrap.v2` in this metadata-enabled app/XCUITest lane

## 2026-03-09 — T-116 delayed metadata enable fixed the remaining UI harness blockers; red is upstream managed promotion again

### Term-side harness progress
- changed the plain-zsh metadata-enabled UI lane to launch inventory-only first, then enable metadata/managed-daemon startup explicitly after the app is already foregrounded
- added a UI-test internal command to enable metadata mode on demand and taught `AppViewModel` to leave inventory-only mode after that switch
- delayed metadata enable now starts the isolated managed daemon synchronously on the custom socket instead of fire-and-forget background startup
- focused verification:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`
  - both green

### Focused UI reruns
- reran:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- result:
  - the lane no longer fails at `launch()` with `Running Background`
  - the lane no longer fails with `managedSocket ... No such file or directory`
  - the lane now proves the isolated daemon was actually spawned on the custom socket:
    - `daemonLaunch=spawned:/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux:--socket-path,/Users/virtualmachine/.agt/uit-<token>.sock,daemon,--tmux-socket,/private/tmp/tmux-501/agtmux-managed-<token>`
    - `daemonEnv=... TMUX_BIN=/opt/homebrew/bin/tmux ...`
  - despite that, the same focused lane still fails at the real product assertion with:
    - `capture-pane` showing a real Codex run completed inside the target plain `zsh` pane
    - `probe=ok total=0 managed=0`
    - `probeTarget=nil`

### Conclusion
- the remaining T-116 red is no longer attributable to:
  - UI foreground activation
  - delayed daemon startup
  - missing custom daemon socket creation
- the blocker is upstream producer truth again:
  - explicit `--tmux-socket` app-child daemon is alive on the correct socket
  - it still promotes zero managed sync-v2 rows for the plain-zsh-launched Codex pane

## 2026-03-08 — T-116 spawn-env hardening landed but did not clear the app-launched empty-bootstrap failure

### Term-side hardening
- added `ManagedDaemonLaunchEnvironment` and routed both direct/XPC daemon launch plus reachability probes through it
- managed-daemon child env now:
  - clears inherited `TMUX` / `TMUX_PANE`
  - normalizes `HOME`, `USER`, `LOGNAME`, `XDG_CONFIG_HOME`, `CODEX_HOME`, `PATH`
  - injects explicit `TMUX_BIN` when resolvable
- focused verification:
  - `swift test -q --filter RuntimeHardeningTests`
  - `swift test -q --filter LocalTmuxTargetTests`
  - `swift test -q --filter AppViewModelLiveManagedAgentTests`
  - all green

### Focused UI rerun
- reran:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- result:
  - the lane still fails at the real managed-row assertion
  - `capture-pane` still proves the real Codex run completed in the target app-driven pane
  - app-side daemon probe still reports `total=0 managed=0 probeTarget=nil`
  - new diagnostics confirm the child daemon already received:
    - `TMUX_BIN=/opt/homebrew/bin/tmux`
    - normalized `HOME/USER/LOGNAME/XDG_CONFIG_HOME/CODEX_HOME/PATH`
  - interpretation correction:
    - this proves sync-v2 bootstrap contains zero managed rows
    - it does not, by itself, prove the daemon's tmux inventory is empty

### Conclusion
- term-side env normalization was necessary hardening, but it was not sufficient
- `T-116` remains blocked by upstream `agtmux:T-XTERM-A6`
- fresh handover should now emphasize:
  - exact socket handoff is correct
  - stripped-PATH producer repro is fixed
  - normalized child-daemon env is also correct
  - yet the app-launched daemon still returns `ui.bootstrap.v2 total=0`

## 2026-03-08 — T-116 narrowed again after upstream stripped-PATH fix: remaining red is app child-daemon environment hardening

### Upstream verification
- rebuilt the local producer binary and reran the explicit-`--tmux-socket` stripped-PATH repro:
  - `cargo build -p agtmux`
  - `cargo test -p agtmux-tmux-v5`
  - `bash scripts/tests/e2e/scenarios/explicit-tmux-socket-sanitized-path.sh`
  - `cargo test -p agtmux`
- result:
  - stripped-PATH repro is now green (`explicit --tmux-socket inventory survives stripped PATH`)
  - upstream `cargo test -p agtmux` is green on the rebuilt binary

### Downstream reruns
- reran lower-layer term canaries against the rebuilt daemon binary:
  - `swift test -q --filter LocalTmuxTargetTests`
  - `swift test -q --filter AppViewModelLiveManagedAgentTests`
  - all green
- reran the focused metadata-enabled UI proof:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- current failure is unchanged in shape but now better isolated:
  - `capture-pane` proves the real Codex run completed in the target pane
  - app-side daemon probe still reports `total=0 managed=0 probeTarget=nil`
  - `daemonArgs` and `bootstrapTmuxSocket` still match exactly
  - daemon stderr remains empty

### Conclusion
- `T-XTERM-A6` fixed the producer-side stripped-PATH gap, but the metadata-enabled UI lane still differs from shell repro
- the remaining hypothesis is the app-launched child-daemon environment itself:
  - shell repro and lower-layer live canaries are green
  - focused XCUITest still spawns a daemon that sees an empty tmux universe
- next term-side slice is to normalize managed-daemon spawn env and pass explicit `TMUX_BIN` so app/XCUITest child launches see the same tmux runtime conditions as shell launches

## 2026-03-08 — T-116 root cause corrected: metadata-enabled UI lane reuses the persistent app-owned daemon socket

### Fresh focused UI evidence
- reran the focused metadata-enabled plain-zsh Codex UI proof:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
- the lane now enters the assertion body reliably and fails with high-signal diagnostics:
  - `probe=ok total=5 managed=5`
  - `probeTarget=nil`
  - visible target row remains inventory-only (`presence=unmanaged, provider=nil, activity=unknown, current_cmd=zsh`)

### Root cause correction
- the previous startup-order hypothesis was incomplete
- direct inspection now shows the real split:
  - app-driven local inventory targets the isolated `AGTMUX_TMUX_SOCKET_NAME`
  - the managed daemon client still talks to the persistent app-owned daemon socket at `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock`
  - when that socket already has a reachable daemon from a normal app launch, the metadata-enabled UI test reuses daemon truth from the user's normal tmux universe
- result:
  - the app-side bootstrap probe is healthy, but it is probing the wrong daemon runtime for the metadata-enabled UI lane
  - the target app-driven pane is absent from daemon truth even though local inventory sees it

### Remediation direction
- keep managed-daemon startup off the metadata-enabled launch critical path
- additionally isolate daemon socket path per metadata-enabled app-driven XCUITest, not just tmux socket name
- route both `AgtmuxDaemonClient` and the managed-daemon supervisors through one env-resolved socket path so app-side probe and visible sidebar consume the same daemon truth

## 2026-03-08 — T-117 opened: reachable stale app-managed daemon still poisons metadata-enabled truth after AGTMUX_BIN rebuilds

### Fresh live evidence
- user reran the normal app path with:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift run AgtmuxTerm`
- the current app log again shows strict local sync-v2 failure:
  - `RPC ui.bootstrap.v2 parse failed: sync-v2 bootstrap pane missing required exact identity field 'session_name'`
- direct probe of the app-managed socket confirms the producer truth is actually invalid on the live path:
  - `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` currently returns 39 managed rows with `session_name = null` / `window_id = null`

### Root cause refinement
- the local debug daemon binary was rebuilt later in the day:
  - `/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux` mtime: `2026-03-08 18:59:32`
- but the current daemon process serving the app-owned socket is much older:
  - PID `1926`
  - start time `2026-03-08 12:47:30`
- current `AgtmuxDaemonSupervisor` and `ServiceDaemonSupervisor` only check `agtmux json` reachability.
- result:
  - a stale but still reachable daemon is silently reused across local daemon rebuilds
  - metadata-enabled UI reruns and normal app launches can keep consuming old invalid producer truth even after the daemon repo fix has landed locally
  - the first hardening pass that compared socket mtime to binary mtime is not sufficient; fresh live repro still hits invalid bootstrap rows because the actual stale invariant is the daemon process start time, not just the socket file timestamp

### Immediate test impact
- metadata-enabled UI is no longer purely a foreground-activation problem:
  - `testSidebarHealthStripShowsMixedHealthStates` ✅
  - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux` ❌ because the expected sidebar pane row never appears under stale invalid metadata
- this makes daemon freshness the current prerequisite before more `T-116` UI-harness analysis

### Tracking result
- opened `T-117` for app-managed daemon freshness restart
- `T-116` remains open, but only after metadata-enabled lanes are running against a fresh daemon runtime again
- narrowed follow-up: once process-aware freshness is landed, the remaining UI red should be treated as plain-zsh Codex managed-row surfacing, not a generic foreground-activation issue

## 2026-03-08 — T-116 narrowed again: metadata-enabled lane still has a launch-critical managed-daemon startup hazard

### Fresh rerun evidence
- after the process-aware daemon freshness hardening, `swift run AgtmuxTerm` with the rebuilt local daemon binary now starts a fresh managed daemon and direct `ui.bootstrap.v2` probe on `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` returns valid strict rows again
- however, the focused metadata-enabled XCUITest lane is still unstable before it reaches the managed-row assertion body:
  - `xcodebuild ... testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity` can fall back to `Failed to activate application ... (current state: Running Background)`
  - this only happens on the metadata-enabled lane where the app currently performs managed-daemon startup on the launch critical path

### Tracking result
- `T-116` is now explicitly split into:
  - launch-path stability for metadata-enabled XCUITest
  - plain-zsh Codex managed-row surfacing once launch is stable
- next remediation direction is to move managed-daemon startup off the launch critical path while keeping daemon-truth diagnostics app-side

## 2026-03-08 — T-116 root cause refined: metadata-enabled daemon binds before the app-driven tmux socket exists

### Fresh app-side diagnostics
- after moving managed-daemon startup off the launch critical path, the focused metadata-enabled plain-zsh Codex UI proof now reaches the managed-row assertion body again
- the new app-side sidebar snapshot plus direct in-app bootstrap probe show:
  - `issue=nil`
  - `probe=ok total=5 managed=5`
  - `probeTarget=nil`
  - visible target row remains inventory-only (`presence=unmanaged, provider=nil, activity=unknown`)
- interpretation:
  - the daemon itself is healthy inside the app process
  - but it is not monitoring the isolated tmux server created for the app-driven UI test session
  - local inventory still sees the target pane, so the split is specifically between inventory and daemon socket binding

### Root cause refinement
- current metadata-enabled UITest startup order is:
  1. app starts managed daemon
  2. `UITestTmuxBridge` creates the isolated tmux socket/server/session
- in that order, the daemon can bind to the wrong tmux universe before the explicit `AGTMUX_TMUX_SOCKET_NAME` server actually exists

### Tracking result
- next patch should reverse the ordering for metadata-enabled app-driven tmux tests:
  - create/bootstrap the isolated tmux server first
  - then start the managed daemon
  - then let polling converge managed metadata onto the target row

## 2026-03-08 — T-115 closed on updated daemon truth; T-116 opened for metadata-enabled UI foreground activation

### Upstream state change
- `agtmux:T-XTERM-A5` is now fixed upstream:
  - managed rows are explicitly demoted when the pane returns to shell state
  - Claude follow-up validation is complete on the daemon side
- user-reported upstream verification:
  - `cargo test -p agtmux-daemon-v5` ✅
  - `cargo test -p agtmux` ✅
  - `PROVIDER=codex bash scripts/tests/e2e/scenarios/managed-exit.sh` ✅
  - `PROVIDER=claude bash scripts/tests/e2e/scenarios/managed-exit.sh` ✅
  - `PROVIDER=claude bash scripts/tests/e2e/online/run-all.sh` ✅

### Term-side revalidation
- reran the exact-row clear regression against the current worktree:
  - `swift test -q --filter AppViewModelA0Tests/testManagedExitChangeClearsStaleProviderActivityAndTitleOnNextPublish` ✅
- reran the full live AppViewModel managed-agent canary suite against the updated daemon binary:
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` ✅
  - result: 5 tests passed (`Claude`, `Codex`, `waiting_input`, plain-zsh managed launch surfacing)

### Remaining red
- reran the focused metadata-enabled plain-zsh XCUITest:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - current result: the test launches, enters the body, and then fails because `XCUIApplication.launch()` cannot foreground `AgtmuxTerm.app` (`current state: Running Background`)

### Tracking result
- `T-115` is now closed:
  - managed entry/exit truth is green at the term boundary against the updated daemon
  - runner-side Codex auth visibility is no longer the gating issue
- `T-116` is now the only active blocker:
  - isolate the metadata-enabled app-driven tmux XCUITest foreground activation failure
  - do not reopen managed-exit product truth unless lower-layer live canaries go red again

## 2026-03-08 — T-115 narrowed: term-side clearing is green, remaining live managed-exit mismatch is upstream, and the focused XCUITest now fails on activation instead of auth

### Term-side status
- added exact-row regression coverage for managed -> unmanaged clearing and kept it green:
  - `swift test -q --filter AppViewModelA0Tests/testManagedExitChangeClearsStaleProviderActivityAndTitleOnNextPublish` ✅
- refreshed live entry canaries against the updated daemon binary:
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` ✅
  - all 5 live tests passed (`Claude`, `Codex`, `waiting_input`, plain-zsh launch surfacing)

### Fresh producer-side managed-exit repro
- a fresh real tmux + real Codex shell repro now proves the remaining mismatch is upstream semantic truth, not the term-side clear-on-change reducer:
  - started a fresh daemon on a temp socket plus a fresh tmux server
  - launched real `codex exec` from a plain `zsh -l` pane
  - after the pane had returned to `current_cmd=zsh`, `agtmux json` still reported:
    - `presence=managed`
    - `provider=codex`
    - `activity_state=waiting_input`
    - `evidence_mode=heuristic`
- this evidence is being handed back to the daemon repo as `T-XTERM-A5`
- scratch handover: `/tmp/agtmux-managed-exit-semantic-truth-handover-20260308.md`

### XCUITest lane
- removed the focused UI proof's dependence on sandboxed runner-side `codex login status`; the test no longer skips solely because the runner cannot see the interactive shell auth context
- fresh targeted rerun:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - current result: the test body starts, launches the app, and then fails later with `Failed to activate application ... (current state: Running Background)`

## 2026-03-08 — T-115 opened: managed exit truth and runner-auth visibility are the remaining live gaps

### 事象
- fresh user evidence says two live problems still remain even after `T-114`:
  - plain `zsh` panes launching Claude/Codex do not always surface in the sidebar
  - after agent exit, the pane can return to a no-agent shell while stale provider marks stay visible
- the metadata-enabled XCUITest lane can now enter the test body after automation permission was granted, but it still skips because the sandboxed runner reports `codex login status: Not logged in`

### 切り分け
- the runner issue is no longer automation permission; PATH normalization already proved that by moving the failure from `env: node: No such file or directory` to a real auth check
- the remaining XCUITest blocker is auth visibility:
  - interactive shell: `codex login status` is logged in
  - sandboxed `xctrunner`: `codex login status` is not logged in
- on the product side, term coverage is strong for managed entry but still lacks a dedicated live managed-exit canary

### 方針
- add integration coverage for exact-row managed -> unmanaged overlay clearing
- add live E2E proving that a real agent started from plain `zsh` is later cleared back to no-agent shell state in the app consumer
- inject explicit real-user auth/config context into UITest runner shell helpers instead of depending on the runner container defaults

## 2026-03-08 — T-114 closed: single-writer local overlay plus live managed-filter canary lock the term-side recovery path

### 事象
- the producer-side daemon fix was already live, but a plain `zsh` pane that launched Claude/Codex could still stay inventory-only in the visible term consumer.
- the risky structural shape was two local-row writers in `AppViewModel`, which allowed stale inventory-only publishes to clobber newer metadata-derived managed rows.

### 実施内容
- completed the clean-break consumer refactor:
  - `fetchAll()` now owns local inventory only
  - local metadata stays in its own cache
  - visible local rows are derived at publish time from `inventory + metadata`
- added a live recurrence canary at the app-consumer boundary:
  - `testLivePlainZshAgentLaunchSurfacesManagedFilterProviderAndActivity`
  - the harness starts plain `zsh -l` tmux panes, launches real Claude plus real Codex, waits for daemon-managed truth, then requires `AppViewModel.statusFilter = .managed` to surface both rows with exact provider/activity truth
- kept the metadata-enabled XCUITest path for the same scenario, with explicit pane-row provider/activity AX markers, but did not depend on it for recurrence closure because the current desktop session still blocks XCTest automation mode before the test body starts

### Verification
- `swift build` ✅
- `swift test -q --filter AppViewModelA0Tests` ✅
- `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` ✅
  - 5 tests passed
  - includes the new plain-zsh managed-filter live canary
- targeted metadata-enabled XCUITest rerun:
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - current result after permission grant: test body starts, runner PATH normalization is fixed, but the sandboxed `xctrunner` still skips because `codex login status` returns `Not logged in`

### 結果
- the term-side consumer now has a structural guard against stale inventory-only overwrites
- the exact user-visible symptom class now has a live recurrence test at the app-consumer layer even when XCUITest automation is unavailable
- `T-114` is closed

## 2026-03-08 — T-114 implementation started: single-writer local overlay model is in place

### 事象
- fresh live user evidence still showed plain zsh panes launching Claude/Codex without visible provider/status surfacing, even after the upstream daemon fix was already live.
- direct socket probes proved daemon truth was already healthy, so the remaining bug moved into the term-side consumer.

### 実施内容
- narrowed the structural issue in `AppViewModel`:
  - `fetchAll()` was publishing local merged rows based on whatever metadata cache existed when inventory returned
  - background sync-v2 refresh could later publish a newer managed overlay
  - stale inventory-only local rows therefore had a path to overwrite newer metadata-derived local rows
- landed the clean-break consumer refactor:
  - local inventory cache and local metadata cache remain separate
  - `publishFromSnapshotCache()` now derives local visible rows from those two states
  - `fetchAll()` no longer writes local merged rows back into the shared snapshot cache
- added focused regressions:
  - healthy bootstrap recovery after an earlier incompatible bootstrap
  - slow remote fetch cannot overwrite a newer local managed overlay publish
- added targeted metadata-enabled UI live proof scaffolding for plain zsh → Codex surfacing:
  - explicit sidebar pane provider/activity AX markers
  - a metadata-enabled XCUITest that launches real Codex from a plain zsh pane

### Verification
- `swift build` ✅
- `swift test -q --filter AppViewModelA0Tests` ✅
- `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` ✅
- targeted UI live proof:
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - current result: blocked before test start by `Timed out while enabling automation mode.`

### 結果
- the consumer model is now structurally safer: local inventory refresh cannot silently clobber a newer managed overlay publish
- recovery + real CLI boundary canaries are green
- `T-114` remains open only for executed UI live proof on an automation-enabled desktop session

## 2026-03-08 — T-114 opened: local overlay publication is still structurally racy after healthy daemon recovery

### 事象
- fresh live user evidence says that a plain zsh pane can launch Claude/Codex, yet the visible sidebar still does not show it as a managed/provider/activity row.
- direct daemon probe on the same machine contradicts the UI:
  - `ui.bootstrap.v2` already returns `presence=managed` plus provider/activity truth for the affected rows
  - the bug therefore moved from producer detection to terminal-side publication / recovery

### 根本原因仮説
- current `AppViewModel` still has two local-row publishers:
  - `fetchAll()` stores a local merged snapshot using whatever metadata cache existed when inventory returned
  - background sync-v2 refresh later publishes a newer metadata-derived local snapshot
- that dual-writer model is structurally unsafe:
  - a stale inventory-only local snapshot can overwrite a newer managed metadata publish
  - the daemon can already be healthy while the visible sidebar remains inventory-only

### 方針
- clean-break the consumer model:
  - keep local inventory cache and local metadata cache separate
  - derive visible local rows from those two states at publish time
  - remove any path where `fetchAll()` writes stale local merged rows back into the shared pane cache
- add regression coverage for:
  - incompatible/bootstrap-cleared state recovering to healthy managed overlay without relaunch
  - no stale inventory-only overwrite after a later metadata publish
- add live E2E proving a real Claude/Codex process started from a plain zsh pane becomes a managed/provider/activity row in the visible app path

## 2026-03-08 — T-113 closed: persistent app-managed socket is clean after upstream bootstrap fix

### 事象
- `T-113` was reopened because the shipped app path was still consuming a dirty persistent daemon socket that emitted managed rows with null exact-location fields.

### 実施内容
- validated the upstream daemon fix now landed in `agtmux` commit `c9807f0` (`Exclude unresolved panes from sync bootstrap`)
- restarted the app-managed daemon and reprobed the real persistent socket at `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock`
- reran the terminal repo's live managed-agent canaries against the updated daemon binary

### Verification
- direct `ui.bootstrap.v2` probe on the app-managed socket now reports:
  - 4 panes total
  - 4 managed panes
  - 0 rows with null `session_name`
  - 0 rows with null `window_id`
- `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` ✅
  - 4 tests passed
  - Codex / Claude exact-row live canaries stayed green

### 結果
- the producer/consumer boundary is aligned again on the normal app-managed socket path
- `T-113` is closed in this repo
- remaining dirty-state online E2E expansion belongs upstream in `agtmux`; it is not a blocking terminal-repo task anymore

## 2026-03-08 — T-113 opened: live bootstrap drift on dirty daemon state hides all managed overlays

### 事象
- fresh live user evidence on Sunday, March 8, 2026 showed that pressing the agents filter no longer surfaces provider badges or updated-at labels even though Codex / Claude panes exist.
- app log repeatedly reports:
  - `RPC ui.bootstrap.v2 parse failed: The data couldn’t be read because it is missing.`
- direct inspection of the app-managed daemon socket then showed the real producer bug:
  - `ui.bootstrap.v2` currently returns 94 panes
  - 88 managed panes carry `session_name: null` and `window_id: null`
  - one invalid managed row is enough for the strict terminal consumer to reject the whole local metadata epoch, so the sidebar falls back to inventory-only rows and loses provider/activity/title overlays.

### なぜ online E2E が素通りしたか
- the current live canaries in this repo and the daemon repo both start a fresh daemon on a temporary socket with a fresh tmux session.
- that harness shape proves clean producer truth, but it does not reproduce dirty persistent daemon state with orphan managed rows that no longer have tmux-backed exact location.
- as a result:
  - clean-socket online E2E stayed green
  - the shipped app path using the persistent app-managed socket still failed

### 実施内容
- hardened terminal-side fail-loud surfacing first:
  - `AgtmuxSyncV2RawPane` now labels missing exact-location fields explicitly (`pane_id`, `session_name`, `session_key`, `window_id`, `pane_instance_id`) instead of collapsing to a generic missing-data decode error
- added focused regressions:
  - core decoding test for null `session_name`
  - app-level regression using a live March 8 style bootstrap fixture with one valid pane plus one orphan managed pane carrying null exact-location fields

### Verification
- `swift test -q --filter AgtmuxSyncV2DecodingTests/testDecodeBootstrapFailsWhenExactLocationFieldsAreNull` ✅
- `swift test -q --filter AppViewModelA0Tests/testLiveMarch8BootstrapSampleWithNullExactLocationFieldsFailsClosedAndSurfacesIncompatibleDaemon` ✅

### 結果
- terminal-side behavior is now clearer and more defensible:
  - the app still fails closed to inventory-only truth
  - but the surfaced error now names the missing exact field instead of hiding behind a generic decode failure
- product recovery is blocked on a daemon-side fix:
  - `agtmux` must stop emitting managed sync-v2 panes with null exact-location fields
  - producer-side online/e2e must add a dirty-state scenario so this class of drift cannot pass unnoticed again

## 2026-03-08 — T-109 started: rendered-client tmux session switch is not yet reflected in sidebar

### 事象
- after commit/push of the V2 mainline, fresh live user evidence on Sunday, March 8, 2026 exposed a new reverse-sync gap:
  - when the main terminal changes tmux session from inside the rendered client (for example via `repo` in `~/.config/zsh`), the sidebar remains on the old session
  - this is not the earlier same-session pane retarget bug; the rendered tmux client itself has moved to another session while the app still projects the original `SessionRef`

### 実施内容
- inspected the current render-path observation flow before code:
  - `WorkbenchV2TerminalNavigationResolver.liveTarget(sessionRef:renderedClientTTY:...)` currently filters `list-clients` by both `client_tty` and stored `sessionRef.sessionName`
  - once the rendered client switches sessions, that observation path fails as `renderedClientUnavailable`
  - `WorkbenchStoreV2.syncTerminalNavigation(...)` only updates pane/window on the already stored session and cannot rebind tile identity to a newly observed session
- updated spec / architecture / workbench design / tracking docs first:
  - rendered-client cross-session switch is now explicit MVP contract
  - destination-session collision is defined as fail-loudly, not silent stale-sidebar fallback
- landed the app-side product slice:
  - `WorkbenchStoreV2` now rebases the visible tile's `SessionRef` and canonical active selection from observed rendered-client session switches
  - rendered-client observation now resolves by exact `client_tty` instead of stored session name
  - `GhosttyTerminalSurfaceRegistry` preserves generation/client tty across in-place session rebases on the same surface
- added and verified focused regressions:
  - `WorkbenchStoreV2Tests.testTerminalOriginatedSessionSwitchRebindsVisibleTileIdentityAndActiveSelection`
  - `WorkbenchStoreV2Tests.testTerminalOriginatedSessionSwitchFailsLoudlyOnDuplicateVisibleDestinationSession`
  - `swift build`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`

### 結果
- `T-109` is now the active product task.
- app-side implementation is in place and focused SPM verification is green.
- remaining closeout blocker is executed real-surface UI proof; the latest targeted arm64 rerun on March 8, 2026 failed before test execution with `Timed out while enabling automation mode.`

## 2026-03-07 — T-108 tracking reconciliation: final green is now the active source of truth

### 事象
- `T-108` itself was green, but tracking docs still mixed final-green state with older reopened blocker text:
  - `docs/65_current.md` still described the term consumer as open
  - `docs/70_progress.md` summary still said the active board was reopened on `T-108`

### 実施内容
- reconciled tracking to the final verified state:
  - kept the long reopen/repair history in the ledger
  - updated current-state docs so the active source of truth matches the final TDD closeout
  - recorded the explicit ownership boundary that any new live status disagreement should first be checked against `ui.bootstrap.v2` / `ui.changes.v2` daemon truth
- reran the central T-108 regression bundle after the tracking edit:
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter AppViewModelA0Tests`
  - targeted arm64 `xcodebuild` for:
    - `testPaneSelectionWithMockDaemonAndRealTmux`
    - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux`
    - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`

### 結果
- there is no open app-side blocker currently tracked for pane retarget / reverse sync
- the final green evidence for `T-108` is now the active current-state baseline

## 2026-03-07 — T-108 root cause narrowed to rendered-client tty binding failure

### 事象
- targeted UI reruns now show the remaining pane-sync failure is lower than the reducer/store layer:
  - sidebar pane click updates the selected-row AX marker
  - the workbench creates a visible terminal tile for the selected session
  - `UITestTmuxBridge` still cannot resolve the active rendered terminal target because the rendered tmux client tty never binds
- vendor Ghostty source inspection then made the bind failure structural rather than heuristic:
  - embedded custom-OSC delivery is hard-wired to `OSC 9911`
  - the current `OSC 9912` surface-telemetry path can therefore never reach `GhosttyApp.handleAction(...)`

### 実施内容
- invalidated the previous assumption that the remaining gap was only “selection state dropped before open”.
- design-locked a clean break before code:
  - fold rendered-client tty bind into the existing structured `OSC 9911` bridge instead of relying on a second private OSC number
  - keep exact-client `switch-client -c <tty> -t <pane>` navigation, but make tty acquisition use the only supported host action seam
  - add failing coverage for missing tty binding and rerun same-session rendered-surface UI proofs on the unified bridge path

### 現状
- `T-108` remains open.
- same-session pane sync is still blocked on product work, not environment.

## 2026-03-07 — T-108 product slice landed: bootstrap fail-close and exact-client retry

### 事象
- live user evidence was still reproducible in code review terms:
  - local bootstrap collisions could fail open
  - same-session pane retarget relied on a one-shot `switch-client`
  - sidebar clicks could leave AppKit first responder on the sidebar instead of the visible terminal host

### 実施内容
- landed the metadata-side clean break:
  - bootstrap location collisions now throw an explicit sync-v2 incompatibility instead of silently choosing a preferred managed row
  - `AppViewModel` now surfaces that collision as `daemon incompatible` and clears stale overlay before the next publish
- landed the pane-sync runtime fix:
  - added `WorkbenchV2NavigationSyncResolver` and changed the terminal sync loop to retry exact-client navigation until rendered tmux client truth matches the requested pane/window
  - added `focusRequestNonce` to reducer-owned runtime pane state so same-session sidebar retargets re-focus the already visible Ghostty terminal host without recreating the tile
- added focused regression coverage:
  - `testBootstrapLocationCollisionFailsClosedForWholeLocalMetadataEpoch`
  - `WorkbenchV2NavigationSyncResolverTests`
  - `testSameSessionRetargetIncrementsFocusRestoreNonce`
  - `testObservedPaneSyncDoesNotBumpFocusRestoreNonce`
- verification:
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2NavigationSyncResolverTests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `swift build`
  - `xcodegen generate`

### 結果
- code-level fail-close and retry semantics are now aligned with the updated design.
- targeted pane-sync UI proof could not be re-executed yet because XCTest again failed before test execution with `Timed out while enabling automation mode.`
- remaining work is now narrowed to executed UI proof / review closeout, not another round of product redesign.

## 2026-03-07 — T-108 root cause narrowed again after live socket inspection and code re-read

### 事象
- the live local daemon still returns invalid `ui.bootstrap.v2` payloads, and the current product code still leaves two concrete gaps:
  - bootstrap/local overlay is still published by visible pane location, which can fail-open on stale or duplicate managed rows
  - same-session pane retarget still hinges on a one-shot `switch-client` attempt and does not explicitly restore terminal first responder after a sidebar click
- live daemon output on Saturday, March 7, 2026 also still reports a plain local `zsh` pane as managed `codex/running`, so “the daemon is wrong” is not an excuse for app-side fail-open behavior

### 実施内容
- compared the latest live socket output against current `AppViewModel`, `WorkbenchStoreV2`, `WorkbenchAreaV2`, and `GhosttySurfaceHostView`
- locked the next implementation slice before code:
  - bootstrap collisions or invalid rows must fail closed for the whole current local metadata epoch
  - exact-client navigation must retry until the rendered tmux client reports the requested pane/window
  - same-session sidebar retarget must explicitly restore first responder to the terminal host
- updated design/tracking docs to reflect those narrower root causes and TDD order

### 結果
- `T-108` is now constrained to two specific product fixes instead of a vague “pane sync is flaky” bucket
- next code slice is:
  - red tests for bootstrap collision fail-closed behavior
  - red tests for retryable exact-client navigation convergence
  - product code to clear stale overlay and un-wedge same-session pane retarget / reverse-sync

## 2026-03-07 — T-108 proposal comparison locked the clean-break plan before code

### 事象
- the user requested a plan-first reset with strong regression coverage after reporting live failures that the current tests did not prevent.
- four independent proposals were collected (`Codex x2`, real `Claude Code` x2).
- live daemon inspection also tightened the upstream failure shape:
  - `ui.bootstrap.v2` currently emits 50 pane rows
  - 44 of those are orphan managed rows with null `session_name` / `window_id`
  - live payloads still carry legacy `session_id`
  - current local metadata cannot be treated as trustworthy overlay input

### 実施内容
- compared the four proposals against current code/docs and locked the common clean-break direction:
  - invalid local managed rows are rejected at ingress instead of heuristically normalized
  - local overlay becomes exact-identity keyed and epoch-gated; incompatible bootstrap clears stale overlay before the next publish
  - persisted terminal identity stays `SessionRef = target + sessionName`
  - live pane focus becomes reducer-owned runtime state split into rendered-client binding, desired `ActivePaneRef`, and observed `ActivePaneRef`
  - sidebar click, duplicate reveal, terminal-originated pane change, and focus observation all dispatch through that same reducer
  - pane-sync UI/E2E proof must require four agreeing oracles:
    - exact rendered tmux client pane/window truth
    - reducer-resolved active pane state
    - sidebar selected-row marker
    - stable rendered-surface identity
  - reverse-sync proof must stimulate pane changes on that same rendered client tty; a generic tmux control client is no longer accepted as product evidence
- updated spec / architecture / workbench design / tracking docs before code changes.

### 結果
- the implementation plan is now re-locked on a narrower, cleaner model rather than more guards on the split state machine.
- next step is TDD-first implementation for:
  - stale-overlay eviction after incompatible bootstrap following previously valid metadata
  - reducer-owned desired-vs-observed pane state
  - stronger exact-client live tmux regression oracles

## 2026-03-07 — T-108 fix shape narrowed again: reject legacy payloads and prove rendered surface state

### 事象
- fresh live daemon inspection on Saturday, March 7, 2026 confirmed `ui.bootstrap.v2` is still returning legacy `session_id` on local pane rows, not just missing exact-identity fields.
- current pane-selection proofs can show store/sidebar/tmux agreement, but they still do not prove that the visible Ghostty surface was rebound to the same target.

### 実施内容
- tightened the app-side contract again before code:
  - local sync-v2 payloads that still carry `session_id` are now treated as incompatible whole-payload input, not as partially acceptable additive metadata
  - pane-selection UI/E2E proof now requires a fourth oracle:
    - rendered Ghostty surface attach state for the visible tile
- updated spec / architecture / workbench design / tracking docs to reflect that narrower implementation target.

### 結果
- the next implementation slice is now explicit and TDD-shaped:
  - add raw sync-v2 rejection for legacy `session_id` local payloads
  - add a rendered-surface registry/snapshot oracle for UI/E2E
  - rerun same-session retarget and reverse-sync proofs against all four agreeing signals

## 2026-03-07 — T-108 review returned dual NO_GO; current gap is contract drift, not environment

### 事象
- after the green verification pass, two independent Codex reviews both returned `NO_GO`.
- the findings align on two contract drifts:
  - bootstrap overlay still deduplicates by visible pane location and can fail-open if multiple `pane_instance_id` values land on the same slot
  - the documented `ActivePaneRef` reducer is still not present in product code; current sidebar selection derives from focused terminal tile context only

### 実施内容
- compared the review findings against code and docs:
  - `docs/30_architecture.md` and `docs/41_design-workbench.md` still require `paneInstanceID`-first matching plus a separate active-pane reducer
  - `AppViewModel` bootstrap merge still groups by `source/session/window/pane`
  - `WorkbenchStoreV2` / `SidebarView` still expose focused terminal context instead of a standalone `ActivePaneRef`
- reopened `T-108` and moved the next slice back to TDD-first implementation.

### 結果
- current status is no longer “review-ready”.
- next implementation slice is narrowly defined:
  - fail loudly on bootstrap exact-identity collisions
  - implement the documented `ActivePaneRef` reducer and cover non-terminal focus / explicit remote edge cases

## 2026-03-07 — T-108 verification closed green; initial UI red was an oracle mismatch, not a product regression

### 事象
- after landing the exact-identity gate plus active-pane reducer path, the first targeted UI rerun still failed.
- the failure was narrower than the original user bug:
  - session/window/pane targeting already matched live tmux truth
  - only the `selectedPaneInventoryID` assertion failed
  - the UI oracle was still expecting the accessibility key form while the app snapshot was already returning canonical `pane.id`

### 実施内容
- aligned the app-driven tmux snapshot and UI oracle to the same canonical selection contract:
  - `UITestTmuxBridge` exports the focused V2 terminal selection from `WorkbenchStoreV2`
  - the UI test now compares `selectedPaneInventoryID` against canonical pane inventory identity (`source:session:pane`)
- kept the product-side reducer on one path:
  - exact-identity decode/XPC coverage stays strict
  - local metadata without `session_key` / `pane_instance_id` still degrades to inventory-only
  - same-session pane retarget and terminal-originated focus changes continue to flow through the focused terminal tile navigation state
- reran fresh focused verification:
  - `swift build`
  - `swift test -q --filter AgtmuxSyncV2DecodingTests`
  - `swift test -q --filter AgtmuxDaemonXPCClientTests`
  - `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - targeted arm64 `xcodebuild` for:
    - `testPaneSelectionWithMockDaemonAndRealTmux`
    - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux`

### 結果
- `T-108` acceptance is green on code and verification.
- the live tmux proofs now execute pass for both directions:
  - sidebar pane click -> visible terminal retarget
  - terminal-originated pane change -> sidebar highlight update
- current next step is review/closeout, not more product debugging.

## 2026-03-07 — T-108 root cause tightened: current daemon omits exact identity, so app must clean-break to inventory-only

### 事象
- direct inspection of the live local daemon on March 7, 2026 shows `ui.bootstrap.v2` is still returning managed/provider/activity rows without `session_key` or `pane_instance_id`.
- this means the earlier app-side assumption that exact pane location alone was enough to trust overlay is false in the current environment.
- live symptoms line up with that gap:
  - plain `zsh` panes are surfaced as managed Codex/Claude rows
  - idle panes are surfaced as `running`
  - orphan metadata rows with `session_name = null` / `window_id = null` still exist upstream

### 実施内容
- queried the live daemon socket directly and compared both `agtmux json` and `ui.bootstrap.v2`.
- confirmed the payload gap is not limited to fixtures or the XPC boundary; the in-process local daemon path also omits exact identity today.
- updated spec / architecture / workbench design / plan / tracking docs so the app-side fix is now explicit:
  - managed/provider/activity overlay is exact-identity gated
  - missing `session_key` / `pane_instance_id` is treated as incompatible metadata, not as a normalization path
  - the app must clear stale overlay and publish inventory-only rows instead of surfacing guessed managed state

### 結果
- T-108 now has a concrete product root cause for the metadata half of the bug, not just a generic “instance-first” direction.
- next implementation step is to make the red tests execute, add inventory-only degrade coverage for missing exact identity, and then land the metadata gate with the canonical active-pane reducer.

## 2026-03-07 — T-108 started: T-107 closeout is invalidated by live user evidence

### 事象
- the earlier `T-107` closeout was a false green:
  - plain `zsh` panes are still surfaced as `codex`
  - idle Codex panes are still surfaced as `running`
  - sidebar pane clicks do not reliably retarget the visible terminal
  - terminal-originated pane changes do not update sidebar highlight
- current passing UI/E2E proof is not sufficient because its main oracle reads app/workbench target state, not live tmux truth.

### 実施内容
- collected four independent remediation proposals (`Codex x2`, `Claude x2`) before changing code.
- compared the proposals against the current codebase and selected the common clean-break direction:
  - sync-v2 / XPC exact identity must preserve `session_key` and `pane_instance_id`
  - metadata merge must be instance-first and fail loudly on ambiguous or missing identity
  - active pane selection must be a canonical key, not `AppViewModel.selectedPane` as a copied pane snapshot
  - sidebar clicks and terminal-originated focus changes must update the same reducer
  - UI/E2E proof must assert live tmux active pane/window rather than only stored workbench target
- updated spec / architecture / workbench design / tracking docs before implementation.

### 結果
- `T-108` is now the active implementation task.
- next step is TDD-first: add failing regression and live E2E coverage for exact identity, same-session retarget, and terminal-to-sidebar reverse sync before product code changes.

## 2026-03-07 — T-107 closed: metadata isolation and same-session pane retarget are verified end-to-end

### 事象
- user-reported regressions were real:
  - a plain `zsh` pane could be surfaced as `codex`
  - idle Codex panes could be surfaced as `running`
  - selecting another pane row in the same real session did not retarget the visible terminal tile
- the first UI diagnosis also drifted into a stale desktop-lock explanation, while the real remaining gap moved into the app-driven tmux harness.

### 実施内容
- closed the metadata-isolation product slice already landed in `AppViewModel` / core pane identity types with focused `AppViewModelA0Tests` proof.
- closed the same-session pane-retarget product slice already landed in `SidebarView`, `WorkbenchStoreV2`, and `WorkbenchV2TerminalAttach` with focused `WorkbenchStoreV2Tests` and `WorkbenchV2TerminalAttachTests` proof.
- tightened the app-driven UI harness:
  - tmux multi-field observation now uses `|`, which tmux emits literally in `-F` output
  - pane/window discovery now polls app-side `list-panes` after `split-window` / `new-window`
  - file-bridge tmux commands retry instead of treating the first startup race as final
  - the UI oracle now reads active terminal target state from app-side `UITestTmuxBridge` snapshot output rather than AX `value`
  - same-session tile-count proof now scopes to the target session label
- simplified the terminal tile AX tree so the visible status path is the only `.status` contract.
- verification:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux`

### 結果
- exact-pane metadata and activity/provider state no longer bleed across unrelated rows.
- same-session pane selection now reuses the single visible terminal tile and retargets it to the requested window/pane without linked-session behavior.
- the rewritten pane-retarget UI proof is now executed green instead of depending on the old runner-created tmux path.

## 2026-03-07 — T-107 UI blocker corrected: current gap is pane discovery timing, not a locked desktop

### 事象
- the earlier `screenLocked=1` explanation was stale for the latest rerun.
- current session-state inspection shows an interactive console session, but the rewritten app-driven proof still skips while waiting for the `secondary` window pane descriptor.

### 実施内容
- corrected the active tracking/docs surface so `T-107` no longer treats a locked desktop as the current blocker.
- narrowed the remaining gap to the rewritten harness seam:
  - `testPaneSelectionWithMockDaemonAndRealTmux`
  - `waitForPaneDescriptor(...)`
  - app-driven tmux command/observation through `UITestTmuxBridge`

### 結果
- the outstanding work is now accurately scoped to app-driven tmux pane discovery timing.
- next step is to tighten the harness/observation path and rerun the targeted UI proof.

## 2026-03-07 — T-107 pane-retarget slice landed; initial UI rerun later proved to be blocked by harness timing, not lock state

### 事象
- same-session sidebar pane selection was still reusing the existing V2 session tile without carrying the requested pane/window intent, so the visible terminal stayed on the old pane.
- the remaining smoke `testPaneSelectionWithMockDaemonAndRealTmux` still used runner-created tmux state, which was the wrong seam for proving the new V2 behavior.

### 実施内容
- landed the same-session pane-retarget product slice:
  - `SessionRef` now carries `preferredWindowID` / `preferredPaneID` as explicit navigation hints while equality/hash stay `target + sessionName`
  - `WorkbenchStoreV2.openTerminal(...)` now merges pane/window intent into the existing session tile on duplicate-open reveal instead of dropping it
  - `WorkbenchV2TerminalAttach` now preselects the requested window/pane before `attach-session`
  - `SidebarView` pane-row open now passes exact pane/window hints into the V2 workbench path
- added focused integration coverage:
  - duplicate-open with different pane/window intent updates the stored tile in place
  - local/remote attach command generation preserves exact pane/window retarget intent
- rewrote `testPaneSelectionWithMockDaemonAndRealTmux` to an app-driven proof:
  - the app bootstraps the isolated tmux session
  - the test creates an additional window through the app-side tmux bridge
  - the oracle checks that the active tmux window/pane moves while the workbench still shows exactly one session tile and zero linked sessions
- verification:
  - `swift build`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux`

### 結果
- same-session pane selection now has a product-code path to retarget the single visible session tile instead of silently doing nothing.
- focused SPM verification is green.
- the first interpretation of the UI rerun was `screenLocked=1`, but later reruns and session-state inspection showed the current remaining gap is the app-driven `secondary` pane discovery timeout instead.

## 2026-03-07 — T-107 metadata-isolation slice landed green

### 事象
- local metadata overlay was correlating by `source + pane_id` only, so stale managed/provider/activity metadata could bleed onto unrelated exact rows.

### 実施内容
- extended pane metadata carrying types so exact local metadata identity survives decode/merge:
  - `Sources/AgtmuxTermCore/CoreModels.swift`
  - `Sources/AgtmuxTermCore/AgtmuxSyncV2Models.swift`
- rewrote local metadata merge/apply in `Sources/AgtmuxTerm/AppViewModel.swift` to:
  - key cached bootstrap metadata by exact row identity
  - resolve change payloads by `sessionKey` + exact pane row instead of raw `pane_id`
  - drop ambiguous or mismatched metadata instead of mislabeling panes
- added regression coverage in `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift` for:
  - stale managed metadata not turning plain `zsh` into `codex`
  - exact session alias rows not inheriting each other's provider/activity state
  - idle sibling rows staying idle when another alias row is `running`
- verification:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`

### 結果
- provider/activity metadata is now correlated by exact pane row rather than coarse pane ID.
- focused build and integration coverage are green for the metadata-isolation slice.
- same-session pane-retarget code and focused SPM verification are green.
- the rewritten UI proof builds and launches successfully, but final executed evidence still depends on tightening the app-driven pane discovery path and rerunning the targeted UI test.

## 2026-03-07 — T-107 started: exact pane navigation and metadata isolation regressions

### 事象
- user reported live regressions after the linked-session cleanup:
  - a plain `zsh` pane in `utm-main` is shown as `codex`
  - idle Codex panes are shown as `running`
  - selecting different pane rows within the same session does not move the main-panel terminal/cursor
- the remaining UI smoke `testPaneSelectionWithMockDaemonAndRealTmux` also still skips in this environment when the XCUITest runner cannot keep a runner-created tmux session alive.

### 実施内容
- captured the first-pass root-cause areas before implementation:
  - local metadata overlay currently keys by `source + paneId`, which is too coarse for exact-row isolation and stale-pane reuse
  - same-session sidebar pane selection currently calls `openTerminal(SessionRef)` with only session identity, so duplicate-open reveal drops pane/window intent
  - the skip-prone UI smoke still relies on runner-side `Process` launching `tmux new-session`, which is fragile under the sandboxed XCUITest bundle
- updated spec / architecture / workbench design / tracking docs to state the intended contract:
  - exact-pane metadata isolation
  - same-session pane selection reuses the existing session tile but navigates it to the requested pane/window

### 結果
- `T-107` is now the active implementation task.
- next step is delegated test-first implementation for metadata isolation, idle/running correctness, and same-session pane navigation.

## 2026-03-07 — T-106 closed: linked-session runtime and stale contracts are physically removed

### 事象
- even after V2 mainline landed, the repo still physically compiled the old linked-session workspace runtime and still carried linked-session-positive tests/docs.
- the test audit also exposed two UI contracts (`focus sync`, `same-window pane switch`) that belonged to the old pane-retarget workspace model rather than the current session-level V2 path.

### 実施内容
- removed dead linked-session runtime from shipped targets:
  - `Sources/AgtmuxTerm/WorkspaceArea.swift`
  - `Sources/AgtmuxTerm/WorkspaceStore.swift`
  - `Sources/AgtmuxTerm/LinkedSessionManager.swift`
- extracted the still-live shared pieces and removed legacy-only core helpers/tests:
  - added `Sources/AgtmuxTerm/TmuxCommandRunner.swift`
  - added `Sources/AgtmuxTermCore/SplitAxis.swift`
  - removed `Sources/AgtmuxTermCore/LayoutNode.swift`
  - removed `Sources/AgtmuxTermCore/TmuxLayoutConverter.swift`
  - removed `Tests/AgtmuxTermCoreTests/LayoutNodeTests.swift`
  - removed `Tests/AgtmuxTermCoreTests/TmuxLayoutConverterTests.swift`
- trimmed the remaining shipped runtime so no linked-session registration/indexing remains in `SurfacePool` / `GhosttySurfaceHostView`.
- deleted stale positive coverage and narrowed UI docs/tests to V2 truths:
  - removed `Tests/AgtmuxTermIntegrationTests/LinkedSessionIntegrationTests.swift`
  - removed linked-session title/runtime UI proofs
  - removed pane-level focus-sync / same-window fast-switch UI proofs because V2 is session-level direct attach and those were stale linked-session workspace contracts
  - updated `Tests/AgtmuxTermUITests/README.md` and `docs/41_design-workbench.md`
- verification:
  - `xcodegen generate`
  - `swift build`
  - `swift test -q --filter WorkbenchV2ModelsTests`
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests`
  - `swift test -q --filter PaneFilterTests`
  - `swift test -q --filter AppViewModelA0Tests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile`
- delegation note:
  - one UI/test cleanup worker was interrupted before returning a usable final report, but a second delegated verifier completed the final focused evidence on the current worktree.

### 結果
- the shipped code path no longer contains a compilable linked-session workspace implementation.
- linked-session creation/title rewrite is no longer represented as active product contract in tests or docs.
- current V2 proofs remain green for direct attach and duplicate-open no-linked-session behavior; `testPaneSelectionWithMockDaemonAndRealTmux` remains an environment skip when the runner cannot create a tmux session.

## 2026-03-07 — T-106 audit refined the deletion scope across runtime, tests, and docs

### 事象
- user asked for a full re-review of UI, E2E, and related tests because legacy linked-session assumptions might still remain beyond the shipped runtime path.
- the repo still contained both dead runtime code and stale positive coverage that treated linked-session creation/title rewriting as active product behavior.

### 実施内容
- completed a targeted inventory across runtime, tests, and docs.
- classified the remaining legacy surface into three groups:
  - delete:
    - `Sources/AgtmuxTerm/WorkspaceStore.swift`
    - `Sources/AgtmuxTerm/WorkspaceArea.swift`
    - `Sources/AgtmuxTerm/LinkedSessionManager.swift`
    - `Tests/AgtmuxTermIntegrationTests/LinkedSessionIntegrationTests.swift`
    - linked-session title/runtime UI proofs and stale README wording
  - rewrite:
    - UI proofs whose real product intent still matters but whose oracle assumes linked-session creation, especially focus-sync and same-window pane-switch cases
  - keep:
    - exact-session identity regressions that prove linked-looking names and `session_group` metadata do not rewrite the normal V2 sidebar path
- updated design/tracking docs so `T-106` now explicitly covers test/doc cleanup, not just dead runtime deletion.

### 結果
- the first safe deletion slice is now concrete instead of open-ended.
- next step is delegated implementation of the slice: remove dead linked-session runtime, delete legacy-positive coverage, and rewrite only the still-needed UI proofs to V2 direct-attach semantics.

## 2026-03-07 — T-106 started: legacy linked-session path deletion is now explicit work

### 事象
- V2 mainline integration is closed, but the repo still physically contains the older linked-session workspace runtime.
- user clarified that the intent of the V2 project is stronger than "not on the normal path": linked-session / group-session creation should no longer remain as shipped product behavior at all.

### 実施内容
- added `T-106` to `docs/60_tasks.md` as the new active implementation task.
- updated `docs/65_current.md` so the active focus is now physical deletion of the legacy linked-session path rather than open-ended "next task" space.
- scoped the first execution step to inventory and remove the old runtime surface in slices, starting from:
  - `WorkspaceStore`
  - `WorkspaceArea`
  - `LinkedSessionManager`
  - `SurfacePool`
  - linked-session-specific tests and stale docs

### 結果
- the board now treats linked-session deletion as first-class implementation work, not residual cleanup.
- next step is a concrete reachability pass over the remaining legacy runtime before code deletion begins.

## 2026-03-07 — T-092 and T-093 umbrella tracking reconciled after fresh evidence

### 事象
- `T-098` / `T-099` and `T-104` / `T-105` were already closed, but their umbrella task entries `T-092` and `T-093` were still left open in tracking.
- earlier review evidence also still described `T-094` / `T-095` UI proof as blocked by a locked desktop session.

### 実施内容
- reran fresh umbrella-focused verification:
  - `swift build`
  - `swift test -q --filter WorkbenchV2BrowserTileTests`
  - `swift test -q --filter WorkbenchV2DocumentTileTests`
  - `swift test -q --filter GhosttyCLIOSCBridgeTests`
  - `swift test -q --filter WorkbenchV2BridgeDispatchTests`
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests`
  - `swift test -q --filter WorkbenchStoreV2PersistenceTests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2DocumentTileTests`
  - `swift test -q --filter WorkbenchV2TerminalRestoreTests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
- refreshed unlocked-session UI evidence:
  - reran the 6-test `T-094` targeted UI batch and got executed PASS
  - reran the 2-test health-strip `T-095` UI batch and got executed PASS
  - reran the 2-test restore-placeholder `T-093` UI batch and got executed PASS
- aligned the remaining bridge-routing wording from `active Workbench` to the implemented emitting-surface Workbench semantics:
  - `docs/30_architecture.md`
  - `docs/42_design-cli-bridge.md`
- updated:
  - `docs/60_tasks.md`
  - `docs/65_current.md`
  - `docs/85_reviews/review-pack-T-092.md`
  - `docs/85_reviews/review-pack-T-093.md`
  - `docs/85_reviews/review-pack-T-094.md`
  - `docs/85_reviews/review-pack-T-095.md`
- bounded Codex CLI closeout attempts on the umbrella packs did not return usable final verdicts in reasonable time, so final umbrella `GO` came from direct Codex fallback review over the already-reviewed split-task evidence

### 結果
- `T-092` is now closed as an umbrella reconciliation of `T-098` plus `T-099` / `T-102` / `T-103`.
- `T-093` is now closed as an umbrella reconciliation of `T-104` plus `T-105`.
- `T-094` and `T-095` review packs now include fresh executed UI evidence from an unlocked desktop session instead of the earlier `screenLocked=1` caveat.
- no active implementation milestone remains on the current task board.

## 2026-03-07 — T-094 and T-095 unlocked-session UI reruns executed PASS

### 事象
- the earlier `T-094` closeout still carried a locked-session caveat because XCTest had skipped the post-fix 6-test UI batch with `screenLocked=1`.
- `T-095` also relied on existing UI coverage references, but the strip presence/absence proofs had not yet been rerun on an unlocked desktop in the current tracking pass.

### 実施内容
- reran:
  - `xcodegen generate`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
- stabilized the duplicate-open UI proof helper so it reuses the already-waited-for sidebar row instead of requerying before click.

### 結果
- the full 6-test `T-094` batch now executes and passes on an unlocked desktop session.
- the 2-test health-strip `T-095` batch also executes and passes on an unlocked desktop session.
- the remaining `screenLocked=1` note is no longer the current review evidence for either task.

## 2026-03-07 — T-095 closeout: local health-strip offline contract locked and reviewed green

### 事象
- `T-095` remained open even though the product behavior already existed, because the local health-strip offline/stale-data contract had never been stated precisely in the docs.
- the first sufficiency review rejected the initial wording because it overpromised an untested coexistence rendering case and the spec section was malformed.

### 実施内容
- narrowed the contract to the behaviors already covered by tests:
  - local inventory offline does not clear the last published health strip
  - `ui.health.v1` refresh continues while inventory is offline
  - no health snapshot means no health strip
- fixed the spec/architecture wording in:
  - `docs/20_spec.md`
  - `docs/30_architecture.md`
- reran `swift test -q --filter AppViewModelA0Tests`
- reran scoped Codex sufficiency review on the narrowed contract

### 結果
- final reviewer verdicts: `GO`, `GO`
- `T-095` is now closed without product-code changes; the work was contract-locking plus evidence reconciliation.
- next active tracking item is the remaining `T-092` umbrella-task reconciliation.

## 2026-03-07 — T-095 started: local health-strip offline contract is now docs-locked

### 事象
- `T-095` existed to decide and document what the sidebar health strip should do when local inventory goes offline or stale panes remain.
- the code and tests already implied a behavior, but that contract was not yet written down in the design/architecture docs.

### 実施内容
- reviewed the current `AppViewModel` / `SidebarView` behavior and the existing coverage surface.
- documented the chosen contract in:
  - `docs/30_architecture.md`
  - `docs/20_spec.md`
- recorded the existing regression coverage in `docs/60_tasks.md`:
  - `AppViewModelA0Tests.testLocalDaemonHealthPublishesEvenWhenInventoryFetchFails`
  - `AppViewModelA0Tests.testLocalInventoryOfflineDoesNotClearExistingHealthAndStillAllowsRefresh`
  - `AgtmuxTermUITests.testSidebarHealthStripShowsMixedHealthStates`
  - `AgtmuxTermUITests.testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`

### 結果
- the intended contract is now explicit:
  - local inventory offline does not clear the last published health strip
  - `ui.health.v1` refresh continues while inventory is offline
  - no health snapshot means no health strip
- next step is a final sufficiency check on whether the existing executed coverage is enough to close T-095 without new product-code changes.

## 2026-03-07 — T-094 closeout: dual Codex GO after exact-selection fix

### 事象
- T-094 had been reopened by dual Codex review on an exact-session selection regression after slice 2 landed.
- the fix and post-fix coverage were in place, but the task still needed fresh verification evidence and final reviewer verdicts.

### 実施内容
- reran focused verification on the final worktree:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodegen generate`
- reran targeted UI proofs for the T-094 surface, including `testSessionGroupAliasSelectionStaysOnExactSessionRow`
  - both the normal rerun and an `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1` retry reached `xcodebuild` success but skipped because XCTest still reported `screenLocked=1`
- refreshed `docs/85_reviews/review-pack-T-094.md` and ran two scoped independent Codex re-reviews on the exact-selection fix

### 結果
- final reviewer verdicts: `GO`, `GO`
- both reviewers confirmed that exact-session alias selection now stays bound to full pane identity and that the new refresh/UI regression coverage targets the right contract.
- the remaining UI skip was judged to be an environment-evidence gap, not a blocking product regression.
- T-094 is now closed; the next active task is T-095.

## 2026-03-07 — T-094 review fix landed: exact-session selection no longer collapses sibling aliases

### 事象
- dual Codex review reopened T-094 after slice 2: once session-group aliases remained visible as separate rows, sidebar selection and `retainSelection(...)` were still matching only `source + windowId + paneId`.
- as a result, selecting one alias row could highlight its sibling alias row too, and a refresh could retarget `selectedPane` to the wrong exact session.

### 実施内容
- tightened exact-selection matching in the mainline path:
  - `Sources/AgtmuxTerm/AppViewModel.swift`
    - `retainSelection(...)` now preserves selection by full pane identity (`source + sessionName + windowId + paneId`)
  - `Sources/AgtmuxTerm/SidebarView.swift`
    - sidebar selected-row matching now keys off `AgtmuxPane.id` instead of collapsing sibling aliases that share the same pane/window
  - `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
    - added `testFetchAllRetainsSelectionForExactSessionGroupAliasAcrossRefresh`
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
    - added `testSessionGroupAliasSelectionStaysOnExactSessionRow`
    - tightened selected-marker lookup to full `AccessibilityID.paneKey(...)`
- focused verification:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodegen generate`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow`
  - `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testEmptyStateOnLaunch -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSelectionStaysOnExactSessionRow`

### 結果
- exact-session alias rows no longer collapse into a shared selected/highlighted state in product code.
- the latest targeted UI rerun reached `** TEST SUCCEEDED **`, but all 6 selected UI proofs skipped because XCTest still reported `screenLocked=1`.
- retrying with `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1` did not bypass the runner-side guard, so T-094 remains open for an actually unlocked-desktop rerun plus review closeout.

## 2026-03-07 — T-094 slice 2 landed: AppViewModel now preserves exact real-session sidebar identity

### 事象
- after the visible-surface switch, the remaining normal-path linked-session assumption was in `AppViewModel.normalizePanes(...)`: it still hid `agtmux-linked-*` names and canonicalized sessions through `session_group`.
- that behavior conflicted with the V2 contract that the sidebar should reflect real tmux sessions as-is.

### 実施内容
- removed the old linked-session/sidebar normalization from `Sources/AgtmuxTerm/AppViewModel.swift`:
  - stopped filtering `agtmux-linked-*` session names from the normal path
  - stopped rewriting sidebar identity through `session_group` / local alias canonicalization
  - kept only exact duplicate-row deduplication (`source + session + window + pane`)
- added focused product-code coverage in `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`:
  - linked-looking session names remain visible as exact sessions
  - session-group aliases remain distinct in `panes` and `panesBySession`
- rewrote conflicting UI proofs in `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`:
  - `testLinkedPrefixedSessionsRemainVisibleAsRealSessions`
  - `testSessionGroupAliasSessionsRemainDistinct`
- removed obsolete `Tests/AgtmuxTermCoreTests/PaneFilterTests.swift`, which only asserted the old prefix-filter contract and no longer covered product behavior
- focused verification:
  - `swift build`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testLinkedPrefixedSessionsRemainVisibleAsRealSessions -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSessionGroupAliasSessionsRemainDistinct`

### 結果
- the remaining linked-session/session-group normalization is no longer part of the normal sidebar path.
- T-094 then reopened in review on an exact-selection regression; that follow-up fix is tracked in the newer entry above.

## 2026-03-07 — T-094 slice 1 landed: visible cockpit surfaces now default to Workbench V2

### 事象
- after T-105 closeout, the remaining mainline gap was that the visible cockpit composition still branched on `WorkbenchStoreV2.isFeatureEnabled()` and could still route sidebar-open through the old linked-session workspace path.

### 実施内容
- updated the visible composition path:
  - `Sources/AgtmuxTerm/CockpitView.swift`
    - made `WorkbenchAreaV2` the normal workspace surface
  - `Sources/AgtmuxTerm/TitlebarChromeView.swift`
    - made `WorkbenchTabBarV2` the normal titlebar tab surface
  - `Sources/AgtmuxTerm/SidebarView.swift`
    - removed the V1 fallback open path from session/window/pane sidebar actions so they always use `WorkbenchStoreV2.openTerminal(...)`
  - `Sources/AgtmuxTerm/main.swift`
    - removed normal-path `WorkspaceStore` wiring from the top-level cockpit environment
  - `Sources/AgtmuxTerm/WindowChromeController.swift`
    - removed normal-path `WorkspaceStore` wiring from titlebar chrome hosting
- updated focused UI coverage in `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift` so the executed proofs target the new default mainline path:
  - `testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile`
  - `testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile`
- fallback execution note:
  - the real agent CLI stalled without a usable report
  - the delegated Codex tier did not return a usable in-band handoff
  - the orchestrator finished the remaining owned-file cleanup and UI-proof stabilization directly

### 結果
- the normal visible cockpit path now defaults to V2 and no longer creates linked sessions from sidebar-open.
- focused verification:
  - `swift build`
  - `AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile`
- both targeted UI proofs executed and passed.
- T-094 remains open for the follow-up slice that removes AppViewModel-side linked-session filtering / title-leak normalization from the main path.

## 2026-03-07 — T-094 started: visible cockpit surfaces are the first mainline-removal slice

### 事象
- T-105 is fully closed, and the next MVP milestone is T-094: reconnect the sidebar/session browser to Workbench V2 and remove linked-session assumptions from the normal product path.
- the current codebase still branches on `WorkbenchStoreV2.isFeatureEnabled()` in the visible cockpit composition surfaces (`SidebarView`, `CockpitView`, `TitlebarChromeView`) even though the V2 product path is now the intended mainline.

### 実施内容
- reviewed `docs/20_spec.md`, `docs/50_plan.md`, and the active cockpit composition files to scope the first T-094 slice.
- locked the first slice to visible-surface mainline integration:
  - make `SidebarView` open/reveal V2 terminal tiles as the normal path
  - make `CockpitView` render `WorkbenchAreaV2` as the normal workspace surface
  - make `TitlebarChromeView` render `WorkbenchTabBarV2` as the normal titlebar tab surface
- left the deeper V1 cleanup as an explicit follow-up slice so verification can prove the visible-mainline switch independently before removing remaining legacy wiring.

### 結果
- T-094 is now active and design-scoped for implementation.
- next execution step is delegated implementation of the visible-surface V2 mainline switch, followed by focused verification and review.

## 2026-03-07 — T-105 closeout: bootstrap/reachability review blockers fixed and review green

### 事象
- the first T-105 implementation landed and the new broken-terminal UI proof passed, but dual Codex review reopened two terminal issues and two document issues:
  - healthy restored terminals could briefly surface a false `Session missing` placeholder before the first inventory fetch completed
  - terminal rebind options could include stale sessions from offline sources
  - remote document restore could race startup reachability and stick on a generic access failure
  - document rebind silently fell back a missing remote target to `local`

### 実施内容
- `Sources/AgtmuxTerm/AppViewModel.swift`
  - added `hasCompletedInitialFetch` so restore surfaces can distinguish bootstrap from live inventory truth
- `Sources/AgtmuxTerm/WorkbenchV2TerminalRestore.swift`
  - added explicit terminal tile state resolution (`bootstrapping / ready / broken`)
  - filtered terminal rebind options to live, non-offline sources only and gated them until the first fetch completes
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - blocked direct attach and broken-tile actions during bootstrap, surfacing a neutral restore-in-progress state instead of a false placeholder
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
  - introduced a document load request key keyed by retry token plus live reachability state
  - deferred remote document load until reachability truth is available
  - preserved missing remote document targets as explicit unavailable rebind options instead of silently selecting `local`
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalRestoreTests.swift`
  - added bootstrap-state and offline-option filtering coverage
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
  - added remote-load defer coverage and explicit missing-target rebind coverage
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - added a healthy restored terminal UI proof so bootstrap settles into direct attach without exposing a false broken placeholder
- refreshed `docs/85_reviews/review-pack-T-105.md` and reran dual Codex re-review

### 結果
- T-105 is now closed on code, focused verification, targeted UI proof, and review.
- final verification:
  - `swift build`
  - `swift test -q --filter WorkbenchV2DocumentTileTests`
  - `swift test -q --filter WorkbenchV2TerminalRestoreTests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchStoreV2PersistenceTests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredBrokenTerminalTileShowsPlaceholderAndCanBeRemoved -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredHealthyTerminalTileDoesNotSurfaceBrokenPlaceholder`
- final review verdicts: `GO`, `GO`

## 2026-03-07 — T-105 restore placeholder UI landed; targeted UI proof blocked by automation mode

### 事象
- after the store-side `Remove Tile` / exact-target `Rebind` slice landed, the remaining T-105 work was the render-time placeholder UI for restored terminal/document tiles.
- both delegated execution tiers failed for the remaining UI slice: real agent CLI runs stalled without usable edits, and the fallback Codex subagent also failed to return a usable patch.

### 実施内容
- used the documented fallback ladder and completed the remaining slice directly in the orchestrator:
  - `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
    - kept the typed document restore-state model, preflight host/offline checks, retry-token reload path, and exact-target `Rebind` / `Remove Tile` actions
  - `Sources/AgtmuxTerm/WorkbenchV2TerminalRestore.swift`
    - added render-time terminal restore issue resolution from persisted `SessionRef` plus live inventory truth
    - added exact-target terminal rebind option synthesis from live panes
    - added the terminal rebind sheet surface
  - `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
    - switched terminal tiles to explicit restore placeholders with `Retry`, `Rebind`, and `Remove Tile`
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalRestoreTests.swift`
    - added focused coverage for host-missing/offline, local daemon issue surfacing, `tmux unavailable`, session-missing, and exact-target rebind option generation
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
    - added targeted UI proof for a restored broken terminal tile staying visible and removable
- verification completed for:
  - `swift build`
  - `swift test -q --filter WorkbenchV2DocumentTileTests`
  - `swift test -q --filter WorkbenchV2TerminalRestoreTests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchStoreV2PersistenceTests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`

### 結果
- T-105 product code now contains the intended render-time recovery path for both document and terminal tiles.
- the new targeted UI proof is present, but `xcodebuild -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2RestoredBrokenTerminalTileShowsPlaceholderAndCanBeRemoved` is currently blocked by `Timed out while enabling automation mode.` before the runner initializes.
- the next required step is to rerun that targeted UI test once the macOS desktop accepts XCTest automation mode immediately.

## 2026-03-07 — Delegation fallback locked for T-105 execution

### 事象
- the remaining T-105 UI slice hit repeated delegation instability: real agent CLI runs stalled without usable output, and subagent runs were intermittently disconnected or interrupted.

### 実施内容
- updated `AGENTS.md`, `docs/60_tasks.md`, and `docs/lessons.md` to lock the user-directed fallback ladder:
  1. real agent CLI
  2. Codex subagent
  3. orchestrator direct execution only after both delegated paths fail

### 結果
- T-105 can continue without violating repo process when delegation tooling is unstable.
- subsequent execution must record which fallback tier was actually needed for each remaining slice.

## 2026-03-07 — T-108 execution policy switched to direct orchestrator implementation

### 事象
- while investigating the reopened pane-selection / overlay regressions, real-agent implementation delegation added latency without producing usable implementation output.
- the active bugfix slice is now explicit user-directed direct implementation work, not a delegation exercise.

### 実施内容
- updated `AGENTS.md`, `docs/60_tasks.md`, and `docs/65_current.md` to stop treating real-agent implementation delegation as the default for this slice.
- recorded that `T-108` will proceed as orchestrator-owned TDD and focused verification.

### 結果
- the active implementation path is now unambiguous: patch product code directly, prove it with regression tests, then refresh tracking/review evidence.

## 2026-03-06 — T-105 partial progress: store mutation support landed for remove/rebind

### 事象
- T-105 needed explicit recovery actions, but the existing V2 store still lacked safe mutation seams for `Remove Tile` and exact-target `Rebind`.

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - added public tree-safe tile removal that collapses splits and repairs focus
  - added exact-target terminal/document rebind APIs that preserve tile identity
  - terminal rebind now clears stale hint-only `SessionRef` fields when target/session changes
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
  - added focused coverage for nested remove/collapse behavior, focus repair, and rebind semantics
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2PersistenceTests.swift`
  - added focused autosave proofs for remove/rebind mutations

### 結果
- the store-side recovery contract for T-105 is now present and verified.
- remaining work is render-time terminal/document restore placeholder UI plus `Retry` / `Rebind` / `Remove Tile` wiring at the tile layer.

### 検証
- `swift test --filter WorkbenchStoreV2Tests` ✅
- `swift test --filter WorkbenchStoreV2PersistenceTests` ✅
- combined focused result: 26 tests, 0 failures

## 2026-03-06 — T-105 design lock: restore placeholders stay render-time, not persisted state

### 事象
- after T-104, the remaining Phase E question was whether broken restore state should be stored in the snapshot or recomputed from live truth.

### 実施内容
- locked `docs/41_design-workbench.md` so restore placeholders are resolved from persisted exact refs plus current host config and tmux inventory truth.
- added `Host missing` to the explicit restore placeholder vocabulary so the design matches the already-landed host-key contracts in terminal/document restore paths.
- updated `docs/60_tasks.md` and `docs/65_current.md` to mark the active T-105 slice as terminal/document placeholders plus exact-target `Rebind` and tree-safe `Remove Tile`.

### 結果
- persistence stays on the simpler `T-104` contract; no cached restore-status field is added to the snapshot format.
- the next code step is to land render-time restore issue resolution, recovery actions, and focused proof for those flows.

## 2026-03-06 — T-104 closeout: autosave/load plumbing landed and bridge persistence gap fixed

### 事象
- T-104 landed snapshot plumbing quickly, but re-review reopened one blocking gap: the bridge-dispatch mutation path was mutating workbenches without autosaving, so pinned companions opened from the CLI bridge could miss persistence.

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchStoreV2Persistence.swift`
  - added the fixed app-owned snapshot path, validated encode/decode, atomic writes, and save-time pruning of unpinned companion tiles
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - restored persisted state at launch when no fixture override is present
  - autosaved representative store mutations fail-loud
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`
  - added autosave on the contextual bridge mutation path so bridge-opened pinned companions are persisted too
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2PersistenceTests.swift`
  - added focused coverage for persisted load, fixture override precedence, prune semantics, representative autosave, explicit-save failure, and bridge-opened pinned companion persistence
- refreshed `docs/85_reviews/review-pack-T-104.md` and reran dual Codex re-review

### 結果
- T-104 is now closed on code, focused verification, and review.
- Phase E now moves to `T-105` restore failure placeholders and recovery actions.

### 検証
- `swift test --filter WorkbenchStoreV2` ✅
- `swift test --filter WorkbenchV2BridgeDispatchTests` ✅
- final review verdicts: `GO`, `GO`

## 2026-03-06 — T-103 closeout: real `GhosttyApp` seam proof landed and review returned green

### 事象
- T-103 had landed decode/dispatch code, but re-review reopened the task because executed tests still bypassed the real `GhosttyApp.handleAction(...)` callback seam.

### 実施内容
- `Sources/AgtmuxTerm/GhosttyApp.swift`
  - exposed a narrow `@testable` seam so integration tests can invoke the real action callback path without changing production behavior
  - added injectable test hooks for bridge dispatch, failure reporting, and main-actor observation
- `Tests/AgtmuxTermIntegrationTests/GhosttyCLIOSCBridgeTests.swift`
  - added executed seam-level tests that call `GhosttyApp.handleAction(...)` itself from an off-main queue
  - proved valid `OSC 9911` consume/open behavior, non-`9911` passthrough, and unregistered-surface failure reporting on main
  - expanded decode coverage to unsupported `version` / `action` / `placement` and empty required fields
- refreshed `docs/85_reviews/review-pack-T-103.md` and reran dual Codex re-review

### 結果
- T-103 is now closed on code, focused verification, and review.
- together with the already-closed T-102 carrier exposure, T-099 terminal bridge transport is now closed in-repo.

### 検証
- `swift build` ✅
- `swift test --filter GhosttyCLIOSCBridgeTests` ✅
  - `Executed 16 tests, with 0 failures (0 unexpected)`
- `swift test -q --filter WorkbenchV2BridgeDispatchTests` ✅
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅
- final review verdicts: `GO`, `GO`

## 2026-03-06 — T-093 decomposition: autosave/load and restore affordances split

### 事象
- after closing bridge transport, the next MVP phase is persistence plus restore states.
- current code review shows two different work surfaces: snapshot storage/load and restore-failure affordances.

### 実施内容
- updated `docs/60_tasks.md` to split `T-093` into:
  - `T-104` workbench autosave/load snapshot plumbing
  - `T-105` restore failure placeholders and recovery actions
- updated `docs/65_current.md` so the next implementation focus points at the split tasks rather than the old umbrella only.

### 結果
- the next implementation can land storage first without entangling it with `Retry` / `Rebind` / `Remove Tile` UI work.
- `T-093` remains the umbrella acceptance surface while execution proceeds through `T-104` then `T-105`.

## 2026-03-06 — T-103 review reopened: real `GhosttyApp` seam proof is still missing

### 事象
- T-103 landed app-side decode/dispatch code plus focused tests, but re-review split on the verification bar.
- one Codex reviewer returned `GO`; another returned `NO_GO`.

### 実施内容
- refreshed `docs/85_reviews/review-pack-T-103.md`.
- reviewed the current evidence against the design-locked verification bar in `docs/42_design-cli-bridge.md`.

### 結果
- the bridge decoder/dispatcher itself is not the blocker.
- the blocking gap is proof: current tests call `GhosttyCLIOSCBridge.dispatchIfBridgeAction(...)` directly, so they do not yet exercise the real `GhosttyApp.handleAction(...)` callback seam, main-thread hop, or failure surfacing path.
- the next fix is to add executed integration proof at the real app callback seam and use that to satisfy the product-level bridge verification requirement.

## 2026-03-06 — T-102 closeout: custom OSC carrier verified and reviewed green

### 事象
- T-102 had been reopened on two blocking review findings: GTK `.custom_osc` parity and missing runtime-hop proof that exact `osc` plus payload bytes reach the host `action_cb`.

### 実施内容
- verified the current worktree against the reopened findings.
- confirmed:
  - `vendor/ghostty/src/apprt/embedded.zig` now proves `.custom_osc` reaches the embedded runtime callback with exact `osc` and payload bytes
  - `vendor/ghostty/src/terminal/stream.zig` now covers the ST-terminated path in addition to BEL parser coverage
  - `vendor/ghostty/src/apprt/gtk/class/application.zig` now handles `.custom_osc` explicitly for shared-source parity
- refreshed `docs/85_reviews/review-pack-T-102.md` with the new evidence and reran dual Codex review.

### 結果
- T-102 is now closed on code, fresh verification, and review.
- the remaining bridge work moves entirely into app-side decode/dispatch (`T-103`).

### 検証
- `cd vendor/ghostty && zig build test -Dtest-filter='custom osc'` ✅
- `./scripts/build-ghosttykit.sh` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64/Headers/ghostty.h` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64-simulator/Headers/ghostty.h` ✅
- `swift build` ✅
- final review verdicts: `GO`, `GO`

## 2026-03-06 — T-103 preflight: payload contract locked before app-side decode

### 事象
- after `T-102`, the remaining bridge work moved into Swift decode/dispatch.
- the docs already locked `OSC 9911` as the carrier, but the payload defaulting rules still needed to be concrete before app-side code could be delegated cleanly.

### 実施内容
- updated `docs/42_design-cli-bridge.md`.
- locked the app-visible payload as strict UTF-8 JSON with explicit `version`, `action`, `kind`, `target`, `cwd`, `argument`, `placement`, and `pin`.
- locked host-side validation to fail loudly for malformed JSON, unsupported enum values, empty required fields, and relative file paths.
- updated `docs/30_architecture.md` so Flow-004 explicitly says the command emits an `OSC 9911` UTF-8 JSON payload.

### 結果
- `T-103` can now implement decode/validation without making a parallel design decision in code.
- the external emitter remains out of tree, but the in-repo host contract is now concrete enough for app-side tests and dispatch wiring.

## 2026-03-06 — T-103 preflight: `agt` emitter is out of tree

### 事象
- after landing `T-102`, the next question was whether this repo already contained the `agt open` emitter side.

### 実施内容
- searched package targets, `Sources/`, scripts, and bundled tools paths.
- confirmed only `AgtmuxTerm`, `AgtmuxDaemonService`, and helper `agtmux` daemon tooling exist in-tree.

### 結果
- there is no `agt` CLI implementation in this repo.
- the documented `agt open` contract remains valid, but the in-repo next step is app-side `custom_osc` decode/dispatch (`T-103`), not emitter implementation.

## 2026-03-06 — T-102 implementation checkpoint: `OSC 9911` carrier exposed through GhosttyKit

### 事象
- T-099 had moved from external blocker to repo-local work: vendored Ghostty needed to surface the custom OSC carrier through the existing embedded runtime seam.

### 実施内容
- vendored Ghostty
  - `vendor/ghostty/src/terminal/osc.zig`
  - `vendor/ghostty/src/terminal/stream.zig`
  - `vendor/ghostty/src/termio/stream_handler.zig`
  - `vendor/ghostty/src/apprt/surface.zig`
  - `vendor/ghostty/src/Surface.zig`
  - `vendor/ghostty/src/apprt/action.zig`
  - `vendor/ghostty/include/ghostty.h`
  - `OSC 9911` を typed `custom_osc` action として `action_cb` に流す path を追加した。
- framework rebuild
  - `scripts/build-ghosttykit.sh`
  - `GhosttyKit/GhosttyKit.xcframework/**`
  - source header と rebuilt xcframework header が一致する状態まで再生成した。

### 結果
- `GhosttyApp.handleAction(...)` から観測できる host-visible carrier が current worktree に入った。
- T-099 の残りは app-side decode/dispatch (`T-103`) に絞られた。

### 検証
- `cd vendor/ghostty && zig build test -Dtest-filter='OSC: custom osc 9911'` ✅
- `./scripts/build-ghosttykit.sh` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64/Headers/ghostty.h` ✅
- `cmp -s vendor/ghostty/include/ghostty.h GhosttyKit/GhosttyKit.xcframework/ios-arm64-simulator/Headers/ghostty.h` ✅
- `swift build` ✅

## 2026-03-06 — T-099 unblock investigation: repo-local GhosttyKit expansion is viable

### 事象
- T-099 had been tracked as blocked because the shipped `GhosttyKit.xcframework` exposes only typed runtime actions and no host-visible custom OSC carrier.

### 実施内容
- inspected
  - public C header surface in `GhosttyKit/GhosttyKit.xcframework/.../Headers/ghostty.h`
  - vendored Ghostty embedded runtime in `vendor/ghostty/src/apprt/embedded.zig`
  - internal OSC parse/message flow in `vendor/ghostty/src/terminal/osc.zig`, `vendor/ghostty/src/termio/stream_handler.zig`, and `vendor/ghostty/src/Surface.zig`
  - framework rebuild path in `scripts/build-ghosttykit.sh`

### 結果
- the current shipped xcframework still has no raw/generic custom OSC action at the C boundary.
- however, this is not an external upstream blocker anymore: the repo already vendors Ghostty source and can rebuild `GhosttyKit.xcframework`.
- the narrowest viable path is to add one new typed `ghostty_action_s` case for custom OSC payloads through the existing `action_cb`, then wire app-side decode/dispatch on top of the T-101 surface registry + dispatch scaffold.
- execution is now split into `T-102` and `T-103`.

## 2026-03-06 — T-091 closeout: executed UI proof recovered after automation approval

### 事象
- the latest T-091 rerun had already narrowed the blocker to macOS automation approval rather than `screenLocked=1`.
- after approving `Enable UI Automation` on the desktop session, the targeted rerun could finally execute the tests again.

### 実施内容
- commands
  - `xcodegen generate`
  - `AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -resultBundlePath /tmp/T-091-ui-proof.xcresult -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond`
- result
  - `testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` PASS (`20.480s`)
  - `testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar` PASS (`16.555s`)

### 結果
- T-091 now has fresh executed UI proof for both targeted behaviors.
- the task is closed on code, focused verification, and review evidence.

### 検証
- targeted `xcodebuild` ✅
  - `Executed 2 tests, with 0 failures (0 unexpected) in 37.035 (37.037) seconds`
  - result bundle: `/tmp/T-091-ui-proof.xcresult`
  - `Failed to suppress screen saver (SACSetScreenSaverCanRun returned 22)` は非致命

## 2026-03-06 — T-091 diagnosis: UI automation approval prompt is the blocker

### 事象
- after `xcodegen generate`, the latest targeted T-091 rerun still failed before either UI proof executed with `Timed out while enabling automation mode.`

### 実施内容
- inspected
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.06_09-28-31--0800.xcresult`
  - `/Users/virtualmachine/Library/Developer/Xcode/DerivedData/AgtmuxTerm-fceaqdlhjyreqtdcfsbnupqgkkjc/Logs/Test/Test-AgtmuxTerm-2026.03.06_09-28-07--0800.xcresult`
- xcresult / archived system log evidence
  - `testmanagerd` logged `Enabling Automation Mode...`
  - writer daemon required authentication
  - `coreauthd` evaluated `Enable UI Automation` with `MechanismPasscode`
  - `coreautha` showed the approval UI
  - `runningboardd` still saw `com.apple.dt.AutomationModeUI(501)` alive at timeout

### 結果
- this blocker is environment-only, not an app/test-code regression.
- the current machine has no biometric/watch fast-path, so the rerun needs an on-console passcode/password approval of the automation prompt.
- next action is a manual approval during the targeted `xcodebuild` rerun.

## 2026-03-06 — T-091 rerun changed blocker: automation mode timeout after xcodegen

### 事象
- T-091 closeout rerun was retried after T-101 landed.
- this time the failure mode changed:
  - first targeted `xcodebuild` failed before tests ran because the generated Xcode project was stale and missing the latest app sources
  - after `xcodegen generate`, the second targeted `xcodebuild` still failed before either UI proof executed, with `Timed out while enabling automation mode.`
- importantly, `screenLocked=1` did not appear in this rerun.

### 実施内容
- rerun commands
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond`
  - `xcodegen generate`
  - same targeted `xcodebuild` again
- evidence
  - first run: build failure from stale generated project
  - second run: `AgtmuxTermUITests-Runner ... encountered an error` / `Timed out while enabling automation mode.`

### 結果
- T-091 is still blocked on fresh executed UI proof.
- the blocker has shifted from screen lock to UI automation initialization, so the next step is harness/environment diagnosis rather than another blind rerun.

## 2026-03-06 — T-101 closeout: final dual Codex GO

### 事象
- T-101 had one final robustness fix pending after the placement and surface-handle remediations.
- real Claude Code CLI was installed and authenticated, but it did not produce a usable review response in this environment because stdin raw mode was unsupported and repeated `claude -p` calls hung without output.

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - valid non-empty workbenches with `focusedTileID == nil` now normalize to the first tile in traversal order before placement is applied.
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BridgeDispatchTests.swift`
  - added regression coverage for `.replace` and directional placement against an unfocused split workbench fixture.
- review
  - compensated for the blocked Claude leg with two independent Codex reviews on the final crash-fixed worktree.

### 結果
- T-101 is now closed on code, focused verification, and review.
- app-side downstream CLI bridge plumbing is in place; the remaining bridge blocker is only `T-099` carrier ingress in GhosttyKit.

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BridgeDispatchTests` ✅（7 tests）
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- final re-review verdicts: `GO`, `GO`

## 2026-03-06 — T-101 crash fix landed: unfocused non-empty workbench normalization

### 事象
- T-101 re-review reopened a remaining crash: `dispatchBridgeRequest(_:)` could precondition-fail on a valid non-empty workbench whose `focusedTileID` was `nil`.

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - non-empty workbench で `focusedTileID == nil` の場合、placement 前に tree traversal 順の first tile を deterministic fallback として採用するようにした。
  - stale focus ID や tileless non-empty tree のような actually invalid state では従来どおり loud failure を維持した。
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BridgeDispatchTests.swift`
  - unfocused split workbench fixture を追加した。
  - `.replace` が fallback tile だけを置換し sibling branch を保つことを固定した。
  - `.left/.right/.up/.down` が preset focus なしでも同じ fallback tile を基準に split insertion することを固定した。

### 結果
- bridge dispatch は valid な unfocused non-empty workbench でも crash せず placement を適用できるようになった。
- T-101 の known code-level blockers は current worktree で解消済み。
- 残るのは fresh review verdict の回収だけ。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BridgeDispatchTests` ✅（7 tests）
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- filtered `swift test` の末尾に Swift Testing footer (`0 tests in 0 suites passed`) が出るが、exit code は `0` で非致命

## 2026-03-06 — T-101 re-review reopened again: unfocused non-empty workbench crash

### 事象
- post-remediation re-review produced a split verdict.
  - one Codex reviewer returned `GO`
  - another returned `NO_GO`
- the blocking finding is that `WorkbenchStoreV2.placeTile(...)` still preconditions on `focusedTileID` for any non-empty workbench, so `dispatchBridgeRequest(_:)` can crash on a valid restored/seeded workbench whose layout has tiles but no focused tile set.

### 実施内容
- tracking
  - `docs/60_tasks.md`
  - `docs/65_current.md`
  - `docs/70_progress.md`
  - `docs/85_reviews/review-pack-T-101.md`
  を更新し、`T-101` を re-review-closeout から unfocused-workbench crash fix に戻した。

### 結果
- surface-handle routing と placement-preserving dispatch は review で概ね確認された。
- ただし `focusedTileID == nil` への robustness gap が残っているため、`T-101` はまだ close できない。
- 次の実装は fallback focus normalization とその regression coverage の追加。

## 2026-03-06 — T-101 remediation landed: surface-handle routing and placement-preserving dispatch

### 事象
- `T-101` short review had reopened the work because the surface registry could not resolve from the real Ghostty callback seam and the bridge request path still dropped non-`replace` placement.

### 実施内容
- `Sources/AgtmuxTerm/GhosttyTerminalSurfaceRegistry.swift`
  - registry を tile ID key から canonical `GhosttySurfaceHandle` key へ切り替えた。
  - `context(forTarget:)` を追加し、`ghostty_target_s.target.surface` から直接 `GhosttyTerminalSurfaceContext` を引ける seam を作った。
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`
  - successful reattach 前に old handle を unregister し、new `ghostty_surface_t` handle で register し直すようにした。
  - dismantle でも surface handle 基準で cleanup するようにした。
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`, `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - `WorkbenchV2BridgeRequest` に placement を追加した。
  - `.replace` は従来どおり focused tile replacement を維持し、`.left/.right/.up/.down` は focused tile を軸に split insertion するようにした。
- tests
  - `Tests/AgtmuxTermIntegrationTests/GhosttyTerminalSurfaceRegistryTests.swift`
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BridgeDispatchTests.swift`
  - handle-based resolve/unregister/overwrite と directional placement split を固定した。

### 結果
- `T-101` は review で指摘された 2 つの code-level gap を current worktree で閉じた。
- app-side downstream plumbing は、carrier ingress を除けば design-locked contract にかなり近い状態まで揃った。
- 現在の残作業は fresh review verdict の回収だけ。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BridgeDispatchTests` ✅（5 tests）
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- `swift test -q --filter WorkbenchV2DocumentTileTests` ✅（4 tests）
- filtered `swift test` の末尾に Swift Testing footer (`0 tests in 0 suites passed`) が出るが、XCTest 実行結果とは独立で非致命

## 2026-03-06 — T-101 review reopened: surface callback routing and placement contract

### 事象
- short review for `T-101` returned `NO_GO` even though the initial focused verification was green.
- the review found that the terminal-surface registry was only keyed by app tile ID, while the real Ghostty callback boundary is keyed by `ghostty_target_s.target.surface`.
- the review also found that the bridge request/dispatch path had dropped the design-locked placement contract and still always fell through to replace-only insertion.

### 実施内容
- tracking
  - `docs/60_tasks.md`
  - `docs/65_current.md`
  - `docs/70_progress.md`
  - `docs/85_reviews/review-pack-T-101.md`
  を更新し、`T-101` を short-review-pending から explicit remediation state に戻した。
- remediation scope を 2 slices に固定した。
  - surface registry: real `ghostty_surface_t` callback key から `GhosttyTerminalSurfaceContext` を引ける production path を作る
  - bridge dispatch: `WorkbenchV2BridgeRequest` と `WorkbenchStoreV2` に placement contract を通し、replace-only 以外の open も保持する

### 結果
- `T-101` は carrier-only blocked ではなく、app-side downstream plumbing にまだ 2 つの gap がある状態だと確定した。
- 次の実装は review 指摘の 2 点を閉じてから re-review する流れに切り替わった。

## 2026-03-06 — T-101 implementation checkpoint: app-side bridge scaffold

### 事象
- `T-099` は carrier ingress で blocked だが、app-side の request/dispatch/registration plumbing は先に進められる状態だった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2BridgeDispatch.swift`
  - carrier-free な `WorkbenchV2BridgeRequest` を追加した。
  - browser/document の resolved request を emitting terminal の Workbench に dispatch する `dispatchBridgeRequest(_:)` を追加した。
- `Sources/AgtmuxTerm/GhosttyTerminalSurfaceRegistry.swift`
  - future bridge routing 用に terminal tile metadata を保持する registry を追加した。
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`, `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - V2 terminal surface の register / unregister を host boundary に追加した。
- tests
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BridgeDispatchTests.swift`
  - `Tests/AgtmuxTermIntegrationTests/GhosttyTerminalSurfaceRegistryTests.swift`
  - dispatch payload 保持、emitting-Workbench placement、surface registry overwrite/unregister を固定した。

### 結果
- `T-099` の downstream plumbing は current worktree で先に成立した。
- これで CLI bridge の残実装は、carrier ingress を `GhosttyApp.handleAction(...)` に届ける部分へほぼ限定された。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BridgeDispatchTests` ✅（3 tests）
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- `swift test -q --filter WorkbenchV2DocumentTileTests` ✅（4 tests）

## 2026-03-06 — T-098 fix landed: document late-completion guard

### 事象
- Codex re-review で reopened した T-098 blocker は、old async document fetch completion が replacement tile の phase を上書きし得ることだった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
  - `WorkbenchV2DocumentLoadCoordinator` を追加した。
  - current `WorkbenchV2DocumentLoadToken` を保持し、`begin` で `.loading` に戻し、completion は `currentToken == token && !Task.isCancelled` の時だけ commit するようにした。
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
  - old token completion が newer token phase を上書きしない test を追加した。
  - cancelled completion が無視される test を追加した。
  - current token success / failure commit を直接 hold する test を追加した。

### 結果
- document tile は replacement 後の stale completion で repaint されなくなった。
- short post-fix Codex re-review は `GO` で、review scope に新しい blocking regression は無かった。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BrowserTileTests` ✅（5 tests）
- `swift test -q --filter WorkbenchV2DocumentTileTests` ✅（4 tests）
- `swift test -q --filter WorkbenchV2DocumentLoaderTests` ✅（5 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- `xcodegen generate` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` ✅
  - suite は成功したが、2 tests とも `screenLocked=1` により skip
  - `SACSetScreenSaverCanRun returned 22` は非致命 warning

## 2026-03-06 — T-098 re-review reopened: document late-completion overwrite

### 事象
- stale reopen-state fix を入れた後の Codex re-review で、document tile は token を分けても old async completion が replacement tile の `phase` を上書きできることが分かった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
  - current implementation を再点検し、`loadToken` change 後も old task completion が unconditional に `phase` を commit している点を blocker として切り出した。
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
  - current token-equality tests だけでは late-completion overwrite を hold できていないことを確認した。
- tracking
  - `docs/60_tasks.md`, `docs/65_current.md`
  - T-098 を `DONE` から `IN PROGRESS` に戻し、document stale-completion fix を active work に戻した。

### 結果
- T-098 は browser 側の stale-state bug は閉じたが、document 側は late-completion overwrite bug が残っている。
- 次の実装は document load completion を current token / cancellation で gate し、その contract を direct test で固定することになった。

## 2026-03-06 — T-099 carrier discovery: Ghostty C API mismatch

### 事象
- `T-099` は design-locked では terminal-scoped custom OSC carrier を前提にしているが、current GhosttyKit integration で raw/generic custom OSC が app に届くかは未確定だった。

### 実施内容
- `GhosttyKit/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`
  - runtime callback surface と `ghostty_action_s` union を確認した。
- `Sources/AgtmuxTerm/GhosttyApp.swift`
  - current app-side ingress が `GhosttyApp.handleAction(...)` だけであることを再確認した。
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`, `Sources/AgtmuxTerm/SurfacePool.swift`, `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - surface identity を `WorkbenchStoreV2` dispatch に接続できる seam を整理した。
- design docs
  - `docs/42_design-cli-bridge.md`, `docs/30_architecture.md`, `docs/50_plan.md`
  - custom OSC carrier は維持しつつ、current GhosttyKit capability が前提であり、typed action への便乗は mainline で採らないことを明文化した。

### 結果
- current GhosttyKit C API は fixed runtime callbacks と typed `ghostty_action_s` payload しか expose しておらず、raw/generic custom OSC callback は無いことが分かった。
- したがって `T-099` の narrowest app-side seam は `GhosttyApp.handleAction(...) -> surface resolution -> WorkbenchStoreV2` だが、design-locked custom OSC carrier 自体は current C API では観測できない。
- `T-099` は transport 実装より前に carrier decision が必要になったため、`T-100` を追加した。
- `T-100` の結論として、temporary typed-action piggyback は採らず、custom OSC carrier を host-visible にする capability が前提だと整理した。

## 2026-03-06 — T-098 regression closeout: stale reopen state fixed

### 事象
- Codex review で、same URL/path を reopen した新 companion tile が previous tile の `WKWebView` / `loadError` / document load phase を引き継ぐ stale-state bug が見つかった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2BrowserTile.swift`
  - browser reload behavior を `tile.id` + URL で key し、fresh navigation 開始時に stale error state を clear するようにした。
  - `WKWebView` cancellation error は visible failure に昇格しないようにした。
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
  - document load state を `WorkbenchV2DocumentLoadToken(tileID, ref)` で key し、token change 時に `.loading` へ reset するようにした。
- tests
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2BrowserTileTests.swift`
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentTileTests.swift`
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentLoaderTests.swift`
  - browser stale-state regression、document token identity、missing remote host key loud failure を固定した。

### 結果
- browser/document companion surfaces は reopen 時に stale loaded/failed state を引き継がなくなった。
- T-098 acceptance は code + focused coverage まで閉じた。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2BrowserTileTests` ✅（5 tests）
- `swift test -q --filter WorkbenchV2DocumentTileTests` ✅（2 tests）
- `swift test -q --filter WorkbenchV2DocumentLoaderTests` ✅（5 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）

## 2026-03-06 — T-091 review checkpoint: Claude verdict obtained

### 事象
- T-091 は code-level review closeout が残っていた。
- final patch 後の targeted UI proof も fresh に取り直す必要があった。

### 実施内容
- real Claude Code CLI review を実行し、usable verdict を取得した。
- Claude condition だった `missingRemoteHostKey` coverage を `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentLoaderTests.swift` に追加した。
- targeted UI proof を March 6, 2026 07:40 PST と 07:55 PST に rerun した。

### 結果
- real Claude Code CLI verdict は `GO_WITH_CONDITIONS` で、唯一の blocking condition は `missingRemoteHostKey` coverage だった。
- その condition は current worktree で解消済み。
- ただし latest targeted UI-proof reruns はどちらも `screenLocked=1` で skip し、final executed proof はまだ fresh に取り直せていない。
- T-091 の残 blocker は unlocked interactive macOS session の availability のみ。

### 検証
- `swift test -q --filter WorkbenchV2DocumentLoaderTests` ✅（5 tests）
- `xcodegen generate` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` ✅
  - March 6, 2026 07:40 PST rerun: `Executed 2 tests, with 2 tests skipped and 0 failures`
  - March 6, 2026 07:55 PST rerun: command succeeded but the first targeted test skipped with `screenLocked=1`; no fresh executed PASS was produced
  - `SACSetScreenSaverCanRun returned 22` は非致命 warning

## 2026-03-06 — T-091 review hardening and T-098 loader coverage

### 事象
- T-091 の executed UI proof はすでに green だったが、follow-up review で `WorkbenchV2DocumentLoader` の child-process handling と duplicate-open UI proof の timing dependency が指摘された。
- 同時に、T-098 では document companion surface の load-path は入っていたものの focused regression coverage が不足していた。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2DocumentLoader.swift`
  - `process.standardInput = FileHandle.nullDevice` を追加し、child が親 stdin を掴まないようにした。
  - `stdout` / `stderr` capture を `Pipe` 直読みから temporary file capture に変更し、large remote output で child が pipe buffer に詰まる deadlock risk を除去した。
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - duplicate-open UI proof の `Thread.sleep(0.3)` を除去し、`count > 1` に対する inverted predicate expectation で duplicate tile が一度も出現しないことを待つ形にした。
- `Tests/AgtmuxTermIntegrationTests/WorkbenchV2DocumentLoaderTests.swift`
  - local success
  - remote success with injected runner
  - explicit remote command failure
  - explicit local directory rejection
  を固定した。

### 結果
- T-091 review-driven fix は current worktree に反映され、known `NO_GO` findings は code と focused verification で閉じた。
- T-098 は document loader の load/failure contract まで automated coverage が入った。
- Claude Code の usable verdict は依然 pending だが、repo policy どおり Codex review coverage を増やす前提が固まった。

### 検証
- `swift test -q --filter WorkbenchV2DocumentLoaderTests` ✅（4 tests）
- `swift build` ✅
- `xcodegen generate` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' build` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` ✅
  - current environment では `screenLocked=1` により skip した rerun もあったが、2026-03-06 の earlier executed proof はすでに PASS を保持している
  - `SACSetScreenSaverCanRun returned 22` は非致命 warning
  - `WorkbenchV2DocumentLoaderTests.swift` の injected runner closure には Swift 6 sendable-capture warning が残るが、failure ではない

## 2026-03-06 — T-098 implementation checkpoint: companion surface render path

### 事象
- T-098 では、V2 `browser` / `document` tile が placeholder のままで、app-local companion surface の実 rendering が未接続だった。
- current worktree には `WorkbenchV2DocumentLoader.swift` の下地が入っていたため、まず browser/document の minimal render path を buildable にする方針で進めた。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2BrowserTile.swift`
  - `WKWebView` ベースの browser tile view を追加した。
  - visible header / open externally action / explicit load-failure banner を追加した。
- `Sources/AgtmuxTerm/WorkbenchV2DocumentTile.swift`
  - `WorkbenchV2DocumentLoader` を使う document tile view を追加した。
  - loading / loaded / failed phase を明示し、local/remote text fetch failure を tile 上に surfacing するようにした。
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - `.browser` を `WorkbenchBrowserTileViewV2` に接続した。
  - `.document` を `WorkbenchDocumentTileViewV2` に接続した。
- manifests
  - `Package.swift`
  - `project.yml`
  - browser tile のために `WebKit` linkage を追加した。

### 結果
- V2 Workbench は placeholder ではなく、minimal browser/document companion surface を描画できる状態になった。
- browser tile は exact URL をそのまま開き、load error を tile 内で visible に保つ。
- document tile は local/remote text content を lazy load し、missing path / directory / remote host key / remote fetch error を explicit failure として残す。
- focused coverage はまだ足していないため、T-098 は継続中のまま。

### 検証
- `swift build` ✅
- `xcodegen generate` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' build` ✅
  - multiple matching macOS destinations (`arm64` / `x86_64`) warning は非致命
  - `appintentsmetadataprocessor` の metadata extraction skipped warning は非致命
  - `SACSetScreenSaverCanRun returned 22` は今回の build では未観測

## 2026-03-06 — T-091 rerun closeout: executed UI proof recovered

### 事象
- unlocked desktop session で T-091 targeted UI proof を rerun したところ、skip ではなく実行まで進んだ。
- rerun の途中で、current worktree には `WorkbenchV2DocumentLoader.swift` の compile blocker と、single-open UI proof の AX contract mismatch が残っていることが分かった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchV2DocumentLoader.swift`
  - `Self.runProcess` を default argument で参照していた initializer を split し、xcodebuild が current worktree を build できる状態に戻した。
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - V2 terminal tile の既存 tile AX anchor はそのまま残しつつ、direct-attach status 専用の invisible AX anchor を追加した。
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - single-open UI proof を tile `value` 待ちから、dedicated `.status` AX anchor 待ちに切り替えた。
- rerun
  - `swift build`
  - `swift test -q --filter WorkbenchV2ModelsTests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - `xcodegen generate`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond`

### 結果
- T-091 の targeted UI proof 2 本は skip ではなく actual execution で両方 PASS に戻った。
- duplicate-open proof は既存 tile reveal/focus semantics を保ったまま green を維持した。
- single-open proof は direct-attach status の explicit AX contract を使う形で安定化した。
- T-091 の実装/verification blocker は external review verdict のみになった。

## 2026-03-06 — T-092 decomposition kickoff: surfaces vs bridge boundary

### 事象
- T-092 は browser/document companion surfaces と `agt open` bridge を同時に含んでいた。
- 現コードを確認すると、browser/document tile rendering は app-local に完結する一方、`agt open` は Ghostty action/OSC boundary をまたぐため実装面が明確に異なっていた。

### 実施内容
- `docs/60_tasks.md`
  - T-092 を Phase D umbrella として残しつつ、app-local companion surface 実装を `T-098`、bridge transport 実装を `T-099` に分割した。
- `docs/65_current.md`
  - current focus を `T-098` / `T-099` に更新した。

### 結果
- companion surface rendering は bridge carrier の最終決定を待たずに進められる状態になった。
- Ghostty/runtime boundary をまたぐ `agt open` transport は `T-099` に切り出し、silent fallback なしで別途詰める方針に整理した。
- current codebase には production の agtmux custom-OSC parser は無く、T-099 の ingress 候補は `GhosttyApp.handleAction(...)` だけだと確認した。

## 2026-03-06 — T-099 ingress discovery checkpoint

### 事象
- `agt open` bridge transport は `T-099` に切り出したが、現コードに production の custom OSC parser / dispatcher があるかは未確認だった。

### 実施内容
- codebase inspection を行い、terminal-to-app callback surface を確認した。
- `Sources/AgtmuxTerm/GhosttyApp.swift`
  - Ghostty runtime `action_cb` が `GhosttyApp.handleAction(...)` に集約されていることを確認した。
- `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift`, `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`, `Sources/AgtmuxTerm/main.swift`
  - per-surface identity を bridge routing に載せる候補点として整理した。

### 結果
- production の agtmux custom-OSC parser / dispatcher はまだ存在しないことが分かった。
- `T-099` の最小 ingress 候補は `GhosttyApp.handleAction(...)` で、そこへ surface/tile registration を渡す設計が自然だと整理した。
- したがって `T-099` は単なる wiring ではなく、terminal-to-app bridge layer の新設が必要な可能性が高い。

## 2026-03-06 — T-091 implementation checkpoint: real-session terminal tile

### 事象
- T-090 では V2 Workbench path が placeholder terminal tile までしか入っておらず、direct tmux attach と duplicate-session policy は未実装だった。
- T-091 では linked-session model を再導入せずに、V2 path だけで real-session terminal open を成立させる必要があった。

### 実施内容
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - terminal open API を placeholder insertion から real-session open に差し替えた。
  - exact `SessionRef` equality で全 workbench を横断する duplicate detection を追加し、既存 tile があれば reveal/focus するようにした。
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - terminal tile を placeholder view から direct-attach terminal view に差し替えた。
  - configured remote host key を attach 時に逆引きし、見つからない場合は tile 上で explicit error を surfacing するようにした。
  - UITest mode では Ghostty surface を省略しつつ、real-session attach state を AX value で検証できるようにした。
- `Sources/AgtmuxTerm/SidebarView.swift`
  - V2 branch の session/window/pane open を real terminal open API に接続した。
- `Sources/AgtmuxTerm/RemoteHostsConfig.swift`
  - `RemoteHost.id` からの reverse lookup helper を追加した。
- shared terminal hosting
  - `Sources/AgtmuxTerm/GhosttySurfaceHostView.swift` を追加し、V1/V2 の Ghostty surface hosting core を共用化した。
  - `Sources/AgtmuxTerm/WorkbenchV2TerminalAttach.swift` を追加し、local/ssh/mosh attach command を pure helper として切り出した。
- tests
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
    duplicate reveal/focus semantics を同一 workbench / 複数 workbench 両方で固定した。
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchV2TerminalAttachTests.swift`
    local + ssh + mosh attach command と missing host key failure を固定した。
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
    T-090 placeholder proof を supersede し、real-session open / duplicate reopen の targeted UI proof に更新した。
- verification refresh
  - fresh `xcodebuild` verification で generated Xcode project が stale になっていることを確認した。
  - `xcodegen generate` で `project.yml` から `AgtmuxTerm.xcodeproj` を再生成し、同じ targeted `xcodebuild` command を rerun した。

### 結果
- V2 sidebar open は placeholder terminal tile を挿すのではなく、exact session name に対する direct attach plan を持つ terminal tile を作るようになった。
- duplicate open は app-global に既存 tile を reveal/focus し、同じ `SessionRef` の visible terminal tile を増やさない実装になった。
- remote `TargetRef.remote(hostKey:)` は attach 時に configured `RemoteHost.id` を逆引きし、unknown host key は local/hostname へ fall back せず explicit failure になる。
- generated Xcode project を refresh 後、targeted `xcodebuild` command 自体は成功するところまで戻した。
- ただし current desktop session は `screenLocked=1` に戻っており、T-091 の targeted UI proof 2 本は rerun しても skip のまま。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2ModelsTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（8 tests）
- `swift test -q --filter WorkbenchV2TerminalAttachTests` ✅（4 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensRealSessionTerminalTileFromSidebar -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2DuplicateSessionOpenRevealsExistingTileInsteadOfCreatingSecond` ✅
  - command/build は成功したが、2 tests は `screenLocked=1, onConsole=1, loginDone=1` により skip
  - `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1` を付けた rerun でも同じ理由で skip した
  - `SACSetScreenSaverCanRun returned 22` は非致命 warning として観測した

### Review
- `docs/85_reviews/review-pack-T-091.md` を作成済み。
- real review CLI availability は `codex` / `claude` を確認した。
- bounded `codex review --uncommitted` attempt は 45 秒 timeout で終了し、現 worktree に対する reliable verdict はまだ返ってきていない。

## 2026-03-06 — T-096/T-097 完了: T-090 condition closeout

### 事象
- T-090 review は `GO_WITH_CONDITIONS` で、2 つの条件が残っていた。
- 条件は、remote hostname -> configured host key mapping の regression coverage と、feature-flagged V2 sidebar-open path の executed UI proof だった。

### 実施内容
- `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
  - configured remote hostname が configured `RemoteHost.id` に写像されて V2 `SessionRef.target` に入る test を追加。
  - unconfigured remote hostname が raw hostname のまま explicit に残る test を追加。
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - placeholder tile の AX label/value を追加し、UI proof を tile element 自体で検証できるようにした。
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - targeted V2 UI test の query を placeholder tile の AX contract に合わせて修正した。
- rerun
  - `swift build`
  - `swift test -q --filter WorkbenchV2ModelsTests`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar`

### 結果
- T-096 condition は code + regression coverage で閉じた。
- T-097 condition は unlocked interactive macOS session で targeted UI test を actual execution し、PASS で閉じた。
- T-090 の review conditions は両方とも解消した。
- T-090 の final re-review verdict は `GO` だった。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2ModelsTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（6 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` ✅（1 test）
- `SACSetScreenSaverCanRun returned 22` は再度観測したが非致命だった

## 2026-03-06 — T-090 phase checkpoint: Workbench V2 foundation path

### 事象
- V2 docs と handover では、linked-session path を壊さずに isolated な Workbench foundation path を立ち上げる必要があった。
- 現コードは `WorkspaceStore` / `WorkspaceArea` / `LinkedSessionManager` を前提にしており、そのままでは V2 model と top-level view path を導入できなかった。

### 実施内容
- `Sources/AgtmuxTermCore/WorkbenchV2Models.swift`
  - V2 `Workbench`, `WorkbenchNode`, `WorkbenchTile`, `TileKind`, `SessionRef`, `DocumentRef`, `TargetRef` を追加。
  - empty node / split node / placeholder tile rendering 用の model utility を追加。
- `Sources/AgtmuxTerm/WorkbenchStoreV2.swift`
  - empty default state, active workbench tracking, placeholder terminal/browser/document insertion API を追加。
  - `AGTMUX_COCKPIT_WORKBENCH_V2=1` feature flag と `AGTMUX_WORKBENCH_V2_FIXTURE_JSON` fixture decode path を追加。
- `Sources/AgtmuxTerm/WorkbenchAreaV2.swift`
  - empty state と terminal/browser/document placeholder tile を描画する V2 area を追加。
- `Sources/AgtmuxTerm/WorkbenchTabBarV2.swift`
  - V2 workbench tab strip を追加。
- existing integration points
  - `main.swift`, `CockpitView.swift`, `TitlebarChromeView.swift`, `WindowChromeController.swift`, `SidebarView.swift`
  - feature flag が ON の時だけ V2 area/tab bar/store を使い、sidebar open は linked-session path ではなく `SessionRef` placeholder insertion に分岐するようにした。
- `Sources/AgtmuxTerm/RemoteHostsConfig.swift`
  - remote pane source hostname から configured `RemoteHost.id` を引く helper を追加し、V2 `TargetRef` が host key 契約を守るようにした。
- tests
  - `Tests/AgtmuxTermCoreTests/WorkbenchV2ModelsTests.swift`
  - `Tests/AgtmuxTermIntegrationTests/WorkbenchStoreV2Tests.swift`
  - `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
  - model codable, pin semantics, placeholder insertion, fixture bootstrap を固定した。
  - `AGTMUX_COCKPIT_WORKBENCH_V2=1` 時に sidebar open が placeholder terminal path を使う targeted UI test を追加した。

### 結果
- V2 foundation path は feature flag 下で app に統合された。
- `AGTMUX_COCKPIT_WORKBENCH_V2=1` 時、visible workspace/titlebar/sidebar-open path は linked-session lifecycle に入らず、V2 placeholder tile path を使うコード/targeted UI test を追加した。
- remote `TargetRef` は configured remote host key を使うようになり、raw hostname を保存しない契約に戻った。
- V1 path は flag OFF のまま隔離された。

### 検証
- `swift build` ✅
- `swift test -q --filter WorkbenchV2ModelsTests` ✅（3 tests）
- `swift test -q --filter WorkbenchStoreV2Tests` ✅（4 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` ✅
  - targeted UI test は build/test command 自体は成功したが、`screenLocked=1, onConsole=1, loginDone=1` により test は skip だった。
  - `SACSetScreenSaverCanRun returned 22` は非致命 warning として観測した。

### Review
- reviewer verdict: `GO_WITH_CONDITIONS`
- condition 1:
  `pane.source` hostname -> configured `RemoteHost.id` -> V2 `SessionRef.target` mapping の regression test を追加する
- condition 2:
  `AgtmuxTermUITests.testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` を unlocked interactive macOS session で rerun し、executed result を progress/review evidence に記録する
- follow-up tasks:
  `T-096`, `T-097`

## 2026-03-06 — T-089 完了: sync-v2 XPC review blocker closeout

### 事象
- commit review で、packaged-app sync-v2 XPC path に dedicated bootstrap/changes coverage が無いという `NO_GO` を受けた。
- 既存の XPC integration tests は `ui.health.v1` に偏っており、`fetchUIBootstrapV2` / `fetchUIChangesV2` の injected-client と service-boundary の実呼び出しを見ていなかった。
- 併せて、bundled runtime README には PATH/common install location fallback をまだ書いており、resolver 契約とずれていた。

### 実施内容
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCClientTests.swift`
  - injected XPC proxy 向けに `fetchUIBootstrapV2` decode test を追加。
  - `fetchUIChangesV2(limit:)` の decode と `limit` 伝播を検証する test を追加。
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCServiceBoundaryTests.swift`
  - anonymous XPC service boundary で `fetchUIBootstrapV2` 成功系を追加。
  - `fetchUIChangesV2` が bootstrap 前に fail loudly し、その後 bootstrap 済みなら成功する service-boundary test を追加。
  - actual service endpoint 側にも同等の bootstrap/changes coverage を追加。
- `Sources/AgtmuxTerm/Resources/Tools/README.md`
  - runtime resolver の現在の契約に合わせて、PATH/common install location fallback 記述を削除。

### 結果
- 初回 review の `NO_GO` で指摘された sync-v2 XPC/bootstrap/changes coverage gap はコード上で閉じた。
- bundled runtime README と resolver 契約のズレも解消した。
- focused post-fix rerun 後の re-review は `GO` だった。
- current worktree は commit/push 可能状態に戻った。

### 検証
- `swift build` ✅
- `swift test -q --filter AgtmuxDaemonXPCClientTests` ✅
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` ✅
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` ✅

## 2026-03-06 — T-088 完了: fresh verification rerun and review-pack prep

### 事象
- 現 worktree には runtime hardening / health observability のコード変更と V2 docs 再編が同居している。
- commit 前に、最終状態に対する fresh verification を取り直し、その結果で review pack を作る必要があった。

### 実施内容
- `swift build` を rerun。
- `swift test -q --filter RuntimeHardeningTests` を rerun。
- `swift test -q --filter AgtmuxSyncV2DecodingTests` を rerun。
- `swift test -q --filter AgtmuxSyncV2SessionTests` を rerun。
- `swift test -q --filter AppViewModelA0Tests` を rerun。
- `swift test -q --filter AppViewModelLiveManagedAgentTests` を rerun。
- `swift test -q --filter AgtmuxDaemonXPCClientTests` を rerun。
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` を rerun。
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` を rerun。
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` を rerun。
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` を rerun。
- `docs/85_reviews/` に review pack を追加する準備を行った。

### Files intended for commit
- `Sources/AgtmuxDaemonService/main.swift`
- `Sources/AgtmuxDaemonService/ServiceEndpoint.swift`
- `Sources/AgtmuxTerm/AgtmuxDaemonSupervisor.swift`
- `Sources/AgtmuxTerm/AgtmuxDaemonXPCClient.swift`
- `Sources/AgtmuxTerm/AppViewModel.swift`
- `Sources/AgtmuxTerm/LocalSnapshotClient.swift`
- `Sources/AgtmuxTerm/SidebarView.swift`
- `Sources/AgtmuxTerm/main.swift`
- `Sources/AgtmuxTermCore/AccessibilityID.swift`
- `Sources/AgtmuxTermCore/AgtmuxBinaryResolver.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonClient.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonClient+SyncV2.swift`
- `Sources/AgtmuxTermCore/AgtmuxDaemonXPCContract.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV2Models.swift`
- `Sources/AgtmuxTermCore/AgtmuxSyncV2Session.swift`
- `Sources/AgtmuxTermCore/AgtmuxUIHealthModels.swift`
- `Sources/AgtmuxTermCore/CoreModels.swift`
- `Tests/AgtmuxTermCoreTests/AgtmuxSyncV2DecodingTests.swift`
- `Tests/AgtmuxTermCoreTests/AgtmuxSyncV2SessionTests.swift`
- `Tests/AgtmuxTermCoreTests/RuntimeHardeningTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCClientTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AgtmuxDaemonXPCServiceBoundaryTests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelA0Tests.swift`
- `Tests/AgtmuxTermIntegrationTests/AppViewModelLiveManagedAgentTests.swift`
- `Tests/AgtmuxTermUITests/AgtmuxTermUITests.swift`
- `Tests/AgtmuxTermUITests/UITestHelpers.swift`
- `docs/00_router.md`
- `docs/10_foundation.md`
- `docs/20_spec.md`
- `docs/30_architecture.md`
- `docs/40_design.md`
- `docs/41_design-workbench.md`
- `docs/42_design-cli-bridge.md`
- `docs/43_design-companion-surfaces.md`
- `docs/50_plan.md`
- `docs/60_tasks.md`
- `docs/65_current.md`
- `docs/70_progress.md`
- `docs/80_decisions/ADR-20260306-tmux-first-cockpit-v2.md`
- `docs/85_reviews/RP-20260306-worktree-closeout.md`
- `docs/90_index.md`
- `docs/archive/README.md`
- `docs/archive/progress/2026-02-28_to_2026-03-06.md`
- `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
- `docs/lessons.md`

`build/` is verification output only and is excluded from commit.

### 結果
- fresh build/test evidence はすべて green だった。
- runtime hardening, sync-v2, health, XPC boundary, service endpoint, targeted UI coverage を commit 前の最終状態で再確認できた。

### 検証
- `swift build` ✅
- `swift test -q --filter RuntimeHardeningTests` ✅（8 tests）
- `swift test -q --filter AgtmuxSyncV2DecodingTests` ✅（4 tests）
- `swift test -q --filter AgtmuxSyncV2SessionTests` ✅（4 tests）
- `swift test -q --filter AppViewModelA0Tests` ✅（15 tests）
- `swift test -q --filter AppViewModelLiveManagedAgentTests` ✅（1 test）
- `swift test -q --filter AgtmuxDaemonXPCClientTests` ✅（2 tests）
- `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` ✅（2 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -target AgtmuxTermCoreTests -configuration Debug build` ✅
- `xcrun xctest -XCTest AgtmuxDaemonServiceEndpointTests build/Debug/AgtmuxTermCoreTests.xctest` ✅（2 tests）
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripShowsMixedHealthStates -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` ✅（2 tests）

## 2026-03-06 — T-087 完了: docs を active-context 向けに compaction

### 事象
- `docs/60_tasks.md` と `docs/70_progress.md` が肥大化し、日常の再読コストが高くなっていた。
- `docs/40_design.md` も mainline truth と detail が1枚に混在しており、毎回の読込量が大きかった。
- Router の読み順も、active summary より先に長い tracking files を要求していた。

### 実施内容
- `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
  - compaction 前の full task board を退避。
- `docs/archive/progress/2026-02-28_to_2026-03-06.md`
  - compaction 前の full progress ledger を退避。
- `docs/archive/README.md`
  - archive の役割を明記。
- `docs/65_current.md`
  - current phase, locked decisions, next tasks, read-next path をまとめた current summary を新設。
- `docs/60_tasks.md`
  - active/next tasks と recent completions だけを残す構成へ再編。
- `docs/70_progress.md`
  - current summary と recent entries だけを残す構成へ再編。
- `docs/40_design.md`
  - compact MVP summary に縮約。
- `docs/41_design-workbench.md`
  - Workbench / terminal tile / duplicate / restore details を分離。
- `docs/42_design-cli-bridge.md`
  - `agt open`, OSC bridge, remote semantics を分離。
- `docs/43_design-companion-surfaces.md`
  - browser/document/future directory surface と lightweight guardrails を分離。
- `docs/00_router.md`
  - read order を `65_current -> 60_tasks -> 10 -> 20 -> 40 -> 41/42/43 -> 30 -> 50 -> 70 -> archive` へ更新。
- `docs/90_index.md`
  - current/design/archive 構成に合わせて read order と documents table を更新。

### 結果
- active implementation context を短い読み順で辿れるようになった。
- history は消さずに archive へ退避された。
- design truth は維持しつつ、summary と detail を分離できた。

### 検証
- docs-only 変更のため build / runtime verification は未実施。
- `65_current / 60_tasks / 70_progress / 40/41/42/43 / router / index` の相互参照を手動確認。

## 2026-03-06 — T-086 完了: V2 design lock を mainline docs に統合

### 結果
- `TargetRef`, OSC bridge, autosave/pinning, duplicate open, manual `Rebind`, directory-tile future scope が main docs に固定された。

### 検証
- docs-only 変更のため build / runtime verification は未実施。

## 2026-03-06 — T-085 完了: V2 docs realignment to tmux-first cockpit baseline

### 結果
- `docs/10` through `docs/50` の mainline truth は V2 direction に揃った。
- linked-session path は implementation history としてのみ扱う位置づけになった。

### 検証
- docs-only 変更のため build / runtime verification は未実施。

## 2026-03-06 — T-076 through T-084 完了: local daemon runtime + A2 health track closeout

### 結果
- local daemon runtime hardening, sync-v2 path, health strip, XPC coverage が完了。
- この implementation track は完了済みで、次の main focus は Workbench V2 である。

### 検証
- 詳細な build/test evidence は archive progress を参照。

## Archive

- Full historical progress ledger:
  `docs/archive/progress/2026-02-28_to_2026-03-06.md`
## 2026-03-07 — T-108 gap isolation: pane-selection UI proof was bypassing the render path

Context:
- live March 7, 2026 user evidence still showed two regressions after the earlier `T-108` slice:
  - local `zsh` panes were still surfaced as managed `codex` / `running`
  - same-session pane clicks could update sidebar highlight without changing the visible main-panel terminal

What changed:
- re-inspected the live local daemon socket and confirmed the currently running `ui.bootstrap.v2` payload is still legacy/incompatible:
  - it emits `session_id` instead of `session_key`
  - it omits `pane_instance_id`
  - it still includes orphan managed rows with null `session_name` / `window_id`
- re-audited the current pane-selection UI proof path and found a structural test gap:
  - `WorkbenchAreaV2` replaced the real Ghostty terminal surface with a UITest placeholder when `AGTMUX_UITEST=1`
  - as a result, the green pane-selection UI proofs only exercised sidebar/store/tmux state, not visible main-panel retargeting
- narrowed the next fix shape:
  - move pane-selection E2E into real-surface mode for the focused terminal tile
  - add rendered-surface attach command / generation as a fourth oracle alongside live tmux truth, canonical `ActivePaneRef`, and sidebar highlight

Why it matters:
- the old UI proof could not detect the user-visible bug where sidebar selection changed but the rendered terminal stayed on the previous pane
- `T-108` remains open until both the metadata fail-closed path and the real rendered-surface retarget path are re-proved

## 2026-03-07 — T-108 implementation checkpoint: real-surface oracle and legacy-daemon sample regression

Context:
- the earlier `T-108` slice fixed canonical selection state, but the trusted pane-selection proof was still missing the actual main-panel render path.
- the live local daemon on March 7, 2026 still emits legacy `ui.bootstrap.v2` rows with `session_id` and orphan managed records, matching the bad `codex/running` labels seen in product.

What changed:
- `WorkbenchAreaV2` now allows a focused UI test to opt into real Ghostty surfaces via `AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES=1`, and the terminal host is hard-reset with a new SwiftUI identity whenever the attach command changes.
- `GhosttyTerminalSurfaceRegistry` now records rendered attach command plus monotonic per-tile render generation.
- `UITestTmuxBridge` now exports rendered attach state, so pane-selection E2E can require four agreeing oracles:
  - live tmux target
  - canonical app target
  - sidebar selection marker
  - rendered surface attach command / generation
- `AppViewModelA0Tests` gained a regression that decodes a real March 7, 2026 legacy daemon bootstrap sample and proves the app stays inventory-only with explicit incompatibility instead of surfacing stale `managed/provider/activity` state.
- `GhosttyTerminalSurfaceRegistryTests` gained generation semantics coverage so harmless re-registers do not advance render generation, while actual attach-command retargets do.

Verification:
- `swift build` ✅
- `swift test -q --filter AppViewModelA0Tests` ✅
- `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅
- `swift test -q --filter GhosttyCLIOSCBridgeTests` ✅
- `swift test -q --filter WorkbenchStoreV2Tests` ✅
- `swift test -q --filter WorkbenchV2TerminalAttachTests` ✅
- `swift test -q --filter AgtmuxSyncV2DecodingTests` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux` ❌ environment blocker
  - the app process launches, but `XCUIApplication.launch()` times out with `Failed to activate application ... (current state: Running Background)`
  - an immediate host-side check via `CGSessionCopyCurrentDictionary()` still reports `CGSSessionScreenIsLocked = 1`, so this is current session state, not a product assertion

Result:
- the false-green pane-selection test gap is closed in code and focused regression coverage
- final executed real-surface UI evidence is pending a truly unlocked interactive desktop session

## 2026-03-07 — T-108 rerun narrowed to one metadata-enabled reverse-sync red

Context:
- reran the current-code focused proofs after the `OSC 9911` client-tty bind, staged registry registration, desired/observed split, and render-path retry fixes.
- fresh targeted verification now distinguishes the remaining product bug from the earlier broader “pane sync is broken” bucket.

What changed:
- focused non-UI verification is green on the current worktree:
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter AppViewModelA0Tests`
- fresh targeted UI rerun now has only one red:
  - `testPaneSelectionWithMockDaemonAndRealTmux` ✅
  - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux` ✅
  - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux` ❌
- the failing UI oracle is specific:
  - under metadata-enabled launch, same-session sidebar retarget to the second pane succeeds
  - later terminal-originated reverse sync back to the first pane is overwritten
  - the rendered tmux client remains on the second pane, so the bug is stale desired-pane persistence, not initial attach, not sidebar click dispatch, and not missing rendered-client tty binding
- also captured the live daemon/local tmux sample for a new no-leak regression:
  - local tmux inventory currently shows unmanaged `utm-main`, managed `vm agtmux`, and mixed managed/unmanaged panes in `vm agtmux-term`
  - `ui.bootstrap.v2` currently emits opaque `session_key` values for the managed rows
  - this sample is the right fixture to prove managed/provider/activity overlay does not bleed onto unrelated exact local rows when `session_key != session_name`

Result:
- `T-108` remains open, but the remaining pane-sync bug is now constrained to metadata-enabled desired/observed convergence after same-session retarget.
- next product slice is:
  - add store-level regression for post-convergence reverse sync after same-session retarget
  - add AppViewModel no-leak regression from the live daemon sample
  - then tighten the reducer/runtime contract and rerun the single red UI proof

## 2026-03-07 — T-108 closeout: same-session retarget confirmation is now origin-aware

Context:
- after the previous rerun, only one UI proof was still red:
  - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`
- the failure shape was specific:
  - same-session sidebar retarget reached the requested pane
  - a later rendered-client-originated pane change was still overwritten because desired state lingered too long
- a new store regression reproduced the exact bug shape:
  - reverse sync failed after the first matching observation of a same-session retarget

What changed:
- added TDD-first regression coverage:
  - `WorkbenchStoreV2Tests.testSameSessionRetargetAllowsLaterRenderedClientReverseSyncAfterFirstMatchingObservation`
  - `AppViewModelA0Tests.testLiveOpaqueSessionKeyBootstrapDoesNotLeakManagedOverlayOntoUnrelatedLocalRows`
- refined the reducer contract:
  - desired-pane confirmation is no longer a single global threshold
  - initial attach still requires stable confirmation
  - same-session retarget from an already observed rendered client clears desired state after the first matching observation
  - this preserves the transient-attach guard while allowing immediate terminal-originated reverse sync after a successful same-session retarget
- reran focused verification on the final code:
  - `swift build`
  - `swift test -q --filter WorkbenchStoreV2Tests`
  - `swift test -q --filter AppViewModelA0Tests`
  - `swift test -q --filter WorkbenchV2NavigationSyncResolverTests`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testPaneSelectionWithMockDaemonAndRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`

Result:
- `T-108` is closed on app-side code and fresh verification.
- current evidence now supports:
  - no managed/provider/activity bleed across exact local rows under opaque `session_key`
  - inventory-only same-session retarget and reverse sync
  - metadata-enabled same-session retarget and reverse sync on the normal app path

## 2026-03-07 — T-108 root cause tightened again: rendered attach command is still too weak

Context:
- fresh live tmux inspection on March 7, 2026 showed the remaining pane-sync bug is more specific than the previous render-path gap:
  - the running app child tmux client on `/dev/ttys008` remained on pane `%2`
  - the rendered attach command tracked for that same tile targeted pane `%4`
- this means the current real-surface oracle can still false-green: rendered attach command is intent, not exact rendered tmux client truth.

What changed:
- inspected the live runtime directly:
  - `ps` confirmed the app-owned child process command line was `tmux select-window -t '@2' ; select-pane -t '%4' ; attach-session -t 'vm agtmux-term'`
  - `tmux list-clients` confirmed the visible app client still reported `%2`
  - manually reproducing the same attach sequence outside the app moved the exact tmux client to `%4`, so the remaining gap is app-side truth binding, not tmux command semantics alone
- narrowed the final remediation shape and updated docs before code:
  - reserve host-owned `OSC 9912` for rendered-surface telemetry
  - bind each rendered terminal tile to one exact tmux client tty
  - switch reverse sync and pane-selection UI/E2E truth from session-scoped `list-panes` flags to exact-client `list-clients`

Result:
- `T-108` now has a concrete product root cause for the remaining pane-sync half of the bug.
- next implementation step is exact-client telemetry plus stronger regression/E2E proof that asserts the rendered client's real pane/window, not just the attach command string.

## 2026-03-08 — T-109 closed, T-110 opened for AppKit IME commit regression

Context:
- `T-109` is now closed on the shipped mainline: commit `57b0f25` landed the rendered-client `client_tty` session-rebind path and fresh targeted UI proof passed.
- fresh March 8, 2026 live user evidence opens a new terminal-input regression:
  - Japanese IME candidate UI appears
  - pressing Enter does not commit the selected candidate into the terminal input line

What changed:
- reconciled tracking/current docs:
  - `T-109` is marked `DONE`
  - new `T-110` tracks Ghostty/AppKit IME correctness
- locked the initial root-cause hypothesis before code:
  - current `GhosttyTerminalView.keyDown` sends `ghostty_surface_key(...)` before `interpretKeyEvents(...)`
  - that ordering is weaker than Ghostty's own `SurfaceView_AppKit.swift` and can let Enter confirmation get consumed as raw terminal input while marked text is still active
  - current implementation also lacks explicit preedit-clear synchronization and `doCommand(by:)` handling from the reference path
- updated terminal-runtime architecture docs to require AppKit IME ordering as the mainline contract

Result:
- the active bugfix slice is now `T-110`
- next step is TDD-first coverage for marked-text commit / preedit clear, then product code changes in `GhosttyTerminalView`

## 2026-03-08 — T-110 implemented and verified; T-111 opened for live activity-state mismatch

Context:
- the active March 8, 2026 terminal-input blocker was Japanese IME commit failure inside the Ghostty-backed terminal surface.
- fresh user evidence in the same session also reports a separate live sidebar state mismatch: the pane currently running Codex is not surfaced as `running`.

What changed:
- implemented the AppKit IME fix in `GhosttyTerminalView`:
  - `keyDown` now runs `interpretKeyEvents(...)` before raw terminal key encoding
  - committed `insertText(...)` clears marked text and explicitly clears libghostty preedit state
  - `doCommand(by:)` is handled explicitly so AppKit text commands do not beep or short-circuit the post-IME key path
  - a small release seam was added so AppKit-focused view tests can run without forcing `GhosttyApp.shared` init during teardown
- added focused regressions in `GhosttyTerminalViewIMETests` for:
  - marked-text Enter confirmation preferring IME commit over raw Return
  - explicit preedit clear when marked text ends
- fresh verification:
  - `swift build` ✅
  - `swift test -q --filter GhosttyTerminalViewIMETests` ✅
  - `swift test -q --filter WorkbenchStoreV2Tests` ✅
- opened `T-111` for the separate live activity-state mismatch on the active Codex pane

Result:
- `T-110` is closed on code and focused regression coverage
- current active slice is `T-111`, which now needs exact payload capture and a failing regression before any metadata/activity fix

## 2026-03-08 — Cross-repo live E2E ownership locked before T-111 canary work

Context:
- the next test investment is live activity-state truth, and the same real-provider scenarios can be exercised in both `agtmux` and `agtmux-term`.
- without an explicit split, the terminal repo risks re-owning daemon semantics instead of validating the daemon-to-sidebar boundary.

What changed:
- updated spec / architecture / tracking docs so the responsibility split is explicit:
  - `agtmux` owns producer-side real-CLI semantic truth for provider/presence/activity/title/no-bleed
  - `agtmux-term` owns thin consumer canaries from exact daemon payload truth to exact visible sidebar row
- fixed the oracle hierarchy for terminal-repo live tests:
  1. daemon exact-row payload truth
  2. app/sidebar visible truth
  3. tmux capture/transcript only for diagnostics
- narrowed `T-111` accordingly:
  - first lane is a Codex live canary that proves `running` and then daemon-reported completion state reach the correct row without bleed
  - broader semantic matrices remain daemon-owned first and can be mirrored later as small terminal canaries

Result:
- the docs now prevent duplicated responsibility between the two repos
- next implementation step is extending `AppViewModelLiveManagedAgentTests` with daemon-truth-first live canaries

## 2026-03-08 — T-111 boundary canary landed: daemon truth now proves running/completion propagation

Context:
- after locking cross-repo ownership, the next step in `agtmux-term` was not another semantic suite; it was one thin daemon-to-sidebar live canary.
- the target bug shape is exact-row activity truth for the active Codex pane, plus no bleed onto sibling rows.

What changed:
- extended `AppViewModelLiveManagedAgentTests` instead of building a second live harness:
  - kept the existing real tmux + real daemon + real Claude/Codex setup
  - added helpers that poll daemon `ui.bootstrap.v2` as the primary oracle
  - added `testLiveCodexActivityTruthReachesExactAppRowWithoutBleed`
- the new live canary proves:
  - Codex exact row reaches daemon-reported `running`
  - the same row later reaches daemon-reported completion (`waiting_input` or `idle`)
  - `AppViewModel` merged rows match daemon truth for `presence`, `provider`, `activity_state`, `evidence_mode`, `session_key`, and `pane_instance_id`
  - sibling Claude row keeps its own daemon truth while Codex is active
- also shortened the live Codex prompt from the older long sleep to a shorter deterministic bash task so the canary stays bounded

Verification:
- `swift build` ✅
- `swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveCodexActivityTruthReachesExactAppRowWithoutBleed` ✅
- `swift test -q --filter AppViewModelLiveManagedAgentTests` ✅

Result:
- the terminal repo now has a live boundary canary for daemon activity-state propagation
- if the original user-visible mismatch reappears while this canary remains green, the next investigation target is daemon-side semantic truth or scenario-specific provider behavior, not generic consumer bleed

## 2026-03-08 — T-111 expanded and closed: Claude mirror + Codex attention canary are green

Context:
- daemon-side online E2E was refreshed with local-built `agtmux`, `claude-sonnet-4-6`, and `gpt-5.4` defaults.
- after the first thin Codex boundary canary landed in `agtmux-term`, the next useful step was to mirror one more provider lane and one user-visible attention lane, not to duplicate the daemon semantic suite.

What changed:
- updated the live harness in `AppViewModelLiveManagedAgentTests` to mirror daemon-side defaults more closely:
  - Claude uses `claude --dangerously-skip-permissions --model claude-sonnet-4-6`
  - Codex uses `codex exec ... -m gpt-5.4 -c model_reasoning_effort='\"medium\"'`
  - `CLAUDE_MODEL` / `CODEX_MODEL` env overrides remain available for local account differences
- added two more terminal-side live canaries:
  - `testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed`
  - `testLiveCodexWaitingInputSurfacesAttentionFilter`
- the new coverage now proves:
  - Claude exact-row `running -> completion` propagation matches daemon truth without sibling bleed
  - Codex `waiting_input` reaches `needsAttention`, `attentionCount`, and `.attention` filter surfacing without pulling the sibling Claude row into attention

Verification:
- `swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveClaudeActivityTruthReachesExactAppRowWithoutBleed` ✅
- `swift test -q --filter AppViewModelLiveManagedAgentTests/testLiveCodexWaitingInputSurfacesAttentionFilter` ✅
- `swift test -q --filter AppViewModelLiveManagedAgentTests` ✅ (4 tests)

Result:
- `T-111` is now closed as a terminal-repo boundary task
- next terminal-side candidate is `T-112`: daemon-reported `waiting_approval` attention/badge/filter surfacing

## 2026-03-08 — T-112 closeout: waiting-approval consumer surfacing is now covered without daemon-side changes

Context:
- daemon-side semantic truth for live activity states is already owned and covered in `agtmux`
- this terminal-repo slice only needed to prove that one daemon-reported `waiting_approval` row reaches the visible consumer surface without sibling bleed
- no stable real-CLI approval prompt was required for this consumer task, so the repo intentionally used a synthetic producer fixture instead of reopening daemon-side implementation

What changed:
- added `testWaitingApprovalManagedRowSurfacesAttentionCountAndFilterWithoutBleed` to `AppViewModelA0Tests`
  - one exact managed row surfaces `waiting_approval`
  - `attentionCount == 1`
  - `.attention` filter keeps only that row
  - managed idle and unmanaged sibling rows do not bleed into attention
- added `testAttentionFilterShowsOnlyWaitingApprovalPanes` to `AgtmuxTermUITests`
  - the visible Attention filter exposes a stable badge AX child
  - selecting the filter keeps the waiting-approval row visible and hides the idle sibling row
- tightened the titlebar AX contract by exposing the Attention badge through an explicit child identifier instead of relying on macOS button value propagation

Verification:
- `swift test -q --filter AppViewModelA0Tests/testWaitingApprovalManagedRowSurfacesAttentionCountAndFilterWithoutBleed` ✅
- `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testAttentionFilterShowsOnlyWaitingApprovalPanes` ✅

Result:
- `T-112` is now closed
- waiting-approval consumer surfacing is covered at the two right layers:
  - integration owns count/filter truth
  - targeted UI owns visible badge/filter surfacing
- no daemon-side follow-up or handover is required for this specific slice

## 2026-03-07 — T-108 clean-break correction: same-session retarget must preserve one rendered client

Context:
- fresh re-read of the live failure reports and the current worktree shows the latest same-session path still relies on attach-command mutation and surface recreation.
- that contract is weaker than the user-facing product requirement: one visible session tile should keep one rendered tmux client, then move that exact client between panes/windows.

What changed:
- design/tracking docs now lock the clean-break direction:
  - mixed-era local sync-v2 pane payloads that still carry `session_id` are incompatible whole-payload input
  - same-session pane/window navigation must use exact-client `switch-client -c <tty> -t <pane>`
  - same-session pane-selection E2E should require stable rendered-surface identity instead of treating surface recreation as success

Result:
- the next product slice is now narrower and more coherent:
  - fix mixed-era sync-v2 decode
  - remove active-pane dependence from terminal attach command generation
  - drive same-session navigation through the rendered tmux client tty
  - replace the false-positive surface-generation assertions in E2E with stable-client assertions

## 2026-03-07 — T-108 implementation checkpoint: exact-client navigation landed, executed UI proof still blocked

Context:
- the clean-break plan is now implemented in product code and tests.
- the remaining gap is not compilation or unit coverage; it is executed XCUITest evidence.

What changed:
- product/runtime:
  - `AgtmuxSyncV2RawPane` now rejects mixed-era `session_id` rows at decode time, even when `session_key` and `pane_instance_id` are also present
  - `AppViewModel` now classifies legacy `session_id` parse failures as explicit `incompatible sync-v2`
  - `WorkbenchV2TerminalAttachResolver` now keeps terminal attach session-scoped instead of encoding pane/window intent into the attach command
  - `WorkbenchV2TerminalNavigationResolver` now drives same-session pane/window retarget through exact-client `switch-client -c <tty> -t <pane>`
  - `WorkbenchAreaV2` now waits for the rendered tmux client tty and applies same-session navigation through that bound client instead of surface recreation
- tests:
  - `WorkbenchV2TerminalAttachTests` now lock the session-scoped attach contract and exact-client `switch-client` contract
  - `AppViewModelA0Tests` and `AgtmuxSyncV2DecodingTests` now prove mixed-era `session_id` payloads fail closed
  - same-session UI/E2E assertions now require stable rendered-surface generation rather than treating surface recreation as success
- verification:
  - `swift build` ✅
  - `swift test -q --filter AgtmuxSyncV2DecodingTests` ✅
  - `swift test -q --filter AppViewModelA0Tests` ✅
  - `swift test -q --filter WorkbenchV2TerminalAttachTests` ✅
  - `swift test -q --filter WorkbenchStoreV2Tests` ✅
  - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests` ✅
  - `xcodegen generate` ✅
  - targeted `xcodebuild` for the two real-surface pane-sync UI proofs now builds successfully but still fails before execution with `Timed out while enabling automation mode.` ❌ environment

Result:
- the code path now matches the clean-break design:
  - metadata fail-closed is explicit for mixed-era local daemon payloads
  - same-session navigation is exact-client-scoped and no longer depends on attach-command mutation
- `T-108` remains open only for executed real-surface UI evidence because the XCTest runner is still timing out while enabling automation mode

## 2026-03-07 — T-108 reopened again after the agtmux wire fix: remaining bug is in the term consumer

### Fresh live evidence
- user reran the normal app path with:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift run AgtmuxTerm`
- the previous `session_id` incompatibility is gone, but product logs now show:
  - `metadata overlay dropped for mismatched session identity 59bafe97-... != vm agtmux on pane %1`
  - `metadata overlay dropped for mismatched session identity rollout-... != vm agtmux-term on pane %2`
- the same live report says selecting panes inside `utm-main` still does not retarget the visible terminal in the normal app path.

### Root cause refinement
- `AppViewModel.mergeLocalInventory(...)` is still comparing `metadataSessionKey(for: metadataPane)` to `inventoryPane.sessionName`.
  - after the agtmux-side wire fix, `metadataSessionKey` is now a real opaque `session_key` (UUID / rollout id), so that guard is invalid even for otherwise correct rows.
- `AppViewModel.metadataBasePane(for:)` still falls back to inventory with `pane.sessionName == paneState.sessionKey`, which is the same incorrect assumption on the change-replay path.
- this means the current consumer can still drop valid managed overlay rows even though the daemon payload is now exact-identity-valid enough to connect.
- the same-session pane retarget area is still not trusted until it is re-proved on the normal daemon-connected path after this metadata fix; the earlier green UITest path is no longer sufficient by itself.

### Docs / tracking update
- `docs/20_spec.md`
  - FR-003 now explicitly says `session_key` is opaque and must not be compared to visible `session_name`.
  - FR-023 now explicitly requires same-session pane sync to keep working when the sidebar is inventory-only.
- `docs/30_architecture.md`
  - Flow-001 now records bootstrap-vs-change correlation rules and forbids `sessionName == session_key` fallback.
- `docs/41_design-workbench.md`
  - metadata overlay gate now treats `session_key` as opaque and requires inventory-only pane sync to remain correct.
- `docs/60_tasks.md`
  - `T-108` TDD bundle now includes valid `session_key != session_name` regressions and normal daemon-connected pane-retarget proof.
- `docs/65_current.md`
  - current truth now reflects that the agtmux wire fix landed and the remaining metadata bug is consumer-side.

### Next
- add failing AppViewModel regressions for valid bootstrap/change payloads where `session_key != session_name`
- implement the consumer-side correlation fix
- rerun focused pane-retarget proof on the normal daemon-connected path after the metadata fix, not only on the app-driven UITest harness
# 2026-03-08 22:20 — Narrowed T-116 from daemon freshness to tmux-runtime handoff

- revalidated `T-117` on the live default app-owned socket:
  - daemon process on `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` started at `2026-03-08 20:53:20`
  - current local `AGTMUX_BIN` mtime is `2026-03-08 18:59:32`
  - direct `ui.bootstrap.v2` probe now returns 5 panes with `managed_missing=0`
- reran the focused metadata-enabled plain-zsh Codex UI proof:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - the test now reaches the real product assertion instead of failing on activation
  - tmux capture proves the app-driven pane really executed Codex and completed the prompt
  - the sidebar snapshot still reports:
    - `issue=nil`
    - `probe=ok total=0 managed=0`
    - `probeTarget=nil`
    - visible target row remains inventory-only (`presence=unmanaged, provider=nil, activity=unknown, current_cmd=zsh`)
- conclusion:
  - current red is no longer stale daemon reuse or decode incompatibility
  - inventory and command bridge are operating on the isolated test tmux server
  - managed-daemon startup is still binding to the wrong tmux universe under metadata-enabled XCUITest
  - the likely gap is the current launch-time re-resolution of `AGTMUX_TMUX_SOCKET_NAME -> #{socket_path}` inside the supervisor
- next remediation:
  - `UITestTmuxBridge` records the exact tmux `#{socket_path}` after bootstrap
  - managed-daemon startup consumes that runtime value directly instead of performing a second socket-name resolution later
# 2026-03-08 22:32 — T-116 term-side runtime handoff verified; remaining blocker moved upstream

- implemented the clean-break runtime handoff in `agtmux-term`:
  - `UITestTmuxBridge` now records the exact bootstrap tmux `#{socket_path}` and publishes it into `AgtmuxManagedDaemonRuntime`
  - managed-daemon startup consumes that runtime socket path ahead of socket-name re-resolution
  - focused unit coverage stays green: `swift build`, `swift test -q --filter LocalTmuxTargetTests`
- added app-side diagnostics so the metadata-enabled UI lane reports:
  - managed daemon socket path
  - exact daemon launch record (`binary + args + reused/spawned`)
  - bootstrap-resolved tmux socket path
  - daemon stderr tail
- reran the focused metadata-enabled plain-zsh Codex UI proof:
  - `AGTMUX_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux AGTMUX_UITEST_ALLOW_SSH=1 xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPlainZshCodexPaneSurfacesManagedProviderAndActivity`
  - result is still red, but the term-side launch path is now explicit and verified:
    - `daemonLaunch=spawned:/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux:--socket-path,/Users/virtualmachine/.agt/uit-<token>.sock,daemon,--tmux-socket,/private/tmp/tmux-501/agtmux-managed-<token>`
    - `bootstrapTmuxSocket=/private/tmp/tmux-501/agtmux-managed-<token>`
    - `capture-pane` proves Codex completed in the app-driven pane
    - `probe=ok total=0 managed=0`
    - daemon stderr is empty
- cross-check:
  - standalone shell repro using the same binary and exact daemon args (`--socket-path <custom-sock> daemon --tmux-socket <same path>`) sees the managed pane within 3 seconds
- conclusion:
  - term-side socket/runtime handoff is no longer the blocker
  - remaining failure is upstream `agtmux:T-XTERM-A6`: a daemon spawned from the metadata-enabled app/XCUITest context with an explicit `--tmux-socket` still returns empty bootstrap
  - upstream handover published: `/tmp/agtmux-app-launched-explicit-tmux-socket-handover-20260308.md`

# 2026-03-09 08:05 — T-122 landed: additive bootstrap-v3 consumer bridge is live without v2 delta cutover

- implemented additive bootstrap-v3 consumer wiring in term:
  - `LocalMetadataClient` now exposes additive `fetchUIBootstrapV3()` with an explicit unsupported-method default
  - bundled XPC contract/service/client now carry `ui.bootstrap.v3` across the packaged-app boundary
  - `AppViewModel` bootstrap/resync path now prefers `ui.bootstrap.v3` and falls back to `ui.bootstrap.v2` only when v3 is unsupported
- exact-row correlation remains strict in the adapter:
  - bootstrap-v3 rows are bridged into the existing local overlay cache using daemon truth for
    - `session_name`
    - `window_id`
    - `session_key`
    - `pane_id`
    - `pane_instance_id`
  - no weakening to visible-session-name fallback was introduced
- intentionally deferred:
  - live delta replay still uses `ui.changes.v2`
  - current product rendering still consumes legacy `AgtmuxPane` / `ActivityState`
  - full `PanePresentationState` UI cutover waits for additive `changes-v3`
- focused verification:
  - `swift build` ✅
  - `swift test -q --filter 'AgtmuxSyncV3DecodingTests|PanePresentationStateTests'` ✅
  - `swift test -q --filter RuntimeHardeningTests/testDaemonClientFetchUIBootstrapV3DecodesDaemonOwnedFixtureFromInlineOverride` ✅
  - `swift test -q --filter AgtmuxDaemonXPCClientTests` ✅
  - `swift test -q --filter AgtmuxDaemonXPCServiceBoundaryTests` ✅
  - `swift test -q --filter 'AppViewModelA0Tests/testBootstrapV3(ManagedFixtureOverlaysExactRowAndRetainsOpaqueSessionKey|WaitingApprovalMapsToLegacyAttentionOnExactRow|MethodNotFoundFallsBackToSyncV2BootstrapWithoutBreakingOverlay)'` ✅

# 2026-03-09 08:47 — T-124 landed: first sidebar-only sync-v3 presentation cutover

- implemented a small UI cutover on top of the additive v3 bridge:
  - `AppViewModel` now keeps a parallel local `PanePresentationState` cache for v3-backed local overlays
  - bootstrap-v3 and changes-v3 update/remove that presentation cache in lockstep with the legacy local metadata overlay cache
  - sync-v2 bootstrap/changes fallback still clears the v3 presentation cache so stale v3 UI state cannot leak forward
- sidebar consumer behavior changed without big-bang rewrite:
  - row AX summaries now prefer `PanePresentationState`
  - row provider/activity/freshness surfacing now prefers `PanePresentationState`
  - sidebar `managed` / `attention` filter and count derivation now prefer `PanePresentationState`
  - broader UI surfaces still intentionally defer to legacy `AgtmuxPane` / `ActivityState`
- focused verification:
  - `swift build` ✅
  - `swift test -q --filter PaneRowAccessibilityTests` ✅
  - `swift test -q --filter AppViewModelA0Tests` ✅
  - `xcodegen generate` ✅
  - targeted `xcodebuild -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testAttentionFilterShowsOnlyWaitingApprovalPanes` ❌
    - current failure is not a product assertion mismatch
    - runner reaches build + test launch, then times out with `Failed to activate application ... (current state: Running Background)`
    - this remains an XCUITest foreground-activation harness blocker for the current slice

# 2026-03-09 08:57 — T-125 landed: titlebar-adjacent and UI-harness presentation consumer cutover

- kept the slice small and reviewable:
  - no broad titlebar rewrite was needed because titlebar already consumes shared `attentionCount` / filter state from `AppViewModel`
  - instead, the remaining low-risk UI-adjacent consumer path was cut over:
    - `UITestTmuxBridge` sidebar state dumps now include presentation-derived pane summaries
    - UI test diagnostics now prefer those summaries over raw legacy `AgtmuxPane` fields when available
- added helper-focused coverage for downstream UI consumers:
  - degraded freshness fixture now proves `paneFreshnessText` stays presentation-derived without inflating attention
  - error fixture now proves `panePrimaryState` / `paneNeedsAttention` / provider helper behavior without relying on legacy guesswork
- focused verification:
  - `swift build` ✅
  - `swift test -q --filter AppViewModelA0Tests` ✅
  - `xcodegen generate` ✅
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' build-for-testing -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testAttentionFilterShowsOnlyWaitingApprovalPanes` ✅
  - targeted `xcodebuild ... testAttentionFilterShowsOnlyWaitingApprovalPanes` ❌
    - same foreground-activation harness blocker remains:
    - `Failed to activate application ... (current state: Running Background)`
