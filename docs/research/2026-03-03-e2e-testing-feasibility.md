# 2026-03-03 — E2E and Integration Testing Feasibility

**Status:** Research complete  
**Authority:** Research only. Durable truth remains code, tests, CI, and ADRs.

## Summary

- Unit tests through SwiftPM/XCTest are viable.
- Integration tests with real tmux subprocesses are viable.
- Full XCUITest coverage is possible but expensive and environment-sensitive.
- Crash and behavior investigation can often proceed without a full E2E harness.

## Notes Worth Reusing

- pure logic should stay extractable from UI-heavy modules so XCTest coverage can
  grow without relying on AppKit or Ghostty surfaces
- tmux-backed integration tests provide high signal for session truth and
  control-mode behavior
- UI automation should be reserved for flows that cannot be proven at lower
  layers

Use this document as dated research context, not as current implementation
contract.
