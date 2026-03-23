#!/bin/zsh
set -euo pipefail
set +x 2>/dev/null || true

zmodload zsh/datetime

: "${GATE_L_ROOT:?GATE_L_ROOT must be set by the caller}"

if [[ -z "${GATE_L_APP_BIN:-}" ]]; then
  GATE_L_APP_BIN="${AGTMUX_PERF_APP_BIN:-$GATE_L_ROOT/.build/arm64-apple-macosx/debug/AgtmuxTerm}"
fi

gate_l_bridge_defaults_active=0

function gate_l_app_bundle_path() {
  if [[ "$GATE_L_APP_BIN" == *.app/Contents/MacOS/* ]]; then
    print -r -- "${GATE_L_APP_BIN%/Contents/MacOS/*}"
    return 0
  fi
  return 1
}

function gate_l_configure_bridge_defaults() {
  defaults write com.g960059.agtmux.term UITestBridgeEnabled -bool true
  defaults write com.g960059.agtmux.term UITestBridgeDebugEnabled -bool true
  defaults write com.g960059.agtmux.term UITestBridgeDebugLogPath -string "$gate_l_tmpdir/bridge-debug.log"
  defaults write com.g960059.agtmux.term UITestTmuxCommandPath -string "$gate_l_command_path"
  defaults write com.g960059.agtmux.term UITestTmuxCommandResultPath -string "$gate_l_command_result_path"
  defaults write com.g960059.agtmux.term UITestTmuxResultPath -string "$gate_l_bootstrap_result_path"
  if [[ -n "${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS:-}" ]]; then
    defaults write com.g960059.agtmux.term UITestTerminalViewRegistrationTimeoutMS -int "${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS}"
  fi
  if [[ -n "${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK:-}" ]]; then
    if [[ "${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK}" == "1" ]]; then
      defaults write com.g960059.agtmux.term UITestAllowSessionOnlyOpenFallback -bool true
    else
      defaults write com.g960059.agtmux.term UITestAllowSessionOnlyOpenFallback -bool false
    fi
  fi
  killall cfprefsd >/dev/null 2>&1 || true
  sleep 0.2
  gate_l_bridge_defaults_active=1
}

function gate_l_clear_bridge_defaults() {
  defaults delete com.g960059.agtmux.term UITestBridgeEnabled >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestBridgeDebugEnabled >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestBridgeDebugLogPath >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestTmuxCommandPath >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestTmuxCommandResultPath >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestTmuxResultPath >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestTerminalViewRegistrationTimeoutMS >/dev/null 2>&1 || true
  defaults delete com.g960059.agtmux.term UITestAllowSessionOnlyOpenFallback >/dev/null 2>&1 || true
  gate_l_bridge_defaults_active=0
}

function gate_l_launch_app_via_bundle() {
  local app_bundle=""
  app_bundle="$(gate_l_app_bundle_path)" || {
    echo "Cannot derive app bundle path from GATE_L_APP_BIN: $GATE_L_APP_BIN" >&2
    return 1
  }

  local app_exec="$GATE_L_APP_BIN"
  local before after new_pid
  pkill -f "$app_exec" >/dev/null 2>&1 || true
  local kill_deadline=$((EPOCHREALTIME + 5))
  while (( EPOCHREALTIME < kill_deadline )); do
    if ! pgrep -f "$app_exec" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  before="$(pgrep -f "$app_exec" || true)"
  open -na "$app_bundle" >/dev/null

  local deadline=$((EPOCHREALTIME + 15))
  while (( EPOCHREALTIME < deadline )); do
    after="$(pgrep -f "$app_exec" || true)"
    new_pid="$(comm -13 <(printf '%s\n' $before | sed '/^$/d' | sort -n) <(printf '%s\n' $after | sed '/^$/d' | sort -n) | tail -n 1)"
    if [[ -n "$new_pid" ]]; then
      gate_l_app_pid="$new_pid"
      return 0
    fi
    sleep 0.1
  done

  echo "Timed out waiting for app bundle launch: $app_bundle" >&2
  return 1
}

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
  gate_l_tmux_socket_path=""
  gate_l_socket_name=""
  gate_l_session_name=""

  gate_l_command_path="$gate_l_tmpdir/tmux-command.json"
  gate_l_command_result_path="$gate_l_tmpdir/tmux-command-result.json"
  gate_l_bootstrap_result_path="$gate_l_tmpdir/tmux-bootstrap-result.json"
  gate_l_managed_daemon_stderr_path="$gate_l_tmpdir/managed-daemon.stderr.log"
  gate_l_app_stdout_path="$gate_l_tmpdir/app.stdout.log"
  gate_l_app_stderr_path="$gate_l_tmpdir/app.stderr.log"
  gate_l_daemon_socket_path="${AGTMUX_PERF_DAEMON_SOCKET_PATH_OVERRIDE:-$HOME/.agt/perf-${token}.sock}"
}

function gate_l_cleanup_stale_perf_processes() {
  local kill_pattern_new='tmux -f /dev/null -L agtmux-gate-l-[^ ]* new-session -d -s agtmux-gate-l-'
  local kill_pattern_attach='tmux -f /dev/null -L agtmux-gate-l-[^ ]* -C attach-session -t agtmux-gate-l-'
  local stale_sockets=()
  local discovered_socket_name=""
  while IFS= read -r discovered_socket_name; do
    [[ -n "$discovered_socket_name" ]] || continue
    stale_sockets+=("$discovered_socket_name")
  done < <(
    ps -ax -o command= | sed -n 's#.*tmux -f /dev/null -L \(agtmux-gate-l-[^ ]*\) new-session.*#\1#p' | sort -u
  )

  # Kill stale tmux client/server processes first so later tmux control commands
  # do not block forever on orphaned control-mode clients.
  pkill -f "$kill_pattern_attach" >/dev/null 2>&1 || true
  pkill -f "$kill_pattern_new" >/dev/null 2>&1 || true
  pkill -f 'less -R -N /var/folders/.*/agtmux-gate-l-' >/dev/null 2>&1 || true

  local stale_socket_name=""
  for stale_socket_name in "${stale_sockets[@]:-}"; do
    perl -e 'alarm shift @ARGV; exec @ARGV' 2 \
      tmux -f /dev/null -L "$stale_socket_name" kill-server >/dev/null 2>&1 || true
  done

  pkill -f 'AgtmuxTerm.app/Contents/MacOS/AgtmuxTerm -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO' >/dev/null 2>&1 || true
}

function gate_l_launch_app() {
  local socket_name="$1"
  local session_name="$2"
  local pane_count="${3:-1}"
  local shell_command="${4:-/bin/sleep 600}"
  local inventory_only="${AGTMUX_PERF_UITEST_INVENTORY_ONLY:-1}"
  local use_default_local_tmux="${AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX:-0}"
  local allow_default_local_tmux_scenario="${AGTMUX_PERF_ALLOW_DEFAULT_LOCAL_TMUX_SCENARIO:-0}"
  local terminal_host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-}"
  local disable_app_state_restore="${AGTMUX_PERF_DISABLE_APP_STATE_RESTORE:-1}"
  local scenario_json
  local -a tmux_socket_env host_mode_env extra_uitest_env

  if [[ "$use_default_local_tmux" == "1" && "$allow_default_local_tmux_scenario" != "1" ]]; then
    echo "Refusing to bootstrap a tmux scenario on the default local tmux server." >&2
    echo "Use gate_l_launch_app_via_bundle for loaded live-pane inspection, or set AGTMUX_PERF_ALLOW_DEFAULT_LOCAL_TMUX_SCENARIO=1 if you intentionally want a destructive default-server bootstrap." >&2
    return 1
  fi

  gate_l_socket_name="$socket_name"
  gate_l_session_name="$session_name"
  if [[ "$use_default_local_tmux" == "1" ]]; then
    tmux_socket_env=()
  else
    tmux_socket_env=(AGTMUX_TMUX_SOCKET_NAME="$socket_name")
  fi
  if [[ -n "$terminal_host_mode" ]]; then
    host_mode_env=(AGTMUX_TERMINAL_HOST_MODE="$terminal_host_mode")
  else
    host_mode_env=()
  fi
  extra_uitest_env=()
  if [[ -n "${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS:-}" ]]; then
    extra_uitest_env+=(
      AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS="${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS}"
    )
  fi
  if [[ -n "${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK:-}" ]]; then
    extra_uitest_env+=(
      AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK="${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK}"
    )
  fi
  scenario_json="$(jq -cn \
    --arg sessionName "$session_name" \
    --arg windowName "main" \
    --argjson paneCount "$pane_count" \
    --arg shellCommand "$shell_command" \
    '{sessionName:$sessionName, windowName:$windowName, paneCount:$paneCount, shellCommand:$shellCommand}')"

  gate_l_app_pid="$(
  env \
    AGTMUX_UITEST=1 \
    AGTMUX_UITEST_INVENTORY_ONLY="$inventory_only" \
    AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES=1 \
    AGTMUX_PERF_DISABLE_APP_STATE_RESTORE="$disable_app_state_restore" \
    "${tmux_socket_env[@]}" \
    "${host_mode_env[@]}" \
    "${extra_uitest_env[@]}" \
    AGTMUX_DAEMON_SOCKET_PATH="$gate_l_daemon_socket_path" \
    AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH="$gate_l_managed_daemon_stderr_path" \
    AGTMUX_UITEST_TMUX_CONFIG_PATH=/dev/null \
    AGTMUX_UITEST_TMUX_COMMAND_PATH="$gate_l_command_path" \
    AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH="$gate_l_command_result_path" \
    AGTMUX_UITEST_TMUX_RESULT_PATH="$gate_l_bootstrap_result_path" \
    AGTMUX_UITEST_TMUX_AUTO_CLEANUP=0 \
    AGTMUX_UITEST_TMUX_KILL_SERVER=0 \
    AGTMUX_UITEST_TMUX_SCENARIO="$scenario_json" \
    TMUX= \
    TMUX_PANE= \
    python3 - "$GATE_L_APP_BIN" "$gate_l_app_stdout_path" "$gate_l_app_stderr_path" <<'PY'
import os
import subprocess
import sys

app_bin, stdout_path, stderr_path = sys.argv[1:]
disable_app_state_restore = os.environ.get("AGTMUX_PERF_DISABLE_APP_STATE_RESTORE", "1") == "1"
argv = [app_bin]
if disable_app_state_restore:
    argv += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        argv,
        stdout=stdout,
        stderr=stderr,
        env=os.environ.copy(),
        start_new_session=True,
    )
print(process.pid)
PY
  )"
}

function gate_l_launch_app_without_bootstrap() {
  local socket_name="$1"
  local inventory_only="${2:-0}"
  local use_default_local_tmux="${AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX:-0}"
  local terminal_host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-}"
  local disable_app_state_restore="${AGTMUX_PERF_DISABLE_APP_STATE_RESTORE:-1}"
  local bridge_config_mode="${AGTMUX_PERF_BRIDGE_CONFIG_MODE:-env}"
  local -a tmux_socket_env host_mode_env extra_uitest_env

  gate_l_socket_name="$socket_name"
  if [[ "$use_default_local_tmux" == "1" ]]; then
    tmux_socket_env=()
    bridge_config_mode="defaults"
  else
    tmux_socket_env=(AGTMUX_TMUX_SOCKET_NAME="$socket_name")
  fi
  if [[ -n "$terminal_host_mode" ]]; then
    host_mode_env=(AGTMUX_TERMINAL_HOST_MODE="$terminal_host_mode")
  else
    host_mode_env=()
  fi
  extra_uitest_env=()
  if [[ -n "${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS:-}" ]]; then
    extra_uitest_env+=(
      AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS="${AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS}"
    )
  fi
  if [[ -n "${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK:-}" ]]; then
    extra_uitest_env+=(
      AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK="${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK}"
    )
  fi

  if [[ "$bridge_config_mode" == "defaults" ]]; then
    gate_l_configure_bridge_defaults
    gate_l_launch_app_via_bundle
    return 0
  fi

  gate_l_app_pid="$(
  env \
    AGTMUX_UITEST=1 \
    AGTMUX_UITEST_INVENTORY_ONLY="$inventory_only" \
    AGTMUX_UITEST_ENABLE_GHOSTTY_SURFACES=1 \
    AGTMUX_PERF_DISABLE_APP_STATE_RESTORE="$disable_app_state_restore" \
    "${tmux_socket_env[@]}" \
    "${host_mode_env[@]}" \
    "${extra_uitest_env[@]}" \
    AGTMUX_DAEMON_SOCKET_PATH="$gate_l_daemon_socket_path" \
    AGTMUX_UITEST_MANAGED_DAEMON_STDERR_PATH="$gate_l_managed_daemon_stderr_path" \
    AGTMUX_UITEST_TMUX_CONFIG_PATH=/dev/null \
    AGTMUX_UITEST_TMUX_COMMAND_PATH="$gate_l_command_path" \
    AGTMUX_UITEST_TMUX_COMMAND_RESULT_PATH="$gate_l_command_result_path" \
    AGTMUX_UITEST_TMUX_RESULT_PATH="$gate_l_bootstrap_result_path" \
    AGTMUX_UITEST_TMUX_AUTO_CLEANUP=0 \
    AGTMUX_UITEST_TMUX_KILL_SERVER=0 \
    TMUX= \
    TMUX_PANE= \
    python3 - "$GATE_L_APP_BIN" "$gate_l_app_stdout_path" "$gate_l_app_stderr_path" <<'PY'
import os
import subprocess
import sys

app_bin, stdout_path, stderr_path = sys.argv[1:]
disable_app_state_restore = os.environ.get("AGTMUX_PERF_DISABLE_APP_STATE_RESTORE", "1") == "1"
argv = [app_bin]
if disable_app_state_restore:
    argv += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        argv,
        stdout=stdout,
        stderr=stderr,
        env=os.environ.copy(),
        start_new_session=True,
    )
print(process.pid)
PY
  )"
}

function gate_l_activate_app() {
  if [[ -n "${gate_l_app_pid:-}" ]]; then
    if "$GATE_L_ROOT/scripts/perf/gate_l_ax_key_sender.sh" --app-pid "$gate_l_app_pid" --activate-app >/dev/null 2>&1; then
      return 0
    fi
  fi
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

function gate_l_record_bootstrap_tmux_socket_path() {
  local bootstrap_json="$1"
  local socket_path=""
  socket_path="$(jq -r '.socketPath // empty' <<<"$bootstrap_json")"
  if [[ -n "$socket_path" && "$socket_path" != "null" ]]; then
    gate_l_tmux_socket_path="$socket_path"
  fi
}

function gate_l_expected_named_socket_path() {
  print -r -- "/private/tmp/tmux-$(id -u)/${gate_l_socket_name}"
}

function gate_l_has_isolated_tmux_socket() {
  [[ -n "${gate_l_tmux_socket_path:-}" && "$gate_l_tmux_socket_path" == "$(gate_l_expected_named_socket_path)" ]]
}

function gate_l_tmux() {
  if [[ -n "${gate_l_tmux_socket_path:-}" ]]; then
    tmux -f /dev/null -S "$gate_l_tmux_socket_path" "$@"
  elif [[ -n "${gate_l_socket_name:-}" ]]; then
    tmux -f /dev/null -L "$gate_l_socket_name" "$@"
  else
    tmux -f /dev/null "$@"
  fi
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

function gate_l_send_bridge_json_command() {
  local output=""
  output="$(gate_l_send_bridge_command "$@")" || return 1

  if ! jq -e . >/dev/null 2>&1 <<<"$output"; then
    echo "App-side tmux command returned non-JSON stdout: $*" >&2
    if [[ -n "$output" ]]; then
      print -r -- "$output" >&2
    else
      echo "<empty stdout>" >&2
    fi
    return 1
  fi

  print -r -- "$output"
}

function gate_l_start_async_bridge_command() {
  local refresh="$1"
  shift

  local request_id
  request_id="$(uuidgen)"

  rm -f "$gate_l_command_path" "$gate_l_command_result_path"
  jq -n \
    --arg id "$request_id" \
    --argjson refresh "$refresh" \
    '{id:$id, args:$ARGS.positional, refreshInventory:$refresh}' \
    --args -- "$@" \
    >"$gate_l_command_path"

  print -r -- "$request_id"
}

function gate_l_wait_for_async_bridge_json_result() {
  local request_id="$1"
  local timeout="$2"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if [[ -s "$gate_l_command_result_path" ]]; then
      local response_id
      response_id="$(jq -r '.id // empty' "$gate_l_command_result_path" 2>/dev/null || true)"
      if [[ "$response_id" == "$request_id" ]]; then
        local ok
        ok="$(jq -r '.ok' "$gate_l_command_result_path")"
        if [[ "$ok" == "true" ]]; then
          local output
          output="$(jq -r '.stdout' "$gate_l_command_result_path")"
          if ! jq -e . >/dev/null 2>&1 <<<"$output"; then
            echo "App-side tmux command returned non-JSON stdout for request $request_id" >&2
            if [[ -n "$output" ]]; then
              print -r -- "$output" >&2
            else
              echo "<empty stdout>" >&2
            fi
            return 1
          fi
          print -r -- "$output"
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

  echo "Timed out waiting for app-side tmux command result: $request_id" >&2
  return 1
}

function gate_l_wait_for_bridge_ready() {
  local timeout="${1:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local last_error=""

  while (( EPOCHREALTIME < deadline )); do
    if gate_l_send_bridge_command false 2 "__agtmux_tmux_bridge_ready__" >/dev/null 2>"$gate_l_tmpdir/bridge-ready.last-error.log"; then
      return 0
    fi
    if [[ -s "$gate_l_tmpdir/bridge-ready.last-error.log" ]]; then
      last_error="$(<"$gate_l_tmpdir/bridge-ready.last-error.log")"
    fi
    sleep 0.05
  done

  echo "Timed out waiting for UITest bridge readiness" >&2
  if [[ -n "$last_error" ]]; then
    echo "$last_error" >&2
  fi
  return 1
}

function gate_l_wait_for_active_target() {
  local session_name="$1"
  local window_id="$2"
  local pane_id="$3"
  local timeout="${4:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local last_error=""
  local last_output=""

  while (( EPOCHREALTIME < deadline )); do
    local output
    if output="$(gate_l_send_bridge_json_command false 2 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/active-target.last-error.log")"; then
      last_output="$output"
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
  if [[ -n "$last_output" ]]; then
    echo "Last active-target snapshot: $last_output" >&2

    local rendered_client_tty tile_id
    rendered_client_tty="$(jq -r '.renderedClientTTY // empty' <<<"$last_output")"
    tile_id="$(jq -r '.tileID // empty' <<<"$last_output")"

    if [[ -n "$rendered_client_tty" ]]; then
      local clients_output
      if clients_output="$(gate_l_send_bridge_command false 2 list-clients -F '#{client_tty}|#{session_name}|#{window_id}|#{pane_id}' 2>/dev/null)"; then
        echo "tmux list-clients: $clients_output" >&2
      fi
    fi

    if [[ -n "$tile_id" ]]; then
      local focus_output
      if focus_output="$(gate_l_send_bridge_json_command false 2 "__agtmux_dump_focus_state__" "$tile_id" 2>/dev/null)"; then
        echo "Terminal focus snapshot: $focus_output" >&2
      fi
    fi
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
    if output="$(gate_l_send_bridge_json_command false 2 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/active-target.last-error.log")"; then
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

function gate_l_wait_for_rendered_target() {
  local session_name="$1"
  local window_id="$2"
  local pane_id="$3"
  local timeout="${4:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local last_error=""
  local last_output=""

  while (( EPOCHREALTIME < deadline )); do
    local output
    if output="$(gate_l_send_bridge_json_command false 2 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/rendered-target.last-error.log")"; then
      last_output="$output"
      local got_session got_window got_pane
      got_session="$(jq -r '.sessionName' <<<"$output")"
      got_window="$(jq -r '.renderedClientWindowID' <<<"$output")"
      got_pane="$(jq -r '.renderedClientPaneID' <<<"$output")"
      if [[ "$got_session" == "$session_name" \
         && "$got_window" == "$window_id" \
         && "$got_pane" == "$pane_id" ]]; then
        print -r -- "$output"
        return 0
      fi
      last_error="unexpected rendered target: session=$got_session rendered_window=$got_window rendered_pane=$got_pane"
    elif [[ -s "$gate_l_tmpdir/rendered-target.last-error.log" ]]; then
      last_error="$(<"$gate_l_tmpdir/rendered-target.last-error.log")"
    fi
    sleep 0.05
  done

  echo "Timed out waiting for rendered target $session_name $window_id $pane_id" >&2
  if [[ -n "$last_error" ]]; then
    echo "$last_error" >&2
  fi
  if [[ -n "$last_output" ]]; then
    echo "Last rendered-target snapshot: $last_output" >&2
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
  if [[ "$gate_l_bridge_defaults_active" == "1" ]]; then
    gate_l_clear_bridge_defaults
  fi
}

function gate_l_cleanup_tmux() {
  if [[ -n "${gate_l_session_name:-}" ]] && gate_l_has_isolated_tmux_socket; then
    gate_l_tmux kill-session -t "$gate_l_session_name" >/dev/null 2>&1 || true
  elif [[ -n "${gate_l_tmux_socket_path:-}" ]]; then
    echo "Skipping tmux cleanup because benchmark resolved non-isolated socket: $gate_l_tmux_socket_path" >&2
  elif [[ -n "${gate_l_socket_name:-}" ]]; then
    tmux -f /dev/null -L "$gate_l_socket_name" kill-server >/dev/null 2>&1 || true
  fi
}
