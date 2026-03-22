#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"

host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-legacy}"
session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-vm agtmux-term}"
pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-}"
pane_title_contains="${AGTMUX_PERF_LIVE_PANE_TITLE_CONTAINS:-}"
pane_command="${AGTMUX_PERF_LIVE_PANE_COMMAND:-}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-20}"
prime_scroll_pixels="${AGTMUX_PERF_LIVE_PRIME_SCROLL_PIXELS:-10}"
prime_scroll_repeat="${AGTMUX_PERF_LIVE_PRIME_SCROLL_REPEAT:-24}"
prime_scroll_interval_ms="${AGTMUX_PERF_LIVE_PRIME_SCROLL_INTERVAL_MS:-8}"
prime_scroll_phase_mode="${AGTMUX_PERF_LIVE_PRIME_PHASE_MODE:-trackpad-burst-momentum}"
prime_settle_ms="${AGTMUX_PERF_LIVE_PRIME_SETTLE_MS:-220}"
prime_max_rounds="${AGTMUX_PERF_LIVE_PRIME_MAX_ROUNDS:-6}"
prime_min_rounds="${AGTMUX_PERF_LIVE_PRIME_MIN_ROUNDS:-1}"
events_per_burst="${AGTMUX_PERF_UPSTEP_EVENTS_PER_BURST:-24}"
scroll_interval_ms="${AGTMUX_PERF_UPSTEP_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_INTERVAL_MS:-16}"
sample_tail_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-180}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"
use_scroll_identifier="${AGTMUX_PERF_LIVE_USE_SCROLL_IDENTIFIER:-1}"

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

function live_tmux() {
  env -u TMUX -u TMUX_PANE tmux "$@"
}

function sample_client_scroll_position() {
  local client_tty="$1"
  live_tmux display-message -p -c "$client_tty" '#{scroll_position}' 2>/dev/null | tr -d '\r\n'
}

function sample_client_pane_in_mode() {
  local client_tty="$1"
  live_tmux display-message -p -c "$client_tty" '#{pane_in_mode}' 2>/dev/null | tr -d '\r\n'
}

function sample_client_key_table() {
  local client_tty="$1"
  live_tmux display-message -p -c "$client_tty" '#{client_key_table}' 2>/dev/null | tr -d '\r\n'
}

function resolve_live_pane_target() {
  local session_name="$1"
  local requested_pane_id="$2"
  local pane_line=""

  if [[ -n "$requested_pane_id" ]]; then
    pane_line="$(live_tmux display-message -p -t "$requested_pane_id" '#{session_name}|#{pane_id}|#{window_id}|#{pane_active}|#{pane_current_command}|#{pane_title}' 2>/dev/null || true)"
    if [[ -n "$pane_line" && "${pane_line%%|*}" == "$session_name" ]]; then
      printf '%s\n' "$pane_line|requested"
      return 0
    fi
  fi

  while IFS= read -r pane_line; do
    if [[ -n "$pane_title_contains" ]]; then
      local title
      title="${pane_line##*|}"
      if [[ "$title" == *"$pane_title_contains"* ]]; then
        printf '%s\n' "$pane_line|title-match"
        return 0
      fi
    fi
  done < <(live_tmux list-panes -t "$session_name" -F '#{session_name}|#{pane_id}|#{window_id}|#{pane_active}|#{pane_current_command}|#{pane_title}' 2>/dev/null || true)

  while IFS= read -r pane_line; do
    if [[ -n "$pane_command" ]]; then
      local command
      command="$(printf '%s' "$pane_line" | awk -F'|' '{print $5}')"
      if [[ "$command" == "$pane_command" ]]; then
        printf '%s\n' "$pane_line|command-match"
        return 0
      fi
    fi
  done < <(live_tmux list-panes -t "$session_name" -F '#{session_name}|#{pane_id}|#{window_id}|#{pane_active}|#{pane_current_command}|#{pane_title}' 2>/dev/null || true)

  pane_line="$(live_tmux list-panes -t "$session_name" -F '#{session_name}|#{pane_id}|#{window_id}|#{pane_active}|#{pane_current_command}|#{pane_title}' 2>/dev/null | awk -F'|' '$4 == "1" { print; exit }')"
  if [[ -n "$pane_line" ]]; then
    printf '%s\n' "$pane_line|active-fallback"
    return 0
  fi

  pane_line="$(live_tmux list-panes -t "$session_name" -F '#{session_name}|#{pane_id}|#{window_id}|#{pane_active}|#{pane_current_command}|#{pane_title}' 2>/dev/null | head -n 1)"
  if [[ -n "$pane_line" ]]; then
    printf '%s\n' "$pane_line|first-pane-fallback"
    return 0
  fi

  return 1
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

  live_tmux send-keys -c "$client_tty" PageUp >/dev/null 2>&1 || true
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

function viewport_sample_count() {
  awk -v events="$events_per_burst" -v interval="$scroll_interval_ms" -v tail="$sample_tail_ms" -v sample_interval="$sample_interval_ms" \
    'BEGIN {
      total_ms = (events * interval) + tail
      samples = int((total_ms / sample_interval) + 2.999999)
      if (samples < 3) samples = 3
      print samples
    }'
}

function wait_for_terminal_viewport_ready() {
  local tile_id="$1"
  local timeout="${2:-15}"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if gate_l_send_bridge_json_command false 2 "__agtmux_dump_terminal_viewport_text__" "$tile_id" \
      >/dev/null 2>"$gate_l_tmpdir/viewport-ready.last-error.log"; then
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for terminal viewport readiness for tileID $tile_id" >&2
  if [[ -s "$gate_l_tmpdir/viewport-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/viewport-ready.last-error.log" >&2
  fi
  return 1
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
    live_tmux send-keys -c "$client_tty" PageUp >/dev/null 2>&1 || true
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
  pane_id="$(live_tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

resolved_pane_target="$(resolve_live_pane_target "$session_name" "$pane_id" || true)"
if [[ -z "$resolved_pane_target" ]]; then
  echo "Failed to resolve pane target in session $session_name" >&2
  exit 1
fi
resolved_session_name="${resolved_pane_target%%|*}"
remaining_target="${resolved_pane_target#*|}"
resolved_pane_id="${remaining_target%%|*}"
remaining_target="${remaining_target#*|}"
window_id="${remaining_target%%|*}"
remaining_target="${remaining_target#*|}"
resolved_pane_active="${remaining_target%%|*}"
remaining_target="${remaining_target#*|}"
resolved_pane_command="${remaining_target%%|*}"
remaining_target="${remaining_target#*|}"
resolved_pane_title="${remaining_target%%|*}"
resolution_reason="${resolved_pane_target##*|}"
pane_id="$resolved_pane_id"

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
post_focus_json_path="$gate_l_tmpdir/post-focus-state.json"
baseline_viewport_json_path="$gate_l_tmpdir/baseline-viewport.json"
final_viewport_json_path="$gate_l_tmpdir/final-viewport.json"
bench_json_path="$gate_l_tmpdir/live-client-bench.json"
client_probe_json_path="$gate_l_tmpdir/client-command-probe.json"
post_scroll_telemetry_json_path="$gate_l_tmpdir/post-scroll-telemetry.json"
viewport_sample_json_path="$gate_l_tmpdir/live-client-viewport-samples.json"
viewport_metrics_json_path="$gate_l_tmpdir/live-client-viewport-metrics.json"

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

wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"

if active_json="$(
  extract_last_json_line "$(
    gate_l_wait_for_active_target "$session_name" "$window_id" "$pane_id" "$settle_timeout"
  )"
)"; then
  :
else
  if active_json="$(
    extract_last_json_line "$(
      gate_l_wait_for_rendered_target "$session_name" "$window_id" "$pane_id" "$settle_timeout"
    )"
  )"; then
    :
  else
    active_json="$(
      extract_last_json_line "$(
        gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout"
      )"
    )"
  fi
fi
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

if baseline_viewport_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$tile_id" 2>"$gate_l_tmpdir/baseline-viewport.last-error.log")"; then
  printf '%s\n' "$baseline_viewport_json" >"$baseline_viewport_json_path"
else
  printf '%s\n' '{}' >"$baseline_viewport_json_path"
fi

sample_count="$(viewport_sample_count)"
sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$tile_id" "$sample_count" "$sample_interval_ms")"

frontmost_bench_args=(
  --app-pid "$gate_l_app_pid"
  --client-tty "$rendered_client_tty"
  --label "$host_mode"
)

if [[ "$use_scroll_identifier" == "1" ]]; then
  frontmost_bench_args+=(--scroll-identifier "$terminal_ax_identifier")
fi

"$SCRIPT_DIR/gate_l_frontmost_live_client_scroll_bench.sh" \
  "${frontmost_bench_args[@]}" >"$bench_json_path"

sample_timeout="$(
  awk -v count="$sample_count" -v interval="$sample_interval_ms" 'BEGIN {
    printf "%.3f", ((count * interval) / 1000.0) + 5.0
  }'
)"
if gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$viewport_sample_json_path"; then
  python3 "$STEP_METRICS_PY" "$viewport_sample_json_path" >"$viewport_metrics_json_path"
else
  printf '%s\n' '{}' >"$viewport_sample_json_path"
  printf '%s\n' '{}' >"$viewport_metrics_json_path"
fi

if final_viewport_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$tile_id" 2>"$gate_l_tmpdir/final-viewport.last-error.log")"; then
  printf '%s\n' "$final_viewport_json" >"$final_viewport_json_path"
else
  printf '%s\n' '{}' >"$final_viewport_json_path"
fi

if post_focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/post-focus-state.last-error.log")"; then
  printf '%s\n' "$post_focus_json" >"$post_focus_json_path"
else
  printf '%s\n' '{"terminalAccessibilityIdentifier":null}' >"$post_focus_json_path"
fi

if post_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_scroll_telemetry__" "$tile_id" 2>"$gate_l_tmpdir/post-scroll-telemetry.last-error.log")"; then
  printf '%s\n' "$post_scroll_telemetry_json" >"$post_scroll_telemetry_json_path"
else
  printf '%s\n' '{}' >"$post_scroll_telemetry_json_path"
fi

probe_client_scroll_command "$rendered_client_tty" >"$client_probe_json_path"

jq -n \
  --arg host_mode "$host_mode" \
  --arg session_name "$session_name" \
  --arg pane_id "$pane_id" \
  --arg window_id "$window_id" \
  --arg requested_pane_id "${AGTMUX_PERF_LIVE_PANE_ID:-}" \
  --arg resolved_session_name "$resolved_session_name" \
  --arg resolved_pane_active "$resolved_pane_active" \
  --arg resolved_pane_command "$resolved_pane_command" \
  --arg resolved_pane_title "$resolved_pane_title" \
  --arg resolution_reason "$resolution_reason" \
  --arg app_pid "$gate_l_app_pid" \
  --arg tmpdir "$gate_l_tmpdir" \
  --slurpfile open "$open_json_path" \
  --slurpfile active "$active_json_path" \
  --slurpfile focus "$focus_json_path" \
  --slurpfile postFocus "$post_focus_json_path" \
  --slurpfile baselineViewport "$baseline_viewport_json_path" \
  --slurpfile finalViewport "$final_viewport_json_path" \
  --slurpfile bench "$bench_json_path" \
  --slurpfile clientProbe "$client_probe_json_path" \
  --slurpfile postScrollTelemetry "$post_scroll_telemetry_json_path" \
  --slurpfile viewportSamples "$viewport_sample_json_path" \
  --slurpfile viewportMetrics "$viewport_metrics_json_path" \
  '{
    hostMode: $host_mode,
    sessionName: $session_name,
    paneID: $pane_id,
    windowID: $window_id,
    requestedPaneID: ($requested_pane_id | if length > 0 then . else null end),
    resolvedPane: {
      sessionName: $resolved_session_name,
      paneID: $pane_id,
      windowID: $window_id,
      paneActive: ($resolved_pane_active == "1"),
      paneCurrentCommand: (if $resolved_pane_command == "" then null else $resolved_pane_command end),
      paneTitle: (if $resolved_pane_title == "" then null else $resolved_pane_title end),
      reason: $resolution_reason
    },
    appPID: ($app_pid | tonumber),
    tmpdir: $tmpdir,
    open: $open[0],
    activeTarget: $active[0],
    focusState: $focus[0],
    postFocusState: $postFocus[0],
    baselineViewport: $baselineViewport[0],
    finalViewport: $finalViewport[0],
    bench: $bench[0],
    clientCommandProbe: $clientProbe[0],
    postScrollTelemetry: $postScrollTelemetry[0],
    viewportSamples: $viewportSamples[0],
    viewportMetrics: $viewportMetrics[0]
  }'
