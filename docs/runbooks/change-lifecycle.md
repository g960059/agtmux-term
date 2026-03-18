# Change Lifecycle

## Default Flow

`Discussion -> Issue -> docs/changes/<issue-id>-slug/ -> branch -> PR -> merge -> retire change pack`

Use Discussion for open-ended exploration. Use Issues for executable work.

## Change Types

### Small change

- narrow bug fix, typo, rename, or test-only adjustment
- use Issue + branch + PR
- do not create a change pack

### Standard change

- one feature or behavior change that spans multiple files
- create `docs/changes/<issue-id>-slug/`
- keep `requirements.md`, `design.md`, `plan.md`, and `tasks.md` short

### Structural change

- boundary cuts, architecture shifts, or major runtime/model changes
- use `docs/changes/<issue-id>-slug/`
- add or update an ADR when the decision has long-term value
- prefer stacked PRs over one oversized PR

### Research

- use Discussion or Issue
- store reusable findings in dated `docs/research/`
- promote only accepted long-lived decisions into ADRs

## Change Pack Rules

Each change pack must contain:

- `README.md`
- `requirements.md`
- `design.md`
- `plan.md`
- `tasks.md`

`docs/changes/0000-...` is reserved for in-progress work that predates GitHub issue
discipline and is being migrated into this model. Replace it with a real issue
id when the issue exists.

## Before Merge

Promote durable knowledge into one of these places:

- `docs/decisions/` for long-lived decisions
- `docs/runbooks/` for repeatable operating procedure
- `docs/research/` for dated reusable findings
- tests for behavior guarantees
- code comments/docstrings for boundary clarification

## After Merge

- remove `docs/changes/<issue-id>-slug/` from the default branch
- keep history in the Issue, PR, and commit log
- do not keep finished change packs in-tree unless there is a deliberate archive policy outside the default branch
- do not recreate numbered task/progress/review ledgers under `docs/`
