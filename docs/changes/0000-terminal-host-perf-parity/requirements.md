# Requirements

## Goals

- make terminal-host perf parity a first-class tracked workstream
- compare embedded and native Ghostty under matched-version conditions
- measure where the embedded host loses time in scroll, redraw, resize, and
  retarget paths
- reduce embedded hot-path host ownership until it is clearly better than the
  current measured baseline
- preserve the current terminal-first embedded Ghostty product boundary

## Non-Goals

- changing the one-window terminal-first product direction
- reviving generic workbench/browser/document UI as a perf workaround
- treating ad hoc visual impressions as the only acceptance signal
- reintroducing compatibility host modes as a perf workaround

## Acceptance

- the perf docs and active pack describe the same measurement matrix
- the code exposes enough telemetry to distinguish:
  - input-to-render delay
  - render-to-draw delay
  - draw-to-present delay
  - resize metrics churn
  - pane/surface lifecycle churn
- the next implementation slices can target a small, explicit list of hot-path
  ownership removals instead of broad exploratory rewrites
