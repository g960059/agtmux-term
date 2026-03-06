# Companion Surface Design Details

## Scope

This document defines the MVP companion surfaces:

- browser tile
- document tile
- future additive extension boundary for directory tile

Read this after `docs/40_design.md`.

## Browser Tile

Scope:

- explicit URL only
- back / forward / reload / open externally
- pinned URL restores
- no devtools in MVP

Rules:

- browser tiles may duplicate
- browser tiles are transient unless pinned
- URLs open exactly as requested
- there is no silent localhost rewrite or tunnel

## Document Tile

Scope:

- explicit local or remote file path
- Markdown or plain text
- refresh from source
- open in external editor if needed

Path semantics:

- file refs carry `target + resolved path`
- relative paths resolve against shell cwd when the bridge request is emitted
- remote file content is fetched lazily from the configured remote identity

Rules:

- document tiles may duplicate
- document tiles are transient unless pinned
- missing path and access failures remain visible

## Future Additive Extension: Directory Tile

Directory tile is reserved for future work only.

If implemented later, it must:

- reuse the same Workbench tile model
- reuse the same source-aware path semantics
- reuse the same placement and pinning conventions as other companion surfaces
- remain lightweight
- avoid pushing the product toward IDE explorer behavior
- use an additive command surface such as reserved `agt reveal`

Not in MVP:

- inline editing
- heavyweight explorer subsystem
- global search
- background crawl

## Performance Guardrails

The product must stay closer to a terminal cockpit than an IDE.

- no project indexer
- no heavyweight file explorer subsystem
- no always-on global search engine
- no background crawl as a default behavior
- companion surfaces load lazily
