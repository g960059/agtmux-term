# Requirements

## Problem

The current repository still carries generic workbench complexity and a docs
story that drifted toward separate Ghostty windows. That does not match the
desired product: a session-first sidebar with the terminal kept in the same app
window.

## Goals

- make the sidebar the mainline session-first UX
- keep the sidebar and the terminal together in one main window
- reveal an existing embedded session viewport before opening a duplicate
- open or retarget a main-panel terminal viewport when a session is not visible
- preserve Ghostty-quality terminal behavior through GhosttyKit/libghostty
- make restore state and diagnostics explicit app-owned concerns
- reduce generic workbench truth in the mainline product path

## Non-Goals

- making separate Ghostty app windows or tabs the mainline session UX
- making generic workbench / tile layout the user-facing source of truth
- opening a duplicate terminal by default when a session is already visible
- making browser/document surfaces the primary session workflow
- requiring remote sidecars by default

## Acceptance

- [x] durable docs describe the session-first embedded Ghostty host boundary
- [ ] session-row activation reveals an existing embedded session viewport first
- [ ] session-row activation otherwise opens or retargets a main-panel terminal
      viewport with the correct attach target
- [ ] attach, restore, and session/viewport drift failures are surfaced clearly
- [ ] generic workbench/browser/document paths are explicitly demoted from the
      mainline product story
