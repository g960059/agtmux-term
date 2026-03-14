# Project Index

## Repository: agtmux-term

tmux-first macOS cockpit for AI-agent-driven development.
The product centers on real tmux sessions, strong sidebar observability, and lightweight companion surfaces.

## Read Order

When rebuilding context, read in this order:

1. `docs/00_router.md`
2. `docs/65_current.md`
3. `docs/60_tasks.md`
4. `docs/10_foundation.md`
5. `docs/20_spec.md`
6. `docs/40_design.md`
7. `docs/41_design-workbench.md`
8. `docs/42_design-cli-bridge.md`
9. `docs/43_design-companion-surfaces.md`
10. `docs/44_design-sync-v3-consumer.md`
11. `docs/47_design-local-first-fast-path.md`
12. `docs/45_design-terminal-performance.md`
13. `docs/46_design-remote-navigation.md`
14. `docs/30_architecture.md`
15. `docs/50_plan.md`
16. `docs/70_progress.md`
17. `docs/archive/README.md`

## Documents

| File | Tier | Content |
|------|------|---------|
| `AGENTS.md` | Stable | repository-specific execution rules |
| `CLAUDE.md` | Stable | project process and quality policy |
| `docs/00_router.md` | Stable | hard gates, review protocol, docs-first contract |
| `docs/65_current.md` | Tracking | active summary, locked decisions, next read path |
| `docs/10_foundation.md` | Stable | product intent, audience, goals, non-goals |
| `docs/20_spec.md` | Design | V2 MVP functional/non-functional spec |
| `docs/30_architecture.md` | Design | V2 system context, components, data flows, boundaries |
| `docs/40_design.md` | Design | compact V2 MVP design summary |
| `docs/41_design-workbench.md` | Design | Workbench / terminal tile / duplicate / restore details |
| `docs/42_design-cli-bridge.md` | Design | `agt open`, OSC bridge, remote semantics |
| `docs/43_design-companion-surfaces.md` | Design | browser/document surfaces and future directory extension |
| `docs/44_design-sync-v3-consumer.md` | Design | term-side sync-v3 consumer foundation and truth/presentation split |
| `docs/45_design-terminal-performance.md` | Design | completed Phase 1-4 terminal performance work |
| `docs/46_design-remote-navigation.md` | Design | completed Phase 5-7 remote navigation work and deferred remote follow-on |
| `docs/47_design-local-first-fast-path.md` | Design | active local-first fast-path plan and local/remote parity gates |
| `docs/50_plan.md` | Design | V2 implementation phases and risks |
| `docs/60_tasks.md` | Tracking | active and next tasks |
| `docs/70_progress.md` | Tracking | recent progress summary |
| `docs/80_decisions/` | Tracking | ADRs |
| `docs/85_reviews/` | Tracking | review packs |
| `docs/archive/` | Archive | historical tasks/progress and superseded context |
| `docs/lessons.md` | Tracking | lessons learned |

## Current Product Direction

Mainline product truth is now:

- real tmux sessions are the visible source of truth
- agtmux daemon sync-v3 is the semantic metadata truth
- agtmux-term is a presentation consumer of that truth
- sync-v2 / legacy collapse is compatibility-only and not a product fallback
- terminal tiles stay normal Ghostty/tmux views
- Workbench is app-owned saved layout state
- browser/document surfaces are explicit companion views
- hidden linked-session is not the normal product path

## ADRs

| File | Title | Status |
|------|-------|--------|
| `docs/80_decisions/ADR-20260228-libghostty-over-swiftterm.md` | libghostty を SwiftTerm の代替として採用 | Accepted |
| `docs/80_decisions/ADR-20260228-ghosttykit-distribution.md` | GhosttyKit.xcframework 配布戦略（Git LFS 採用） | Accepted |
| `docs/80_decisions/ADR-20260306-tmux-first-cockpit-v2.md` | tmux-first cockpit への mainline pivot | Accepted |

## Key External Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| GhosttyKit.xcframework | `vendor/ghostty` build output | libghostty terminal runtime |
| agtmux daemon | `agtmux-v5-architecture-blueprint` repo | local metadata overlay and health |
| tmux | system PATH / remote hosts | real session runtime |

## Current Tracking Focus

- `Gate-L`
  local-first implementation slices are now closed; Gate-L measurement is in progress:
  - repo-local signpost / idle / pane-switch scripts now exist
  - the last false-green risks are now closed:
    - idle CPU sampling uses interval-based `top` delta samples
    - signpost / pane-switch percentile summaries use nearest-rank `p95`
    - empty signpost windows fail loudly
  - the pane-switch root cause was term-side:
    - local control-mode events were session-scoped and could drift away from rendered-client truth
    - `WorkbenchFocusedNavigationActor` now re-reads exact rendered-client state on control-mode startup and non-output events
  - the repo-local pane-switch proxy bench is now green:
    - `scripts/perf/gate_l_pane_switch_bench.sh --iterations 4 --timeout 20` => PASS
    - this is a 2-pane internal-bridge proxy, not the final 4-pane/sidebar-click Gate-L proof
    - latest proxy sample: `p95_ms = 2339.612`
    - `FetchAll` is absent in the captured pane-switch signpost window
  - the vendored native Ghostty bundle exists and launches from this repo:
    - `vendor/ghostty/zig-out/Ghostty.app`
    - `ghostty +version` => `1.2.3`
    - `scripts/perf/gate_l_native_ghostty_probe.sh` => launch/activation/key injection PASS
  - `scripts/perf/gate_l_ax_key_sender.sh` now builds an app-backed helper:
    - `scripts/perf/.apps/GateLAXKeySender.app`
    - `scripts/perf/gate_l_ax_key_sender.sh --prompt --dry-run` => PASS (`trusted = true`)
  - helper-based native input smoke is also green:
    - `scripts/perf/gate_l_native_ghostty_input_smoke.sh --timeout 15` => PASS
    - tmux capture matches the receive-marker pattern `__GATE_L_RECV__:\s*a`
  - the current blocker is final same-host parity-number capture, not native input automation
- `T-152`
  live Codex full-lane drift is closed; `AppViewModelLiveManagedAgentTests` now returns success again after the interactive trust-prompt wrap fix and Codex-only canary precondition cleanup
- live Claude prompt proof
  the suite currently records one explicit skip because local `claude -p` execution returns `401` expired-token auth on March 13, 2026; this is tracked as environment/auth signal, not a reopened term regression
- `T-LF-08`
  render scheduler cleanup / multi-display audit is closed on fresh SwiftPM + Xcode verification and dual Codex re-review `GO`
- `T-LF-07`
  dirty-only draw is closed on fresh SwiftPM + Xcode verification and dual Codex review `GO`
- `T-LF-06`
  local fallback / command-broker hardening is closed on fresh SwiftPM + Xcode verification and Codex review `GO`; remote `sshTarget` drift now invalidates frozen attach plans as well as focused navigation ownership
- `T-LF-05`
  focused navigation actor extraction is closed on fresh SwiftPM + Xcode verification and Codex CLI review `GO`
- `T-LF-01` + `T-LF-02`
  local metadata/health steady state is coordinator-owned, local inventory converges automatically outside the global `fetchAll()` loop, and startup/poll rewiring is closed on fresh SwiftPM + Xcode verification and review `GO`
- `T-LF-00`
  local-first kickoff baseline is closed on docs, signposts, runnable perf script, and fresh verification
- `T-090` through `T-094`
  Workbench V2 implementation kickoff track
- `T-120` through `T-128`
  sync-v3 consumer foundation, daemon-owned fixture ingest, additive bridge, first UI cutover, thin live canary, shared display-adapter isolation, and local transport-bridge extraction are landed
- `T-129`
  local metadata overlay/replay cache application is now isolated behind one helper while publish/clear orchestration still remains in `AppViewModel`
- `T-130`
  local metadata refresh state transitions are now isolated behind one helper while the async loop still remains in `AppViewModel`
- `T-131`
  local metadata async refresh decisions are now isolated behind one coordinator while the `Task` lifecycle still remains in `AppViewModel`
- `T-132`
  product local metadata now requires sync-v3; remaining sync-v2 code is compatibility-only
- `T-133`
  broad AppViewModel product tests now match the sync-v3-only product path; remaining sync-v2 assertions are compat-only
- `T-134`
  dead sync-v3->v2 fallback selector surface is removed from `LocalMetadataTransportBridge`
- `T-135`
  product-facing daemon incompatibility naming now matches the sync-v3 metadata protocol path
- `T-136`
  product live managed-agent suite now matches sync-v3 exact-row truth and no longer relies on sync-v2/`ActivityState` assumptions
- `T-137`
  UI test bridge sidebar/bootstrap diagnostics now use sync-v3 truth and presentation-derived summaries
- `T-138`
  remaining live Codex UI proof now asserts `primary=...` semantics and accepts `completed_idle`
- `T-139`
  UI sidebar dump payloads and summary helpers are presentation-first; raw pane arrays are no longer part of the product-facing diagnostics path
- `T-140`
  pane row accessibility summaries now use `primary=...` terminology and no longer expose stale raw `activity=...` wording
- `T-141`
  stale freshness/accessibility helper drift is removed; `sidebar.pane.activity.*` is now documented as a stable legacy identifier with primary-state semantics
- `T-142`
  product-facing incompatible metadata detail is protocol-accurate and no longer treats raw `sync-v2 bootstrap` wording as product truth
- `T-143`
  product metadata reset/orchestration now depends on a v3-only abstraction; sync-v2 reset survives only on compat surfaces
- `T-144`
  product-facing metadata clients/tests now depend on `ProductLocalMetadataClient`; `LocalMetadataClient` survives only as a compat-only surface
- `T-150`
  product metadata refresh helpers no longer model mixed sync-v2/sync-v3 bootstrap state; remaining sync-v2 code is compat-only below the product boundary
- `T-151`
  term-side sync-v2 endpoint/session/XPC compat code is removed after daemon `T-SV2-P2`; only legacy sync-v2 model types remain where still needed
- `T-145`
  `PaneDisplayState` now reads legacy `ActivityState` collapse through explicit compat helper `PaneDisplayCompatFallback`
- `T-146`
  `LocalMetadataOverlayStore` now reads `PanePresentationState` → `ActivityState` collapse through explicit compat helper `PaneMetadataCompatFallback`
- `T-147`
  `PaneDisplayState` now reads legacy `ActivityState` → `needsAttention` collapse through explicit compat helper `PaneDisplayCompatFallback`
- `T-148`
  `AgtmuxPane.needsAttention` now delegates to `PaneDisplayCompatFallback`; duplicated legacy attention collapse is gone from `CoreModels`
- `T-119`
  live product Codex completion targets `completed_idle` without attention unless pending requests explicitly exist, and the dedicated live completed-idle canary is green again after the March 13, 2026 harness fix
- `T-116`
  metadata-enabled plain-zsh Codex XCUITest is now recorded as environment-blocked/deferred; the semantic replacement is the green live AppViewModel managed-agent proof, with explicit Codex freshness coverage on sync-v3 bootstrap truth
- strict live Codex running-state proof is green again on both lanes:
  `testLiveCodexActivityTruthReachesExactAppRowWithoutBleed` remains the main exec-mode proof, and `testLiveCodexInteractiveRunningSentinelStillSurfacesExactRunningTruth` is back to green after the wrapped trust-prompt fix
- `T-087`
  docs compaction and active-context redesign complete
- `T-076` through `T-084`
  local daemon runtime hardening and health observability complete

## Notes

- Older linked-session workspace work remains part of implementation history.
- It is no longer the mainline product truth described by `docs/10`〜`docs/50`.
- Historical task/progress detail is preserved under `docs/archive/`.
