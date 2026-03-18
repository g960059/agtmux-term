# Design

## Chosen Approach

Use a vector-first workflow to explore candidate icons, then regenerate the
entire macOS AppIcon PNG set from the selected source SVG.

The selected direction is the bold prompt mark: a large cyan chevron with a
small cursor block on a dark rounded square. It is the clearest terminal cue in
the generated set and retains the best small-size recognition.

## Boundaries

- changes now: selected source SVG, research note, AppIcon PNG replacements, active change pack
- unchanged: app behavior, release pipeline, asset catalog layout, icon filenames

## Failure Modes

- the icon looks strong at 1024px but becomes muddy at small sizes; mitigated by reviewing the 16px through 256px outputs before commit
- the selected source cannot be reproduced cleanly into the AppIcon set; mitigated by regenerating every size from the SVG and validating with an app build
