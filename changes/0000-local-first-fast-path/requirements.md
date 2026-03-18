# Requirements

## Problem

The local-first groundwork is largely landed, but the repository still needs:

- closure of the transient local overlay blink regression (`T-LF-13`)
- final local parity evidence for Gate-L

## Goals

- keep tmux session truth and daemon sync-v3 metadata truth unchanged
- preserve managed-row overlay continuity under transient metadata transport misses
- prove or falsify local parity for scroll, keypress-to-glyph, and final pane-switch behavior

## Non-Goals

- remote fast-path work before Gate-L is green
- changing product truth away from tmux-first + daemon-metadata-first

## Acceptance

- [x] `T-LF-13` broad verification is green
- [x] scroll p95 is within `1.25x` of native Ghostty + local tmux
- [x] keypress-to-glyph p95 is within `1.15x`
- [x] pane switch p95 is within `1.20x`
- [x] idle CPU is within `+3pt` of baseline
- [x] focused local steady state is no longer dominated by `FetchAll` / `TmuxRunner`
