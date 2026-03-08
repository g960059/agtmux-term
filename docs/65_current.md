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
- local managed/provider/activity overlay target contract remains exact sync-v2 identity (`session_key` + `pane_instance_id`) with whole-epoch fail-closed behavior on invalid rows
- `session_key` is now treated as opaque overlay identity, not as a visible tmux session alias
- same-session pane selection must reuse the existing session tile and navigate it to the requested pane/window without reviving linked-session behavior
- same-session pane selection and terminal-originated pane changes must converge through one reducer-owned runtime pane state with desired/observed separation
- pane-selection proof is not trusted unless it exercises a real Ghostty surface and checks rendered attach state, not just store/sidebar/tmux intent
- pane-selection truth must now be exact-client scoped: the visible terminal tile is bound to one rendered tmux client tty, and reverse sync / E2E proof must use that client's pane/window rather than session-wide active flags
- rendered-client binding now rides the structured `OSC 9911` host bridge rather than a private `OSC 9912` path
- initial attach and same-session retarget use different desired-pane confirmation policies; same-session retarget from an already observed rendered client releases desired state after the first matching observation
- same-session pane/window retarget must preserve the existing Ghostty surface and navigate the already bound tmux client with `switch-client -c <tty> -t <pane>`
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

- no open app-side product task is currently blocking the V2 cockpit path

### Done

- `T-108`
  epoch-gated exact-identity overlay + reducer-owned desired/observed active-pane state + exact-client pane-sync E2E correction (`DONE`)
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

- if live status disagreements still remain after this slice, treat them as daemon-payload truth issues first and validate `ui.bootstrap.v2` / `ui.changes.v2` output before reopening the term consumer
- optional follow-up: capture a fresh post-fix manual screenshot/log pair from the live desktop to confirm the earlier March 7, 2026 user report no longer reproduces in the shipped app path

## Open Blockers

- no app-side blocker is currently tracked
- if fresh live disagreement appears, validate daemon payload truth first before reopening the term consumer

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
