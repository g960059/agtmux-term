# ADR-0002: Distribute GhosttyKit as a checked-in binary artifact

- **Status**: Accepted
- **Date**: 2026-02-28

## Context

`GhosttyKit.xcframework` is expensive to rebuild and awkward to regenerate in
every developer or CI environment.

## Decision

Keep the built GhosttyKit artifact in the repository and document regeneration
from `vendor/ghostty` when the dependency is intentionally updated.

## Consequences

Positive:

- faster onboarding and simpler CI
- the app can build without re-running a heavy Ghostty toolchain step

Tradeoffs:

- larger repository footprint
- artifact updates must be deliberate and traceable
