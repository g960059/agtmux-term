# Goals and Non-Goals

## Goals

- make local and remote tmux sessions easy to browse and act on
- make session-row open / focus behavior binding-aware and explicit
- focus an existing Ghostty binding before opening a duplicate session
- open a new Ghostty tab or window when no live binding exists
- keep Ghostty normal outside tmux-attached flows
- surface binding, automation, daemon, and host failures clearly
- keep remote support no-install by default
- stay closer to a lightweight control plane than an IDE

## Non-Goals

- preserving any app-owned terminal runtime as the mainline product path
- mirroring Ghostty tabs, windows, or panes inside app-owned layout truth
- automating new Ghostty pane creation in the first mainline wave
- requiring remote sidecars by default
- guessing session identity from fuzzy prompt or hostname heuristics
