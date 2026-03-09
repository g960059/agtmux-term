# Current State

## Snapshot

- Product mode: V2 tmux-first cockpit
- Mainline docs are aligned to V2 and design-locked for MVP
- The older linked-session workspace path has been physically removed from the shipped target and stale linked-session-positive tests/docs are retired
- T-090 Workbench V2 foundation landed behind an isolated feature-flagged path
- T-090 review closeout is `GO`; T-091 code is landed, Claude review has returned a usable verdict, and all code-level review conditions are cleared
- T-091 is now closed on code, focused verification, and fresh executed UI proof
- T-092 umbrella reconciliation is now closed through `T-098` companion surface rendering plus `T-099` / `T-102` / `T-103` bridge transport closeout evidence
- T-093 umbrella reconciliation is now closed through `T-104` autosave/load plus `T-105` restore placeholder closeout evidence
- T-098 companion surfaces are now closed on code, focused verification, and post-fix review
- T-099 terminal bridge transport is now closed on code, focused verification, and dual Codex `GO`
- T-103 payload contract is locked: `OSC 9911` carries strict UTF-8 JSON with required `target`, `cwd`, `argument`, `placement`, and `pin`
- `agt` itself is not implemented in this repo; the in-repo seam is now the app-side `custom_osc` decode path
- T-101 app-side bridge scaffold is now closed on code, focused verification, and review
- T-094 and T-095 review evidence now includes fresh executed UI proof from an unlocked desktop session
- T-107 closeout is no longer trusted as product truth; live March 7, 2026 evidence reopened the area as `T-108`
- T-108 is now closed on app-side code and focused verification; execution stayed in direct orchestrator mode for this slice
- T-109 is now closed on code and fresh executed UI proof; terminal-originated tmux session switch rebases the visible tile/session selection from rendered-client truth
- T-110 is now closed on code and focused verification:
  - `GhosttyTerminalView` now lets AppKit IME processing run before raw terminal key encoding
  - marked-text commit and preedit clear behavior are locked by focused AppKit-hosted regression tests
- T-111 is now closed on thin boundary coverage:
  - daemon-vs-term ownership split is locked
  - the terminal repo now carries daemon-truth-first live canaries for Codex running/completion and Claude running/completion
  - deterministic `waiting_input` attention/filter truth remains anchored in `AppViewModelA0Tests`; live product Codex completion now expects `completed_idle` without attention unless pending requests explicitly exist
  - if the original user-visible mismatch persists while these canaries stay green, validate daemon payload truth first before reopening the terminal consumer
- `T-112` is now closed:
  - daemon-reported `waiting_approval` reaches exact visible row attention/badge/filter surfacing without bleed
  - the terminal repo used a synthetic producer fixture for this consumer-side slice; no new daemon handover was needed
- T-113 is closed:
  - the app-managed daemon socket no longer emits null exact-location rows after the upstream daemon fix and restart
  - current managed-pane surfacing regressions are no longer attributed to daemon detection
- `T-114` is now closed:
  - local inventory and local metadata publication are split into one derived visible-row path
  - a live plain-zsh managed-filter canary proves real Claude/Codex launches surface with provider/activity truth in the app consumer
- `T-115` is now closed:
  - upstream `agtmux:T-XTERM-A5` landed and the managed-exit semantic bug is no longer open on producer truth
  - term-side exact-row managed -> unmanaged clearing is regression-covered and green
  - term-side live AppViewModel canaries are green against the updated daemon binary
- `T-117` is now closed:
  - the app-managed daemon supervisor now enforces process-aware freshness on the default app-owned socket
  - fresh live inspection shows the current daemon process started after the rebuilt local `AGTMUX_BIN`
  - direct `ui.bootstrap.v2` probe on the normal app-owned socket now returns strict-compatible rows again
- `T-120` is now closed:
  - term-side `sync-v3` consumer foundation is landed and ready for additive live wiring
  - strict `AgtmuxSyncV3Models` now preserve exact-row identity assumptions on the consumer side
  - a local `PanePresentationState` derivation layer now exists so future v3 UI cutover does not bind views directly to raw daemon structs
  - temporary local decode fixtures were only a bridge until daemon-owned canonical fixtures arrived
- `T-121` is now closed:
  - term-side v3 consumer tests now ingest daemon-owned canonical fixtures directly from sibling repo truth
  - current fixture truth source is `agtmux` commit `cb198cca7226666fbb26df34d4e17582a208c3e6`
  - the term repo also has an additive `fetchUIBootstrapV3()` decode surface, but no live app wiring yet
- `T-122` is now closed:
  - AppViewModel bootstrap/resync now prefers daemon `ui.bootstrap.v3` truth and adapts it into the existing local overlay cache without weakening exact-row identity
  - bundled XPC service/client expose the same additive bootstrap-v3 surface, so packaged app and direct daemon paths stay aligned
  - intentional deferral remains:
    - current sidebar/titlebar/filter/count rendering still flows through legacy `AgtmuxPane` / `ActivityState`
- `T-123` is now closed:
  - AppViewModel live replay can now consume daemon `ui.changes.v3` additively after a bootstrap-v3 epoch is established
  - bundled XPC service/client expose matching `fetchUIChangesV3()` / `resetUIChangesV3()` transport so packaged app and direct daemon paths stay aligned
  - exact-row update/remove remains strict on `session_name` / `window_id` / `session_key` / `pane_id` / `pane_instance_id`
  - this historical additive bridge slice originally preserved sync-v2 fallback, but the current product path no longer uses it
  - intentional deferral remains:
    - current sidebar/titlebar/filter/count rendering still flows through legacy `AgtmuxPane` / `ActivityState`
- `T-124` is now closed:
  - the first sync-v3 UI cutover slice landed on top of the additive v3 bridge
  - sidebar row presentation now prefers local `PanePresentationState` for provider/activity/freshness/AX surfacing when a v3-backed local overlay exists
  - sidebar `managed` / `attention` filter and count derivation now use the same local presentation layer instead of only legacy `ActivityState`
  - intentional deferral remains:
    - full titlebar and broader sidebar cutover are still deferred
    - the targeted waiting-approval XCUITest is still blocked by `Failed to activate application ... (current state: Running Background)`
- `T-125` is now closed:
  - titlebar remains on the shared presentation-derived `attentionCount` / filter path introduced by the sidebar-first cutover
  - the remaining low-risk UI-adjacent consumer path is now presentation-aware too:
    - UI-harness sidebar state dumps prefer local presentation-derived summaries over raw legacy row fields
  - additional helper coverage now locks degraded freshness and error surfacing for downstream UI consumers
  - intentional deferral remains:
    - targeted waiting-approval XCUITest still fails at foreground activation before the product assertion body
- `T-129` is now closed:
  - exact-row local metadata bootstrap-cache construction and v2/v3 replay application now live in `LocalMetadataOverlayStore`
  - `AppViewModel` keeps publish/clear timing and task orchestration, but no longer open-codes the overlay/replay seam itself
  - exact-row v3 live lane stays on the same helper-backed cache/update path
- `T-130` is now closed:
  - bootstrap-not-ready defer handling and publish/clear cache state transitions now live in `LocalMetadataRefreshBoundary`
  - `AppViewModel` keeps the async refresh loop, replay resets, and snapshot publication orchestration, but no longer open-codes that refresh-state seam
  - the proven v3 bootstrap/changes live lane still flows through the same bridge + overlay store + refresh boundary stack
- `T-131` is now closed:
  - the remaining local metadata async refresh decision body now lives in `LocalMetadataRefreshCoordinator`
  - bootstrap fetch/result resolution, replay reset selection, and one-step v2/v3 refresh decisions no longer live directly in `AppViewModel`
  - `AppViewModel` still owns the `Task` lifecycle, scheduling guards, and top-level fetch/publish orchestration
- `T-132` is now closed:
  - the product `AppViewModel` local metadata path now requires sync-v3 for both bootstrap and changes
  - unsupported `ui.bootstrap.v3` / `ui.changes.v3` now clears local overlay state and surfaces daemon incompatibility instead of silently downgrading to sync-v2
  - remaining sync-v2 transport/service-boundary/workbench code is compatibility-only
- `T-133` is now closed:
  - the broad `AppViewModelA0Tests` suite now matches current product behavior:
    - product metadata requires sync-v3
    - unsupported `ui.bootstrap.v3` / `ui.changes.v3` surfaces daemon incompatibility plus inventory-only rows instead of sync-v2 fallback
    - exact-row v3 updates are the product truth in the broad suite
  - stale product assertions that depended on legacy sync-v2 replay or legacy `conversationTitle` carry-over were removed from the broad suite; remaining sync-v2 assumptions are compat-only
- `T-134` is now closed:
  - `LocalMetadataTransportBridge` no longer carries the dead sync-v3->v2 fallback selector surface
  - the bridge now only exposes the required-v3 bootstrap passthrough used by product refresh code
  - remaining sync-v2 transport compatibility lives outside that bridge cleanup slice
- `T-135` is now closed:
  - the product-facing daemon incompatibility issue is now named `incompatibleMetadataProtocol`
  - current banners / empty states no longer imply that the product issue is specifically a sync-v2 incompatibility
- `T-136` is now closed:
  - `AppViewModelLiveManagedAgentTests` now matches current product truth:
    - live product metadata bootstraps and replays only through sync-v3
    - exact-row assertions are anchored in sync-v3 identity rather than raw sync-v2 `ActivityState`
    - managed-exit and same-session no-bleed live canaries are green after shell demotion replacement at the same visible row
- `T-137` is now closed:
  - `UITestTmuxBridge` sidebar diagnostics now probe `ui.bootstrap.v3`
  - metadata-enabled UI diagnostics prefer sync-v3 presentation/identity summaries over raw sync-v2 activity collapse
  - deterministic integration coverage now locks the migrated diagnostic shape in `UITestSidebarDiagnosticsTests`
  - the targeted metadata-enabled plain-zsh Codex UI execution no longer fails before the body on automation mode
  - the current remaining UI blocker has moved to post-launch activation later in the proof
- `T-138` is now closed:
  - the metadata-enabled plain-zsh Codex UI proof no longer relies on raw `activity=...` labels
  - live Codex row assertions now use `primary=...` semantics and accept `completed_idle` as a canonical completion state
- `T-139` is now closed:
  - UI test sidebar dump payloads are presentation-first and no longer depend on raw `AgtmuxPane` arrays for summary output
  - bootstrap-ready polling now uses presentation snapshots plus `current_cmd` only where it still proves exact-row shell targeting
- `T-140` is now closed:
  - pane row accessibility summaries now emit `primary=...` terminology instead of raw `activity=...`
  - `PaneRowAccessibility` no longer carries the stale pane-only overload that product code stopped using
- `T-141` is now closed:
  - the unused `FreshnessLabel(ageSecs:)` helper is gone
  - docs/comments now make it explicit that `sidebar.pane.activity.*` remains a stable AX identifier name while its label/value carries primary-state semantics
- `T-142` is now closed:
  - product-facing incompatible metadata detail now speaks in terms of metadata protocol / exact-identity failures rather than treating raw `sync-v2 bootstrap` wording as product truth
  - factual failing RPC names like `ui.bootstrap.v2` can still appear in detail when they are the actual failing method or payload source
- `T-143` is now closed:
  - product `AppViewModel` now resets only sync-v3 replay state
  - sync-v2 reset remains compatibility-only on lower transport/service-boundary surfaces and is no longer part of the product metadata abstraction
- `T-144` is now closed:
  - product-facing tests and injected metadata stubs now type against `ProductLocalMetadataClient`
  - `LocalMetadataClient` is now an explicit compat-only surface for low-level sync-v2 coverage
- `T-145` is now closed:
  - `PaneDisplayState` is still presentation-first, but its legacy `ActivityState` collapse now lives in explicit compat-only helper `PaneDisplayCompatFallback`
  - visible sidebar/accessibility behavior is unchanged; the cleanup only narrows the fallback seam
- `T-146` is now closed:
  - `LocalMetadataOverlayStore` still materializes compat `AgtmuxPane` rows, but the `PanePresentationState` → `ActivityState` collapse now lives in explicit helper `PaneMetadataCompatFallback`
  - visible/product behavior is unchanged; the cleanup only narrows the metadata compat seam
- `T-147` is now closed:
  - `PaneDisplayState` fallback no longer depends on `AgtmuxPane.needsAttention`
  - legacy `ActivityState` → `needsAttention` collapse now lives in explicit helper `PaneDisplayCompatFallback`
- `T-148` is now closed:
  - `AgtmuxPane.needsAttention` still exists for compat callers, but it now delegates to `PaneDisplayCompatFallback`
  - visible/product behavior is unchanged; the cleanup only removes duplicated legacy collapse logic
- `T-116` is now open:
  - metadata-enabled plain-zsh Codex UI reruns now pass the pre-launch bootstrap gate with the correct sync-v3 truth:
    - before provider launch, the app-driven pane is expected to remain `presence=unmanaged, provider=nil, primary=idle`
    - the targeted helper now asserts that pre-provider state instead of requiring managed truth too early
  - the `Running Background` activation blocker is now cleared in the primary targeted lane:
    - the same executed XCUITest reaches the managed-provider assertion body after Codex launch
  - the remaining red is now substantive managed surfacing:
    - after Codex launch completes, the targeted XCUITest still reports `probe=ok transport=sync-v3 total=1 managed=0`
    - the exact row remains `presence=unmanaged, provider=nil, primary=idle`, so the held attention-filter lane is still deferred behind this primary failure
  - March 9, 2026 term-side readiness hardening remains valid:
    - `inventory present + bootstrap panes=[]` no longer primes sync-v2 ownership
    - live AppViewModel managed entry/exit canaries stay green against the updated daemon binary
  - term-side readiness hardening is now in:
    - `AppViewModel` keeps retrying instead of priming on `inventory present + bootstrap panes=[]`
    - focused integration regression is green
    - focused metadata-enabled UI proof now fails earlier and more precisely: the isolated app-child daemon still never reaches a non-empty bootstrap before any live Codex assertion runs
    - same app process can directly run `tmux -S <bootstrapResolvedTmuxSocketPath> list-panes` and sees the target row, so the remaining mismatch is not `-L` vs `-S` resolution inside the app process
  - current remediation direction:
    - keep `UITestTmuxBridge` exact-socket/runtime/launch-env diagnostics
    - harden term so `inventory present + bootstrap panes=[]` is treated as startup-not-ready instead of a primed sync-v2 epoch
    - keep the focused UI lane gated on non-empty isolated bootstrap before launching the live Codex proof
    - hand the remaining `starts-and-listens-but-bootstrap-stays-empty` app-child repro back to `agtmux`
- fresh live tmux inspection proved the durable product oracle is exact rendered-client truth, not attach-command intent alone
- vendor Ghostty forwards only `OSC 9911` into the embedded host action seam, and the app's rendered-client binding now uses that supported path
- fresh current-code rerun closed the last metadata-enabled pane-sync red:
  - rendered-client tty binding works
  - inventory-only same-session retarget and reverse-sync proofs are green
  - metadata-enabled normal app path is also green after splitting confirmation policy between initial attach and same-session retarget
- fresh live socket inspection also gives a concrete local regression sample:
  - local tmux inventory currently contains unmanaged `utm-main` plus mixed managed/unmanaged panes in `vm agtmux-term`
  - `ui.bootstrap.v2` currently emits opaque `session_key` values for managed `vm agtmux` / `vm agtmux-term` rows
  - this is the right fixture shape for proving no provider/activity/title bleed across exact local rows

## Current Product Truth

- `tmux first`
- `terminal stays terminal`
- `1 terminal tile = 1 real tmux session`
- `Workbench = app-owned saved layout`
- browser/document companion surfaces are explicit
- shipped product path must not create or depend on hidden linked sessions
- local managed/provider/activity overlay target contract remains exact sync-v3 identity (`session_key` + `pane_instance_id`) with whole-epoch fail-closed behavior on invalid rows
- `session_key` is now treated as opaque overlay identity, not as a visible tmux session alias
- same-session pane selection must reuse the existing session tile and navigate it to the requested pane/window without reviving linked-session behavior
- same-session pane selection and terminal-originated pane changes must converge through one reducer-owned runtime pane state with desired/observed separation
- terminal-originated cross-session switch on the rendered tmux client is also observation-authoritative and must rebase the visible tile's `SessionRef` plus sidebar selection to the observed session
- pane-selection proof is not trusted unless it exercises a real Ghostty surface and checks rendered attach state, not just store/sidebar/tmux intent
- pane-selection truth must now be exact-client scoped: the visible terminal tile is bound to one rendered tmux client tty, and reverse sync / E2E proof must use that client's pane/window rather than session-wide active flags
- rendered-client binding now rides the structured `OSC 9911` host bridge rather than a private `OSC 9912` path
- initial attach and same-session retarget use different desired-pane confirmation policies; same-session retarget from an already observed rendered client releases desired state after the first matching observation
- same-session pane/window retarget must preserve the existing Ghostty surface and navigate the already bound tmux client with `switch-client -c <tty> -t <pane>`
- terminal-originated session-switch collision with another visible tile is an explicit error path; stale sidebar state is not an acceptable fallback
- terminal IME input must follow AppKit `interpretKeyEvents` / `NSTextInputClient` ordering before raw terminal key encoding; marked-text confirmation must not be pre-consumed as a terminal Return
- live sidebar activity state must continue to be exact-row truth for the active managed pane; an actively running Codex pane surfacing as non-running is a product bug, not an acceptable stale-overlay state
- cross-repo live testing is split by responsibility:
  - `agtmux` owns provider/activity/title semantic truth with real CLI online scenarios
  - `agtmux-term` owns thin daemon-to-sidebar canaries that prove strict consumer decode, exact-row overlay, and visible rendering
- dirty persistent daemon state is now part of the producer contract:
  - sync-v2 bootstrap must never emit managed panes with null exact-location fields
  - if it does, the terminal consumer rejects the whole local metadata epoch and falls back to inventory-only truth
- the next status-model migration keeps the same consumer boundary split:
  - daemon will own structured multi-axis truth (`agent/thread/blocking/execution/turn/pending_requests/attention/freshness/provider_raw`)
  - term will own local presentation derivation from that structured truth
  - `attention` remains summary-only in the consumer; request identity truth stays in `pending_requests[].request_id`
  - canonical positive consumer scenarios now come from daemon-owned fixtures, not local mirrored JSON
- the current persistent app-managed socket has been revalidated after the upstream daemon fix and daemon restart:
  - `/Users/virtualmachine/Library/Application Support/AGTMUXDesktop/agtmuxd.sock` now returns only rows with complete exact-location fields
  - managed provider/activity/title overlay is expected to recover on the normal app path without further terminal-side protocol changes
- plain zsh panes that launch Claude/Codex now have an explicit term-side recurrence guard:
  - local inventory cache and local metadata cache are separate state
  - visible local rows are derived at publish time
  - a live AppViewModel canary exercises plain `zsh -l` panes, launches real Claude/Codex, applies the `managed` filter, and requires provider/activity truth on the surfaced rows
- managed-exit truth is now closed at the term boundary:
  - when daemon truth returns the exact row to unmanaged shell state, the app clears provider/activity/title marks on the next publish
  - exact-row clear regression plus live AppViewModel canaries are both green against the updated daemon
- app-managed daemon freshness is now enforced on the default socket:
  - if `AGTMUX_BIN` is rebuilt while an older app-managed daemon still owns `~/Library/Application Support/AGTMUXDesktop/agtmuxd.sock`, the supervisor restarts it instead of silently reusing stale truth
  - the freshness invariant now uses daemon process start time vs candidate binary mtime and falls back to socket mtime only when process inspection is unavailable
- a metadata-enabled XCUITest exists for the same scenario; automation mode is granted and the auth-only skip was removed
- that focused lane now launches cleanly and reaches the real plain-zsh Codex assertion, but still fails on producer truth:
  - isolated custom daemon socket is spawned successfully
  - the same daemon still reports `ui.bootstrap.v2 total=0 managed=0`
- the newer focused red is now split in two:
  - metadata-enabled pane-sync is green on a fresh daemon runtime
  - plain-zsh Codex managed-row surfacing remains the target product proof
  - but the metadata-enabled launch path can still regress to `Running Background` before the proof body when managed-daemon startup stays synchronous on launch
- first sync-v3 UI cutover is now sidebar-first:
  - local v3-backed rows keep a parallel `PanePresentationState` cache
  - sidebar row provider/activity/freshness surfacing plus `managed` / `attention` filter-count derivation prefer that cache
  - broader render surfaces still intentionally defer to legacy row state
- titlebar continues to inherit the same presentation-derived attention/filter state through shared `AppViewModel` helpers; this slice did not introduce a separate titlebar-only state path
- a thin live sync-v3 gate canary now exists below XCUITest:
  - it uses a real daemon/runtime lane
  - it proves `AppViewModel` bootstraps on `ui.bootstrap.v3`, polls `ui.changes.v3`, and updates the same exact local row through `PanePresentationState`
  - if daemon support disappears, the product path now degrades to inventory-only plus explicit daemon incompatibility instead of falling back to sync-v2
- the product-facing legacy boundary is narrower:
  - sidebar rows, sidebar badges/counts, row accessibility summaries, and UI-test sidebar snapshots now consume one shared `PaneDisplayState` adapter
  - legacy `ActivityState` collapse is still present, but it is no longer reimplemented independently across those UI consumers
  - explicit remaining holdouts are:
    - `AgtmuxPane.activityState` as the compatibility field carried through the merged row model
    - sync-v2 transport/session types and exact-row replay path
    - workbench/runtime structs that still store `AgtmuxSyncV2PaneInstanceID`
- AppViewModel's local metadata bootstrap fallback is also narrower:
  - sync-v3/v2 bootstrap selection and `method not found` downgrade classification now live in `LocalMetadataTransportBridge`
  - the product refresh loop now consumes only sync-v3 and treats sync-v2 helpers as compat-only
  - AppViewModel still owns:
    - top-level fetch/publish orchestration
    - publish / clear / not-ready handling
- same-session multi-view is out of MVP

## Locked MVP Decisions

- `SessionRef = target + exact session name`
- `TargetRef = local or configured remote-host key`
- `lastSeenSessionID` is hint-only
- one real tmux session may appear in only one visible terminal tile across the app
- duplicate open reveals/focuses existing tile by default
- active pane selection is canonical, runtime-only, separate from terminal tile identity, and implemented as reducer-owned desired/observed pane state plus rendered-client binding
- `Rebind` is manual exact-target reassignment only
- Workbenches autosave
- terminal tiles are always part of saved Workbench state
- autosave persists terminal session identity, not live pane focus
- browser/document tiles restore only when pinned
- CLI bridge is terminal-scoped custom OSC
- `agt open <url-or-file>` is MVP
- directory input to `agt open` fails explicitly in MVP
- reserved future command: `agt reveal <dir>`
- no implicit localhost rewrite
- no implicit SSH tunnel
- no right-click override
- no shortcut interception layer

## Current Tracking Focus

### Active

- `T-118`
  producer-side shell demotion with a non-agent child process still leaves a stale managed Codex row on the fresh desktop daemon
- `T-119`
  stale live Codex `waiting_input` expectation is retired:
  - sync-v3 product truth emits `completed_idle` without attention for plain live Codex completion unless a pending user-input request exists
  - deterministic `waiting_input` attention/filter coverage remains canonical in `AppViewModelA0Tests`

### Done

- `T-120`
  sync-v3 term consumer foundation and presentation scaffolding (`DONE`)
- `T-121`
  daemon-owned sync-v3 fixture ingestion and additive bootstrap decode surface (`DONE`)
- `T-122`
  additive bootstrap-v3 consumer bridge in AppViewModel/XPC path (`DONE`)
- `T-123`
  additive changes-v3 consumer bridge in AppViewModel/XPC path (`DONE`)
- `T-126`
  thin live sync-v3 bootstrap/changes exact-row canary (`DONE`)
- `T-127`
  shared `PaneDisplayState` adapter isolates product-facing legacy pane collapse (`DONE`)
- `T-128`
  `LocalMetadataTransportBridge` isolates bootstrap transport/fallback selection (`DONE`)
- `T-129`
  `LocalMetadataOverlayStore` isolates bootstrap-cache construction and v2/v3 replay application (`DONE`)
- `T-130`
  `LocalMetadataRefreshBoundary` isolates bootstrap-not-ready and publish/clear state transitions (`DONE`)
- `T-131`
  `LocalMetadataRefreshCoordinator` isolates bootstrap fetch/result resolution and one-step refresh orchestration (`DONE`)
- `T-114`
  single-writer local overlay recovery and live managed-pane surfacing (`DONE`)
- `T-115`
  live agent entry/exit truth and UITest runner auth visibility (`DONE`)
- `T-113`
  dirty bootstrap contract drift handback for null exact-location fields (`DONE`)
- `T-112`
  waiting-approval consumer canary and visible attention surfacing (`DONE`)
- `T-111`
  live daemon-to-sidebar activity-state canaries for Codex/Claude running-completion plus Codex waiting-input attention (`DONE`)
- `T-108`
  epoch-gated exact-identity overlay + reducer-owned desired/observed active-pane state + exact-client pane-sync E2E correction (`DONE`)
- `T-109`
  rendered-client tmux session-switch reverse sync and in-place `SessionRef` rebasing (`DONE`)
- `T-110`
  Ghostty terminal IME commit and preedit correctness (`DONE`)
- `T-091`
  real-session terminal tile (`GO`)
- `T-090`
  Workbench V2 foundation path (`GO`)
- `T-092`
  CLI bridge plus browser/document companion surfaces umbrella (`GO`)
- `T-093`
  Workbench persistence and restore placeholders umbrella (`GO`)
- `T-094`
  sidebar integration and linked-session normal-path removal (`GO`)
- `T-095`
  local health-strip offline contract follow-up (`GO`)
- `T-098`
  V2 browser/document companion surface rendering (`GO`)
- `T-099`
  `agt open` terminal bridge transport (`GO`)
- `T-102`
  GhosttyKit custom OSC host action exposure (`GO`)
- `T-103`
  app-side `agt open` bridge decode and dispatch (`GO`)
- `T-100`
  Ghostty CLI-bridge carrier decision
- `T-089`
  sync-v2 XPC/service-boundary coverage gap closeout and re-review
- `T-085`
  V2 docs realignment to tmux-first cockpit baseline
- `T-086`
  design-lock integration into mainline docs
- `T-087`
  docs compaction for active-context efficiency
- `T-088`
  fresh verification rerun and review-pack preparation for commit
- `T-076` through `T-084`
  local daemon runtime hardening and A2 health observability closeout

### Next

- keep the focused metadata-enabled plain-zsh Codex UI lane on hold until the post-launch `Running Background` activation blocker is resolved
- rerun the held attention-filter lane only after the primary metadata-enabled lane is green again
- keep lower-layer live managed entry/exit canaries green while the UI harness is being debugged

## Open Blockers

- current non-product blocker:
  - the current app-managed socket can still be served by an older reachable daemon process after local `AGTMUX_BIN` rebuilds, so metadata-enabled UI lanes are not yet running on trustworthy producer truth

## Read Next

For implementation:

1. `docs/60_tasks.md`
2. `docs/10_foundation.md`
3. `docs/20_spec.md`
4. `docs/40_design.md`
5. `docs/41_design-workbench.md`
6. `docs/42_design-cli-bridge.md`
7. `docs/43_design-companion-surfaces.md`
8. `docs/30_architecture.md`
9. `docs/50_plan.md`

For history:

- `docs/70_progress.md`
- `docs/archive/README.md`
