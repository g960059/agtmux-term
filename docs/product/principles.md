# Principles

- **session-first UX**: the main thing the app shows and acts on is a tmux session.
- **one main window**: the sidebar and the terminal stay together in the app's main panel.
- **tmux truth first**: tmux and SSH define session existence; the app does not.
- **Ghostty engine authority**: rendering, input, IME, and terminal semantics come from GhosttyKit/libghostty, not app-authored terminal code.
- **daemon as metadata truth**: agtmux sync-v3 provides health, metadata, and observability, not session existence.
- **reveal before spawn**: reveal an existing embedded session viewport before opening another one.
- **fail loudly**: permission, transport, binding, and host failures are surfaced explicitly.
- **no silent guessing**: no fuzzy rebinding, guessed host substitution, or implicit fallback that changes meaning.
- **thin host, not generic workspace truth**: the app hosts Ghostty surfaces, but generic workbench/tile state is not the mainline product model.
- **session viewport first**: the main panel is for session terminals first; browser/document companions are secondary or migration-only.
- **remote remains no-install**: richer remote workflows must not require remote sidecars by default.
