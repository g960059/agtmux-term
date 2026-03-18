# Principles

- **tmux truth first**: tmux and SSH define session existence; the app does not.
- **Ghostty authority**: rendering, input, IME, and runtime terminal behavior belong to Ghostty.
- **daemon as metadata truth**: agtmux sync-v3 provides health, metadata, and observability, not session existence.
- **fail loudly**: permission, transport, binding, and host failures are surfaced explicitly.
- **no silent guessing**: no fuzzy rebinding, guessed host substitution, or implicit fallback that changes meaning.
- **lightweight control plane**: the app owns bindings, restore state, diagnostics, and companion surfaces, not a second terminal runtime.
- **remote remains no-install**: richer remote workflows must not require remote sidecars by default.
