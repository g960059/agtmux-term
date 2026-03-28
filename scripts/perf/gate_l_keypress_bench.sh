#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=20
settle_timeout=15
session_name=""
key_code=0
key_hex="61"
key_label="a"
delivery="ax"

function wait_for_pane_text() {
  local socket_name="$1"
  local target="$2"
  local expected="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local captured=""

  while (( EPOCHREALTIME < deadline )); do
    captured="$(gate_l_tmux capture-pane -p -t "$target" -S -120 2>/dev/null || true)"
    if [[ "$captured" == *"$expected"* ]]; then
      typeset -g "$output_var_name=$captured"
      return 0
    fi
    sleep 0.01
  done

  typeset -g "$output_var_name=$captured"
  return 1
}

function wait_for_viewport_text() {
  local surface_id="$1"
  local expected="$2"
  local timeout="$3"
  local output_var_name="$4"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local viewport_json=""
  local viewport_text=""

  while (( EPOCHREALTIME < deadline )); do
    viewport_json="$(gate_l_send_bridge_json_command false 3 "__agtmux_dump_terminal_viewport_text__" "$surface_id" 2>/dev/null || true)"
    viewport_text="$(jq -r '.text // empty' <<<"$viewport_json" 2>/dev/null || true)"
    if [[ "$viewport_text" == *"$expected"* ]]; then
      typeset -g "$output_var_name=$viewport_text"
      return 0
    fi
    sleep 0.01
  done

  typeset -g "$output_var_name=$viewport_text"
  return 1
}

function current_layer_present_count() {
  local surface_id="$1"
  local telemetry_json
  telemetry_json="$(gate_l_send_bridge_json_command false 3 "__agtmux_dump_scroll_telemetry__" "$surface_id" 2>/dev/null || true)"
  jq -r '.scroll.layerPresentCount // 0' <<<"$telemetry_json" 2>/dev/null || print -r -- "0"
}

function wait_for_layer_present_count() {
  local surface_id="$1"
  local minimum_count="$2"
  local timeout="$3"
  local output_var_name="$4"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest="0"

  while (( EPOCHREALTIME < deadline )); do
    latest="$(current_layer_present_count "$surface_id")"
    if [[ -n "$latest" && "$latest" != "null" && "$latest" -ge "$minimum_count" ]]; then
      typeset -g "$output_var_name=$latest"
      return 0
    fi
    sleep 0.01
  done

  typeset -g "$output_var_name=$latest"
  return 1
}

function latest_key_sequence() {
  local socket_name="$1"
  local target="$2"
  local captured
  captured="$(gate_l_tmux capture-pane -p -t "$target" -S -120 2>/dev/null || true)"
  perl -ne 'while (/__GATE_L_KEY__:(\d+):/g) { $last = $1 } END { print($last || 0) }' <<<"$captured"
}

while (( $# > 0 )); do
  case "$1" in
    --iterations)
      iterations="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    --session-name)
      session_name="$2"
      shift 2
      ;;
    --delivery)
      delivery="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--session-name NAME] [--delivery bridge|ax]" >&2
      exit 1
      ;;
  esac
done

gate_l_require_app_bin

if [[ "$delivery" != "bridge" && "$delivery" != "ax" ]]; then
  echo "Unsupported keypress delivery mode: $delivery" >&2
  exit 1
fi

helper_json='null'
if [[ "$delivery" == "ax" ]]; then
  helper_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --dry-run)"
  if [[ "$(jq -r '.trusted' <<<"$helper_json")" != "true" ]]; then
    echo "AX helper is not trusted: $helper_json" >&2
    exit 2
  fi
fi

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="agtmux-gate-l-key-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-key-${token}"
fi
target="${session_name}:main"

gate_l_setup_paths "$token"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=1

keypress_driver_path="$gate_l_tmpdir/gate-l-keypress-driver.py"
cat >"$keypress_driver_path" <<'EOF'
import sys
import termios
import tty

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
seq = 0

try:
    sys.stdout.write("__GATE_L_READY__\r\n")
    sys.stdout.flush()
    while True:
        chunk = sys.stdin.buffer.read(1)
        if not chunk:
            break
        seq += 1
        sys.stdout.write(f"__GATE_L_KEY__:{seq}:{chunk.hex()}\r\n")
        sys.stdout.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
EOF

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  gate_l_cleanup_tmux
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L keypress temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app "$socket_name" "$session_name" 1 "python3 -u $keypress_driver_path"
gate_l_activate_app || true

bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi
gate_l_record_bootstrap_tmux_socket_path "$bootstrap_json"

pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
target="$pane_id"
ready_capture=""
if ! wait_for_pane_text "$socket_name" "$target" "__GATE_L_READY__" "$settle_timeout" ready_capture; then
  echo "Timed out waiting for keypress driver readiness banner" >&2
  exit 1
fi

if [[ "$delivery" == "ax" ]]; then
  open_terminal_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id" "nowait")"
  surface_id="$(jq -r '.surfaceID // empty' <<<"$open_terminal_json")"
  if [[ -z "$surface_id" || "$surface_id" == "null" ]]; then
    echo "Failed to resolve surfaceID from open_terminal_for_pane result" >&2
    echo "$open_terminal_json" >&2
    exit 1
  fi
  gate_l_activate_app || true
  focus_snapshot="$(gate_l_wait_for_terminal_snapshot_ready "$surface_id" "$settle_timeout")"
else
  gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id" >/dev/null
  gate_l_activate_app || true

  active_snapshot="$(gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout")"
  surface_id="$(jq -r '.surfaceID' <<<"$active_snapshot")"
  focus_snapshot="$(gate_l_send_bridge_command false 10 "__agtmux_dump_focus_state__" "$surface_id")"
fi
terminal_ax_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_snapshot")"
terminal_ax_fallback_identifier="workspace.terminalHost.${surface_id}"
resolved_terminal_ax_identifier="$terminal_ax_identifier"
if [[ -z "$resolved_terminal_ax_identifier" ]]; then
  resolved_terminal_ax_identifier="$terminal_ax_fallback_identifier"
fi

keypress_point_x=""
keypress_point_y=""
ax_refocus_each_iteration=0
if [[ "$delivery" == "ax" ]]; then
  keypress_point_x="$(jq -r '.terminalFrameInScreen.x // empty' <<<"$focus_snapshot")"
  keypress_point_y="$(jq -r '.terminalFrameInScreen.y // empty' <<<"$focus_snapshot")"
  keypress_frame_width="$(jq -r '.terminalFrameInScreen.width // empty' <<<"$focus_snapshot")"
  keypress_frame_height="$(jq -r '.terminalFrameInScreen.height // empty' <<<"$focus_snapshot")"
  if [[ -n "$keypress_point_x" && -n "$keypress_point_y" && -n "$keypress_frame_width" && -n "$keypress_frame_height" ]]; then
    keypress_point_x="$(awk "BEGIN { printf \"%.3f\", ($keypress_point_x + ($keypress_frame_width * 0.5)) }")"
    keypress_point_y="$(awk "BEGIN { printf \"%.3f\", ($keypress_point_y + ($keypress_frame_height * 0.5)) }")"
    initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      --app-pid "$gate_l_app_pid" \
      --click-point \
      --point-x "$keypress_point_x" \
      --point-y "$keypress_point_y")"
  else
    initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      --app-pid "$gate_l_app_pid" \
      --click-identifier "$resolved_terminal_ax_identifier" \
      --x-frac 0.5 \
      --y-frac 0.5)"
    keypress_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
    keypress_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
  fi
  if [[ -z "$keypress_point_x" || -z "$keypress_point_y" ]]; then
    echo "Failed to resolve initial keypress target point" >&2
    exit 1
  fi
  sleep 0.2
  focus_snapshot="$(gate_l_wait_for_terminal_focus_ready "$surface_id" "$settle_timeout")"
  if [[ -n "$keypress_point_x" && -n "$keypress_point_y" ]]; then
    if [[ "$(jq -r '.appIsActive // false' <<<"$focus_snapshot")" != "true" \
       || "$(jq -r '.terminalIsFirstResponder // false' <<<"$focus_snapshot")" != "true" ]]; then
      ax_refocus_each_iteration=1
    fi
  fi
fi
gate_l_send_bridge_command false 10 "__agtmux_reset_scroll_telemetry__" "$surface_id" >/dev/null

tmux_latencies_file="$gate_l_tmpdir/keypress-tmux-latencies.txt"
viewport_latencies_file="$gate_l_tmpdir/keypress-viewport-latencies.txt"
viewport_delta_file="$gate_l_tmpdir/keypress-viewport-delta-latencies.txt"
layer_present_latencies_file="$gate_l_tmpdir/keypress-layer-present-latencies.txt"
layer_present_delta_file="$gate_l_tmpdir/keypress-layer-present-delta-latencies.txt"
touch "$layer_present_latencies_file" "$layer_present_delta_file"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"
last_sequence="$(latest_key_sequence "$socket_name" "$target")"
last_send_json='null'
last_capture="$ready_capture"
last_viewport_text=""
last_layer_present_count="$(current_layer_present_count "$surface_id")"
layer_present_timeout_count=0

for (( i = 1; i <= iterations; i++ )); do
  expected_sequence=$((last_sequence + 1))
  expected_marker="__GATE_L_KEY__:${expected_sequence}:${key_hex}"
  expected_layer_present_count=$((last_layer_present_count + 1))
  start_realtime="$EPOCHREALTIME"
  if [[ "$delivery" == "bridge" ]]; then
    gate_l_send_bridge_command false 10 "__agtmux_send_terminal_key_down__" "$surface_id" "$key_label" "$key_code" >/dev/null
    last_send_json="$(jq -nc \
      --arg action "bridge-key-down" \
      --arg surface_id "$surface_id" \
      --arg characters "$key_label" \
      --argjson keyCode "$key_code" \
      '{action:$action, surfaceID:$surface_id, characters:$characters, keyCode:$keyCode, sent:true}')"
  else
    if [[ "$ax_refocus_each_iteration" == "1" && -n "$keypress_point_x" && -n "$keypress_point_y" ]]; then
      last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
        --app-pid "$gate_l_app_pid" \
        --focus-key-point \
        --point-x "$keypress_point_x" \
        --point-y "$keypress_point_y" \
        --key-code "$key_code")"
    else
      last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
        --app-pid "$gate_l_app_pid" \
        --key-code "$key_code")"
    fi
  fi
  if ! wait_for_pane_text "$socket_name" "$target" "$expected_marker" "$settle_timeout" last_capture; then
    echo "Timed out waiting for keypress marker $expected_marker" >&2
    exit 1
  fi
  tmux_latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  if ! wait_for_viewport_text "$surface_id" "$expected_marker" "$settle_timeout" last_viewport_text; then
    echo "Timed out waiting for viewport marker $expected_marker" >&2
    exit 1
  fi
  viewport_latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  viewport_delta_ms="$(awk "BEGIN { printf \"%.3f\", ($viewport_latency_ms - $tmux_latency_ms) }")"
  print -r -- "$tmux_latency_ms" >>"$tmux_latencies_file"
  print -r -- "$viewport_latency_ms" >>"$viewport_latencies_file"
  print -r -- "$viewport_delta_ms" >>"$viewport_delta_file"
  if wait_for_layer_present_count "$surface_id" "$expected_layer_present_count" "$settle_timeout" last_layer_present_count; then
    layer_present_latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
    layer_present_delta_ms="$(awk "BEGIN { printf \"%.3f\", ($layer_present_latency_ms - $tmux_latency_ms) }")"
    print -r -- "$layer_present_latency_ms" >>"$layer_present_latencies_file"
    print -r -- "$layer_present_delta_ms" >>"$layer_present_delta_file"
  else
    layer_present_timeout_count=$((layer_present_timeout_count + 1))
  fi
  last_sequence="$expected_sequence"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"
sleep 1

tmux_latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$tmux_latencies_file")"
viewport_latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$viewport_latencies_file")"
viewport_delta_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$viewport_delta_file")"
layer_present_latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$layer_present_latencies_file")"
layer_present_delta_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$layer_present_delta_file")"
signpost_json="$("$SCRIPT_DIR/gate_l_signpost_summary.sh" --start "$bench_start" --end "$bench_end" --pid "$gate_l_app_pid" --allow-empty)"
final_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 3 "__agtmux_dump_scroll_telemetry__" "$surface_id" 2>/dev/null || echo '{}')"

jq -n \
  --arg app_bin "$GATE_L_APP_BIN" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg pane_id "$pane_id" \
  --arg surface_id "$surface_id" \
  --arg key_label "$key_label" \
  --arg key_hex "$key_hex" \
  --arg delivery "$delivery" \
  --arg terminal_ax_identifier "$terminal_ax_identifier" \
  --arg terminal_ax_fallback_identifier "$terminal_ax_fallback_identifier" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --arg final_capture "$last_capture" \
  --arg final_viewport_text "$last_viewport_text" \
  --argjson helper "$helper_json" \
  --argjson focus_snapshot "$focus_snapshot" \
  --argjson last_send "$last_send_json" \
  --argjson app_pid "$gate_l_app_pid" \
  --argjson iterations "$iterations" \
  --argjson layer_present_timeout_count "$layer_present_timeout_count" \
  --argjson tmux_latencies "$tmux_latencies_json" \
  --argjson viewport_latencies "$viewport_latencies_json" \
  --argjson viewport_delta_latencies "$viewport_delta_json" \
  --argjson layer_present_latencies "$layer_present_latencies_json" \
  --argjson layer_present_delta_latencies "$layer_present_delta_json" \
  --argjson final_scroll_telemetry "$final_scroll_telemetry_json" \
  --argjson signposts "$signpost_json" '
  def round3:
    ((. * 1000.0) | round) / 1000.0;
  def percentile($p):
    if length == 0 then null
    else
      sort as $sorted
      | ($sorted | length) as $n
      | (((($p / 100.0) * $n) | ceil) - 1) as $index
      | $sorted[
          if $index < 0 then
            0
          elif $index >= $n then
            ($n - 1)
          else
            $index
          end
        ]
    end;
  def safe_round3:
    if . == null then null else round3 end;
  def safe_max:
    if length == 0 then null else (max | round3) end;

  {
    app_bin: $app_bin,
    app_pid: $app_pid,
    session_name: $session_name,
    socket_name: $socket_name,
    target: $target,
    pane_id: $pane_id,
    surface_id: $surface_id,
    key_label: $key_label,
    key_hex: $key_hex,
    delivery: $delivery,
    terminal_ax_identifier: (if $terminal_ax_identifier == "" then null else $terminal_ax_identifier end),
    terminal_ax_fallback_identifier: $terminal_ax_fallback_identifier,
    resolved_terminal_ax_identifier: $resolved_terminal_ax_identifier,
    benchmark_start: $bench_start,
    benchmark_end: $bench_end,
    iterations: $iterations,
    layer_present_timeout_count: $layer_present_timeout_count,
    latencies_ms: $tmux_latencies,
    p50_ms: (($tmux_latencies | percentile(50)) | round3),
    p95_ms: (($tmux_latencies | percentile(95)) | round3),
    max_ms: (($tmux_latencies | max) | round3),
    tmux_capture_latencies_ms: $tmux_latencies,
    tmux_capture_p50_ms: (($tmux_latencies | percentile(50)) | round3),
    tmux_capture_p95_ms: (($tmux_latencies | percentile(95)) | round3),
    tmux_capture_max_ms: (($tmux_latencies | max) | round3),
    viewport_latencies_ms: $viewport_latencies,
    viewport_p50_ms: (($viewport_latencies | percentile(50)) | round3),
    viewport_p95_ms: (($viewport_latencies | percentile(95)) | round3),
    viewport_max_ms: (($viewport_latencies | max) | round3),
    viewport_after_tmux_delta_ms: $viewport_delta_latencies,
    viewport_after_tmux_p50_ms: (($viewport_delta_latencies | percentile(50)) | round3),
    viewport_after_tmux_p95_ms: (($viewport_delta_latencies | percentile(95)) | round3),
    viewport_after_tmux_max_ms: (($viewport_delta_latencies | max) | round3),
    layer_present_latencies_ms: $layer_present_latencies,
    layer_present_p50_ms: (($layer_present_latencies | percentile(50)) | safe_round3),
    layer_present_p95_ms: (($layer_present_latencies | percentile(95)) | safe_round3),
    layer_present_max_ms: ($layer_present_latencies | safe_max),
    layer_present_after_tmux_delta_ms: $layer_present_delta_latencies,
    layer_present_after_tmux_p50_ms: (($layer_present_delta_latencies | percentile(50)) | safe_round3),
    layer_present_after_tmux_p95_ms: (($layer_present_delta_latencies | percentile(95)) | safe_round3),
    layer_present_after_tmux_max_ms: ($layer_present_delta_latencies | safe_max),
    helper: $helper,
    focus_snapshot: $focus_snapshot,
    last_send: $last_send,
    ready_capture: $ready_capture,
    final_capture: $final_capture,
    final_viewport_text: $final_viewport_text,
    final_scroll_telemetry: $final_scroll_telemetry,
    signposts: $signposts
  }'
