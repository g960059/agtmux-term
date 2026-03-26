# Principles

- **terminal first**: the main panel behaves like a normal terminal before it behaves like a cockpit.
- **one main window**: the sidebar and the terminal stay together in the app's main panel.
- **sidebar as overlay**: the sidebar helps with tmux and agent awareness; it does not replace the terminal as the primary runtime.
- **tmux truth first**: tmux and SSH define session existence; the app does not.
- **Ghostty engine authority**: rendering, input, IME, and terminal semantics come from GhosttyKit/libghostty, not app-authored terminal code.
- **daemon as metadata truth when enabled**: agtmux sync-v3 provides health, metadata, and observability, not session existence.
- **reuse in place**: sidebar actions should reuse or retarget the current terminal in place before introducing more surface complexity.
- **fail loudly**: permission, transport, binding, and host failures are surfaced explicitly.
- **no silent guessing**: no fuzzy rebinding, guessed host substitution, or implicit fallback that changes meaning.
- **thin host, not generic workspace truth**: the app hosts Ghostty surfaces, but generic workbench/tile state is not the mainline product model.
- **plain shell by default**: startup should land in a plain shell unless the user explicitly opts into auto-launch.
- **sidebar-guided tmux**: session/window/pane navigation should come from the sidebar, not from generic app-owned tile graphs.
- **remote remains no-install**: richer remote workflows must not require remote sidecars by default.
