# Router & Contract (always read first)

## L1: Non-negotiables (Hard Gates)
- `docs/` is the ONLY source of truth. If it is not in `docs/`, it is not authoritative.
- Router is process-only. Product intent/spec lives in `docs/10_foundation.md` and above, not in this file.
- Orchestrator MUST delegate Implement / Test / Review to separate subagents.
- Final Go/Stop decision is made ONLY by Orchestrator.
- Only Orchestrator may edit:
  - `docs/60_tasks.md`, `docs/70_progress.md`, `docs/80_decisions/*`, `docs/85_reviews/*`
- Local-first execution is default. Daily development/testing MUST NOT require commit/PR workflow.
- If commit/PR/release is performed, Quality Gates MUST pass first (see below).
- If unsure, be fail-closed: STOP or escalate (Escalation Matrix).

## L1.5: Execution Mode (B: Core-first)
- Current mode is `B` (core spec + implementation feedback).
- During Phase 0-1, only items tagged `[MVP]` in `docs/20_spec.md` are implementation blockers.
- Items tagged `[Post-MVP]` are valid design assets but must NOT block Phase 0-1 coding.
- If `[Post-MVP]` work is discovered as unexpectedly necessary, Orchestrator must:
  - create a task in `docs/60_tasks.md` with clear dependency and rationale
  - record the decision in `docs/70_progress.md`
  - escalate only when it changes `docs/10_foundation.md` or public behavior

## L2: Progressive Disclosure (What to read, in order)
1) `docs/70_progress.md` (latest learnings, constraints, open points)
2) `docs/60_tasks.md` (`MVP Track` first)
3) `docs/10_foundation.md` (stable intent)
4) `docs/20_spec.md` (`[MVP]` first, `[Post-MVP]` only as needed)
5) `docs/40_design.md` (`Main (MVP Slice)` first, `Appendix` only if blocked)
6) `docs/30_architecture.md` -> `docs/50_plan.md` (as needed)
7) `docs/90_index.md` (only if structure changed / cannot navigate)

## Plan mode policy (Docs-first)
- Built-in plan/task outputs are scratch.
- In plan mode, DO NOT create a separate plan document.
- Output ONLY: "Proposed edits to docs/*" (file-by-file patch suggestions) + "Proposed updates to docs/60_tasks.md".
- After approval, apply edits to `docs/*` BEFORE writing code.

### Plan mode output format (mandatory)
A) Proposed edits:
- File: `docs/20_spec.md`
  - Section: ...
  - Replace/Add: ...
- File: `docs/40_design.md`
  - ...

B) Proposed task board update:
- Add/modify tasks in `docs/60_tasks.md` (IDs stable; keep history)

C) Open questions ONLY if Escalation triggers.

## Implementation checkpoints (context-compaction safety)
- **Multi-phase tasks**: update `docs/70_progress.md` after **each phase completes** — do NOT defer to task close.
  - Include: phase name, what was changed, files touched, live verification result.
  - Rationale: context compaction mid-task loses unreported phase details; next session resumes from docs, not memory.
- **`docs/60_tasks.md` DONE entry**: reflect all phases on task close (not just Phase 1).

## Quality Gates (project-specific)
- Build: `swift build` must PASS (zero errors)
- Typecheck: Swift compiler errors = 0
- Lint: `swiftlint` warnings should not increase (if swiftlint is configured)
- Unified local gate: build + typecheck must PASS before review/commit/PR.
- **Review Pack prerequisite**: `swift build` PASS required before creating a Review Pack.
- Reviewer verdict required: `GO / GO_WITH_CONDITIONS / NO_GO / NEED_INFO`

## Review protocol (prevent stall)
- Reviewer does NOT run tests (Tester does). Reviewer judges using Review Pack only.
- Orchestrator MUST create a Review Pack in `docs/85_reviews/` before requesting review.
- Verdict schema:
  - `GO`
  - `GO_WITH_CONDITIONS` (ship + create follow-up tasks)
  - `NO_GO` (must fix)
  - `NEED_INFO` (max 3 missing items; Orchestrator supplies and re-review)

### NEED_INFO loop
- If `NEED_INFO`: Orchestrator supplies ONLY the requested evidence and re-runs review.
- If `NEED_INFO` repeats twice:
  - switch reviewer (second reviewer), OR
  - proceed with `GO_WITH_CONDITIONS` + create explicit follow-up tasks, OR
  - escalate to user (if risk is high).

## Escalation Matrix (ask user)
- Change to `docs/10_foundation.md` (persona/user story/goals/non-goals/global AC)
- Breaking public API / CLI compatibility or major behavior change
- Change to libghostty C API integration strategy
- Change to agtmux daemon communication protocol
- Large dependency bumps with wide blast radius
- Decision to vendor or submodule Ghostty source
