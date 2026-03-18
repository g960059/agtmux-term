#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=10
settle_timeout=15
session_name=""
line_count="${AGTMUX_PERF_LINES:-40000}"
warmup_scrolls="${AGTMUX_PERF_SCROLL_WARMUP_EVENTS:-${AGTMUX_PERF_SCROLL_WARMUP_PAGES:-2}}"
scroll_lines_per_event="${AGTMUX_PERF_SCROLL_LINES_PER_EVENT:-12}"
scroll_down_lines="$((-scroll_lines_per_event))"
scroll_up_lines="$scroll_lines_per_event"

function first_visible_line_number() {
  local socket_name="$1"
  local target="$2"
  local captured
  captured="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
  awk '
    /^[[:space:]]*[0-9]+[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, fields, /[[:space:]]+/)
      print fields[1]
      exit
    }
  ' <<<"$captured"
}

function wait_for_first_visible_line_number() {
  local socket_name="$1"
  local target="$2"
  local expected_line="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest=""

  while (( EPOCHREALTIME < deadline )); do
    latest="$(first_visible_line_number "$socket_name" "$target")"
    if [[ -n "$latest" && "$latest" -eq "$expected_line" ]]; then
      typeset -g "$output_var_name=$latest"
      return 0
    fi
    sleep 0.05
  done

  typeset -g "$output_var_name=$latest"
  return 1
}

function wait_for_first_visible_line_change() {
  local socket_name="$1"
  local target="$2"
  local baseline_line="$3"
  local direction="$4"
  local timeout="$5"
  local output_var_name="$6"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest=""

  while (( EPOCHREALTIME < deadline )); do
    latest="$(first_visible_line_number "$socket_name" "$target")"
    if [[ -n "$latest" ]]; then
      if [[ "$direction" == "down" && "$latest" -gt "$baseline_line" ]]; then
        typeset -g "$output_var_name=$latest"
        return 0
      fi
      if [[ "$direction" == "up" && "$latest" -lt "$baseline_line" ]]; then
        typeset -g "$output_var_name=$latest"
        return 0
      fi
    fi
    sleep 0.01
  done

  typeset -g "$output_var_name=$latest"
  return 1
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
socket_name="agtmux-gate-l-scroll-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-scroll-${token}"
fi
target="${session_name}:main"

gate_l_setup_paths "$token"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=1

fixture_path="$gate_l_tmpdir/scroll-fixture.txt"
python3 - <<PY >"$fixture_path"
for i in range(1, ${line_count} + 1):
    print(f"{i:06d} agtmux-scroll")
PY
shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec less -N \"$fixture_path\"'"

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  gate_l_cleanup_tmux
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L scroll temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app "$socket_name" "$session_name" 1 "$shell_command"
gate_l_activate_app

bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi

ready_line=""
if ! wait_for_first_visible_line_number "$socket_name" "$target" 1 "$settle_timeout" ready_line; then
  echo "Timed out waiting for less fixture to render the first page" >&2
  exit 1
fi
ready_capture="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"

pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
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
scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
  echo "Failed to resolve initial scroll target point" >&2
  exit 1
fi
sleep 0.2

for (( i = 1; i <= warmup_scrolls; i++ )); do
  warmup_moved=0
  for attempt in 1 2 3; do
    warmup_baseline_line="$(first_visible_line_number "$socket_name" "$target")"
    if [[ -z "$warmup_baseline_line" ]]; then
      echo "Failed to resolve warmup baseline visible line number before scroll event $i attempt $attempt" >&2
      exit 1
    fi

  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-point \
    --point-x "$scroll_point_x" \
    --point-y "$scroll_point_y" \
    --scroll-lines "$scroll_down_lines" >/dev/null

    if wait_for_first_visible_line_change "$socket_name" "$target" "$warmup_baseline_line" "down" "$settle_timeout" warmup_visible_line; then
      warmup_moved=1
      break
    fi
    sleep 0.1
  done

  if (( warmup_moved != 1 )); then
    echo "Timed out waiting for warmup scroll $i to move down after 3 attempts" >&2
    exit 1
  fi
done
sleep 0.2

latencies_file="$gate_l_tmpdir/scroll-latencies.txt"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"
last_send_json='null'
last_visible_line=""

for (( i = 1; i <= iterations; i++ )); do
  direction="down"
  scroll_lines="$scroll_down_lines"
  if (( i % 2 == 0 )); then
    direction="up"
    scroll_lines="$scroll_up_lines"
  fi

  baseline_line="$(first_visible_line_number "$socket_name" "$target")"
  if [[ -z "$baseline_line" ]]; then
    echo "Failed to resolve baseline visible line number before scroll iteration $i" >&2
    exit 1
  fi

  start_realtime="$EPOCHREALTIME"
  last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-point \
    --point-x "$scroll_point_x" \
    --point-y "$scroll_point_y" \
    --scroll-lines "$scroll_lines")"
  if ! wait_for_first_visible_line_change "$socket_name" "$target" "$baseline_line" "$direction" "$settle_timeout" last_visible_line; then
    echo "Timed out waiting for less first visible line to move $direction from $baseline_line" >&2
    exit 1
  fi
  latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  print -r -- "$latency_ms" >>"$latencies_file"
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
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --arg terminal_ax_identifier "$terminal_ax_identifier" \
  --arg terminal_ax_fallback_identifier "$terminal_ax_fallback_identifier" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --arg last_visible_line "$last_visible_line" \
  --argjson helper "$helper_json" \
  --argjson focus_snapshot "$focus_snapshot" \
  --argjson last_send "$last_send_json" \
  --argjson app_pid "$gate_l_app_pid" \
  --argjson iterations "$iterations" \
  --argjson line_count "$line_count" \
  --argjson warmup_scrolls "$warmup_scrolls" \
  --argjson scroll_lines_per_event "$scroll_lines_per_event" \
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
    line_count: $line_count,
    warmup_scrolls: $warmup_scrolls,
    scroll_lines_per_event: $scroll_lines_per_event,
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
    last_visible_line: (if $last_visible_line == "" then null else ($last_visible_line | tonumber) end),
    terminal_ax_identifier: (if $terminal_ax_identifier == "" then null else $terminal_ax_identifier end),
    terminal_ax_fallback_identifier: $terminal_ax_fallback_identifier,
    resolved_terminal_ax_identifier: $resolved_terminal_ax_identifier,
    signposts: $signposts
  }'
