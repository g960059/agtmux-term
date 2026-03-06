# Current State

## Snapshot

- Product mode: V2 tmux-first cockpit
- Mainline docs are aligned to V2 and design-locked for MVP
- The codebase still contains the older linked-session workspace path
- Current worktree has cleared commit/review gates and is ready for commit/push
- The next implementation step is to create and execute isolated V2 tasks, not to incrementally mutate V1 into V2

## Current Product Truth

- `tmux first`
- `terminal stays terminal`
- `1 terminal tile = 1 real tmux session`
- `Workbench = app-owned saved layout`
- browser/document companion surfaces are explicit
- hidden linked-session is not the normal product path
- same-session multi-view is out of MVP

## Locked MVP Decisions

- `SessionRef = target + exact session name`
- `TargetRef = local or configured remote-host key`
- `lastSeenSessionID` is hint-only
- one real tmux session may appear in only one visible terminal tile across the app
- duplicate open reveals/focuses existing tile by default
- `Rebind` is manual exact-target reassignment only
- Workbenches autosave
- terminal tiles are always part of saved Workbench state
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

### Done

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

- `T-090`
  Workbench V2 foundation path
- `T-091`
  real-session terminal tile
- `T-092`
  CLI bridge plus browser/document companion surfaces
- `T-093`
  Workbench persistence and restore placeholders
- `T-094`
  sidebar integration and linked-session normal-path removal

## Open Blockers

- Implementation tasks for V2 still need to be executed in order
- V2 should begin on an isolated path inside the repo, not as an in-place mutation of the linked-session model

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
