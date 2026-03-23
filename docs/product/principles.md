# Principles

- **session-first UX**: the main thing the app shows and acts on is a tmux session.
- **tmux truth first**: tmux and SSH define session existence; the app does not.
- **native Ghostty authority**: rendering, input, IME, and runtime terminal behavior belong to Ghostty, not the app.
- **daemon as metadata truth**: agtmux sync-v3 provides health, metadata, and observability, not session existence.
- **binding before spawning**: focus an existing live Ghostty binding before opening another terminal.
- **fail loudly**: permission, transport, binding, and host failures are surfaced explicitly.
- **no silent guessing**: no fuzzy rebinding, guessed host substitution, or implicit fallback that changes meaning.
- **control plane only**: the app owns bindings, restore state, diagnostics, and launch/focus automation.
- **tab/window first**: new Ghostty tab/window flows come before any pane-automation ambitions.
- **remote remains no-install**: richer remote workflows must not require remote sidecars by default.
