# Requirements

## Problem

The local-first groundwork is largely landed, but the repository still needs:

- final post-Gate-L full macOS UI E2E verification
- closure of the client-side regressions exposed by that rerun
- a durable daemon-side handoff for the managed-provider classification failure

## Goals

- keep tmux session truth and daemon sync-v3 metadata truth unchanged
- preserve managed-row overlay continuity under transient metadata transport misses
- prove or falsify local parity for scroll, keypress-to-glyph, and final pane-switch behavior
- rerun full macOS UI E2E after the local-first changes and classify the
  remaining failures without patching around truth boundaries

## Non-Goals

- remote fast-path work before Gate-L is green
- changing product truth away from tmux-first + daemon-metadata-first
- adding client-side fallback logic to hide daemon/provider truth mismatches

## Acceptance

- [x] `T-LF-13` broad verification is green
- [x] scroll p95 is within `1.25x` of native Ghostty + local tmux
- [x] keypress-to-glyph p95 is within `1.15x`
- [x] pane switch p95 is within `1.20x`
- [x] idle CPU is within `+3pt` of baseline
- [x] focused local steady state is no longer dominated by `FetchAll` / `TmuxRunner`
- [x] full macOS UI E2E rerun after Gate-L is completed and failures are classified
- [x] daemon-side managed-provider regression is documented for handoff
- [x] client-side failures exposed by the full macOS UI E2E rerun are fixed
- [x] full macOS UI E2E rerun on corrected head leaves only the daemon-side managed-provider failure
