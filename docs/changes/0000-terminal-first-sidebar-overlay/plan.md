# Plan

1. Rewrite durable product and decision docs around the terminal-first sidebar
   overlay model.
2. Define the minimal `MainTerminalStore` boundary and document how it replaces
   visible Workbench ownership.
3. Rewire visible mainline UI to `sidebar + single main terminal`, removing
   visible workbench tabs and companion surfaces from the main window path.
4. Make plain-shell startup and `New Shell` reset behavior real through the
   embedded Ghostty host.
5. Implement sidebar target resolution:
   `session active pane -> restore target -> first listed pane`.
6. Implement same-session in-place retarget and cross-session single-terminal
   reattach.
7. Add diagnostics for attach, restore, and terminal/sidebar drift failures.
8. Quarantine or prune generic workbench/browser/document paths from the
   mainline UX once the thinner terminal-first host is stable.
