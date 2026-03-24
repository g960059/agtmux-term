#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"
EMITTER_PY="$SCRIPT_DIR/gate_l_emit_loaded_history_fixture.py"
CURSES_HISTORY_VIEWER_PY="$SCRIPT_DIR/gate_l_curses_history_viewer.py"

host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-30}"
fixture_lines="${AGTMUX_PERF_LOADED_FIXTURE_LINES:-12000}"
fixture_wrap_columns="${AGTMUX_PERF_LOADED_FIXTURE_WRAP_COLUMNS:-180}"
fixture_marker="${AGTMUX_PERF_LOADED_FIXTURE_MARKER:-AGTMUX_LOADED_HISTORY_DONE}"
fixture_idle_seconds="${AGTMUX_PERF_LOADED_FIXTURE_IDLE_SECONDS:-600}"
fixture_settle_ms="${AGTMUX_PERF_LOADED_FIXTURE_SETTLE_MS:-350}"
focus_settle_ms="${AGTMUX_PERF_LOADED_FOCUS_SETTLE_MS:-120}"
focus_mode="${AGTMUX_PERF_LOADED_FOCUS_MODE:-identifier}"
scroll_mode="${AGTMUX_PERF_LOADED_SCROLL_MODE:-point}"
events_per_burst="${AGTMUX_PERF_UPSTEP_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_UPSTEP_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_UPSTEP_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_INTERVAL_MS:-16}"
sample_tail_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-1600}"
scroll_phase_mode="${AGTMUX_PERF_UPSTEP_PHASE_MODE:-trackpad-burst-momentum}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"

function sleep_ms() {
  local milliseconds="$1"
  sleep "$(awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
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
    local remaining_timeout
    remaining_timeout="$(awk -v deadline="$deadline" -v now="$EPOCHREALTIME" 'BEGIN {
      remaining = deadline - now
      if (remaining < 0.05) remaining = 0.05
      printf "%.3f", remaining
    }')"
    if gate_l_wait_for_bridge_json_command_until "$remaining_timeout" "$gate_l_tmpdir/viewport-ready.last-error.log" "__agtmux_dump_terminal_viewport_text__" "$tile_id" \
      >/dev/null; then
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

function wait_for_viewport_marker() {
  local tile_id="$1"
  local marker="$2"
  local timeout="${3:-20}"
  local deadline=$((EPOCHREALTIME + timeout))
  local output=""

  while (( EPOCHREALTIME < deadline )); do
    local remaining_timeout
    remaining_timeout="$(awk -v deadline="$deadline" -v now="$EPOCHREALTIME" 'BEGIN {
      remaining = deadline - now
      if (remaining < 0.05) remaining = 0.05
      printf "%.3f", remaining
    }')"
    if output="$(gate_l_wait_for_bridge_json_command_until "$remaining_timeout" "$gate_l_tmpdir/viewport-marker.last-error.log" "__agtmux_dump_terminal_viewport_text__" "$tile_id")"; then
      if jq -er --arg marker "$marker" '.text | contains($marker)' >/dev/null <<<"$output"; then
        return 0
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for viewport marker '$marker'" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  fi
  return 1
}

while (( $# > 0 )); do
  case "$1" in
    --host-mode)
      host_mode="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--host-mode legacy|next] [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

gate_l_require_explicit_terminal_host_mode "$host_mode" "$0" || exit 1

case "$focus_mode" in
  identifier|front-window)
    ;;
  *)
    echo "Unsupported loaded viewport focus mode: $focus_mode" >&2
    exit 1
    ;;
esac

case "$scroll_mode" in
  point|front-window)
    ;;
  *)
    echo "Unsupported loaded viewport scroll mode: $scroll_mode" >&2
    exit 1
    ;;
esac

token="loaded-view-${host_mode}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="agtmux-gate-l-$token"
session_name="agtmux-loaded-$token"
gate_l_setup_paths "$token"
export AGTMUX_PERF_TERMINAL_HOST_MODE="$host_mode"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0

fixture_file="$gate_l_tmpdir/loaded-history-fixture.txt"
fixture_build_done_file="$gate_l_tmpdir/loaded-history-fixture.done"
fixture_event_log_path="$gate_l_tmpdir/curses-history-events.json"
fixture_event_summary_json_path="$gate_l_tmpdir/curses-history-events-summary.json"
open_json_path="$gate_l_tmpdir/open-terminal.json"
active_json_path="$gate_l_tmpdir/active-target.json"
focus_json_path="$gate_l_tmpdir/focus-state.json"
baseline_viewport_json_path="$gate_l_tmpdir/baseline-viewport.json"
final_viewport_json_path="$gate_l_tmpdir/final-viewport.json"
sample_json_path="$gate_l_tmpdir/viewport-samples.json"
metrics_json_path="$gate_l_tmpdir/viewport-metrics.json"
send_json_path="$gate_l_tmpdir/send.json"
scroll_telemetry_json_path="$gate_l_tmpdir/post-scroll-telemetry.json"

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  gate_l_cleanup_tmux
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L terminal-host loaded viewport temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

python3 "$EMITTER_PY" \
  --ready-file /dev/null \
  --done-file "$fixture_build_done_file" \
  --lines "$fixture_lines" \
  --wrap-columns "$fixture_wrap_columns" \
  --idle-seconds 0 \
  --marker "$fixture_marker" >"$fixture_file"

shell_command="/bin/zsh -lc 'python3 \"$CURSES_HISTORY_VIEWER_PY\" --fixture \"$fixture_file\" --ready-marker \"$fixture_marker\" --event-log \"$fixture_event_log_path\"'"

gate_l_launch_app "$socket_name" "$session_name" 1 "$shell_command"
bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi
gate_l_record_bootstrap_tmux_socket_path "$bootstrap_json"

window_id="$(jq -r '.windowID // empty' <<<"$bootstrap_json")"
pane_id="$(jq -r '.paneIDs[0] // empty' <<<"$bootstrap_json")"
if [[ -z "$window_id" || -z "$pane_id" ]]; then
  echo "Failed to resolve bootstrap pane from $bootstrap_json" >&2
  exit 1
fi

gate_l_activate_app
open_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id")"
printf '%s\n' "$open_json" >"$open_json_path"
tile_id="$(jq -r '.tileID // empty' <<<"$open_json")"
if [[ -z "$tile_id" ]]; then
  echo "Failed to resolve tile from __agtmux_open_terminal_for_pane__: $open_json" >&2
  exit 1
fi
if ! wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"; then
  exit 1
fi

active_json="$(gate_l_wait_for_active_target "$session_name" "$window_id" "$pane_id" "$settle_timeout")"
printf '%s\n' "$active_json" >"$active_json_path"

gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$tile_id" >/dev/null
gate_l_activate_app

focus_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_focus_state__" "$tile_id")"
printf '%s\n' "$focus_json" >"$focus_json_path"
terminal_ax_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_json")"
resolved_terminal_ax_identifier="$terminal_ax_identifier"
if [[ -z "$resolved_terminal_ax_identifier" ]]; then
  resolved_terminal_ax_identifier="workspace.terminalHost.${tile_id}"
fi

if ! wait_for_viewport_marker "$tile_id" "$fixture_marker" "$settle_timeout"; then
  exit 1
fi
sleep_ms "$fixture_settle_ms"

baseline_viewport_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_terminal_viewport_text__" "$tile_id")"
printf '%s\n' "$baseline_viewport_json" >"$baseline_viewport_json_path"
gate_l_send_bridge_command false 10 "__agtmux_reset_scroll_telemetry__" "$tile_id" >/dev/null

gate_l_activate_app
if [[ "$focus_mode" == "identifier" ]]; then
  focus_sender_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-identifier "$resolved_terminal_ax_identifier" \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac")"
else
  focus_sender_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-front-window \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac")"
fi
if [[ "$(jq -r '.sent // false' <<<"$focus_sender_json")" != "true" ]]; then
  echo "Failed to focus loaded viewport scroll target: $focus_sender_json" >&2
  exit 1
fi
scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$focus_sender_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$focus_sender_json")"
if [[ "$scroll_mode" == "point" ]]; then
  if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
    echo "Loaded viewport focus did not report a click point: $focus_sender_json" >&2
    exit 1
  fi
fi
sleep_ms "$focus_settle_ms"
sample_count="$(viewport_sample_count)"
sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$tile_id" "$sample_count" "$sample_interval_ms")"
sleep_ms 20
if [[ "$scroll_mode" == "point" ]]; then
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --scroll-point \
    --point-x "$scroll_point_x" \
    --point-y "$scroll_point_y" \
    --scroll-pixels "$scroll_pixels_per_event" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path"
else
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --scroll-front-window \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac" \
    --scroll-pixels "$scroll_pixels_per_event" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path"
fi

sample_timeout="$(
  awk -v count="$sample_count" -v interval="$sample_interval_ms" 'BEGIN {
    printf "%.3f", ((count * interval) / 1000.0) + 5.0
  }'
)"
if ! gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$sample_json_path"; then
  echo "Loaded viewport bridge sampler failed" >&2
  exit 1
fi

python3 "$STEP_METRICS_PY" "$sample_json_path" >"$metrics_json_path"
final_viewport_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_terminal_viewport_text__" "$tile_id")"
printf '%s\n' "$final_viewport_json" >"$final_viewport_json_path"
scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$tile_id")"
printf '%s\n' "$scroll_telemetry_json" >"$scroll_telemetry_json_path"
jq -n \
  --slurpfile payload "$fixture_event_log_path" \
  '($payload[0].events // []) as $events |
   {
     eventCount: ($payload[0].eventCount // ($events | length)),
     resizeCount: ($events | map(select(.kind == "resize")) | length),
     keyUpCount: ($events | map(select(.kind == "key" and .keyName == "KEY_UP")) | length),
     keyDownCount: ($events | map(select(.kind == "key" and .keyName == "KEY_DOWN")) | length),
     firstKeyUpElapsedMs:
       (($events | map(select(.kind == "key" and .keyName == "KEY_UP") | .elapsedMs) | first) // null),
     firstKeyDownElapsedMs:
       (($events | map(select(.kind == "key" and .keyName == "KEY_DOWN") | .elapsedMs) | first) // null),
     lastKeyUpElapsedMs:
       (($events | map(select(.kind == "key" and .keyName == "KEY_UP") | .elapsedMs) | last) // null),
     finalTop:
       (($events | map(select(.kind == "key") | .top) | last) // null)
   }' >"$fixture_event_summary_json_path"

jq -n \
  --arg host_mode "$host_mode" \
  --arg session_name "$session_name" \
  --arg window_id "$window_id" \
  --arg pane_id "$pane_id" \
  --arg tile_id "$tile_id" \
  --arg app_bin "$GATE_L_APP_BIN" \
  --argjson app_pid "$gate_l_app_pid" \
  --arg fixture_marker "$fixture_marker" \
  --argjson fixture_lines "$fixture_lines" \
  --argjson fixture_wrap_columns "$fixture_wrap_columns" \
  --arg fixture_file "$fixture_file" \
  --arg fixture_event_log_path "$fixture_event_log_path" \
  --argjson events_per_burst "$events_per_burst" \
  --argjson scroll_pixels_per_event "$scroll_pixels_per_event" \
  --argjson scroll_interval_ms "$scroll_interval_ms" \
  --argjson sample_interval_ms "$sample_interval_ms" \
  --argjson sample_tail_ms "$sample_tail_ms" \
  --argjson focus_settle_ms "$focus_settle_ms" \
  --arg focus_mode "$focus_mode" \
  --arg scroll_mode "$scroll_mode" \
  --arg scroll_phase_mode "$scroll_phase_mode" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --slurpfile open "$open_json_path" \
  --slurpfile active "$active_json_path" \
  --slurpfile focus "$focus_json_path" \
  --slurpfile baseline "$baseline_viewport_json_path" \
  --slurpfile final "$final_viewport_json_path" \
  --slurpfile samples "$sample_json_path" \
  --slurpfile metrics "$metrics_json_path" \
  --slurpfile send "$send_json_path" \
  --slurpfile scroll_telemetry "$scroll_telemetry_json_path" \
  --slurpfile fixture_event_summary "$fixture_event_summary_json_path" \
  --arg tmpdir "$gate_l_tmpdir" \
  '{
    hostMode: $host_mode,
    appBin: $app_bin,
    appPID: $app_pid,
    sessionName: $session_name,
    windowID: $window_id,
    paneID: $pane_id,
    tileID: $tile_id,
    fixture: {
      lines: $fixture_lines,
      wrapColumns: $fixture_wrap_columns,
      marker: $fixture_marker,
      fixtureFile: $fixture_file,
      eventLogPath: $fixture_event_log_path
    },
    benchConfig: {
      eventsPerBurst: $events_per_burst,
      scrollPixelsPerEvent: $scroll_pixels_per_event,
      scrollIntervalMs: $scroll_interval_ms,
      sampleIntervalMs: $sample_interval_ms,
      sampleTailMs: $sample_tail_ms,
      focusSettleMs: $focus_settle_ms,
      focusMode: $focus_mode,
      scrollMode: $scroll_mode,
      scrollPhaseMode: $scroll_phase_mode,
      terminalAccessibilityIdentifier: $resolved_terminal_ax_identifier
    },
    openTerminal: $open[0],
    activeTarget: $active[0],
    focus: $focus[0],
    baselineViewport: $baseline[0],
    finalViewport: $final[0],
    samples: $samples[0],
    metrics: $metrics[0],
    sender: $send[0],
    scrollTelemetry: $scroll_telemetry[0],
    fixtureEventSummary: $fixture_event_summary[0],
    tmpdir: $tmpdir
  }'
