#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-legacy}"
session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-vm agtmux-term}"
pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-20}"
prime_scroll_pixels="${AGTMUX_PERF_LIVE_PRIME_SCROLL_PIXELS:-10}"
prime_scroll_repeat="${AGTMUX_PERF_LIVE_PRIME_SCROLL_REPEAT:-24}"
prime_scroll_interval_ms="${AGTMUX_PERF_LIVE_PRIME_SCROLL_INTERVAL_MS:-8}"
prime_scroll_phase_mode="${AGTMUX_PERF_LIVE_PRIME_PHASE_MODE:-trackpad-burst-momentum}"
prime_settle_ms="${AGTMUX_PERF_LIVE_PRIME_SETTLE_MS:-220}"
prime_max_rounds="${AGTMUX_PERF_LIVE_PRIME_MAX_ROUNDS:-6}"
prime_min_rounds="${AGTMUX_PERF_LIVE_PRIME_MIN_ROUNDS:-1}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"

function extract_last_json_line() {
  local raw="$1"
  local json_line
  json_line="$(printf '%s\n' "$raw" | awk '/^[[:space:]]*[{[]/ { line = $0 } END { if (line != "") print line }')"
  if [[ -z "$json_line" ]] || ! jq -e . >/dev/null 2>&1 <<<"$json_line"; then
    echo "Failed to normalize JSON payload" >&2
    print -r -- "$raw" >&2
    return 1
  fi
  print -r -- "$json_line"
}

function sleep_ms() {
  local milliseconds="$1"
  sleep "$(awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
}

function sample_client_scroll_position() {
  local client_tty="$1"
  tmux display-message -p -c "$client_tty" '#{scroll_position}' 2>/dev/null | tr -d '\r\n'
}

function sample_client_pane_in_mode() {
  local client_tty="$1"
  tmux display-message -p -c "$client_tty" '#{pane_in_mode}' 2>/dev/null | tr -d '\r\n'
}

function sample_client_key_table() {
  local client_tty="$1"
  tmux display-message -p -c "$client_tty" '#{client_key_table}' 2>/dev/null | tr -d '\r\n'
}

function probe_client_scroll_command() {
  local client_tty="$1"
  local before_scroll_position
  local after_scroll_position
  local pane_in_mode
  local before_key_table
  local after_key_table

  before_scroll_position="$(sample_client_scroll_position "$client_tty")"
  pane_in_mode="$(sample_client_pane_in_mode "$client_tty")"
  before_key_table="$(sample_client_key_table "$client_tty")"

  tmux send-keys -c "$client_tty" PageUp >/dev/null 2>&1 || true
  sleep_ms 120

  after_scroll_position="$(sample_client_scroll_position "$client_tty")"
  after_key_table="$(sample_client_key_table "$client_tty")"

  jq -n \
    --arg client_tty "$client_tty" \
    --arg before_scroll_position "$before_scroll_position" \
    --arg after_scroll_position "$after_scroll_position" \
    --arg pane_in_mode "$pane_in_mode" \
    --arg before_key_table "$before_key_table" \
    --arg after_key_table "$after_key_table" \
    '{
      clientTTY: $client_tty,
      paneInMode: (if $pane_in_mode == "" then null else ($pane_in_mode | tonumber) end),
      beforeKeyTable: (if $before_key_table == "" then null else $before_key_table end),
      afterKeyTable: (if $after_key_table == "" then null else $after_key_table end),
      beforeScrollPosition: (if $before_scroll_position == "" then null else ($before_scroll_position | tonumber) end),
      afterScrollPosition: (if $after_scroll_position == "" then null else ($after_scroll_position | tonumber) end),
      moved: (
        if ($before_scroll_position == "" or $after_scroll_position == "") then
          false
        else
          (($after_scroll_position | tonumber) != ($before_scroll_position | tonumber))
        end
      )
    }'
}

function send_prime_scroll() {
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-front-window \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac" \
    --scroll-pixels "$prime_scroll_pixels" \
    --scroll-repeat "$prime_scroll_repeat" \
    --scroll-interval-ms "$prime_scroll_interval_ms" \
    --scroll-phase-mode "$prime_scroll_phase_mode" >/dev/null
}

function prepare_live_client() {
  local client_tty="$1"
  local previous_scroll_position=""
  local current_scroll_position
  local current_mode
  local current_key_table
  local round=0

  current_scroll_position="$(sample_client_scroll_position "$client_tty")"
  current_mode="$(sample_client_pane_in_mode "$client_tty")"
  current_key_table="$(sample_client_key_table "$client_tty")"

  if [[ -z "$current_scroll_position" || "$current_scroll_position" == "0" ]]; then
    tmux send-keys -c "$client_tty" PageUp >/dev/null 2>&1 || true
    sleep_ms "$prime_settle_ms"
    current_scroll_position="$(sample_client_scroll_position "$client_tty")"
    current_mode="$(sample_client_pane_in_mode "$client_tty")"
    current_key_table="$(sample_client_key_table "$client_tty")"
  fi

  while (( round < prime_max_rounds )); do
    if (( round >= prime_min_rounds )) && [[ "$current_mode" == "1" \
          && -n "$current_scroll_position" \
          && "$current_scroll_position" != "0" \
          && -n "$current_scroll_position" \
          && "$current_scroll_position" == "$previous_scroll_position" ]]; then
      return 0
    fi
    round=$((round + 1))
    previous_scroll_position="$current_scroll_position"
    send_prime_scroll
    sleep_ms "$prime_settle_ms"
    current_scroll_position="$(sample_client_scroll_position "$client_tty")"
    current_mode="$(sample_client_pane_in_mode "$client_tty")"
    current_key_table="$(sample_client_key_table "$client_tty")"
  done

  if [[ "$current_mode" != "1" || -z "$current_scroll_position" || "$current_scroll_position" == "0" ]]; then
    echo "Failed to prime live client into copy mode for host mode $host_mode: keyTable=$current_key_table mode=$current_mode scroll=$current_scroll_position" >&2
    return 1
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --host-mode)
      host_mode="$2"
      shift 2
      ;;
    --session-name)
      session_name="$2"
      shift 2
      ;;
    --pane-id)
      pane_id="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--host-mode legacy|next] [--session-name NAME] [--pane-id %id] [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$pane_id" ]]; then
  pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

if [[ -z "$pane_id" ]]; then
  echo "Failed to resolve pane id; pass --pane-id explicitly" >&2
  exit 1
fi

window_id="$(tmux display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null || true)"
if [[ -z "$window_id" ]]; then
  echo "Failed to resolve window id for pane $pane_id" >&2
  exit 1
fi

case "$host_mode" in
  legacy|next)
    ;;
  *)
    echo "Unsupported host mode: $host_mode" >&2
    exit 1
    ;;
esac

token="live-client-${host_mode}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
gate_l_setup_paths "$token"
export AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX=1
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0
export AGTMUX_PERF_TERMINAL_HOST_MODE="$host_mode"

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L terminal-host live client-scroll temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app_without_bootstrap "agtmux-gate-l-$token" 0
gate_l_wait_for_bridge_ready "$settle_timeout"
gate_l_activate_app

open_json_path="$gate_l_tmpdir/open-terminal.json"
active_json_path="$gate_l_tmpdir/active-target.json"
focus_json_path="$gate_l_tmpdir/focus-state.json"
bench_json_path="$gate_l_tmpdir/live-client-bench.json"
client_probe_json_path="$gate_l_tmpdir/client-command-probe.json"

open_json="$(
  extract_last_json_line "$(
    gate_l_send_bridge_json_command true "$settle_timeout" "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id"
  )"
)"
printf '%s\n' "$open_json" >"$open_json_path"

reported_host_mode="$(jq -r '.terminalHostMode // empty' <<<"$open_json")"
tile_id="$(jq -r '.tileID // empty' <<<"$open_json")"
if [[ -z "$tile_id" ]]; then
  echo "Failed to open pane $session_name $pane_id for host mode $host_mode: $open_json" >&2
  exit 1
fi
if [[ "$reported_host_mode" != "$host_mode" ]]; then
  echo "Opened pane with unexpected host mode: expected=$host_mode got=$reported_host_mode" >&2
  exit 1
fi

active_json="$(
  extract_last_json_line "$(
    gate_l_wait_for_active_target "$session_name" "$window_id" "$pane_id" "$settle_timeout"
  )"
)"
printf '%s\n' "$active_json" >"$active_json_path"

active_host_mode="$(jq -r '.terminalHostMode // empty' <<<"$active_json")"
rendered_client_tty="$(jq -r '.renderedClientTTY // empty' <<<"$active_json")"
if [[ -z "$rendered_client_tty" ]]; then
  echo "Failed to resolve rendered client tty for $session_name $pane_id ($host_mode)" >&2
  exit 1
fi
if [[ "$active_host_mode" != "$host_mode" ]]; then
  echo "Active target reported unexpected host mode: expected=$host_mode got=$active_host_mode" >&2
  exit 1
fi

terminal_ax_identifier="workspace.terminalHost.${tile_id}"
if focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/focus-state.last-error.log")"; then
  printf '%s\n' "$focus_json" >"$focus_json_path"
  focus_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_json")"
  if [[ -n "$focus_identifier" ]]; then
    terminal_ax_identifier="$focus_identifier"
  fi
else
  printf '%s\n' '{"terminalAccessibilityIdentifier":null}' >"$focus_json_path"
fi

prepare_live_client "$rendered_client_tty"

"$SCRIPT_DIR/gate_l_frontmost_live_client_scroll_bench.sh" \
  --app-pid "$gate_l_app_pid" \
  --client-tty "$rendered_client_tty" \
  --label "$host_mode" \
  --scroll-identifier "$terminal_ax_identifier" >"$bench_json_path"

probe_client_scroll_command "$rendered_client_tty" >"$client_probe_json_path"

jq -n \
  --arg host_mode "$host_mode" \
  --arg session_name "$session_name" \
  --arg pane_id "$pane_id" \
  --arg window_id "$window_id" \
  --arg app_pid "$gate_l_app_pid" \
  --arg tmpdir "$gate_l_tmpdir" \
  --slurpfile open "$open_json_path" \
  --slurpfile active "$active_json_path" \
  --slurpfile focus "$focus_json_path" \
  --slurpfile bench "$bench_json_path" \
  --slurpfile clientProbe "$client_probe_json_path" \
  '{
    hostMode: $host_mode,
    sessionName: $session_name,
    paneID: $pane_id,
    windowID: $window_id,
    appPID: ($app_pid | tonumber),
    tmpdir: $tmpdir,
    open: $open[0],
    activeTarget: $active[0],
    focusState: $focus[0],
    bench: $bench[0],
    clientCommandProbe: $clientProbe[0]
  }'
