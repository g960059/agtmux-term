# AgtmuxTermUITests Cleanup Contract

## Goal

E2E tests must leave **zero residue** after each test:

1. tmux sessions created by tests
2. agent processes inside those sessions (Codex / Claude / shells started by them)
3. linked session UX contracts (for example, linked session titles) must be verified via explicit E2E cases when changed

Title consistency contracts:

1. user-facing tab title should track selected pane/session context
2. internal linked session names (`agtmux-linked-*`) must not leak into user-facing titles
3. sidebar pane identity must be `source + session + pane` (not only `pane`) to avoid alias collisions
4. session-group aliases that expose the same pane must collapse to a single sidebar row
5. main-panel pane focus changes must sync back to sidebar selected-row highlight
6. sidebar pane-row click path must enable the same focus-sync behavior (not only context-menu window open)
7. opening one tmux window must produce exactly one workspace tile (single-surface contract)
8. focus-sync monitoring must continue even if the original parent session is gone (linked-session runtime is authoritative)

Accessibility contracts for E2E:

1. pane row AX identifier: `sidebar.pane.<source_session_pane>`
2. pane row AX value: `selected` / `unselected`
3. window row AX identifier: `sidebar.window.<source_session_window>`

## Required rules for new tests

1. Never call raw `tmux new-session` directly in test bodies.
2. Always create sessions via `createTrackedTmuxSession(prefix:tmux:)`.
3. Use an `agtmux-e2e-...` prefix for test-created sessions.
4. Do not add custom teardown logic that bypasses `tearDownWithError`.

## Current teardown behavior (authoritative)

`AgtmuxTermUITests.tearDownWithError` performs:

1. terminate app process
2. agent cleanup for test-owned sessions:
   - `tmux send-keys C-c`, `C-c`, `exit`
   - TTY/process-group/process-tree termination:
     - `pkill -t <pane_tty>`
     - `kill -- -<pgid>`
     - `pkill -P <pane_pid>` / `kill <pane_pid>`
     (`TERM` then `KILL`)
3. tmux cleanup:
   - kill all sessions in `(currentSessions - preExistingSessions) ∪ ownedSessions`
4. leak gate:
   - re-list sessions and fail test if any non-preexisting session remains

If a new E2E test needs tmux resources, the only supported path is the tracked-session helper.
