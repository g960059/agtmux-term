# ADR-0001: Adopt libghostty instead of SwiftTerm

- **Status**: Accepted
- **Date**: 2026-02-28

## Context

SwiftTerm did not meet the terminal quality bar for this product:

- rendering performance was too low
- IME behavior was unreliable
- VT parsing accuracy was not sufficient for agent-heavy terminal output

## Decision

Adopt Ghostty's C API via `GhosttyKit.xcframework` as the terminal runtime.

## Consequences

Positive:

- GPU-backed rendering and stronger VT behavior
- native AppKit IME path
- tighter alignment with the Ghostty runtime the product already depends on

Tradeoffs:

- dependency on Zig/Ghostty build tooling
- upstream API instability must be managed deliberately
- Swift must bridge C APIs carefully and fail loudly
