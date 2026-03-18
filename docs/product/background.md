# Background

The repository originally invested heavily in app-owned terminal hosting and
linked-session workspace machinery. That work proved costly in complexity,
performance, and truth drift.

The current direction exists because:

- app-owned terminal hosting created too much rendering and layout complexity
- hidden tmux sessions drifted away from `tmux ls` and external tooling
- the strongest product value was already in sidebar observability, health, and
  session control rather than terminal emulation itself
- Ghostty provides the terminal runtime quality that the app should delegate to

The result is a simpler model: tmux remains session truth, Ghostty remains
runtime authority, and the app focuses on control-plane value.
