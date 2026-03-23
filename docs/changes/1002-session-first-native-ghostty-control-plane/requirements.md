# Requirements

## Problem

The current repository still carries app-owned terminal and workbench
complexity that does not match the desired user model. Users want normal
Ghostty behavior plus a strong tmux session control plane, not a second
terminal runtime inside the app.

## Goals

- make the sidebar the mainline session-first UX
- focus an existing Ghostty binding before opening a duplicate terminal
- open a new Ghostty tab or window when a session has no live binding
- keep Ghostty fully normal outside tmux-attached flows
- make bindings, restore hints, and diagnostics explicit app-owned concerns
- defer Ghostty pane automation until the simpler model is proven reliable

## Non-Goals

- preserving app-owned terminal hosting as the mainline product path
- making generic workbench / tile layout the user-facing source of truth
- opening a new terminal by default when a live binding already exists
- implementing new Ghostty pane creation in the first wave
- requiring remote sidecars by default

## Acceptance

- [x] durable docs describe the session-first Ghostty-native control-plane
      boundary
- [ ] session-row activation focuses an existing live Ghostty binding first
- [ ] session-row activation otherwise opens a new Ghostty tab or window with
      the correct attach command
- [ ] stale-binding and launch/focus failures are surfaced clearly
- [ ] first-wave scope explicitly excludes new Ghostty pane creation
