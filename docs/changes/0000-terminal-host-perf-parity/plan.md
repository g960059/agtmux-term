# Plan

1. normalize the perf baseline
   - document the required matched-version comparison against native Ghostty
   - drop removed host-mode branches from benches and bridge payloads

2. add the missing telemetry
   - render callback ownership counters
   - dirty-draw scheduling counters
   - main-thread tick/draw timing
   - resize churn counters
   - pane/surface lifecycle counters

3. produce the first parity table
   - embedded vs native on the same upstream Ghostty version
   - scroll, resize, and retarget scenarios only

4. thin the embedded hot path
   - remove steady-state host cadence where the measurements show it
   - special-case the one-main-terminal path before deleting broader
     scaffolding

5. delete migration leftovers instead of preserving compatibility seams
   - prefer removing stale scripts/docs over carrying dead host-mode language
