# Change Pack

- **Issue:** `#1`
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** [2026-03-18-terminal-icon-refresh.md](../../research/2026-03-18-terminal-icon-refresh.md)

This pack tracks the macOS app icon refresh work.

Current state:

- the original four-pane neon icon was replaced because it read more like a dashboard than a terminal app at small sizes
- Gemini CLI produced five simpler review directions, and `05 Bold` was selected
- the repo AppIcon asset set was regenerated from the selected bold prompt SVG
- docs validation passed, and a local `xcodebuild` app build succeeded after the asset update
