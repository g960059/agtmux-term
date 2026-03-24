# Goals and Non-Goals

## Goals

- make local and remote tmux sessions easy to browse and act on
- keep the sidebar and the active terminal in one app window
- make session-row activation reveal an existing embedded session viewport first
- open a session in the main panel when it is not already visible
- preserve Ghostty-quality terminal behavior through GhosttyKit/libghostty
- surface attach, restore, daemon, and host failures clearly
- keep remote support no-install by default
- keep the mainline UX closer to a tmux cockpit than a generic IDE workspace

## Non-Goals

- making separate external Ghostty windows or tabs the mainline UX
- treating generic workbench / tile graphs as product truth
- making browser/document surfaces the primary session workflow
- rebuilding terminal behavior outside GhosttyKit/libghostty
- requiring remote sidecars by default
- guessing session identity from fuzzy prompt or hostname heuristics
