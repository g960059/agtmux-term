# Plan

1. Rewrite durable product and decision docs around the session-first
   Ghostty-native control-plane model.
2. Model binding identity, storage, and stale-binding recovery.
3. Implement session-row activation as "focus existing binding first, else open
   new Ghostty tab/window".
4. Add diagnostics for Ghostty launch/focus failures and binding drift.
5. Retire or quarantine embedded-host and generic workbench flows from the
   mainline UX once the simpler model is working.
