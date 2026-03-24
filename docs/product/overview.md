# Overview

`agtmux-term` is a session-first macOS tmux cockpit with a sidebar and an
embedded Ghostty terminal in one main window.

The sidebar shows local and remote tmux sessions plus daemon-backed status.
Clicking a session row reveals an existing terminal viewport in the main panel
first, or opens one there when none exists. The app keeps the sidebar and the
terminal together instead of bouncing the user into separate Ghostty app
windows.

tmux owns session truth, GhosttyKit/libghostty owns terminal behavior, and
agtmux-term owns the session inventory, selection, restore state, and
diagnostics around those embedded terminal surfaces.

The primary user is an AI-heavy macOS developer who runs multiple Claude Code,
Codex, or similar tmux sessions and wants to jump to the right session quickly
without giving up a sidebar-first cockpit or a native-feeling terminal.
