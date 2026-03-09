# Task Board

This file keeps the active task surface small.
Historical task detail lives in `docs/archive/tasks/2026-02-28_to_2026-03-06.md`.

## Current Phase

Mainline docs are aligned to the V2 tmux-first cockpit.
Commit closeout is clear; next implementation proceeds on the new Workbench path.

## Active / Next

### T-119 — Live Codex `waiting_input` calibration after immediate shell demotion
- **Status**: TODO
- **Priority**: P1
- **Depends**: T-118
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - `codex exec` no longer guarantees a stable post-completion `waiting_input` window after the upstream immediate shell-demotion fix.
  - The term repo still needs a real-CLI canary for `waiting_input` / attention surfacing, but it must use a calibrated prompt or interactive harness instead of assuming the old one-shot exec flow will hold the row in `waiting_input`.
- **Plan**:
  - keep `waiting_input` / attention consumer truth covered deterministically in `AppViewModelA0Tests`
  - design a real-Codex live prompt or interactive lane that yields a reproducible `waiting_input` window
  - re-enable the live canary only after that prompt/harness is proven stable
- **Acceptance Criteria**:
  - [ ] deterministic integration coverage proves `waiting_input` contributes to attention count/filter without sibling bleed
  - [ ] a real-Codex live canary for `waiting_input` is calibrated and re-enabled without relying on stale final-state assumptions

### T-118 — Reopen: producer-side managed demotion and same-session activity bleed
- **Status**: IN_PROGRESS
- **Priority**: P0
- **Depends**: T-116
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - A fresh live user report shows two new managed-pane truth regressions after `T-116` closeout:
    - pressing `Ctrl-C` in a Codex/Claude pane can return the pane to `zsh`, but the row remains `presence=managed` with stale provider/activity
    - when one Codex pane in a session becomes `running`, sibling Codex panes in the same session can also surface as `running` even when they should remain `idle` or unmanaged
- **Current split**:
  - the original live user report was correctly handed back upstream as producer truth
  - upstream now reports that:
    - exact-row shell demotion was fixed
    - same-session same-provider Codex ownership/no-bleed was fixed
    - producer-side online E2E for `managed-exit` and `same-session-codex-no-bleed` now pass
  - term-side live canaries were updated and are now green for the original reopened symptoms on a fresh daemon runtime:
    - exact-row managed-exit demotion
    - same-session same-provider Codex no-bleed
  - the normal desktop-owned daemon has also now restarted onto the rebuilt binary, so the desktop socket is again a fresh oracle
  - remaining live desktop mismatch is narrower than the original report:
    - same-session `running` bleed no longer reproduces on the fresh desktop socket
    - but a shell pane with a non-agent child process still remains `presence=managed provider=codex`
      even when `current_cmd=zsh`
    - concrete local sample:
      - `vm agtmux-term %6` reports `current_cmd=zsh presence=managed provider=codex activity=waiting_input`
      - tmux shows that pane's shell child is `chezmoi cd`, not a live Codex/Claude process
  - Codex `waiting_input` live attention coverage is now split to `T-119` because one-shot `codex exec` may demote immediately after completion
- **Plan**:
  - keep the new term-side live canaries in place for exact-row managed-exit demotion and same-session no-bleed
  - hand back the remaining fresh-desktop bug upstream as a narrower producer truth issue:
    - demote managed rows when the pane has returned to shell and the remaining live child process is not an agent process
- **Acceptance Criteria**:
  - [ ] fresh desktop daemon truth never reports `presence=managed` for a pane whose `current_cmd` has already returned to `zsh` and whose remaining shell child process is not an agent
  - [x] fresh daemon truth does not propagate one pane's `running` state to sibling Codex panes in the same session
  - [x] terminal-side thin live canaries exist for exact-row managed-exit demotion and same-session same-provider no-bleed

### T-117 — App-managed daemon freshness restart on updated AGTMUX_BIN
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-115
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Stop reusing a reachable but stale app-managed daemon after `AGTMUX_BIN` has been rebuilt, so the normal app path and metadata-enabled XCUITest do not keep consuming invalid old `ui.bootstrap.v2` truth.
- **Current split**:
  - fresh live app evidence on March 8, 2026 shows the current app-managed socket is again serving invalid rows with `session_name = null` / `window_id = null`
  - direct probe confirms the socket is owned by a daemon process started at `2026-03-08 12:47`, while `/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux` was rebuilt at `2026-03-08 18:59`
  - current `AgtmuxDaemonSupervisor` / `ServiceDaemonSupervisor` only check `agtmux json` reachability, so they silently reuse stale producer truth across daemon rebuilds
  - the first freshness hardening pass compared socket mtime to binary mtime, but fresh user evidence plus live repro show that socket mtime is not a reliable proxy for daemon freshness; the real invariant must be daemon process start time vs candidate binary mtime
- **Plan**:
  - add a freshness policy for the app-owned socket so a newer daemon binary forces restart instead of silent reuse
  - make the freshness decision process-aware: if the reachable app-owned daemon process started before the candidate binary was rebuilt, force restart even when the socket file itself is newer
  - apply the same policy to both direct supervisor and XPC-service supervisor paths
  - let metadata-enabled XCUITest opt into managed-daemon startup so the same freshness policy is exercised there too
- **Acceptance Criteria**:
  - [x] the app-owned daemon is not silently reused when the candidate `agtmux` binary is newer than the reachable daemon process that currently owns the app-owned socket
  - [x] focused regression coverage proves the freshness policy and daemon-process matching logic
  - [x] after restart, direct `ui.bootstrap.v2` probe on `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` contains no null `session_name` / `window_id` rows on the current local sample

### T-116 — Metadata-enabled plain-zsh XCUITest managed-row surfacing
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-117
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Close the remaining metadata-enabled plain-zsh UI proof failure so a real Codex process launched from a plain `zsh` pane surfaces as a managed sidebar row with provider/activity metadata on a fresh daemon runtime.
- **Current split**:
  - daemon freshness is now revalidated on the normal app-owned socket; the current focused red is no longer attributed to stale daemon reuse
  - targeted metadata-enabled `xcodebuild` now reaches the real managed-row assertions and fails with:
    - `capture-pane` proving a real Codex run completed inside the app-driven `zsh` pane
    - sidebar snapshot showing `issue=nil probe=ok total=0 managed=0 probeTarget=nil`
  - the launch/harness side is now tightened further:
    - inventory-only launch no longer dies at `Running Background`
    - delayed metadata enable now spawns the isolated managed daemon on the custom socket
    - focused UI failure now records `daemonLaunch=spawned:... --socket-path /Users/virtualmachine/.agt/uit-<token>.sock daemon --tmux-socket /private/tmp/tmux-501/agtmux-managed-<token>`
    - focused UI failure also records `probe=ok total=0 managed=0`, so the remaining red is no longer daemon-socket startup but producer-side managed promotion on that explicit tmux socket
  - this narrows the remaining bug to the metadata-enabled harness runtime boundary:
    - app-driven tmux inventory is operating on the isolated test server
    - the managed daemon launched inside the app still yields zero managed rows on sync-v2 bootstrap
    - runtime handoff is now verified in-process:
      - `daemonLaunch=spawned:/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux:--socket-path,<custom-sock>,daemon,--tmux-socket,/private/tmp/tmux-501/agtmux-managed-<token>`
      - `bootstrapTmuxSocket` and `daemonArgs` match the same exact tmux socket path
      - `capture-pane` proves Codex completed inside that app-driven pane
    - upstream `agtmux:T-XTERM-A6` stripped-PATH producer repro is now green, so the remaining red is narrowed further to the app-launched child-daemon environment/context
    - `ui.bootstrap.v2 total=0` should now be read precisely:
      - it does not prove tmux inventory is empty
      - it proves the daemon did not promote any pane into a managed sync-v2 row in this launch context
    - term-side spawn-env hardening is now landed and verified in the failure summary:
      - child daemon launch env includes normalized `HOME/USER/LOGNAME/XDG_CONFIG_HOME/CODEX_HOME/PATH`
      - child daemon launch env includes explicit `TMUX_BIN=/opt/homebrew/bin/tmux`
    - even with normalized spawn env, the metadata-enabled UI lane still returns `ui.bootstrap.v2 total=0`, so the blocker remains upstream `agtmux:T-XTERM-A6`
  - March 9, 2026 follow-up narrowed a second term-side readiness bug:
    - a live manual repro that matches the app lane (`zsh -l`, isolated `tmux -f /dev/null -L ...`, explicit `--tmux-socket`, real `codex exec`) shows `ui.bootstrap.v2` can legitimately start at `snapshot_seq=0 panes=[]` and then become non-empty on the next poll
    - current `AppViewModel` primes sync-v2 ownership on the first successful bootstrap, even when local tmux inventory is already non-empty
    - that is too early for the exact-identity consumer because an empty bootstrap carries no visible `session_name` / `window_id` mapping, so later change replay cannot recover exact-row overlay from that epoch
  - upstream `agtmux:T-XTERM-A6` is now green on the explicit-socket app-child repro:
    - producer truth is present in the same failing UI lane
    - live probing during the focused XCUITest now shows `ui.bootstrap.v2` surfacing the exact target row as `presence=managed provider=codex activity=running|waiting_input`
    - the app-side sidebar snapshot path also reports `all=presence=managed,provider=codex,activity=waiting_input`
  - the remaining red is now narrowed to the terminal repo's visible accessibility surfacing:
    - the existing UI proof still times out on provider/activity marker detection even while app truth is already managed
    - current pane-row accessibility relies on tiny hidden overlay children beneath a `.combine` wrapper, so the visible row can be correct while the XCUITest marker descendants remain undiscoverable
- **Plan**:
  - keep launch-path managed-daemon startup off the metadata-enabled launch critical path so XCUITest activation remains stable
  - keep metadata-enabled app-driven tmux UI tests on an isolated daemon socket in addition to the isolated tmux server
  - add app-side diagnostics that dump the exact managed-daemon socket path, daemon CLI arguments, and bootstrap-resolved tmux socket path into the UI-test snapshot
  - keep the runtime handoff in place and preserve its diagnostics (`managedSocket`, `daemonLaunch`, `bootstrapTmuxSocket`, daemon stderr tail)
  - preserve the landed spawn-env hardening and its diagnostics (`daemonEnv`)
  - treat `inventory present + bootstrap panes=[]` as a transient not-ready state in the term consumer instead of priming sync-v2 ownership on it
  - keep the metadata-enabled UI lane from launching the real Codex proof until the isolated daemon has published a non-empty bootstrap for the exact tmux runtime
  - replace the fragile hidden child-marker contract with an explicit pane-row accessibility contract that surfaces provider/activity/freshness on the visible row itself
  - keep a targeted metadata-enabled live XCUITest proving a plain `zsh`-launched Codex pane becomes a managed row and exposes provider/activity through the stable AX contract
  - keep live AppViewModel managed entry/exit canaries green as the lower-layer product oracle
- **Acceptance Criteria**:
  - [x] targeted metadata-enabled `xcodebuild` no longer fails at `launch()` with `Running Background`
  - [x] targeted metadata-enabled `xcodebuild` reaches the plain-zsh managed-pane assertions on a fresh daemon runtime
  - [x] delayed metadata enable from an inventory-only launch still starts the isolated managed daemon on the custom socket
  - [x] targeted metadata-enabled `xcodebuild` proves a plain-zsh-launched Codex pane surfaces as a managed sidebar row with provider/activity metadata
  - [x] the visible pane row exposes provider/activity/freshness through a stable row-level accessibility contract instead of fragile hidden child markers
  - [x] metadata-enabled app-driven XCUITest no longer shares the persistent app-owned daemon socket with normal app launches
  - [ ] metadata-enabled managed-daemon launch consumes the exact bootstrap-resolved tmux socket path instead of re-resolving by socket name later
  - [x] upstream `agtmux:T-XTERM-A6` stripped-PATH producer repro is green on the rebuilt local daemon binary
  - [x] app-launched managed-daemon spawn env is now normalized and includes explicit `TMUX_BIN` in both launch and probe paths
  - [x] metadata-enabled local sync-v2 does not treat `inventory present + bootstrap panes=[]` as a ready epoch
  - [x] targeted metadata-enabled XCUITest waits for a non-empty isolated bootstrap before asserting managed Codex surfacing
  - [x] lower-layer live Codex/Claude canaries remain green against the updated daemon binary
  - [x] docs/current/progress isolate daemon socket/runtime handoff as the current harness prerequisite instead of blaming managed-exit product truth

## Recently Closed

### T-131 — extract local metadata async refresh coordinator
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-130
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Narrow the remaining AppViewModel-heavy local metadata async orchestration without changing semantics.
  - Extract bootstrap fetch/result resolution, replay reset selection, and the one-step refresh decision body into one coordinator while leaving `Task` lifecycle in `AppViewModel`.
- **Acceptance Criteria**:
  - [x] bootstrap fetch/result resolution no longer lives directly in `AppViewModel`
  - [x] active replay reset selection no longer lives directly in `AppViewModel`
  - [x] the main metadata refresh decision body is delegated into one helper/coordinator
  - [x] focused coordinator tests and existing AppViewModel v2/v3 fallback regressions remain green

### T-130 — extract local metadata refresh state-transition boundary
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-129
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Narrow AppViewModel's direct ownership of local metadata refresh state transitions without changing semantics.
  - Extract bootstrap-not-ready classification plus publish/clear state transitions into one helper while leaving the async refresh loop in place.
- **Acceptance Criteria**:
  - [x] bootstrap-not-ready handling for sync-v2 and sync-v3 no longer lives directly in `AppViewModel`
  - [x] publish/clear cache state transitions are shaped by one helper boundary
  - [x] exact-row replay/cache semantics remain unchanged because replay still flows through `LocalMetadataOverlayStore`
  - [x] focused state-transition tests are green alongside the existing AppViewModel fallback/exact-row regressions

### T-129 — extract local metadata overlay/replay application behind one helper
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-128
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Narrow AppViewModel's direct ownership of local metadata overlay cache construction and replay application without changing semantics.
  - Extract the exact-row bootstrap cache builder, v2/v3 replay application, and base-pane resolution helpers into one pure helper/store.
  - Leave transport selection in `LocalMetadataTransportBridge`, and leave publish/clear scheduling plus task orchestration in `AppViewModel`.
- **Acceptance Criteria**:
  - [x] the overlay/replay seam no longer lives directly inside `AppViewModel.swift`
  - [x] exact-row v2 base-pane resolution and v3 upsert/remove behavior remain unchanged
  - [x] focused helper tests cover v3 bootstrap cache build plus v2/v3 replay application
  - [x] existing AppViewModel fallback/exact-row regressions stay green

### T-128 — isolate local metadata transport/fallback selection behind a small bridge
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-127
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Narrow AppViewModel's direct knowledge of sync-v3/v2 bootstrap fallback without changing overlay semantics.
  - Keep overlay application, publish, and exact-row merge in AppViewModel for now, but move transport selection and unsupported-method fallback classification into one helper.
- **Acceptance Criteria**:
  - [x] local metadata bootstrap transport selection is isolated behind one helper
  - [x] sync-v3 unsupported-method fallback classification is no longer open-coded inside AppViewModel
  - [x] exact-row overlay behavior and v2 fallback semantics stay unchanged
  - [x] focused tests cover the extracted bridge plus the existing AppViewModel fallback regressions

### T-127 — isolate product-facing legacy pane collapse behind a display adapter
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-126
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Shrink the product-facing `ActivityState` / legacy-pane boundary without attempting full v2 removal.
  - Introduce one local display adapter so sidebar/accessibility/UI-test consumers no longer each re-implement legacy fallback logic.
- **Acceptance Criteria**:
  - [x] one shared display adapter isolates product-facing fallback from raw `AgtmuxPane` + optional v3 presentation
  - [x] sidebar row, badge/count, accessibility summary, and UI-test sidebar snapshot use the shared adapter rather than bespoke legacy collapse logic
  - [x] focused tests lock both v3-backed and legacy-fallback display behavior
  - [x] v2 transport/workbench compatibility and fallback remain intact

### T-132 — product local metadata path requires sync-v3
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-131
- **Owner**: term implementation agent
- **Description**:
  - Remove sync-v2 fallback from the product `AppViewModel` local metadata refresh/bootstrap path while leaving transport/service-boundary/workbench compatibility code alive.
  - Unsupported `ui.bootstrap.v3` / `ui.changes.v3` must now surface a product-facing daemon incompatibility instead of silently downgrading the live overlay path.
- **Acceptance Criteria**:
  - [x] product `AppViewModel` local metadata bootstrap uses sync-v3 only
  - [x] product `AppViewModel` local metadata replay uses sync-v3 changes only
  - [x] unsupported sync-v3 bootstrap or changes now clears overlay state and surfaces daemon incompatibility instead of falling back to sync-v2
  - [x] exact-row v3 overlay behavior and live canary assumptions remain intact
  - [x] remaining sync-v2 code is documented as compatibility-only, not product refresh truth

### T-133 — migrate broad AppViewModel product tests off sync-v2 assumptions
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-132
- **Owner**: term implementation agent
- **Description**:
  - The broad `AppViewModelA0Tests` suite still contains many pre-cutover cases that inject sync-v2-only bootstrap/changes into the product AppViewModel path.
  - Migrate those product-facing tests to sync-v3 fixtures or move remaining sync-v2 expectations into compat-only suites so the broad product suite matches current product truth.
- **Acceptance Criteria**:
  - [x] broad AppViewModel product tests no longer assume sync-v2 fallback in the product metadata path
  - [x] any remaining sync-v2 coverage lives in compat-only transport/service-boundary tests instead of product AppViewModel expectations
  - [x] focused no-fallback sync-v3 product tests remain green after the migration

### T-134 — remove dead sync-v2 fallback selector surface from LocalMetadataTransportBridge
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-133
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Product code no longer uses `LocalMetadataTransportBridge` as a sync-v3->v2 fallback selector.
  - Delete the dead bridge surface and narrow tests to the remaining required-v3 passthrough behavior.
- **Acceptance Criteria**:
  - [x] `prefersSyncV3` is removed from `LocalMetadataTransportBridge`
  - [x] `fetchBootstrap(using:)` and `markV3UnsupportedIfNeeded(...)` are removed
  - [x] bridge tests cover only the remaining required-v3 bootstrap passthrough/error propagation
  - [x] product no-fallback and coordinator tests remain green after the cleanup

### T-135 — rename stale product-facing local daemon incompatibility naming
- **Status**: DONE
- **Priority**: P2
- **Depends**: T-134
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - The product metadata path now requires sync-v3, so `LocalDaemonIssue.incompatibleSyncV2` is stale and misleading.
  - Rename the product-facing issue identity to match current reality without deleting broader sync-v2 compatibility code.
- **Acceptance Criteria**:
  - [x] the product-facing enum case is renamed to reflect incompatible metadata protocol rather than sync-v2 specifically
  - [x] banner / empty-state text and restore-path mappings use the renamed product issue identity consistently
  - [x] focused tests and current tracking docs no longer present the product issue as specifically a sync-v2 incompatibility

### T-136 — migrate live product managed-agent suite to sync-v3 truth
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-135
- **Owner**: term implementation agent
- **Description**:
  - Migrate `AppViewModelLiveManagedAgentTests` off sync-v2 and raw `ActivityState` assumptions so the live product suite matches the current sync-v3-only metadata path.
  - Keep the live suite anchored in sync-v3 exact-row identity and presentation/display semantics while preserving compat-only coverage elsewhere.
- **Acceptance Criteria**:
  - [x] live managed-agent tests bootstrap and observe daemon truth through `ui.bootstrap.v3` / `ui.changes.v3`
  - [x] live product assertions prefer `PanePresentationState` / `PaneDisplayState` over raw legacy `ActivityState` where the product path already does
  - [x] product live assertions explicitly prove sync-v2 bootstrap/changes fallback stays unused
  - [x] managed-exit and same-session no-bleed live cases stay green after the sync-v3 migration

### T-137 — migrate UI test bridge diagnostics to sync-v3 truth
- **Status**: DONE
- **Priority**: P2
- **Depends**: T-136
- **Owner**: term implementation agent
- **Description**:
  - Move `UITestTmuxBridge` sidebar dump/bootstrap diagnostics off `ui.bootstrap.v2` and raw `AgtmuxPane.activityState` assumptions.
  - Keep UI harness output anchored in sync-v3 bootstrap truth plus `PaneDisplayState` / `PanePresentationState` summaries.
- **Acceptance Criteria**:
  - [x] app-side `__agtmux_dump_sidebar_state__` probe uses `ui.bootstrap.v3`
  - [x] bootstrap target diagnostics expose sync-v3 presentation/identity fields instead of raw sync-v2 activity/current-cmd assumptions
  - [x] deterministic non-UI verification locks the sync-v3 diagnostic shape
  - [x] focused metadata-enabled UI execution blocker remains documented as an automation harness defer, not a product failure

### T-138 — migrate live Codex UI proof off raw activity labels
- **Status**: DONE
- **Priority**: P2
- **Depends**: T-137
- **Owner**: term implementation agent
- **Description**:
  - Align the metadata-enabled plain-zsh Codex UI proof with sync-v3 presentation semantics.
  - Replace remaining raw `activity=...` checks in the live Codex UI test with `primary=...` checks and allow the canonical `completed_idle` completion state.
- **Acceptance Criteria**:
  - [x] the live Codex UI proof asserts `primary=...` instead of raw `activity=...`
  - [x] completion assertions accept `completed_idle` alongside `waiting_user_input` and `idle`
  - [x] focused compile/build verification remains green while the automation-mode execution blocker stays documented separately

### T-139 — make UI sidebar diagnostics presentation-first
- **Status**: DONE
- **Priority**: P2
- **Depends**: T-137, T-138
- **Owner**: term implementation agent
- **Description**:
  - Remove the remaining raw `AgtmuxPane` fallback arrays from the UI test sidebar dump payload and make summary/polling paths consume presentation snapshots first.
  - Keep exact-row targeting strict through session/pane identity plus `current_cmd` where shell readiness still needs inventory-derived proof.
- **Acceptance Criteria**:
  - [x] `UITestTmuxBridge` sidebar dump payload no longer requires raw pane arrays for the product-facing summary path
  - [x] `AgtmuxTermUITests` bootstrap-ready polling and `sidebarStateSummary(...)` consume presentation snapshots first
  - [x] deterministic integration coverage locks the presentation-first sidebar summary shape

### T-140 — align pane row accessibility summaries with sync-v3 presentation semantics
- **Status**: DONE
- **Priority**: P2
- **Depends**: T-139
- **Owner**: term implementation agent
- **Description**:
  - Replace the remaining `activity=...` terminology in pane row accessibility summaries with `primary=...`.
  - Keep accessibility identifiers stable while aligning row metadata text with `PanePresentationPrimaryState`.
- **Acceptance Criteria**:
  - [x] `PaneRowAccessibility` emits `primary=...` instead of `activity=...`
  - [x] focused accessibility summary tests reflect the presentation-first terminology
  - [x] stale no-presentation overload is removed if it no longer serves product code

### T-141 — remove stale freshness/accessibility wording drift
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-140
- **Owner**: term implementation agent
- **Description**:
  - Remove the unused `FreshnessLabel(ageSecs:)` helper and tighten wording around the legacy-stable `sidebarPaneActivityPrefix`.
  - Keep the identifier string unchanged while making docs/comments explicit that the marker now carries sync-v3 primary-state semantics.
- **Acceptance Criteria**:
  - [x] `FreshnessLabel(ageSecs:)` is removed if unused
  - [x] accessibility/docs wording explains that `sidebar.pane.activity.*` is a stable identifier name with primary-state semantics
  - [x] focused verification remains green

### T-142 — make incompatible metadata detail protocol-accurate
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-132, T-135
- **Owner**: term implementation agent
- **Description**:
  - Keep product-facing local daemon incompatibility detail aligned with the current sync-v3-required metadata path.
  - Preserve factual failing RPC names where useful, but stop surfacing raw `sync-v2 bootstrap` wording as if it were product truth.
- **Acceptance Criteria**:
  - [x] surfaced incompatible metadata detail prefers `metadata protocol` / `metadata bootstrap` wording
  - [x] factual failing RPC names like `ui.bootstrap.v2` remain visible where they are the actual failing method or payload source
  - [x] focused product tests cover the updated detail wording

### T-143 — remove sync-v2 reset usage from product metadata path
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-132
- **Owner**: term implementation agent
- **Description**:
  - Narrow the product-facing metadata abstraction so `AppViewModel` only resets sync-v3 replay state.
  - Keep low-level sync-v2 reset APIs alive only on compatibility-layer surfaces that still need them.
- **Acceptance Criteria**:
  - [x] `AppViewModel` no longer calls `resetUIChangesV2()`
  - [x] product-facing metadata abstraction no longer requires sync-v2 reset
  - [x] focused no-fallback product tests assert reset-v2 stayed unused

### T-144 — narrow product-facing metadata client surface to sync-v3
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-143
- **Owner**: term implementation agent
- **Description**:
  - Keep product code on a v3-only metadata client/protocol surface while leaving sync-v2 helpers on compat-only low-level clients and tests.
- **Acceptance Criteria**:
  - [x] product-facing tests and stubs now depend on `ProductLocalMetadataClient`
  - [x] product-facing client wording now describes snapshot + sync-v3 metadata + health instead of generic sync-v2-era metadata
  - [x] focused verification stays green without widening sync-v2 RPC deletion scope

### T-145 — isolate PaneDisplayState legacy activity fallback seam
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-144
- **Owner**: term implementation agent
- **Description**:
  - Keep `PaneDisplayState` presentation-first while moving legacy `ActivityState` collapse into an explicit compat-only helper in `AgtmuxTermCore`.
- **Acceptance Criteria**:
  - [x] `PaneDisplayState` no longer inlines the legacy `ActivityState` → primary/freshness mapping
  - [x] a compat-only helper owns that mapping without changing visible behavior
  - [x] focused core tests cover the extracted seam and the unchanged display behavior

### T-146 — isolate metadata overlay legacy activity collapse seam
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-145
- **Owner**: term implementation agent
- **Description**:
  - Keep `LocalMetadataOverlayStore` behavior unchanged while moving its `PanePresentationState` → `ActivityState` collapse into an explicit compat-only helper.
- **Acceptance Criteria**:
  - [x] `LocalMetadataOverlayStore` no longer inlines legacy presentation-to-activity collapse
  - [x] compat-only helper owns the mapping from `PanePresentationState` to `ActivityState`
  - [x] focused core/integration tests prove the unchanged compat row behavior

### T-147 — isolate legacy needs-attention compat collapse
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-145
- **Owner**: term implementation agent
- **Description**:
  - Keep `PaneDisplayState` presentation-first while moving its fallback `ActivityState` → `needsAttention` collapse into an explicit compat-only helper.
- **Acceptance Criteria**:
  - [x] `PaneDisplayState` fallback path no longer relies on `AgtmuxPane.needsAttention`
  - [x] `PaneDisplayCompatFallback` owns legacy `ActivityState` → `needsAttention` collapse
  - [x] focused core tests cover the extracted seam and unchanged display behavior

### T-148 — delegate pane attention compat property to helper
- **Status**: DONE
- **Priority**: P3
- **Depends**: T-147
- **Owner**: term implementation agent
- **Description**:
  - Keep `AgtmuxPane.needsAttention` alive for compat while making it delegate to `PaneDisplayCompatFallback` instead of owning an inline legacy collapse.
- **Acceptance Criteria**:
  - [x] `AgtmuxPane.needsAttention` no longer inlines `ActivityState` → attention collapse
  - [x] `PaneDisplayCompatFallback` is the single compat helper for that legacy mapping
  - [x] focused core tests prove the delegate path without changing visible behavior

### T-126 — thin live canary for sync-v3 bootstrap/changes exact-row lane
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-125
- **Owner**: term implementation agent
- **Description**:
  - Add one narrow live canary that proves the term app consumes daemon `ui.bootstrap.v3` plus `ui.changes.v3` and updates the same exact local row without falling back to sync-v2.
- **Acceptance Criteria**:
  - [x] one live integration canary exercises real daemon bootstrap-v3 plus changes-v3 through `AppViewModel`
  - [x] the canary proves the same exact local row is updated from v3 truth rather than recreated through a weakened identity match
  - [x] the canary records that `AppViewModel` used `fetchUIBootstrapV3()` and `fetchUIChangesV3()` while leaving sync-v2 fallback untouched
  - [x] current XCUITest foreground-activation blocker remains explicitly deferred instead of being stretched into this slice

### T-125 — titlebar-adjacent and UI-harness presentation consumer cutover
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-124
- **Owner**: term implementation agent
- **Description**:
  - Land the next small presentation cutover slice without broad UI rewrite.
  - Keep titlebar on the shared presentation-derived count/filter path and cut over remaining low-risk UI-adjacent consumers such as test/diagnostic sidebar summaries.
- **Acceptance Criteria**:
  - [x] shared `attentionCount` / filter derivation continues to serve titlebar through `PanePresentationState`
  - [x] UI-harness sidebar summaries no longer depend only on raw legacy `AgtmuxPane` fields when a presentation-derived summary is available
  - [x] focused integration coverage locks freshness/error helper behavior for low-risk UI consumers
  - [x] targeted UI-test build compiles with the additive summary changes
  - [ ] targeted XCUITest rerun is green; current result is still blocked by `Failed to activate application ... (current state: Running Background)`

### T-124 — first sync-v3 UI cutover for sidebar row presentation and filter/count
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-123
- **Owner**: term implementation agent
- **Description**:
  - Land the first small UI cutover onto `PanePresentationState` without removing the legacy render model.
  - Scope is limited to sidebar row presentation plus sidebar filter/count derivation.
- **Acceptance Criteria**:
  - [x] sidebar row AX summary can consume `PanePresentationState` instead of only legacy `AgtmuxPane`
  - [x] sidebar row provider/activity/freshness surfacing prefers local presentation state when a v3-backed overlay exists
  - [x] sidebar filter/count derivation (`managed` / `attention`) uses `PanePresentationState` when present and falls back to legacy state otherwise
  - [x] exact-row presentation cache is updated/cleared alongside additive bootstrap-v3 / changes-v3 overlay state
  - [x] focused tests cover presentation-aware row summary plus AppViewModel presentation/filter/count behavior
  - [x] current v2 / `ActivityState` render path remains otherwise intact
  - [ ] targeted XCUITest rerun is green; current result is still blocked by `Failed to activate application ... (current state: Running Background)`

### T-123 — additive changes-v3 consumer bridge in AppViewModel/XPC path
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-122
- **Owner**: term implementation agent
- **Description**:
  - Consume daemon `ui.changes.v3` additively in the term replay path without cutting over the live render path yet.
  - Keep exact-row correlation strict and adapt v3 change truth into the existing term-local row model only as far as needed for live overlay update/remove.
- **Acceptance Criteria**:
  - [x] the daemon client and bundled XPC service expose additive `fetchUIChangesV3()` / `resetUIChangesV3()` support
  - [x] `AppViewModel` can keep a bootstrap-v3 live overlay current through additive `ui.changes.v3` upsert/remove handling
  - [x] exact-row replay mapping remains strict on:
    - `session_name`
    - `window_id`
    - `session_key`
    - `pane_id`
    - `pane_instance_id`
  - [x] sync-v2 remains the fallback path whenever bootstrap-v3 or changes-v3 is unsupported
  - [x] focused tests cover changes-v3 decode, v3 session cursor handling, XPC/service transport handling, and AppViewModel exact-row update/remove/fallback behavior
  - [x] current sidebar/titlebar/filter/count rendering remains intentionally on legacy `AgtmuxPane` / `ActivityState`

### T-122 — additive bootstrap-v3 consumer bridge in AppViewModel/XPC path
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-121
- **Owner**: term implementation agent
- **Description**:
  - Consume daemon `ui.bootstrap.v3` additively in the term bootstrap path without cutting over the live v2 delta/render path yet.
  - Keep exact-row correlation strict and bridge v3 truth into the existing term-local row model only as far as needed for bootstrap.
- **Acceptance Criteria**:
  - [x] the daemon client and bundled XPC service expose additive `fetchUIBootstrapV3()` support
  - [x] `AppViewModel` bootstrap/resync path prefers `ui.bootstrap.v3` and falls back to `ui.bootstrap.v2` only when v3 is unsupported
  - [x] bootstrap-v3 overlay mapping preserves strict correlation identity:
    - `session_name`
    - `window_id`
    - `session_key`
    - `pane_id`
    - `pane_instance_id`
  - [x] focused tests cover bootstrap-v3 decode through direct/XPC clients plus exact-row AppViewModel mapping
  - [x] `ui.changes.v2` and current sidebar/titlebar/filter/count product paths remain live by design

### T-121 — daemon-owned sync-v3 fixture ingestion in term consumer tests
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-120
- **Owner**: term implementation agent
- **Description**:
  - Replace temporary local v3 consumer fixtures with daemon-owned canonical bootstrap fixtures from `agtmux` commit `cb198cca7226666fbb26df34d4e17582a208c3e6`.
  - Keep v3 client support additive only; do not start AppViewModel/live cutover.
- **Acceptance Criteria**:
  - [x] term-side v3 decode tests read daemon-owned fixtures directly from `agtmux/fixtures/sync-v3/`
  - [x] decode/presentation coverage explicitly includes:
    - `codex-running`
    - `codex-waiting-approval`
    - `codex-completed-idle`
    - `claude-approval`
    - `claude-stop-idle`
    - `unmanaged-demotion`
    - `error`
    - `freshness-degraded`
  - [x] term-side docs record daemon commit `cb198cca7226666fbb26df34d4e17582a208c3e6` as the current fixture truth source
  - [x] an additive v3 bootstrap decode surface exists in the daemon client layer without wiring live app paths
  - [x] v2 / `ActivityState` product paths remain untouched

### T-120 — sync-v3 term consumer foundation and presentation scaffolding
- **Status**: DONE
- **Priority**: P1
- **Depends**: none
- **Owner**: term implementation agent
- **Description**:
  - Land the first term-side v3 slice without touching the live v2 product path:
    - strict consumer-side `AgtmuxSyncV3Models`
    - local `PanePresentationState` derivation layer
    - temporary fixture-first decode/presentation tests derived from the final design doc
    - local consumer docs explaining daemon truth vs term presentation
- **Acceptance Criteria**:
  - [x] a consumer-side `AgtmuxSyncV3Models` file exists and keeps exact identity fields strict (`session_name`, `window_id`, `session_key`, `pane_id`, `pane_instance_id`)
  - [x] the term repo has a local `PanePresentationState` derivation layer that is decoupled from raw wire structs
  - [x] pure tests cover representative v3 presentation states: running, waiting approval, waiting user input, completed+idle, error, degraded freshness
  - [x] docs explain daemon truth vs term presentation, exact-row correlation, and `attention` as summary-not-truth
  - [x] current v2 / `ActivityState` product paths remain intact
### T-115 — Live agent entry/exit truth and UITest runner auth visibility
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-114
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Close the remaining March 8, 2026 live regressions where plain `zsh` panes launching Claude/Codex do not always surface in the sidebar and managed/provider marks can persist after the pane has already returned to a no-agent shell.
- **Closeout**:
  - upstream `agtmux:T-XTERM-A5` is now fixed and validated with Codex/Claude managed-exit scenarios
  - term-side exact-row managed -> unmanaged clearing remains green in `AppViewModelA0Tests`
  - term-side live `AppViewModelLiveManagedAgentTests` are green against the updated daemon binary, including the plain-zsh managed-pane surfacing canary
  - the only remaining red is the metadata-enabled XCUITest foreground-activation harness issue, now tracked separately as `T-116`

### T-114 — Single-writer local overlay recovery and live managed-pane surfacing
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-113
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Clean-break the term-side local inventory/metadata consumer so healthy daemon truth cannot be hidden by stale inventory-only publishes, and prove recovery plus plain-zsh agent detection with live E2E.
- **Root cause**:
  - current `AppViewModel` lets two paths publish local rows:
    - `fetchAll()` writes a local merged snapshot based on whatever metadata cache existed when inventory returned
    - background sync-v2 refresh writes a newer metadata-derived local snapshot later
  - that dual-writer model allows stale inventory-only local rows to overwrite newer managed/provider/activity overlay rows, so the daemon can already report `managed/provider/activity` truth while the sidebar still renders inventory-only rows
- **Plan**:
  - split local inventory cache from local metadata cache and derive visible local rows at publish time
  - make metadata recovery explicit: invalid bootstrap clears overlay, later healthy bootstrap restores overlay in the same app instance without relaunch
  - add regression coverage for incompatible → healthy recovery
  - add live E2E proving a plain zsh pane that launches real Claude/Codex becomes a managed/provider/status row in the visible app path
- **Progress**:
  - `AppViewModel` no longer writes local merged rows into the shared snapshot cache from `fetchAll()`
  - local visible rows are now derived from `lastSuccessfulLocalInventory + cachedLocalMetadataByPaneKey` at publish time
  - focused regressions are landed and green:
    - `testHealthyBootstrapAfterIncompatibleStateRestoresManagedOverlayWithoutRelaunch`
    - `testSlowRemoteFetchCannotOverwriteNewerLocalManagedOverlay`
  - existing real CLI live canaries remain green after the refactor:
    - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests`
  - a new live consumer canary now proves the user-reported symptom directly without XCUITest:
    - `testLivePlainZshAgentLaunchSurfacesManagedFilterProviderAndActivity`
    - plain `zsh -l` panes launch real Claude/Codex, then `AppViewModel.statusFilter = .managed` must surface both rows with exact provider/activity truth
  - targeted metadata-enabled UI live proof also exists for plain zsh → Codex surfacing
  - latest XCUITest rerun now enters the test body, but the sandboxed `xctrunner` still skips the proof because `codex login status` returns `Not logged in`; this remains a non-blocking environment note, not the recurrence-prevention gate
- **Acceptance Criteria**:
  - [x] `fetchAll()` no longer stores stale local merged rows that can overwrite a newer metadata publish
  - [x] incompatible bootstrap followed by healthy bootstrap restores provider/activity/title overlay without relaunch
  - [x] live E2E proves a real Claude/Codex session launched from a plain zsh pane is surfaced as a managed row with provider/activity in the app path
  - [x] docs/current/progress are updated to the new single-writer model before commit

### T-113 — Dirty bootstrap contract drift handback for null exact-location fields
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-112
- **Owner**: Orchestrator (direct implementation + daemon handback)
- **Description**:
  - Track the fresh March 8, 2026 live regression where `ui.bootstrap.v2` emits managed panes with `session_name` / `window_id` missing, causing the strict terminal consumer to drop all managed overlay rows.
- **Progress**:
  - live app evidence plus direct socket inspection now agree on the producer-side failure:
    - app log: `RPC ui.bootstrap.v2 parse failed: The data couldn’t be read because it is missing.`
    - direct socket payload contains many managed rows with `session_name: null` and `window_id: null`
    - current local sample on the app-managed socket: 94 panes total, 88 rows with null exact-location fields
  - terminal-side remediation landed for fail-loud surfacing:
    - strict bootstrap decoding now labels missing exact-location fields explicitly (`session_name`, `window_id`) instead of collapsing to a generic missing-data decode error
    - focused regressions now cover the live March 8 null-exact-field payload shape
  - producer fix is now landed upstream in `agtmux` commit `c9807f0` (`Exclude unresolved panes from sync bootstrap`)
  - cross-repo validation after restarting the app-managed daemon now shows the normal path is healthy again:
    - `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` returns 4 managed panes with `session_name` / `window_id` / `session_key` / `pane_instance_id` all present
    - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests` is green
- **Verification**:
  - `swift test -q --filter AgtmuxSyncV2DecodingTests/testDecodeBootstrapFailsWhenExactLocationFieldsAreNull`
  - `swift test -q --filter AppViewModelA0Tests/testLiveMarch8BootstrapSampleWithNullExactLocationFieldsFailsClosedAndSurfacesIncompatibleDaemon`
  - direct `ui.bootstrap.v2` probe against `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` after daemon restart
  - `AGTMUX_LIVE_TEST_BIN=/Users/virtualmachine/ghq/github.com/g960059/agtmux/target/debug/agtmux swift test -q --filter AppViewModelLiveManagedAgentTests`
- **Acceptance Criteria**:
  - [x] terminal-side strict decode surfaces the missing exact field name instead of only a generic missing-data error
  - [x] terminal-side regression coverage includes a live March 8 style bootstrap payload with null `session_name` / `window_id`
  - [x] daemon-side docs are updated and a handover exists for the producer fix plus the online E2E blind spot
  - [x] after the daemon fix, cross-repo live smoke shows managed provider/activity metadata in the normal app path again

### T-111 — Live sidebar activity-state truth for the active Codex pane
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-110
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - fresh March 8, 2026 live user evidence reports a new activity-state regression after the IME slice:
    - the current pane where Codex is actively working is not surfaced as `running` in the sidebar
  - the cross-repo boundary is now locked before more code:
    - `agtmux` owns full real-CLI semantic truth for provider/activity/title/no-bleed
    - `agtmux-term` owns thin daemon-to-sidebar canaries for strict decode, exact-row overlay, and visible rendering
  - current implementation progress:
    - `AppViewModelLiveManagedAgentTests` now mirrors daemon-owned prompt defaults:
      - Claude default model: `claude-sonnet-4-6`
      - Codex default model: `gpt-5.4`
      - env overrides remain available via `CLAUDE_MODEL` / `CODEX_MODEL`
    - live daemon-truth-first canaries are now landed for:
      - Codex exact-row `running -> completion` propagation
      - Claude exact-row `running -> completion` propagation
      - Codex `waiting_input` -> attention/filter surfacing
    - all canaries require sibling rows to preserve their own daemon truth, so no-bleed is exercised on every live lane
    - fresh focused verification is green:
      - `swift build`
      - `swift test -q --filter AppViewModelLiveManagedAgentTests`
- **Description**:
  - Make the terminal repo prove that exact daemon activity truth for the active Codex pane reaches the correct sidebar row without bleed.
- **Acceptance Criteria**:
  - [x] the exact pane row hosting the active Codex process is surfaced as `running` when the daemon reports that row as `running`
  - [x] after the live Codex run settles, the same pane row surfaces the daemon-reported completion state (`waiting_input` or `idle`) without stale `running`
  - [x] no unrelated pane row inherits the target row's provider/activity metadata; sibling rows match their own daemon truth
  - [x] focused live regression coverage in this repo stays boundary-scoped: daemon payload truth is the primary oracle and sidebar/app truth is the consumer assertion

### T-112 — Waiting-approval consumer canary and visible attention surfacing
- **Status**: DONE
- **Priority**: P1
- **Depends**: T-111
- **Owner**: Orchestrator (direct implementation)
- **Description**:
  - Add the next thin terminal-repo canary for daemon-reported `waiting_approval`, including exact-row attention/badge/filter surfacing.
- **Progress**:
  - consumer-side proof stayed in the terminal repo; no daemon-side implementation or handover was needed for this slice because daemon semantic truth is already covered upstream
  - added an integration regression for exact-row `waiting_approval` overlay, `attentionCount`, and `.attention` filter without sibling bleed
  - added a targeted UI proof that exercises the visible Attention filter plus a stable explicit badge AX child instead of transcript heuristics
- **Verification**:
  - `swift test -q --filter AppViewModelA0Tests/testWaitingApprovalManagedRowSurfacesAttentionCountAndFilterWithoutBleed`
  - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testAttentionFilterShowsOnlyWaitingApprovalPanes`
- **Acceptance Criteria**:
  - [x] when the daemon reports `waiting_approval` for one exact managed row, the same visible row surfaces `waiting_approval`
  - [x] attention count / attention filter / visible badges match daemon truth for that row without sibling bleed
  - [x] if no stable real-CLI approval prompt exists, the repo uses an explicit daemon-owned handover or synthetic producer fixture instead of transcript heuristics

### T-110 — Ghostty terminal IME commit and preedit correctness
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-109
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - fresh March 8, 2026 live user evidence opens a terminal-input regression:
    - Japanese IME candidate window appears, but pressing Enter does not commit the candidate into the terminal
    - composed text does not reach the shell input line after conversion confirmation
  - current product root cause is narrowed to the AppKit IME event path in `GhosttyTerminalView`:
    - the current `keyDown` sends `ghostty_surface_key(...)` before `interpretKeyEvents(...)`
    - when marked text is active, confirm keys such as Enter can be consumed as raw terminal keys before AppKit finishes IME commit
    - the current implementation also omits Ghostty reference behaviors that matter for AppKit text input:
      - explicit preedit clear synchronization when marked text ends
      - explicit `doCommand(by:)` handling for AppKit command selectors during text input
  - clean-break remediation direction:
    - make AppKit IME the first-stage authority for `keyDown`
    - mirror Ghostty `SurfaceView_AppKit.swift` ordering closely enough that marked text / commit / composing state are derived from `interpretKeyEvents(...)`
    - keep terminal key encoding as the post-IME step, not the pre-IME gate
    - add focused regressions for marked-text Enter commit and preedit clearing
  - TDD order:
    - add failing terminal-view/input regressions for marked-text Enter commit and preedit clear behavior
    - implement Ghostty-aligned `keyDown` / `NSTextInputClient` fixes
    - rerun focused build/tests and, if needed, a lightweight AppKit-hosted regression harness
  - implementation is now landed in `GhosttyTerminalView`:
    - `keyDown` now runs `interpretKeyEvents(...)` before raw terminal key encoding
    - marked-text commit clears preedit explicitly
    - AppKit `doCommand(by:)` is handled explicitly so text input command selectors do not beep or short-circuit the keyDown post-processing path
    - deinit/release calls now expose a test seam so AppKit-focused view tests do not force `GhosttyApp.shared` initialization
  - focused verification is green on the current worktree:
    - `swift build`
    - `swift test -q --filter GhosttyTerminalViewIMETests`
    - `swift test -q --filter WorkbenchStoreV2Tests`
- **Description**:
  - Make Japanese/CJK IME commit behave like a normal AppKit text input client inside the Ghostty-backed terminal surface so conversion confirmation reaches the terminal reliably.
- **Acceptance Criteria**:
  - [x] when marked text is active, Enter confirmation reaches the IME pipeline before raw terminal Return handling
  - [x] committed IME text is sent to the terminal exactly once
  - [x] ending marked text clears libghostty preedit state explicitly
  - [x] focused regression coverage proves marked-text commit and preedit clear behavior without relying on manual confirmation

### T-109 — Terminal-originated tmux session-switch reverse sync
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-108
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - fresh March 8, 2026 user evidence reopens terminal reverse-sync at the session layer:
    - when the main terminal changes tmux session from inside the rendered client (for example via `repo` from `~/.config/zsh`), the sidebar remains pinned to the old session
    - the visible terminal continues to run on the new tmux session, so the app is now stale relative to rendered-client truth
  - current product root cause is narrower than metadata or same-session pane sync:
    - `WorkbenchV2TerminalNavigationResolver.liveTarget(sessionRef:renderedClientTTY:...)` filters `list-clients` by both `client_tty` and the tile's stored `sessionRef.sessionName`
    - once the rendered tmux client switches to another session, observation fails as `renderedClientUnavailable` instead of reporting the new session
    - `WorkbenchStoreV2.syncTerminalNavigation(...)` only updates window/pane on the existing stored session and has no path to rebind the tile's `SessionRef` from observed rendered-client truth
  - clean-break implementation direction:
    - rendered-client observation becomes authoritative for cross-session switch on the focused visible tile
    - the store gets an explicit observed-session rebind path that updates the tile's `SessionRef` and canonical active selection in place while preserving surface identity
    - duplicate-session collision on an observed session rebind must fail loudly instead of silently freezing the sidebar on stale identity
  - TDD order:
    - add failing store-level regression for rendered-client session switch rebasing the tile identity and active selection
    - add failing UI/E2E proof that switches the rendered tmux client to another session and expects sidebar/session highlight to follow
    - then land product code and rerun focused SPM + targeted UI verification
  - current implementation progress:
    - `WorkbenchStoreV2` now has an observed-session rebind path for rendered-client tmux session switches
    - rendered-client observation no longer filters `list-clients` by the tile's stored `sessionRef.sessionName`; it now observes the exact `client_tty` first and rebases session identity from that truth
    - same-surface cross-session rebases preserve rendered surface generation and client tty in `GhosttyTerminalSurfaceRegistry`
    - focused store/runtime regressions are green:
      - `testTerminalOriginatedSessionSwitchRebindsVisibleTileIdentityAndActiveSelection`
      - `testTerminalOriginatedSessionSwitchFailsLoudlyOnDuplicateVisibleDestinationSession`
      - `swift test -q --filter WorkbenchStoreV2Tests`
      - `swift test -q --filter GhosttyTerminalSurfaceRegistryTests`
      - `swift test -q --filter WorkbenchV2TerminalAttachTests`
      - `swift build`
    - targeted real-surface UI proof is now green on the current mainline:
      - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`
      - `xcodebuild -project AgtmuxTerm.xcodeproj -scheme AgtmuxTerm -destination 'platform=macOS,arch=arm64' test -only-testing:AgtmuxTermUITests/AgtmuxTermUITests/testTerminalSessionSwitchUpdatesSidebarSelectionWithRealTmux`
- **Description**:
  - Make terminal-originated tmux session switches authoritative so the visible tile and sidebar follow the rendered client's actual session instead of freezing on the session that was originally attached.
- **Acceptance Criteria**:
  - [x] terminal-originated tmux client session switch on the rendered visible tile updates sidebar session/pane highlight to the observed session
  - [x] the current visible tile rebases its `SessionRef` in place to the observed session when no duplicate visible owner exists
  - [x] the rebased tile preserves one Ghostty surface; session-switch reverse sync must not recreate a hidden clone or second visible tile
  - [x] if the observed destination session is already owned by another visible tile, the app surfaces an explicit collision instead of silently keeping stale sidebar state
  - [x] focused regression coverage proves rendered-client truth, tile identity, and sidebar selection all agree after a terminal-originated session switch

### T-108 — Active-pane single-source-of-truth and pane-instance identity recovery
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-107
- **Owner**: Orchestrator (direct implementation)
- **Progress**:
  - live March 7, 2026 user evidence invalidates the earlier `T-107` closeout:
    - plain `zsh` panes are still surfaced as `codex`
    - idle Codex panes are still surfaced as `running`
    - sidebar pane clicks do not reliably retarget the visible terminal
    - terminal-originated pane changes do not update sidebar highlight
  - after the agtmux-side wire fix, fresh live March 7, 2026 evidence narrows the remaining metadata bug to the term consumer:
    - the previous `session_id` incompatibility is gone, but product logs now show `metadata overlay dropped for mismatched session identity ...`
    - the current consumer is still comparing opaque `session_key` values (UUID / rollout IDs) to visible tmux `session_name`
    - same-session pane selection on real local sessions (for example `utm-main`) is still reported as not retargeting the visible terminal in the normal app path
  - fresh code inspection after the proposal pass isolates two product-side gaps that still explain the user-visible regressions:
    - bootstrap merge and change replay still contain `session_key == session_name` assumptions, so valid managed rows with opaque session keys are dropped before they can enrich inventory
    - same-session pane retarget is still not trusted against the normal app path once live daemon overlay is present; the remaining gap must be proved against real rendered-client truth, not only the app-driven UITest harness
  - proposal comparison already converged on the same gaps:
    - local overlay is still vulnerable to stale bleed because cache/publish semantics are not epoch-gated exact-identity truth
    - active pane state is still not modeled as one reducer-owned runtime state with rendered-client binding plus desired/observed pane truth
    - current pane-sync UI proofs are still not strong enough when they mutate tmux from an out-of-band control path instead of the rendered client itself
  - execution strategy changed on March 7, 2026 user direction:
    - stop real-agent implementation delegation for this slice
    - continue with orchestrator-owned TDD and verification directly
  - selected remediation direction is now design-locked:
    - local managed/provider/activity overlay must be exact-identity keyed (`session_key` + `pane_instance_id`) and epoch-gated
    - `session_key` must be treated as opaque metadata identity, not as tmux `session_name`
    - bootstrap correlation uses visible location (`session_name + window_id + pane_id`); change replay uses bootstrap-established exact identity and cached alias knowledge
    - any invalid local sync-v2 row (`session_id`, missing `session_key`, missing `pane_instance_id`, missing `session_name`, missing `window_id`) invalidates the whole current local metadata epoch and clears stale overlay before the next publish
    - terminal tile identity remains session-scoped (`SessionRef = target + sessionName`)
    - runtime pane focus moves into one reducer-owned state carrying rendered client binding, desired `ActivePaneRef`, and observed `ActivePaneRef`
    - sidebar click / duplicate reveal update desired state only; rendered-client observation updates observed state only; stale observed state must not overwrite a newer desired selection
    - same-session navigation stays exact-client scoped with `switch-client -c <tty> -t <pane>` and must preserve one rendered Ghostty surface
    - same-session navigation must retry until the exact rendered client converges and must restore first responder to the visible terminal host after sidebar clicks
    - pane-sync E2E must assert exact rendered-client truth and must stimulate reverse-sync on that same rendered client tty
  - TDD execution order:
    - add failing regressions for bootstrap location-collision / invalid-epoch fail-closed behavior after previously valid metadata
    - add failing regressions for valid bootstrap/change payloads where `session_key != session_name`
    - add reducer/navigation tests for desired-vs-observed race, rendered-client retry, and same-session focus restoration
    - strengthen real-surface UI/E2E so reverse-sync no longer uses a generic control client as the stimulus and prove same-session retarget on the normal daemon-connected path
  - current implementation progress:
    - bootstrap location collisions now invalidate the whole local metadata epoch and surface `daemon incompatible`
    - exact-client navigation now retries until rendered tmux client truth converges instead of issuing a one-shot `switch-client`
    - same-session sidebar retarget now emits a focus-restore nonce so the focused Ghostty host reclaims first responder after sidebar clicks
    - existing failing-regression scaffolding is already present in `AppViewModelA0Tests` and `WorkbenchStoreV2Tests`, but product code still does not satisfy it
    - fresh March 7, 2026 investigation found a second testing gap: `AGTMUX_UITEST` currently conflates bridge enablement, inventory-only fetch behavior, daemon-supervisor disablement, and polling suppression, so it cannot exercise the true metadata-enabled normal app path
    - fresh March 7, 2026 live and targeted-UI reruns narrowed the pane-sync failure again:
      - sidebar click updates the selected row and creates the terminal tile
      - the rendered tmux client tty never resolves for that tile, so exact-client navigation and reverse sync never start
      - vendor Ghostty only forwards custom OSC `9911` into the host action seam, so the current `9912` tty telemetry path can never bind in product
    - next step is a clean break:
      - fold rendered-client tty bind into the existing structured `OSC 9911` host bridge instead of relying on a second private OSC number
      - add failing coverage for missing rendered-client tty and rerun same-session UI/E2E on that new binding path
      - keep a later harness split on the board once the current product path is trustworthy again
    - fresh March 7, 2026 current-code rerun narrows the remaining UI red again:
      - `testPaneSelectionWithMockDaemonAndRealTmux` is green
      - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux` is green
      - only `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux` is red
      - the failure is no longer initial attach or sidebar selection; after a same-session sidebar retarget under metadata-enabled launch, terminal-originated reverse sync back to the first pane is still overwritten and the rendered tmux client stays on the second pane
    - fresh live daemon/socket inspection also produced a reusable exact-identity sample:
      - `ui.bootstrap.v2` now emits opaque `session_key` values for `vm agtmux` / `vm agtmux-term` while local tmux inventory still contains unmanaged rows such as `utm-main` and extra unmanaged panes in `vm agtmux-term`
      - this sample should become a fixture regression that proves managed/provider/activity overlay does not leak onto unrelated inventory rows even when `session_key != session_name`
    - final app-side fix shape is now landed:
      - desired-pane convergence confirmation is no longer one global threshold
      - initial attach still requires stable confirmation
      - same-session retarget from an already observed rendered client clears desired state after the first matching observation, so a later rendered-client-originated pane change is not overwritten
      - live opaque-session-key bootstrap sample is now locked as a no-leak regression fixture
    - final focused verification is green on the current worktree:
      - `swift build`
      - `swift test -q --filter WorkbenchStoreV2Tests`
      - `swift test -q --filter AppViewModelA0Tests`
      - `swift test -q --filter WorkbenchV2NavigationSyncResolverTests`
      - targeted arm64 `xcodebuild` for:
        - `testPaneSelectionWithMockDaemonAndRealTmux`
        - `testTerminalPaneChangeUpdatesSidebarSelectionWithRealTmux`
        - `testMetadataEnabledPaneSelectionAndReverseSyncWithRealTmux`
    - current app-side closeout boundary is explicit:
      - no open term-consumer blocker is tracked after the final green rerun
      - if fresh live status disagreements reappear, validate `ui.bootstrap.v2` / `ui.changes.v2` daemon truth before reopening the app consumer
- **Description**:
  - Replace the false-green `T-107` outcome with a clean-break fix for exact-pane identity, same-session pane retarget, and bidirectional sidebar/terminal selection sync.
- **Acceptance Criteria**:
  - [x] sync-v2 / XPC bootstrap rejects invalid local pane identity (`session_id`, missing `session_key`, missing `pane_instance_id`, missing `session_name`, missing `window_id`) as whole-payload incompatibility
  - [x] when an incompatible local bootstrap arrives after previously valid metadata, stale overlay cache is cleared before the next publish and sidebar truth becomes inventory-only immediately
  - [x] invalid/orphan local daemon managed rows never surface provider / activity / title bleed onto plain inventory rows
  - [x] bootstrap collisions or duplicate managed rows at one visible local pane location fail closed for the whole current metadata epoch instead of picking a “preferred” managed row
  - [x] valid local bootstrap rows still apply managed/provider/activity overlay when `session_key` is opaque and differs from visible `session_name`
  - [x] valid `ui.changes.v2` rows still update the matching inventory row when `session_key` is opaque and differs from visible `session_name`
  - [x] persisted terminal tile identity remains session-scoped only; reducer-owned runtime pane state is separate and non-persistent
  - [x] same-session sidebar click updates desired pane state, preserves tile/surface identity, and retargets the exact rendered tmux client tty
  - [x] same-session sidebar click keeps retrying exact-client navigation until observed rendered-client truth matches the requested pane/window and returns first responder to the visible terminal host
  - [x] same-session sidebar click and terminal-originated pane change still converge when the sidebar is showing inventory-only rows
  - [x] terminal-originated pane change on the rendered client updates observed pane state and sidebar highlight through the same reducer
  - [x] metadata-enabled normal app path also converges after a same-session sidebar retarget: once the rendered client has reached the requested pane, a later rendered-client-originated pane change must not be overwritten by stale desired state
  - [x] regression coverage proves exact rendered tmux client truth, reducer-resolved active pane state, sidebar highlight, and stable rendered-surface identity agree for sidebar -> terminal and terminal -> sidebar flows in both app-driven UITest and normal daemon-connected paths

### T-107 — Exact pane navigation and metadata isolation regressions
- **Status**: SUPERSEDED_BY_T-108
- **Priority**: P0
- **Depends**: T-106
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - this closeout is no longer treated as final product truth; later live user evidence on March 7, 2026 proved the remaining regressions were still present.
  - user-reported live regressions on March 7, 2026:
    - a plain `zsh` pane in `utm-main` is surfaced as `codex`
    - idle Codex panes are surfaced as `running`
    - selecting a different pane row within the same session does not change the main-panel terminal/cursor
  - root causes are now isolated:
    - local metadata overlay keyed by `source + paneId` was bleeding managed/provider/activity state across exact rows
    - duplicate-open reveal logic for same-session pane selection was dropping pane/window intent before `openTerminal(...)`
    - the remaining runner-side tmux UI smoke (`testPaneSelectionWithMockDaemonAndRealTmux`) was harness-fragile because it depended on the XCUITest runner creating a real tmux session itself
  - metadata-isolation product slice is landed:
    - `AgtmuxPane` now carries `metadataSessionKey` / `paneInstanceID`
    - `AppViewModel` correlates local metadata by exact row identity and drops ambiguous or mismatched changes
    - focused verification is green for `swift build` and `AppViewModelA0Tests`
  - same-session pane retarget product slice is now landed:
    - `SessionRef` carries explicit `preferredWindowID` / `preferredPaneID` hints while tile identity remains `target + sessionName`
    - duplicate-open reveal updates the stored terminal tile intent in place instead of dropping pane/window selection
    - direct tmux attach now preselects the requested window/pane before `attach-session`
    - sidebar pane-row open now passes exact pane/window intent into the V2 workbench path
  - focused verification for the pane-retarget slice is green in SPM:
    - `swift build`
    - `swift test -q --filter WorkbenchStoreV2Tests`
    - `swift test -q --filter WorkbenchV2TerminalAttachTests`
  - the flaky same-session smoke is now closed on the app-driven harness path:
    - tmux multi-field observation now uses a delimiter that tmux emits literally (`|`), not `\t`
    - pane/window observation polls app-driven `list-panes` results after `split-window` / `new-window`
    - the proof now reads active terminal retarget state from app-side `UITestTmuxBridge` snapshot output instead of AX `value`
    - targeted arm64 `xcodebuild` reruns for `testPaneSelectionWithMockDaemonAndRealTmux` and the duplicate-open proof are green
- **Description**:
  - Fix exact-pane metadata/status bleed and make same-session pane row selection drive the visible V2 terminal tile to the requested pane without reintroducing linked-session behavior.
- **Acceptance Criteria**:
  - [ ] superseded by `T-108`

### T-106 — Legacy linked-session path physical deletion
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-095
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - user clarification is explicit: V2 exists to eliminate linked-session / group-session creation from the shipped product path, not merely to stop using it by default.
  - dead runtime entry points are physically removed from the shipped target:
    - `WorkspaceStore`
    - `WorkspaceArea`
    - `LinkedSessionManager`
    - legacy-only core layout helpers/tests (`LayoutNode`, `TmuxLayoutConverter`, related tests) after extracting live `SplitAxis` and `TmuxCommandRunner`
  - `SurfacePool` and `GhosttySurfaceHostView` no longer carry linked-session-specific registration/indexing state.
  - linked-session-positive coverage is deleted:
    - `LinkedSessionIntegrationTests`
    - linked-session title/runtime UI proofs
  - current-path coverage is narrowed to V2 truths:
    - keep direct-attach open / duplicate-open proofs
    - keep exact-session identity regressions for linked-looking names and `session_group`
    - remove pane-level focus-sync / same-window fast-switch proofs that belonged to the old linked-session workspace model and are not current V2 contract
  - delegated verification closed successfully after one interrupted UI/test worker attempt; final focused build/test/UI evidence came from a second delegated verifier run.
- **Description**:
  - Physically remove the obsolete linked-session workspace implementation so the shipped app no longer contains code that can create `agtmux-linked-*` sessions through the legacy path.
- **Acceptance Criteria**:
  - [x] shipped app target no longer wires or compiles the legacy linked-session workspace path
  - [x] linked-session creation helpers and legacy workspace-only runtime types are removed unless still required by an explicitly retained non-product surface
  - [x] tests/docs no longer present linked-session or session-group behavior as an active product contract
  - [x] focused verification proves the V2 mainline still opens real sessions directly without linked-session regressions

### T-090 — Workbench V2 foundation path
- **Status**: DONE
- **Priority**: P0
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - V2 core/store/view foundation and feature-flagged top-level path landed on 2026-03-06.
  - Remote `TargetRef` mapping now resolves configured host keys rather than raw hostnames.
  - Fresh build, focused SPM tests, and the targeted flag-on UI test are green.
  - Review conditions from the earlier `GO_WITH_CONDITIONS` verdict were cleared by `T-096` and `T-097`.
  - Final review verdict is `GO`.
- **Description**:
  - Create an isolated V2 Workbench model and top-level view/store path.
  - Support `terminal`, `browser`, and `document` tile kinds without mixing with linked-session lifecycle.
- **Acceptance Criteria**:
  - [x] `Workbench`, `WorkbenchNode`, `WorkbenchTile`, and `TileKind` exist for V2
  - [x] V2 path can render empty or placeholder terminal/browser/document tiles
  - [x] V1 linked-session path remains isolated rather than interleaved with V2 semantics

### T-091 — Real-session terminal tile
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-090
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - V2 terminal tile path now builds direct tmux attach commands from exact `SessionRef`.
  - duplicate-session prevention is implemented app-wide in `WorkbenchStoreV2` with reveal/focus semantics.
  - sidebar V2 branch now calls the real terminal-open API instead of placeholder insertion.
  - Xcode verification exposed a stale generated project; `xcodegen generate` refreshed the Xcode target graph so the new V2 app sources and integration test are visible to `xcodebuild`.
  - a verification-only compile blocker in `WorkbenchV2DocumentLoader.swift` was fixed so the current worktree can reach the T-091 UI proof path again.
  - the V2 terminal tile now exposes a dedicated direct-attach status AX anchor, and the targeted single-open UI proof uses that explicit contract instead of the flaky tile `value`.
  - real Claude Code CLI review returned `GO_WITH_CONDITIONS`; the only blocking condition was explicit `missingRemoteHostKey` coverage in `WorkbenchV2DocumentLoaderTests`, and that condition is now cleared on the current worktree.
  - one Codex review returned `GO_WITH_CONDITIONS` and required `WorkbenchV2DocumentLoader` to disconnect child stdin; that condition is also cleared.
  - a later Codex review returned `NO_GO` on pipe-buffer deadlock risk in `WorkbenchV2DocumentLoader`, timing-based `Thread.sleep` in the duplicate-open UI proof, and stale reopen state in companion surfaces; all of those findings are fixed on the current worktree.
  - fresh focused verification is green for `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2DocumentLoaderTests`, and `WorkbenchStoreV2Tests`.
  - the March 6, 2026 09:28 PST rerun exposed an environment-only automation approval blocker, but that blocker was cleared by approving `Enable UI Automation` on-console.
  - final targeted rerun on March 6, 2026 executed both UI proofs on `platform=macOS,arch=arm64` and passed: single-open real-session attach and duplicate-open reveal/focus both produced executed PASS results.
  - T-091 closeout is now complete on code, verification, and review evidence.
- **Description**:
  - Replace linked-session placement with direct attach to real tmux sessions in the V2 path.
  - Add app-global duplicate-session prevention.
- **Acceptance Criteria**:
  - [x] sidebar selection places a `SessionRef` into a V2 terminal tile
  - [x] terminal tile attaches directly to the real tmux session
  - [x] duplicate open reveals/focuses the existing tile instead of creating a second visible terminal tile

### T-092 — CLI bridge plus browser/document companion surfaces
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-091
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - Implementation planning exposed two different boundaries: companion surface rendering is app-local, while `agt open` bridge transport depends on the Ghostty action/OSC boundary.
  - Execution is being split into `T-098` and `T-099` so the app-local surface work can proceed without guessing over the bridge carrier.
  - `T-098` is now closed on code, focused verification, and review for the companion-surface rendering half.
  - `T-099` is now closed through `T-102` + `T-103` on code, focused verification, and dual Codex `GO` verdicts for the bridge carrier plus app-side decode/dispatch half.
  - fresh umbrella verification is green for `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `GhosttyCLIOSCBridgeTests`, `WorkbenchV2BridgeDispatchTests`, and `GhosttyTerminalSurfaceRegistryTests`.
  - umbrella reconciliation also aligned the remaining bridge-routing wording from `active Workbench` to the implemented emitting-surface Workbench semantics in architecture/design/tracking docs.
  - umbrella closeout is now a tracking reconciliation only; no extra product diff was required beyond the already-reviewed split tasks.
- **Description**:
  - Deliver the full Phase D outcome: browser/document companion surfaces plus `agt open <url-or-file>` over the terminal-scoped bridge.
- **Acceptance Criteria**:
  - [x] `agt open` opens browser tiles for URLs
  - [x] `agt open` opens document tiles for files
  - [x] directory input fails explicitly in MVP
  - [x] bridge-unavailable failure is explicit

### T-098 — V2 browser/document companion surface rendering
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-091
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - placeholder-only `browser` / `document` tile rendering in `WorkbenchAreaV2` has been replaced with minimal real surfaces.
  - browser tiles now use `WKWebView` with a visible load-failure banner and external-open affordance.
  - document tiles now use `WorkbenchV2DocumentLoader` to fetch local/remote text content and surface explicit load/fetch failures in-tile.
  - browser navigation now ignores cancellation errors, clears stale failure state on fresh loads, and keys reload behavior by `tile.id` so reopening the same URL does not inherit stale state.
  - document load completion now routes through a `WorkbenchV2DocumentLoadCoordinator` that tracks the current token and ignores stale/cancelled completions, so an old fetch cannot repaint the replacement tile.
  - focused coverage in `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, and `WorkbenchV2DocumentLoaderTests` now directly holds late-completion overwrite, cancellation ignore, browser reload identity, and missing-host-key loud failure.
  - fresh `swift build`, `WorkbenchV2BrowserTileTests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2DocumentLoaderTests`, and `WorkbenchStoreV2Tests` are green for the final T-098 worktree.
  - short post-fix Codex re-review returned `GO`.
- **Description**:
  - Replace V2 browser/document placeholder tiles with actual companion surface views and explicit load/fetch failure states.
- **Acceptance Criteria**:
  - [x] browser tiles render the requested URL in the targeted Workbench
  - [x] document tiles render requested local or remote file content in the targeted Workbench
  - [x] load/fetch failures remain visible as explicit tile states
  - [x] focused coverage exists for the new browser/document tile behaviors

### T-099 — `agt open` terminal bridge transport
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - current codebase has no production agtmux custom-OSC parser or dispatcher yet.
  - the likely ingress is `GhosttyApp.handleAction(...)`, with per-surface routing registered from `GhosttySurfaceHostView`, `WorkbenchAreaV2`, and `main.swift`.
  - investigation confirmed the shipped `GhosttyKit.xcframework` still exposes only fixed runtime callbacks and typed `ghostty_action_s` payloads; it does not expose a raw/generic custom OSC callback.
  - the repo already contains vendored Ghostty source plus `scripts/build-ghosttykit.sh`, so the blocker is no longer external upstream access; it is a repo-local expansion to add one custom OSC host action through the existing `action_cb` seam.
  - execution is now split into `T-102` carrier exposure in vendored GhosttyKit and `T-103` app-side decode/dispatch wiring.
  - `T-102` is now closed on the current worktree: `OSC 9911` is exposed as a typed `custom_osc` action through the existing `action_cb`, parser/runtime coverage proves BEL and ST delivery into the host action seam with exact payload bytes, and GTK shared-source parity is explicit.
  - fresh verification is green for `zig build test -Dtest-filter='custom osc'`, `./scripts/build-ghosttykit.sh`, xcframework/header sync `cmp`, and `swift build`.
  - final re-review returned `GO` from two independent Codex reviewers.
  - investigation confirmed there is no `agt` CLI implementation in this repo; `agt open` remains a documented external emitter contract, not an in-tree binary target.
  - `T-103` is now closed on the current worktree: app-side decode/dispatch is landed, seam-level integration proof now exercises `GhosttyApp.handleAction(...)` itself, and dual Codex re-review returned `GO`.
  - the in-repo bridge path is now closed on code, focused verification, and review; the external `agt` emitter remains documented and out of tree.
- **Description**:
  - Implement the terminal-originated bridge request path for `agt open <url-or-file>` without silent fallback at the Ghostty/runtime boundary.
- **Acceptance Criteria**:
  - [x] terminal-originated open requests reach the emitting terminal's Workbench with source/cwd context
  - [x] directory input is rejected explicitly in MVP
  - [x] bridge-unavailable failure is explicit
  - [x] local and remote shells use the same explicit bridge path

### T-102 — GhosttyKit custom OSC host action exposure
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100, T-101
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `OSC 9911` carrier exposure is present in the embedded runtime, public header, and rebuilt `GhosttyKit.xcframework`.
  - automated coverage now proves BEL and ST terminated `OSC 9911` sequences preserve exact `osc` and payload bytes through parser, stream, surface, and embedded `action_cb` delivery.
  - GTK runtime parity is explicit via `.custom_osc` handling in `vendor/ghostty/src/apprt/gtk/class/application.zig`.
  - fresh verification is green for `zig build test -Dtest-filter='custom osc'`, `./scripts/build-ghosttykit.sh`, xcframework/header sync `cmp`, and `swift build`.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Description**:
  - Expand the vendored Ghostty embedded runtime so terminal-scoped custom OSC payloads become a typed host-visible `ghostty_action_s` case delivered through the existing `action_cb`.
- **Acceptance Criteria**:
  - [x] vendored Ghostty parses the chosen custom OSC bridge command and preserves its raw payload
  - [x] `ghostty_action_s` exposes a typed custom-OSC payload at the C boundary
  - [x] the rebuilt `GhosttyKit.xcframework` delivers that typed action through `GhosttyApp.handleAction(...)`
  - [x] GTK runtime handles `.custom_osc` consistently with the shared source contract
  - [x] automated proof shows BEL and ST terminated `OSC 9911` sequences reaching the runtime/host action seam with exact `osc` and payload bytes

### T-103 — App-side `agt open` bridge decode and dispatch
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-102
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - payload contract is now locked before code: `OSC 9911` carries strict UTF-8 JSON with `version`, `action`, `kind`, `target`, `cwd`, `argument`, `placement`, and `pin`.
  - host-side validation is fail-loud by design: malformed JSON, unsupported enum values, empty required fields, and relative file paths are not normalization paths.
  - app-side decode/dispatch is now landed on the current worktree in `GhosttyApp.handleAction(...)`, `GhosttyCLIOSCBridge`, `GhosttyTerminalSurfaceRegistry`, and `WorkbenchV2BridgeDispatch`.
  - focused `GhosttyCLIOSCBridgeTests` now cover malformed JSON, object-root enforcement, unsupported `version` / `action` / `kind` / `placement`, empty required fields, relative file path rejection, cross-workbench browser/document dispatch, explicit failures for unregistered or non-surface targets, and real `GhosttyApp.handleAction(...)` seam behavior from an off-main callback context.
  - fresh focused verification is green for `swift build`, `GhosttyCLIOSCBridgeTests`, `WorkbenchV2BridgeDispatchTests`, and `GhosttyTerminalSurfaceRegistryTests`.
  - initial re-review split on missing `GhosttyApp.handleAction(...)` proof, but the seam-level integration fix is now landed and final re-review returned `GO` from two independent Codex reviewers.
- **Description**:
  - Decode the custom OSC bridge payload, resolve source/cwd context, and dispatch browser/document opens into `WorkbenchStoreV2`.
- **Acceptance Criteria**:
  - [x] custom OSC payload decode/validation fails loudly for malformed or unsupported requests
  - [x] valid bridge requests resolve the emitting surface context and open the expected browser/document tile
  - [x] explicit failure remains visible when the payload cannot be resolved or dispatched
  - [x] in-repo tests prove the app-side decode/dispatch path even though the `agt` emitter itself is out of tree

### T-100 — Ghostty CLI-bridge carrier decision
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-098
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `docs/42_design-cli-bridge.md` now explicitly keeps terminal-scoped custom OSC as the carrier contract.
  - typed-action piggyback (`title`, `notification`, `open-url`, etc.) is explicitly rejected as a non-mainline fallback.
  - the required host capability is now documented: surface-scoped delivery, raw payload visibility, explicit consume/dispatch, and local/remote symmetry.
  - the verification strategy is now documented well enough for `T-099`: payload decode tests, dispatch tests, and product-level proof.
- **Description**:
  - Resolve the mismatch between the design-locked custom OSC bridge and the current GhosttyKit C API, which only exposes typed runtime actions.
- **Acceptance Criteria**:
  - [x] the bridge carrier is locked explicitly in `docs/42_design-cli-bridge.md`
  - [x] the chosen carrier preserves explicit failure semantics and local/remote symmetry
  - [x] the app-side ingress seam and verification strategy are documented well enough for `T-099` implementation

### T-101 — App-side CLI bridge dispatch scaffold
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-100
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - `WorkbenchV2BridgeRequest` now preserves the design-locked placement contract (`--left|--right|--up|--down|--replace`) end to end.
  - `GhosttyTerminalSurfaceRegistry` is now keyed by a canonical `GhosttySurfaceHandle` derived from the real `ghostty_surface_t`, with `context(forTarget:)` available for the `GhosttyApp.handleAction(...)` seam.
  - `GhosttySurfaceHostView` now unregisters stale handles on reattach/dismantle so registry state stays aligned with live Ghostty surfaces.
  - the unfocused-workbench crash is now fixed on the current worktree: non-empty layouts without a preset focus normalize to the first tile in traversal order before placement is applied, while actually invalid states still fail loudly.
  - fresh final verification is green for `swift build`, `WorkbenchV2BridgeDispatchTests`, `GhosttyTerminalSurfaceRegistryTests`, and `WorkbenchStoreV2Tests`.
  - final re-review returned `GO` from two independent Codex reviewers on the crash-fixed worktree.
  - real Claude Code CLI was installed and authenticated, but unusable in this environment (`Raw mode is not supported on the current process.stdin`; repeated `claude -p` attempts returned no usable output), so the blocked Claude leg was compensated with extra Codex review coverage per repo policy.
- **Description**:
  - Implement the app-side bridge request model, surface registration metadata, and Workbench dispatch path so `T-099` is blocked only on carrier ingress, not on downstream plumbing.
- **Acceptance Criteria**:
  - [x] a bridge request model exists for browser/document open with placement plus source/cwd context
  - [x] terminal surfaces register enough identity/metadata for future bridge dispatch from the real Ghostty surface callback boundary
  - [x] the dispatcher can open browser/document tiles in the resolved emitting Workbench from an injected request without dropping placement semantics or crashing on a valid unfocused non-empty workbench
  - [x] focused tests exist for dispatch and surface-resolution behavior without requiring the final carrier

### T-093 — Workbench persistence and restore placeholders
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-092
- **Owner**: Orchestrator (implementation delegated)
- **Progress**:
  - phase start review shows two separable implementation surfaces: autosave/load plumbing and restore-failure affordances.
  - execution is now split into `T-104` and `T-105` so storage can land without mixing it into restore-action UI work.
  - `T-104` is now closed on code, focused verification, and dual Codex `GO`.
  - `T-105` is now closed on code, focused verification, targeted UI proof, and dual Codex `GO`.
  - fresh umbrella verification is green for `swift build`, `WorkbenchStoreV2PersistenceTests`, `WorkbenchStoreV2Tests`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2TerminalRestoreTests`, `WorkbenchV2TerminalAttachTests`, and the targeted restore UI proof batch.
  - bounded Codex CLI closeout attempts on the umbrella pack did not return a usable final verdict in reasonable time; the final umbrella `GO` came from direct Codex fallback review over the already-reviewed split-task evidence.
  - umbrella closeout is now a tracking reconciliation only; no extra product diff was required beyond the already-reviewed split tasks.
- **Description**:
  - Persist Workbench layout and restore terminal plus pinned companion tiles.
  - Surface broken refs as explicit placeholder states.
- **Acceptance Criteria**:
  - [x] Workbenches autosave
  - [x] terminal tiles restore by `SessionRef`
  - [x] pinned browser/document tiles restore
  - [x] missing host/session/path surfaces remain visible with `Retry` / `Rebind` / `Remove Tile`

### T-104 — Workbench autosave/load snapshot plumbing
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-099
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Persist V2 Workbench state to app-owned storage, restore it on launch, and save only terminal tiles plus pinned companion tiles.
- **Progress**:
  - `WorkbenchStoreV2Persistence` now owns the fixed snapshot path, validated encode/decode, and atomic writes.
  - `WorkbenchStoreV2(env:)` restores persisted state when no fixture override is present; fixture JSON still wins for tests.
  - autosave now covers representative store mutations and the bridge-dispatch mutation path.
  - focused verification is green for `WorkbenchStoreV2PersistenceTests`, `WorkbenchStoreV2Tests`, and `WorkbenchV2BridgeDispatchTests`.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Acceptance Criteria**:
  - [x] app launch restores the last autosaved Workbench snapshot when no fixture override is active
  - [x] terminal tiles persist by exact `SessionRef`
  - [x] unpinned browser/document tiles are dropped from the persisted snapshot
  - [x] pinned browser/document tiles restore from the persisted snapshot

### T-105 — Restore failure placeholders and recovery actions
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-104
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Surface restore-time broken refs as explicit placeholder states with `Retry`, `Rebind`, and `Remove Tile`.
- **Notes**:
  - T-105 will not add a persisted `restoreStatus` field. Broken-state rendering is computed from the persisted tile ref plus live app state.
  - Initial scope is terminal `SessionRef` and document `DocumentRef` recovery. Browser navigation failures remain on their existing load-error path.
- **Progress**:
  - render-time restore resolution from persisted refs + live inventory/host-config truth is now design-locked in `docs/41_design-workbench.md`.
  - the active implementation surface is terminal/document placeholders plus exact-target `Rebind` and tree-safe `Remove Tile`.
  - store mutation support is landed: `WorkbenchStoreV2` now has tree-safe `Remove Tile` plus exact-target terminal/document `Rebind` APIs with autosave coverage.
  - execution fallback for the remaining UI slice is now locked: real agent CLI first, then Codex subagent, then orchestrator direct execution only if both delegated paths fail to return usable output.
  - document restore UI is landed with typed `Host missing` / `Host offline` / `Path missing` / `Access failed` states plus retry-token coverage.
  - terminal restore UI is landed via orchestrator direct execution after both delegated tiers failed to return usable edits; terminal tiles now resolve `Host missing` / `Host offline` / `tmux unavailable` / `Session missing` and local daemon issue placeholders from live inventory truth.
  - terminal/document startup races reopened the task in review; the final remediation added terminal `bootstrapping` state, deferred remote document load until reachability truth is ready, and removed document rebind's silent local fallback.
  - focused verification is green for `swift build`, `WorkbenchV2DocumentTileTests`, `WorkbenchV2TerminalRestoreTests`, `WorkbenchStoreV2Tests`, `WorkbenchStoreV2PersistenceTests`, and `WorkbenchV2TerminalAttachTests`.
  - targeted UI proofs are green for both a broken restored terminal tile and a healthy restored terminal tile.
  - final re-review returned `GO` from two independent Codex reviewers.
- **Acceptance Criteria**:
  - [x] broken terminal/document refs remain visible after restore instead of silently disappearing
  - [x] `Retry` re-attempts the failed attach/load path
  - [x] `Rebind` allows manual exact-target reassignment only
  - [x] `Remove Tile` removes the broken tile from the restored Workbench

### T-094 — Sidebar integration and linked-session normal-path removal
- **Status**: DONE
- **Priority**: P0
- **Depends**: T-093
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Reconnect sidebar workflows to V2 and remove linked-session assumptions from the normal product path.
- **Progress**:
  - execution started after T-105 closeout.
  - the first slice is to make the visible cockpit surfaces (`SidebarView`, `CockpitView`, `TitlebarChromeView`) use the V2 workbench path as the default mainline composition instead of branching on the temporary feature flag.
  - slice 1 is landed: the visible cockpit surfaces now route the normal path through `WorkbenchAreaV2`, `WorkbenchTabBarV2`, and `WorkbenchStoreV2.openTerminal(...)` without `WorkbenchStoreV2.isFeatureEnabled()` branching.
  - focused verification is green for `swift build`, `WorkbenchStoreV2Tests`, `WorkbenchV2TerminalAttachTests`, and the targeted UI proofs `testDefaultSidebarOpenUsesWorkbenchV2RealSessionTerminalTile` / `testDefaultDuplicateSessionOpenRevealsExistingWorkbenchV2Tile` / `testEmptyStateOnLaunch`.
  - the fallback ladder was exercised during slice 1: the real agent CLI did not return a usable report in reasonable time, and the delegated Codex tier did not return a usable in-band handoff, so the orchestrator completed the remaining owned-file cleanup and UI-proof stabilization directly.
  - slice 2 is landed: `AppViewModel` no longer filters `agtmux-linked-*` session names or canonicalizes sidebar identity through `session_group`; the normal sidebar path now preserves exact tmux session names and only dedupes exact duplicate rows.
  - conflicting tests were rewritten to the real-session sidebar contract:
    - `AppViewModelA0Tests` now covers exact visibility for linked-looking session names and session-group aliases
    - `AgtmuxTermUITests` now proves linked-looking sessions remain visible and session-group aliases remain distinct
    - obsolete `PaneFilterTests` were removed because they only asserted the old prefix-filter contract and no longer exercised product code
  - focused verification is green for `swift build`, `AppViewModelA0Tests`, `WorkbenchStoreV2Tests`, and targeted UI proofs for linked-looking sessions plus session-group alias visibility.
  - dual Codex review reopened T-094 on an exact-session selection regression: sidebar highlight and `retainSelection` were still collapsing sibling alias rows back to `source + window + pane`.
  - the regression fix is now landed: `AppViewModel.retainSelection(...)` and `SidebarView` selection matching both use exact pane identity including `sessionName`, and the UI test helper now keys selected markers by full `AccessibilityID.paneKey(...)`.
  - regression coverage is added in `AppViewModelA0Tests` for refresh-time retention of the exact selected alias session, and in `AgtmuxTermUITests` for exact selected-row marker behavior across sibling aliases.
  - fresh post-fix verification is green for `swift build`, `swift test -q --filter AppViewModelA0Tests`, `swift test -q --filter WorkbenchStoreV2Tests`, `swift test -q --filter WorkbenchV2TerminalAttachTests`, and `xcodegen generate`.
  - a later unlocked-session rerun now executes all 6 selected UI proofs and passes on the current worktree.
  - the duplicate-open proof helper now reuses the already-resolved sidebar row element instead of re-querying before click, which removed the transient AX flake seen in the first unlocked batch.
  - final scoped Codex re-review returned `GO` from two independent reviewers; both treated the locked-session UI skip as an environment evidence gap rather than a remaining code blocker.
- **Acceptance Criteria**:
  - [x] sidebar can jump to existing V2 terminal tiles
  - [x] normal path creates no linked sessions
  - [x] obsolete linked-session filtering/title-leak behavior is removed from the main path

### T-095 — local health-strip offline contract follow-up
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Decide and lock the intended health-strip behavior when local inventory goes offline or stale data remains.
  - Add regression coverage once the contract is explicit.
- **Progress**:
  - current code/test behavior is now identified: local inventory offline marks `offlineHosts` for `local`, but does not clear `localDaemonHealth`; the app keeps polling `ui.health.v1`, and the health strip stays absent only when no health snapshot exists.
  - architecture/spec docs now record that contract explicitly.
  - existing regression coverage already exercises the chosen behavior in `AppViewModelA0Tests`:
    - `testLocalDaemonHealthPublishesEvenWhenInventoryFetchFails`
    - `testLocalInventoryOfflineDoesNotClearExistingHealthAndStillAllowsRefresh`
  - existing UI coverage already fixes the visible strip contract for presence/absence:
    - `testSidebarHealthStripShowsMixedHealthStates`
    - `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot`
  - fresh verification reran `swift test -q --filter AppViewModelA0Tests` and passed (18 tests).
  - a later unlocked-session targeted UI rerun executed `testSidebarHealthStripShowsMixedHealthStates` and `testSidebarHealthStripStaysAbsentWithoutHealthSnapshot` with PASS.
  - final scoped Codex re-review returned `GO` from two independent reviewers after the docs were narrowed to the actually covered contract.
- **Acceptance Criteria**:
  - [x] intended health-strip behavior on local inventory/offline failure is documented
  - [x] regression coverage exists for the chosen behavior

### T-096 — V2 remote `TargetRef` regression coverage
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Add focused regression coverage for `pane.source` hostname -> configured `RemoteHost.id` -> V2 `SessionRef.target`.
- **Implemented**:
  - added focused `WorkbenchStoreV2Tests` coverage for configured and unconfigured remote hostname mapping
- **Acceptance Criteria**:
  - [x] configured remote hostname maps to `TargetRef.remote(hostKey: <RemoteHost.id>)`
  - [x] unconfigured remote hostname remains explicit rather than silently remapped

### T-097 — V2 feature-flag sidebar-open live UI proof
- **Status**: DONE
- **Priority**: P1
- **Owner**: Orchestrator (implementation delegated)
- **Description**:
  - Rerun `AgtmuxTermUITests.testV2FeatureFlagOpensPlaceholderTerminalTileFromSidebar` from an unlocked interactive macOS session and record executed proof in docs.
- **Implemented**:
  - reran the targeted UI test from an unlocked interactive macOS session and captured an executed PASS result
- **Acceptance Criteria**:
  - [x] targeted UI test executes rather than skipping
  - [x] executed PASS/FAIL result is recorded in `docs/70_progress.md`
  - [x] review evidence reflects the executed result

## Recently Done

### T-089 — sync-v2 XPC/service-boundary coverage gap closeout (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Closed the packaged-app sync-v2 XPC coverage gap found during commit review.
  - Added dedicated client/service-boundary tests for `fetchUIBootstrapV2` and `fetchUIChangesV2`.
  - Removed stale bundled-runtime README guidance about PATH/common install-location fallback.
- **Implemented**:
  - added injected-proxy decode/limit coverage in `AgtmuxDaemonXPCClientTests`
  - added anonymous service-boundary and actual service-endpoint coverage for sync-v2 bootstrap/changes
  - refreshed `Sources/AgtmuxTerm/Resources/Tools/README.md`
  - reran focused post-fix verification and cleared the prior `NO_GO` on re-review
- **Acceptance Criteria**:
  - [x] `AgtmuxDaemonXPCClientTests` has dedicated sync-v2 client coverage for bootstrap/changes
  - [x] `AgtmuxDaemonXPCServiceBoundaryTests` has service-boundary coverage for bootstrap/changes
  - [x] bundled runtime README matches the current resolver contract
  - [x] `NO_GO` review blocker is cleared and the worktree is ready for commit/push

### T-088 — Fresh verification rerun and review-pack prep (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Rerun the required final verification against the final worktree before commit and prepare a review pack using the fresh evidence.
- **Implemented**:
  - reran `swift build`
  - reran focused SPM tests for runtime hardening, sync-v2 decoding/session, AppViewModel, and XPC coverage
  - reran `AgtmuxDaemonServiceEndpointTests` via `xcrun xctest`
  - reran targeted sidebar health UI tests via `xcodebuild`
  - prepared a review pack under `docs/85_reviews/`
- **Acceptance Criteria**:
  - [x] fresh build verification recorded
  - [x] fresh focused tests recorded
  - [x] review pack created after build pass

### T-087 — Docs compaction for active-context efficiency (2026-03-06)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - Reduce everyday context load by introducing a current summary, compacting active tracking docs, and moving history into archive files.
- **Implemented**:
  - added `docs/65_current.md`
  - compacted `docs/60_tasks.md` to active/next tasks plus recent completions
  - compacted `docs/70_progress.md` to recent entries plus summary
  - split `docs/40_design.md` into summary plus detailed design files
  - updated `docs/00_router.md` and `docs/90_index.md` to the new read path
- **Acceptance Criteria**:
  - [x] active reading path starts with `docs/65_current.md`
  - [x] history is preserved under `docs/archive/`
  - [x] design detail is available without forcing every reader through one long file

### T-086 — V2 docs consistency pass: design-lock integration (2026-03-06)
- **Status**: DONE
- **Priority**: P1
- **Description**:
  - Integrated design-lock details into mainline docs.
- **Result**:
  - `TargetRef`, OSC bridge, autosave/pinning, duplicate open, manual `Rebind`, and directory-tile future scope are fixed in main docs.

### T-085 — V2 docs realignment: tmux-first cockpit baseline (2026-03-06)
- **Status**: DONE
- **Priority**: P0
- **Description**:
  - Rewrote foundation/spec/architecture/design/plan around the V2 tmux-first cockpit model.

### T-076 through T-084 — Local daemon runtime hardening and health observability
- **Status**: DONE
- **Priority**: P0/P1
- **Description**:
  - A1 and A2 local daemon/runtime/health work is complete.
  - See archive task board and progress ledger for full detail.

## Archive

- Full historical task board:
  `docs/archive/tasks/2026-02-28_to_2026-03-06.md`
