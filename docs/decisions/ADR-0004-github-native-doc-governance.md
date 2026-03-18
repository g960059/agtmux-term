# ADR-0004: Keep durable docs on the default branch and retire finished change packs

- **Status**: Accepted
- **Date**: 2026-03-17

## Context

The previous numbered-doc model mixed durable product intent with active task
tracking, review packs, and progress ledgers. That created duplicated truth and
left old execution notes in the default branch long after the implementation had
changed.

This repository is also used by coding agents. Agents tend to treat reachable
repo text as authoritative, so stale task/progress docs increase the risk of
context drift.

## Decision

Adopt a GitHub-native split:

- keep only durable product intent in `docs/product/`
- keep long-lived decisions in `docs/decisions/` ADRs
- keep repeatable procedure in `docs/runbooks/`
- keep dated, non-authoritative findings in `docs/research/`
- use `changes/<issue-id>-slug/` only for active multi-step work
- remove finished change packs from the default branch after merge
- rely on Issues, PRs, and git history for historical execution trace

`changes/0000-...` is allowed only as a migration placeholder for in-progress
work that predates issue-based naming.

## Consequences

Positive:

- the default branch contains less stale execution text
- durable and temporary docs are easier to distinguish
- GitHub Issue, branch, PR, and change-pack ids line up cleanly
- agents have a smaller and more trustworthy documentation surface

Tradeoffs:

- some historical detail moves out of the working tree and into GitHub history
- larger changes require deliberate promotion of durable knowledge before merge
