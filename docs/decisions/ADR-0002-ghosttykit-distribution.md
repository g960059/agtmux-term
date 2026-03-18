# ADR-0002: Distribute GhosttyKit as a checked-in binary artifact

- **Status**: Accepted
- **Date**: 2026-02-28

## Context

`GhosttyKit.xcframework` is expensive to rebuild and awkward to regenerate in
every developer or CI environment.

## Decision

Keep the built GhosttyKit artifact in the repository and document regeneration
from `vendor/ghostty` when the dependency is intentionally updated.
When that checked-in artifact is unavailable as a real payload, standard CI and
release workflows rebuild it from a pinned Ghostty tag plus the repo's custom
OSC bridge patch instead of depending on Git LFS at checkout time.

## Consequences

Positive:

- faster onboarding and simpler CI
- the app can build without re-running a heavy Ghostty toolchain step
- standard CI and release workflows can fall back to rebuilding the same
  artifact from pinned Ghostty source when Git LFS payloads are unavailable

Tradeoffs:

- larger repository footprint
- artifact updates must be deliberate and traceable
