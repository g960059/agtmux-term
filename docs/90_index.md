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
11. `docs/30_architecture.md`
12. `docs/50_plan.md`
13. `docs/70_progress.md`
14. `docs/archive/README.md`

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
- `T-145`
  `PaneDisplayState` now reads legacy `ActivityState` collapse through explicit compat helper `PaneDisplayCompatFallback`
- `T-146`
  `LocalMetadataOverlayStore` now reads `PanePresentationState` → `ActivityState` collapse through explicit compat helper `PaneMetadataCompatFallback`
- `T-147`
  `PaneDisplayState` now reads legacy `ActivityState` → `needsAttention` collapse through explicit compat helper `PaneDisplayCompatFallback`
- `T-148`
  `AgtmuxPane.needsAttention` now delegates to `PaneDisplayCompatFallback`; duplicated legacy attention collapse is gone from `CoreModels`
- `T-119`
  live product Codex completion no longer expects `waiting_input`; sync-v3 truth is `completed_idle` without attention unless pending requests explicitly exist
- `T-116`
  metadata-enabled plain-zsh Codex XCUITest is now recorded as environment-blocked/deferred; the semantic replacement is the green live AppViewModel managed-agent proof, with explicit Codex freshness coverage on sync-v3 bootstrap truth
- strict live Codex running-state proof is also green again on `agtmux` `7536bea`:
  `testLiveCodexActivityTruthReachesExactAppRowWithoutBleed` now reserves interactive Codex launch for semantic-state observation of `primary=.running`
- `T-087`
  docs compaction and active-context redesign complete
- `T-076` through `T-084`
  local daemon runtime hardening and health observability complete

## Notes

- Older linked-session workspace work remains part of implementation history.
- It is no longer the mainline product truth described by `docs/10`〜`docs/50`.
- Historical task/progress detail is preserved under `docs/archive/`.
