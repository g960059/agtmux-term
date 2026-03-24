# Plan

1. normalize the perf baseline
   - force explicit `legacy`/`next` host modes in the relevant benches
   - document the required matched-version comparison against native Ghostty

2. add the missing telemetry
   - render callback ownership counters
   - dirty-draw scheduling counters
   - main-thread tick/draw timing
   - resize churn counters
   - pane/surface lifecycle counters

3. produce the first parity table
   - `legacy` vs `next`
   - embedded vs native on the same upstream Ghostty version
   - scroll, resize, and retarget scenarios only

4. thin the `next` hot path
   - remove steady-state host cadence where the measurements show it
   - special-case the one-main-terminal path before deleting broader
     scaffolding

5. decide the default-mode transition
   - only consider changing the default away from `legacy` after the parity
     data is stable
