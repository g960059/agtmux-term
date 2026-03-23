# Documentation

This repository keeps durable documentation and active change packs under
`docs/`:

- `docs/product/` — stable product intent
- `docs/decisions/` — ADRs
- `docs/runbooks/` — operating procedures
- `docs/research/` — dated, non-authoritative research
- `docs/changes/` — active multi-step change packs only

Active multi-step work belongs in `docs/changes/<issue-id>-slug/` and is removed
from the default branch after merge.

Do not reintroduce numbered task/progress/review doc sets on the default branch.

## Read Order

1. `README.md`
2. `docs/product/overview.md`
3. `docs/product/principles.md`
4. `docs/product/goals-non-goals.md`
5. `docs/decisions/`
6. `docs/runbooks/change-lifecycle.md`
7. active Issue / PR
8. active change pack under `docs/changes/`, if one exists
