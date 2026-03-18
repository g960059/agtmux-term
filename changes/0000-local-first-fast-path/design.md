# Design

## Current State

Completed groundwork already moved the local steady state toward:

- coordinator-owned metadata/health refresh
- local inventory authority instead of a 1 Hz broad local poll
- chunk-based tmux control-mode parsing with pane-output emission off by default
- off-main publish snapshot assembly
- focused navigation ownership in `WorkbenchFocusedNavigationActor`
- dirty-only draw and render-scheduler cleanup
- asynchronous Ghostty action bridge handling
- remote broad polling only when configured remote targets exist
- AX-targeted terminal host exposure for perf automation, plus a bench seam to
  focus the active embedded terminal host deterministically

## Remaining Gaps

1. transient metadata transport misses can still blink the local overlay and
   active-pane highlight in the broader suite
2. canonical workbench selection can still lag rendered tmux truth in live-app
   runs, so perf capture now keys off rendered-client convergence for pane-switch

## Constraints

- tmux / SSH remain session-existence truth
- daemon sync-v3 remains metadata and health truth
- failures stay fail-loud
- remote follow-on remains blocked until Gate-L is green

## Evidence Already Landed

- native Ghostty launch, activation, and helper-driven input are automated
- focused idle parity is green on the current host
- broad SwiftPM verification is green on the corrected head when the unrelated
  live managed-agent harness suite is excluded
- focused local-only steady-state signposts show `NavigationSync` micro-costs
  only; `FetchAll` / `TmuxRunner` do not dominate the 10s capture window
- pane-switch proxy proof is green
- same-host scroll proof is green via a wheel-driven `less -N` proxy that is
  read through `tmux capture-pane`; the current 10-run sample puts embedded p95
  at `485.808ms` versus native p95 `482.161ms` (`1.008x`)
- true key-mode pane-switch proof is green again after replaying accumulated
  `keyDown` text through `ghostty_surface_key(..., text: ...)` instead of the
  paste-oriented `ghostty_surface_text`
- same-host keypress benches exist for both embedded `agtmux-term` and native
  Ghostty, and the current 10-run sample puts embedded p95 at `415.557ms`
  versus native p95 `422.673ms` (`0.983x`)
- the keypress harness now reuses a resolved click point between iterations and
  forces `\r\n` marker emission from the raw-tty driver so `capture-pane`
  matching stays stable across longer runs
- true terminal-local scrollback image diffing is still unavailable in this
  environment because display capture is not usable, so the scroll harness uses
  a tmux-observable proxy instead of screen-image comparison
- embedded terminal host lookup is now addressable through the AX tree by tile
  identifier
- producer-side signposts are split enough to attribute local inventory, remote
  inventory, publish assembly, and Ghostty bridge work separately
