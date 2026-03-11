# Review Pack

## Objective
- Task: T-SM03
- User story: managed sidebar pane rows stay single-line while provider identity and primary state move into one compact left badge
- Acceptance criteria touched:
  - managed pane rows use a left `ProviderStatusBadge`
  - running / waiting / error / idle map to the requested ring treatments
  - right edge no longer repeats `ProviderIcon`
  - unmanaged rows stay badge-free and single-line

## Summary
- Replaced the temporary managed-row inline 2-line layout in `PaneRowView` with a compact single-line row.
- Added `ProviderStatusBadge`, which centers the existing provider icon inside a state ring.
- Reused `SpinnerView` animation logic for the running ring by making trim, line width, and duration configurable.
- Removed the right-edge provider icon so managed rows now render `badge + title + freshness`.
- Kept subtitle metadata available through the row tooltip instead of inline row height expansion.

## Change scope
- `Sources/AgtmuxTerm/SidebarView.swift`
- `docs/40_design.md`
- `docs/60_tasks.md`
- `docs/70_progress.md`

## Verification evidence
- Commands run:
  - `HOME=$PWD/.swiftpm-home XDG_CACHE_HOME=$PWD/.swiftpm-home/.cache CLANG_MODULE_CACHE_PATH=$PWD/.swiftpm-home/.cache/clang/ModuleCache swift build --disable-sandbox` => PASS
  - `HOME=$PWD/.swiftpm-home XDG_CACHE_HOME=$PWD/.swiftpm-home/.cache CLANG_MODULE_CACHE_PATH=$PWD/.swiftpm-home/.cache/clang/ModuleCache swift test --disable-sandbox --skip AppViewModelLiveManagedAgentTests` => PASS
- Notes:
  - deterministic test lane executed 299 tests with 2 expected skips and 0 failures
  - no dedicated view snapshot test exists for this sidebar-only layout slice

## Risk declaration
- Breaking change: yes, intentional UI contract change for managed sidebar row layout
- Fallbacks: none; the old 2-line row and right-edge provider icon are removed
- Known gaps / follow-ups:
  - no automated assertion currently checks exact sidebar row spacing or ring rendering pixels

## Reviewer request
- Provide verdict: GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO
- Focus on:
  - managed vs unmanaged row behavior regressions
  - status-to-ring mapping correctness
  - tooltip/accessibility regressions after removing the inline subtitle

## Review execution note
- attempted `codex review --uncommitted`
- blocked by the current network-restricted sandbox:
  - websocket setup failed with `failed to lookup address information`
  - HTTPS fallback also failed sending the request to `https://chatgpt.com/backend-api/codex/responses`
- no external Codex verdict was available in this environment
