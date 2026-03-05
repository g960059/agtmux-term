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
9. linked session `status-left` / `set-titles-string` must preserve parent template intent (local or inherited global) and rewrite session-name token to `session_group`
10. titlebar sidebar-toggle icon (`sidebar.filter.toggle`) must always collapse/expand sidebar
11. a local tmux session created after app launch must appear in sidebar (session row + pane row)
12. local tmux socket override must be applied consistently to inventory, attach command, and control mode (`AGTMUX_TMUX_SOCKET_NAME` / `AGTMUX_TMUX_SOCKET`)
13. inherited `TMUX` must not hijack local socket targeting in UITest runs unless a test explicitly opts in
14. terminal-driven pane focus change must update sidebar selected-row within 2.0s
15. sidebar same-window pane switch must complete within 0.8s without `workspace.loading.*` and without creating an extra linked session
16. runner-side tmux preflight must distinguish `no server running` from true socket-inaccessible failures; skip理由は分類して明示する
17. live tmux UI tests should execute tmux commands via app-side UITest bridge (file command channel), not via runner shell
18. pane-ID suffix matching helpers must use `_ + sanitizedPaneID` (not `__ + ...`) so `%123` resolves to `...__123`

Accessibility contracts for E2E:

1. pane row AX identifier: `sidebar.pane.<source_session_pane>`
2. pane row AX value: `selected` / `unselected`
3. window row AX identifier: `sidebar.window.<source_session_window>`
4. session row AX identifier: `sidebar.session.<source_session>`

## Required rules for new tests

1. Never call raw `tmux new-session` directly in test bodies.
2. Always create sessions via `createTrackedTmuxSession(prefix:tmux:)`.
3. Use an `agtmux-e2e-...` prefix for test-created sessions.
4. Do not add custom teardown logic that bypasses `tearDownWithError`.
5. Live reflection tests (session/window/pane create/kill) must verify both appear and disappear paths.
6. Session DnD tests should prefer AGTMUX_JSON fixture mode for deterministic ordering.
7. Isolated tmux-socket tests must use `AGTMUX_TMUX_SOCKET_NAME` (tmux `-L`) and may `XCTSkip` only when sandbox constraints prevent keeping an isolated tmux session alive.
8. For live tmux tests, avoid default-socket assumptions in the runner when an explicit socket (`AGTMUX_TMUX_SOCKET_NAME` / `AGTMUX_TMUX_SOCKET`) is under test.
9. Tests that need to exercise inherited `TMUX` behavior must set:
   - `AGTMUX_UITEST_PRESERVE_TMUX=1`
   - explicit `TMUX` / `TMUX_PANE` in `app.launchEnvironment`
10. App-driven live tmux tests must set:
   - `AGTMUX_UITEST_TMUX_COMMAND_PATH`
   - `AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH`
   - `AGTMUX_UITEST_TMUX_RESULT_PATH` (when bootstrap scenario is used)
   - `AGTMUX_UITEST_TMUX_AUTO_CLEANUP=1` and `AGTMUX_UITEST_TMUX_KILL_SERVER=1` for isolated socket cleanup
11. UI tests should run inventory-only local fetch to avoid daemon metadata stalls:
   - `AGTMUX_UITEST_INVENTORY_ONLY=1`
12. `launchForUITest()` must include:
   - `-ApplePersistenceIgnoreState YES`
   - `-NSQuitAlwaysKeepsWindows NO`
   so AppKit state restoration does not block activation.

## Runtime Preconditions (macOS UI tests)

1. Tests require an interactive GUI login session (not locked / not at login window).
2. If Xcode reports `Failed to suppress screen saver (SACSetScreenSaverCanRun returned 22)`, treat run results as environment-invalid for activation-sensitive cases.
3. If failures show `Failed to activate application ... (current state: Running Background)`, first restore an active desktop session, then rerun before judging product logic.
4. Runner preflight skips when launched from SSH by default (`SSH_CONNECTION` present). To force-run from SSH, set `AGTMUX_UITEST_ALLOW_SSH=1`.
5. Runner preflight also skips when `CGSessionScreenIsLocked != 0` (or non-console / login incomplete). To force-run anyway, set `AGTMUX_UITEST_ALLOW_LOCKED_SESSION=1`.

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
