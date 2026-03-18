# Goals and Non-Goals

## Goals

- make local and remote tmux sessions easy to browse and act on
- keep open / focus / reveal session flows binding-aware and explicit
- provide best-effort restore for last-known logical sessions
- surface Ghostty automation, daemon, binding, and host failures clearly
- keep the product lighter than an IDE and closer to normal terminal behavior

## Non-Goals

- preserving embedded libghostty terminal hosting as the mainline product path
- mirroring arbitrary Ghostty split graphs inside app-owned layout state
- requiring remote sidecars or remote daemon installs by default
- shipping built-in browser, filer, or document surfaces as MVP-critical truth
- guessing session identity from fuzzy prompt or hostname heuristics
- supporting Linux or Windows in this repository
