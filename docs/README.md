# Documentation

The default branch keeps only durable documentation:

- `docs/product/` — stable product intent
- `docs/decisions/` — ADRs
- `docs/runbooks/` — operating procedures
- `docs/research/` — dated, non-authoritative research

Active multi-step work belongs in `changes/<issue-id>-slug/` and is removed
from the default branch after merge.

Do not reintroduce numbered task/progress/review doc sets on the default branch.

## Read Order

1. `README.md`
2. `docs/product/overview.md`
3. `docs/product/objectives.md`
4. `docs/product/principles.md`
5. `docs/product/goals-non-goals.md`
6. `docs/decisions/`
7. `docs/runbooks/change-lifecycle.md`
8. active Issue / PR
9. active change pack, if one exists
