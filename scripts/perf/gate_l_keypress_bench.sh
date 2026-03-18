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

function wait_for_pane_text() {
  local socket_name="$1"
  local target="$2"
  local expected="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local captured=""

  while (( EPOCHREALTIME < deadline )); do
    captured="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -120 2>/dev/null || true)"
    if [[ "$captured" == *"$expected"* ]]; then
      typeset -g "$output_var_name=$captured"
      return 0
    fi
    sleep 0.01
  done

  typeset -g "$output_var_name=$captured"
  return 1
}

function latest_key_sequence() {
  local socket_name="$1"
  local target="$2"
  local captured
  captured="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -120 2>/dev/null || true)"
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
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--session-name NAME]" >&2
      exit 1
      ;;
  esac
done

gate_l_require_app_bin

helper_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --dry-run)"
if [[ "$(jq -r '.trusted' <<<"$helper_json")" != "true" ]]; then
  echo "AX helper is not trusted: $helper_json" >&2
  exit 2
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
gate_l_activate_app

bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi

pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
ready_capture=""
if ! wait_for_pane_text "$socket_name" "$target" "__GATE_L_READY__" "$settle_timeout" ready_capture; then
  echo "Timed out waiting for keypress driver readiness banner" >&2
  exit 1
fi

gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id" >/dev/null
gate_l_activate_app

active_snapshot="$(gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout")"
tile_id="$(jq -r '.tileID' <<<"$active_snapshot")"
focus_snapshot="$(gate_l_send_bridge_command false 10 "__agtmux_dump_focus_state__" "$tile_id")"
terminal_ax_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_snapshot")"
terminal_ax_fallback_identifier="workspace.terminalHost.${tile_id}"
resolved_terminal_ax_identifier="$terminal_ax_identifier"
if [[ -z "$resolved_terminal_ax_identifier" ]]; then
  resolved_terminal_ax_identifier="$terminal_ax_fallback_identifier"
fi

initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
  --app-pid "$gate_l_app_pid" \
  --click-identifier "$resolved_terminal_ax_identifier" \
  --x-frac 0.5 \
  --y-frac 0.5)"
keypress_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
keypress_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$keypress_point_x" || -z "$keypress_point_y" ]]; then
  echo "Failed to resolve initial keypress target point" >&2
  exit 1
fi
sleep 0.2

latencies_file="$gate_l_tmpdir/keypress-latencies.txt"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"
last_sequence="$(latest_key_sequence "$socket_name" "$target")"
last_send_json='null'
last_capture="$ready_capture"

for (( i = 1; i <= iterations; i++ )); do
  expected_sequence=$((last_sequence + 1))
  expected_marker="__GATE_L_KEY__:${expected_sequence}:${key_hex}"
  start_realtime="$EPOCHREALTIME"
  last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-key-point \
    --point-x "$keypress_point_x" \
    --point-y "$keypress_point_y" \
    --key-code "$key_code")"
  if ! wait_for_pane_text "$socket_name" "$target" "$expected_marker" "$settle_timeout" last_capture; then
    echo "Timed out waiting for keypress marker $expected_marker" >&2
    exit 1
  fi
  latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  print -r -- "$latency_ms" >>"$latencies_file"
  last_sequence="$expected_sequence"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"
sleep 1

latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$latencies_file")"
signpost_json="$("$SCRIPT_DIR/gate_l_signpost_summary.sh" --start "$bench_start" --end "$bench_end" --pid "$gate_l_app_pid" --allow-empty)"

jq -n \
  --arg app_bin "$GATE_L_APP_BIN" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg pane_id "$pane_id" \
  --arg tile_id "$tile_id" \
  --arg key_label "$key_label" \
  --arg key_hex "$key_hex" \
  --arg terminal_ax_identifier "$terminal_ax_identifier" \
  --arg terminal_ax_fallback_identifier "$terminal_ax_fallback_identifier" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --arg final_capture "$last_capture" \
  --argjson helper "$helper_json" \
  --argjson focus_snapshot "$focus_snapshot" \
  --argjson last_send "$last_send_json" \
  --argjson app_pid "$gate_l_app_pid" \
  --argjson iterations "$iterations" \
  --argjson latencies "$latencies_json" \
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

  {
    app_bin: $app_bin,
    app_pid: $app_pid,
    session_name: $session_name,
    socket_name: $socket_name,
    target: $target,
    pane_id: $pane_id,
    tile_id: $tile_id,
    key_label: $key_label,
    key_hex: $key_hex,
    terminal_ax_identifier: (if $terminal_ax_identifier == "" then null else $terminal_ax_identifier end),
    terminal_ax_fallback_identifier: $terminal_ax_fallback_identifier,
    resolved_terminal_ax_identifier: $resolved_terminal_ax_identifier,
    benchmark_start: $bench_start,
    benchmark_end: $bench_end,
    iterations: $iterations,
    latencies_ms: $latencies,
    p50_ms: (($latencies | percentile(50)) | round3),
    p95_ms: (($latencies | percentile(95)) | round3),
    max_ms: (($latencies | max) | round3),
    helper: $helper,
    focus_snapshot: $focus_snapshot,
    last_send: $last_send,
    ready_capture: $ready_capture,
    final_capture: $final_capture,
    signposts: $signposts
  }'
