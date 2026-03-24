# Requirements

## Problem

The current repository still carries generic workbench complexity and a docs
story that drifted between session-first viewports and separate Ghostty
windows. That does not match the desired product: a normal embedded terminal
with a tmux and agent sidebar in the same app window.

## Goals

- make the embedded terminal the mainline UX
- keep the sidebar and the terminal together in one main window
- start in a plain shell by default
- let sidebar activation reuse or retarget the current terminal in place
- preserve Ghostty-quality terminal behavior through GhosttyKit/libghostty
- make restore state and diagnostics explicit app-owned concerns
- reduce generic workbench truth in the mainline product path

## Non-Goals

- making separate Ghostty app windows or tabs the mainline session UX
- making generic workbench / tile layout the user-facing source of truth
- opening a duplicate terminal by default when the current terminal can be reused
- making browser/document surfaces the primary session workflow
- requiring remote sidecars by default

## Acceptance

- [x] durable docs describe the terminal-first sidebar-overlay boundary
- [x] startup lands in a plain shell by default
- [x] session-row activation reuses or retargets the current terminal until the
      correct session target is visible
- [x] pane-row activation retargets the current terminal toward the exact pane
- [ ] attach, restore, and terminal/sidebar drift failures are surfaced clearly
- [x] generic workbench/browser/document paths are explicitly demoted from the
      mainline product story
