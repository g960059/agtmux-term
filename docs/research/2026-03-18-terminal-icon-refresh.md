# 2026-03-18 Terminal Icon Refresh

## Summary

The original app icon used a four-pane neon layout that was distinctive at large
sizes but read more like a dashboard than a terminal app at smaller sizes.

The selected replacement is a simpler "bold prompt" direction:

- dark graphite rounded-square base
- oversized cyan chevron prompt
- small cyan cursor block

This keeps terminal recognition strong at launcher and Dock sizes while still
feeling aligned with `agtmux-term`.

## Selection Notes

- chosen candidate: `05 Bold`
- strongest qualities: immediate terminal recognition, clean silhouette, high
  small-size legibility
- rejected tradeoffs:
  - split-pane and cockpit variants hinted at tmux layout, but lost clarity at
    small sizes
  - the more native-window variant read as app chrome instead of terminal-first

## Source Asset

The selected vector source is stored at:

- `docs/research/2026-03-18-terminal-icon-05-bold.svg`

PNG files in `Sources/AgtmuxTerm/Resources/Assets.xcassets/AppIcon.appiconset/`
were regenerated from that SVG for the macOS asset catalog sizes.
