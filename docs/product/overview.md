# Overview

`agtmux-term` is a terminal-first macOS tmux cockpit with an embedded Ghostty
terminal and a tmux/agent sidebar in one main window.

The main panel is a normal terminal first. It starts in a plain shell by
default. The sidebar shows local and remote tmux sessions, and clicking a
session or pane retargets that current terminal in place. When the local
metadata lane is enabled, the sidebar also shows daemon-backed agent status.

tmux owns session truth, GhosttyKit/libghostty owns terminal behavior, and
agtmux-term owns the sidebar inventory, selection, restore state, and
diagnostics around that embedded terminal.

The primary user is an AI-heavy macOS developer who runs multiple Claude Code,
Codex, or similar tmux sessions and wants to jump to the right session quickly
without giving up a native-feeling terminal.
