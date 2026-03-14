#!/bin/zsh
set -euo pipefail

zmodload zsh/datetime

: "${GATE_L_ROOT:?GATE_L_ROOT must be set by the caller}"

if [[ -z "${GATE_L_APP_BIN:-}" ]]; then
  GATE_L_APP_BIN="${AGTMUX_PERF_APP_BIN:-$GATE_L_ROOT/.build/arm64-apple-macosx/debug/AgtmuxTerm}"
fi

function gate_l_require_app_bin() {
  if [[ ! -x "$GATE_L_APP_BIN" ]]; then
    echo "Gate-L perf app binary is not executable: $GATE_L_APP_BIN" >&2
    return 1
  fi
}

function gate_l_read_plist_value() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

function gate_l_resolve_native_ghostty_app_path() {
  if [[ -d "/Applications/Ghostty.app" ]]; then
    print -r -- "/Applications/Ghostty.app"
    return 0
  fi

  local vendored_app="$GATE_L_ROOT/vendor/ghostty/zig-out/Ghostty.app"
  if [[ -d "$vendored_app" ]]; then
    print -r -- "$vendored_app"
    return 0
  fi

  local xcodebuild_app="$GATE_L_ROOT/vendor/ghostty/macos/build/Debug/Ghostty.app"
  if [[ -d "$xcodebuild_app" ]]; then
    print -r -- "$xcodebuild_app"
    return 0
  fi

  local spotlight_hit=""
  spotlight_hit="$(mdfind 'kMDItemCFBundleIdentifier == "com.mitchellh.ghostty" || kMDItemCFBundleIdentifier == "com.mitchellh.ghostty.debug"' | head -n 1)"
  if [[ -n "$spotlight_hit" && -d "$spotlight_hit" ]]; then
    print -r -- "$spotlight_hit"
    return 0
  fi

  return 1
}

function gate_l_setup_paths() {
  local token="$1"

  gate_l_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/agtmux-gate-l-${token}.XXXXXX")"
  mkdir -p "$HOME/.agt"

  gate_l_command_path="$gate_l_tmpdir/tmux-command.json"
  gate_l_command_result_path="$gate_l_tmpdir/tmux-command-result.json"
  gate_l_bootstrap_result_path="$gate_l_tmpdir/tmux-bootstrap-result.json"
  gate_l_managed_daemon_stderr_path="$gate_l_tmpdir/managed-daemon.stderr.log"
  gate_l_app_stdout_path="$gate_l_tmpdir/app.stdout.log"
  gate_l_app_stderr_path="$gate_l_tmpdir/app.stderr.log"
  gate_l_daemon_socket_path="$HOME/.agt/perf-${token}.sock"
}

function gate_l_launch_app() {
  local socket_name="$1"
  local session_name="$2"
  local pane_count="${3:-1}"
  local shell_command="${4:-/bin/sleep 600}"
  local scenario_json

  gate_l_socket_name="$socket_name"
  scenario_json="$(jq -cn \
    --arg sessionName "$session_name" \
    --arg windowName "main" \
    --argjson paneCount "$pane_count" \
    --arg shellCommand "$shell_command" \
    '{sessionName:$sessionName, windowName:$windowName, paneCount:$paneCount, shellCommand:$shellCommand}')"

  env \
    AGTMUX_UITEST=1 \
    AGTMUX_UITEST_INVENTORY_ONLY=1 \
    AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES=1 \
    AGTMUX_TMUX_SOCKET_NAME="$socket_name" \
    AGTMUX_DAEMON_SOCKET_PATH="$gate_l_daemon_socket_path" \
    AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH="$gate_l_managed_daemon_stderr_path" \
    AGTMUX_UITEST_TMUX_CONFIG_PATH=/dev/null \
    AGTMUX_UITEST_TMUX_COMMAND_PATH="$gate_l_command_path" \
    AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH="$gate_l_command_result_path" \
    AGTMUX_UITEST_TMUX_RESULT_PATH="$gate_l_bootstrap_result_path" \
    AGTMUX_UITEST_TMUX_AUTO_CLEANUP=1 \
    AGTMUX_UITEST_TMUX_KILL_SERVER=1 \
    AGTMUX_UITEST_TMUX_SCENARIO="$scenario_json" \
    TMUX= \
    TMUX_PANE= \
    "$GATE_L_APP_BIN" \
    -ApplePersistenceIgnoreState YES \
    -NSQuitAlwaysKeepsWindows NO \
    >"$gate_l_app_stdout_path" \
    2>"$gate_l_app_stderr_path" &

  gate_l_app_pid=$!
}

function gate_l_activate_app() {
  osascript -e 'tell application id "com.g960059.agtmux.term" to activate' >/dev/null
}

function gate_l_wait_for_bootstrap() {
  local timeout="${1:-15}"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if [[ -s "$gate_l_bootstrap_result_path" ]]; then
      cat "$gate_l_bootstrap_result_path"
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for app-side tmux bootstrap result" >&2
  return 1
}

function gate_l_send_bridge_command() {
  local refresh="$1"
  local timeout="$2"
  shift 2

  local request_id
  request_id="$(uuidgen)"

  rm -f "$gate_l_command_path" "$gate_l_command_result_path"
  jq -n \
    --arg id "$request_id" \
    --argjson refresh "$refresh" \
    '{id:$id, args:$ARGS.positional, refreshInventory:$refresh}' \
    --args -- "$@" \
    >"$gate_l_command_path"

  local deadline=$((EPOCHREALTIME + timeout))
  while (( EPOCHREALTIME < deadline )); do
    if [[ -s "$gate_l_command_result_path" ]]; then
      local response_id
      response_id="$(jq -r '.id // empty' "$gate_l_command_result_path")"
      if [[ "$response_id" == "$request_id" ]]; then
        local ok
        ok="$(jq -r '.ok' "$gate_l_command_result_path")"
        if [[ "$ok" == "true" ]]; then
          jq -r '.stdout' "$gate_l_command_result_path"
          return 0
        fi

        local error_message
        error_message="$(jq -r '.error // "unknown error"' "$gate_l_command_result_path")"
        echo "App-side tmux command failed: $error_message" >&2
        return 1
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for app-side tmux command result: $*" >&2
  return 1
}

function gate_l_wait_for_active_target() {
  local session_name="$1"
  local window_id="$2"
  local pane_id="$3"
  local timeout="${4:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local last_error=""

  while (( EPOCHREALTIME < deadline )); do
    local output
    if output="$(gate_l_send_bridge_command false 2 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/active-target.last-error.log")"; then
      local got_session got_window got_pane selected_window selected_pane
      got_session="$(jq -r '.sessionName' <<<"$output")"
      got_window="$(jq -r '.renderedClientWindowID' <<<"$output")"
      got_pane="$(jq -r '.renderedClientPaneID' <<<"$output")"
      selected_window="$(jq -r '.windowID' <<<"$output")"
      selected_pane="$(jq -r '.paneID' <<<"$output")"
      if [[ "$got_session" == "$session_name" \
         && "$got_window" == "$window_id" \
         && "$got_pane" == "$pane_id" \
         && "$selected_window" == "$window_id" \
         && "$selected_pane" == "$pane_id" ]]; then
        print -r -- "$output"
        return 0
      fi
      last_error="unexpected rendered target: session=$got_session rendered_window=$got_window rendered_pane=$got_pane selected_window=$selected_window selected_pane=$selected_pane"
    elif [[ -s "$gate_l_tmpdir/active-target.last-error.log" ]]; then
      last_error="$(<"$gate_l_tmpdir/active-target.last-error.log")"
    fi
    sleep 0.05
  done

  echo "Timed out waiting for active target $session_name $window_id $pane_id" >&2
  if [[ -n "$last_error" ]]; then
    echo "$last_error" >&2
  fi
  return 1
}

function gate_l_wait_for_active_snapshot() {
  local session_name="$1"
  local timeout="${2:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local last_error=""

  while (( EPOCHREALTIME < deadline )); do
    local output
    if output="$(gate_l_send_bridge_command false 2 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/active-target.last-error.log")"; then
      local got_session rendered_pane
      got_session="$(jq -r '.sessionName' <<<"$output")"
      rendered_pane="$(jq -r '.renderedClientPaneID // empty' <<<"$output")"
      if [[ "$got_session" == "$session_name" && -n "$rendered_pane" ]]; then
        print -r -- "$output"
        return 0
      fi
      last_error="unexpected active snapshot for session=$got_session rendered_pane=$rendered_pane"
    elif [[ -s "$gate_l_tmpdir/active-target.last-error.log" ]]; then
      last_error="$(<"$gate_l_tmpdir/active-target.last-error.log")"
    fi
    sleep 0.05
  done

  echo "Timed out waiting for any active snapshot for session $session_name" >&2
  if [[ -n "$last_error" ]]; then
    echo "$last_error" >&2
  fi
  return 1
}

function gate_l_terminate_app() {
  if [[ -n "${gate_l_app_pid:-}" ]] && kill -0 "$gate_l_app_pid" 2>/dev/null; then
    kill "$gate_l_app_pid" 2>/dev/null || true
    local deadline=$((EPOCHREALTIME + 5))
    while (( EPOCHREALTIME < deadline )); do
      if ! kill -0 "$gate_l_app_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$gate_l_app_pid" 2>/dev/null; then
      kill -9 "$gate_l_app_pid" 2>/dev/null || true
    fi
  fi
}

function gate_l_cleanup_tmux() {
  if [[ -n "${gate_l_socket_name:-}" ]]; then
    tmux -L "$gate_l_socket_name" kill-server >/dev/null 2>&1 || true
  fi
}
