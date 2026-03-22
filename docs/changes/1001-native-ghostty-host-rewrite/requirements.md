# Requirements

## Problem

Even after multiple tuning waves, `agtmux-term` still feels materially worse
than native Ghostty during upward trackpad history scroll on real live panes.
The remaining problem is architectural, not just timer tuning.

## Goals

- move new terminal hosting toward Ghostty-owned render cadence
- stop relying on same-surface pane retargeting in the new path
- isolate terminal rendering from SwiftUI/control-plane lifecycle as much as
  practical
- keep the rewrite in the same repository so daemon, tmux, tests, release, and
  docs stay shared
- prove behavior with realistic live-pane parity gates, not only synthetic
  fixtures

## Non-Goals

- preserving the current legacy host as the mainline architecture
- creating a separate repository or second product
- redesigning sidebar UX as part of the host rewrite
- deleting the legacy host before the new path has live-pane proof

## Acceptance

- [ ] a dedicated "next host" path exists behind an internal switch
- [ ] the new path gives each visible pane a persistent Ghostty surface instead
      of retargeting one surface across panes
- [ ] the new path removes host-owned scroll presentation pumping from normal
      history scroll
- [ ] a realistic live-pane parity gate exists for the rewritten path
- [ ] durable docs describe the new boundary and the migration plan
