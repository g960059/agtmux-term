# AgtmuxTermUITests Cleanup Contract

## Goal

E2E tests must leave **zero residue** after each test:

1. tmux sessions created by tests
2. agent processes inside those sessions (Codex / Claude / shells started by them)

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
