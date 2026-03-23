# Overview

`agtmux-term` is a session-first macOS control plane for tmux users who want
native Ghostty behavior.

The sidebar shows local and remote tmux sessions plus daemon-backed status.
Clicking a session row focuses an existing Ghostty binding first, or opens a
new Ghostty tab/window when none exists. Outside those attached sessions,
Ghostty remains a normal terminal.

tmux owns session truth, Ghostty owns terminal runtime behavior, and
agtmux-term owns bindings, restore hints, diagnostics, and automation.

The primary user is an AI-heavy macOS developer who runs multiple Claude Code,
Codex, or similar tmux sessions in Ghostty and wants to jump to the right
terminal quickly, avoid duplicates, and recover from stale bindings or host
failures without learning an app-owned terminal model.
