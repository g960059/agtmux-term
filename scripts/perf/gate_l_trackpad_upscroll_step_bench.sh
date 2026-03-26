#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"
STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"
TMUX_TEXT_SAMPLER_PY="$SCRIPT_DIR/gate_l_tmux_text_sampler.py"
TMUX_SCROLL_AND_SAMPLE_PY="$SCRIPT_DIR/gate_l_tmux_scroll_and_sample.py"
RUN_SENDER_PY="$SCRIPT_DIR/gate_l_run_sender.py"

bursts="${AGTMUX_PERF_UPSTEP_BURSTS:-12}"
settle_timeout=15
session_name=""
line_count="${AGTMUX_PERF_LINES:-12000}"
warmup_bursts="${AGTMUX_PERF_UPSTEP_WARMUP_BURSTS:-2}"
warmup_mode="${AGTMUX_PERF_UPSTEP_WARMUP_MODE:-tmux-keys}"
events_per_burst="${AGTMUX_PERF_UPSTEP_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_UPSTEP_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_UPSTEP_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_INTERVAL_MS:-16}"
sample_tail_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-180}"
scroll_phase_mode="${AGTMUX_PERF_UPSTEP_PHASE_MODE:-trackpad-burst-momentum}"
warmup_scroll_phase_mode="${AGTMUX_PERF_UPSTEP_WARMUP_PHASE_MODE:-trackpad-burst}"
fixture_mode="${AGTMUX_PERF_UPSTEP_FIXTURE_MODE:-less}"
fixture_source_file="${AGTMUX_PERF_UPSTEP_FIXTURE_FILE:-}"
scrollback_defer_replay="${AGTMUX_PERF_SCROLLBACK_DEFER_REPLAY:-0}"
raw_alt_input_timeout_ms="${AGTMUX_PERF_RAW_ALT_TIMEOUT_MS:-15000}"
scrollback_sampler_mode="${AGTMUX_PERF_SCROLLBACK_SAMPLER_MODE:-ax-text}"
scrollback_ax_probe_identifier_mode="${AGTMUX_PERF_SCROLLBACK_AX_IDENTIFIER_MODE:-resolved}"
scroll_target_mode="${AGTMUX_PERF_UPSTEP_SCROLL_TARGET_MODE:-front-window}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"

function sleep_ms() {
  local milliseconds="$1"
  sleep "$(awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
}

function elapsed_ms_since() {
  local start_time="$1"
  awk -v now="$EPOCHREALTIME" -v start="$start_time" 'BEGIN { printf "%.3f", ((now - start) * 1000.0) }'
}

function first_visible_line_number() {
  local socket_name="$1"
  local target="$2"
  local captured
  captured="$(gate_l_tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
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

function visible_rows_capture() {
  local socket_name="$1"
  local target="$2"
  gate_l_tmux capture-pane -p -t "$target" 2>/dev/null || true
}

function tmux_alternate_on() {
  local socket_name="$1"
  local target="$2"
  gate_l_tmux display-message -p -t "$target" '#{alternate_on}' 2>/dev/null || true
}

function first_visible_line_number_from_text() {
  local captured="$1"
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

function physical_row_shift() {
  local previous_capture="$1"
  local current_capture="$2"
  local -a previous_rows
  local -a current_rows
  previous_rows=("${(@f)previous_capture}")
  current_rows=("${(@f)current_capture}")

  local previous_count=${#previous_rows}
  local current_count=${#current_rows}
  if (( previous_count == 0 || current_count == 0 )); then
    printf '0\n'
    return 0
  fi

  if [[ "${previous_rows[1]}" == "${current_rows[1]}" ]]; then
    printf '0\n'
    return 0
  fi

  local max_shift=12
  local max_probe=3
  local shift probe previous_index current_index matched
  for (( shift = 1; shift <= max_shift && shift < previous_count; shift++ )); do
    if [[ "${previous_rows[$((shift + 1))]-}" != "${current_rows[1]-}" ]]; then
      continue
    fi
    matched=1
    for (( probe = 1; probe <= max_probe; probe++ )); do
      previous_index=$(( shift + probe ))
      current_index=$probe
      if (( previous_index > previous_count || current_index > current_count )); then
        break
      fi
      if [[ "${previous_rows[$previous_index]}" != "${current_rows[$current_index]}" ]]; then
        matched=0
        break
      fi
    done
    if (( matched )); then
      printf '%s\n' "$shift"
      return 0
    fi
  done

  printf '1\n'
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

function wait_for_visible_line_stability() {
  local socket_name="$1"
  local target="$2"
  local timeout="${3:-2.0}"
  local stable_required=3
  local deadline
  deadline="$(awk -v now="$EPOCHREALTIME" -v timeout="$timeout" 'BEGIN { printf "%.6f", (now + timeout) }')"
  local last_line=""
  local stable_count=0
  local current_line=""

  while awk -v now="$EPOCHREALTIME" -v deadline="$deadline" 'BEGIN { exit !(now < deadline) }'; do
    current_line="$(first_visible_line_number "$socket_name" "$target")"
    if [[ -n "$current_line" && "$current_line" == "$last_line" ]]; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= stable_required )); then
        printf '%s\n' "$current_line"
        return 0
      fi
    else
      last_line="$current_line"
      stable_count=1
    fi
    sleep 0.05
  done

  if [[ -n "$last_line" ]]; then
    printf '%s\n' "$last_line"
  fi
  return 1
}

function wait_for_scrollback_ready() {
  local socket_name="$1"
  local target="$2"
  local ready_marker="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest=""

  while (( EPOCHREALTIME < deadline )); do
    local captured
    captured="$(gate_l_tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
    if grep -Fq "$ready_marker" <<<"$captured"; then
      latest="$(first_visible_line_number "$socket_name" "$target")"
      typeset -g "$output_var_name=$latest"
      return 0
    fi
    sleep 0.05
  done

  latest="$(first_visible_line_number "$socket_name" "$target")"
  typeset -g "$output_var_name=$latest"
  return 1
}

function wait_for_sidebar_pane_presence() {
  local session_name="$1"
  local pane_id="$2"
  local timeout="${3:-15}"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local last_snapshot=""

  while (( EPOCHREALTIME < deadline )); do
    if last_snapshot="$(gate_l_send_bridge_json_command false 2 "__agtmux_dump_sidebar_state__" "$session_name" "$pane_id" 2>"$gate_l_tmpdir/sidebar-state.last-error.log")"; then
      local present
      present="$(jq -r --arg session_name "$session_name" --arg pane_id "$pane_id" '
        (.panePresentations // [])
        | any(.sessionName == $session_name and .paneID == $pane_id)
      ' <<<"$last_snapshot")"
      if [[ "$present" == "true" ]]; then
        print -r -- "$last_snapshot"
        return 0
      fi
    fi
    sleep 0.10
  done

  echo "Timed out waiting for sidebar pane source=local session=$session_name pane=$pane_id" >&2
  if [[ -n "$last_snapshot" ]]; then
    echo "Last sidebar snapshot: $last_snapshot" >&2
  elif [[ -s "$gate_l_tmpdir/sidebar-state.last-error.log" ]]; then
    cat "$gate_l_tmpdir/sidebar-state.last-error.log" >&2
  fi
  return 1
}

function gate_l_app_is_running() {
  [[ -n "${gate_l_app_pid:-}" ]] && kill -0 "$gate_l_app_pid" >/dev/null 2>&1
}

function gate_l_tmux_target_exists() {
  local target="$1"
  gate_l_tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
}

function sample_visible_rows_json() {
  local socket_name="$1"
  local target="$2"
  local sample_count="$3"
  local interval_ms="$4"
  python3 "$TMUX_TEXT_SAMPLER_PY" \
    --socket-name "$socket_name" \
    --target "$target" \
    --sample-count "$sample_count" \
    --sample-interval-ms "$interval_ms"
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

function sample_terminal_viewport_text_json() {
  local surface_id="$1"
  local sample_count="$2"
  local interval_ms="$3"
  local output_path="$4"

  local bridge_output=""
  local bridge_error_path="$gate_l_tmpdir/viewport-sample.last-error.log"
  local request_id=""
  request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$surface_id" "$sample_count" "$interval_ms")"
  if bridge_output="$(gate_l_wait_for_async_bridge_json_result "$request_id" 20 2>"$bridge_error_path")"; then
    print -r -- "$bridge_output" >"$output_path"
    return 0
  fi

  local sample_lines_path="$gate_l_tmpdir/viewport-sample-lines.jsonl"
  rm -f "$sample_lines_path"
  local started_at="$EPOCHREALTIME"
  local index snapshot_json elapsed_ms

  for (( index = 0; index < sample_count; index++ )); do
    snapshot_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$surface_id")" || return 1
    elapsed_ms="$(elapsed_ms_since "$started_at")"
    jq -cn \
      --argjson sampleIndex "$index" \
      --argjson elapsedMs "$elapsed_ms" \
      --argjson snapshot "$snapshot_json" \
      '{sampleIndex: $sampleIndex, elapsedMs: $elapsedMs, snapshot: $snapshot}' >>"$sample_lines_path"

    if (( index + 1 < sample_count )); then
      sleep_ms "$interval_ms"
    fi
  done

  jq -s '{samples: .}' "$sample_lines_path" >"$output_path"
}

function wait_for_terminal_viewport_ready() {
  local surface_id="$1"
  local timeout="${2:-15}"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$surface_id" \
      >/dev/null 2>"$gate_l_tmpdir/viewport-ready.last-error.log"; then
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for terminal viewport readiness for surfaceID $surface_id" >&2
  if [[ -s "$gate_l_tmpdir/viewport-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/viewport-ready.last-error.log" >&2
  fi
  return 1
}

function wait_for_terminal_focus_ready() {
  local surface_id="$1"
  local timeout="${2:-5}"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local last_snapshot=""

  while (( EPOCHREALTIME < deadline )); do
    if last_snapshot="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$surface_id" 2>"$gate_l_tmpdir/focus-ready.last-error.log")"; then
      local app_is_active window_is_key terminal_is_first_responder
      app_is_active="$(jq -r '.appIsActive // false' <<<"$last_snapshot")"
      window_is_key="$(jq -r '.windowIsKey // false' <<<"$last_snapshot")"
      terminal_is_first_responder="$(jq -r '.terminalIsFirstResponder // false' <<<"$last_snapshot")"
      if [[ "$app_is_active" == "true" && "$window_is_key" == "true" && "$terminal_is_first_responder" == "true" ]]; then
        print -r -- "$last_snapshot"
        return 0
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for terminal focus readiness for surfaceID $surface_id" >&2
  if [[ -n "$last_snapshot" ]]; then
    echo "Last focus snapshot: $last_snapshot" >&2
  elif [[ -s "$gate_l_tmpdir/focus-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/focus-ready.last-error.log" >&2
  fi
  return 1
}

function build_fixture() {
  local fixture_path="$1"
  AGTMUX_PERF_TRACKPAD_FIXTURE_LINES="$line_count" python3 - <<'PY' >"$fixture_path"
import os

green = "\033[32m"
red = "\033[31m"
blue = "\033[34m"
yellow = "\033[33m"
reset = "\033[0m"

paragraph = (
    "This is a deliberately long wrapped transcript paragraph that mimics agent output, "
    "status chatter, shell diagnostics, and markdown prose so scroll pacing sees real "
    "line wrapping rather than uniform short rows."
)
code = [
    "```swift",
    "struct ScrollSample {",
    "    let title: String",
    "    let measurements: [Double]",
    "    func p95() -> Double { measurements.sorted()[Int(Double(measurements.count - 1) * 0.95)] }",
    "}",
    "```",
]
json_line = '{"type":"item.completed","status":"completed","aggregated_output":"wait_result=managed","metadata":{"provider":"codex","duration_ms":412}}'
line_count = int(os.environ["AGTMUX_PERF_TRACKPAD_FIXTURE_LINES"])

for index in range(1, line_count + 1):
    print(f"{index:06d} {blue}## Transcript block {index % 17}{reset}")
    print(f"{index:06d} {paragraph} segment={index} wrapping={'x' * 72}")
    print(f"{index:06d} {green}+ added line with ansi highlight and synthetic diff payload {index}{reset}")
    print(f"{index:06d} {red}- removed line with stderr-like content and long suffix {'error-' * 8}{reset}")
    print(f"{index:06d} {yellow}{json_line}{reset}")
    for line in code:
        print(f"{index:06d} {line}")
PY
}

function prepare_fixture() {
  local fixture_path="$1"
  if [[ -n "$fixture_source_file" ]]; then
    cp "$fixture_source_file" "$fixture_path"
    return 0
  fi
  build_fixture "$fixture_path"
}

function warmup_down_scroll() {
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    "${scroll_sender_args[@]}" \
    --scroll-pixels "$((-scroll_pixels_per_event))" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$warmup_scroll_phase_mode" >/dev/null
}

function warmup_position_for_upscroll() {
  local socket_name="$1"
  local target="$2"
  if [[ "$fixture_mode" == "scrollback" || "$fixture_mode" == "raw-alt-input-logger" || "$fixture_mode" == "curses-key-logger" ]]; then
    return 0
  fi
  case "$warmup_mode" in
    tmux-keys)
      gate_l_tmux send-keys -t "$target" -N "$events_per_burst" Down
      wait_for_visible_line_stability "$socket_name" "$target" 2.0 >/dev/null || true
      ;;
    trackpad)
      warmup_down_scroll
      sleep 0.2
      ;;
    *)
      echo "Unsupported AGTMUX_PERF_UPSTEP_WARMUP_MODE: $warmup_mode" >&2
      exit 1
      ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --bursts)
      bursts="$2"
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
      echo "Usage: $0 [--bursts COUNT] [--timeout SECONDS] [--session-name NAME]" >&2
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
socket_name="agtmux-gate-l-upstep-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-upstep-${token}"
fi
target="${session_name}:main"

gate_l_cleanup_stale_perf_processes
gate_l_setup_paths "$token"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0
gate_l_socket_name="$socket_name"
gate_l_session_name="$session_name"

burst_metrics_path="$gate_l_tmpdir/upscroll-step-burst-metrics.jsonl"
sample_metrics_path="$gate_l_tmpdir/upscroll-step-sample-metrics.jsonl"
rm -f "$burst_metrics_path" "$sample_metrics_path"

fixture_path="$gate_l_tmpdir/trackpad-history-fixture.txt"
raw_alt_input_log_path="$gate_l_tmpdir/raw-alt-input.log"
raw_curses_key_log_path="$gate_l_tmpdir/curses-key-log.json"
curses_history_event_log_path="$gate_l_tmpdir/curses-history-events.json"
scrollback_trigger_path="$gate_l_tmpdir/scrollback-trigger.ready"
prepare_fixture "$fixture_path"
ready_marker="AGTMUX_SCROLLBACK_READY_${token}"
case "$fixture_mode" in
  less)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec less -R -N \"$fixture_path\"'"
    ;;
  curses-history)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_curses_history_viewer.py\" --fixture \"$fixture_path\" --ready-marker \"$ready_marker\" --event-log \"$curses_history_event_log_path\"'"
    ;;
  raw-alt-input-logger)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_raw_alt_input_logger.py\" --ready-marker \"$ready_marker\" --output \"$raw_alt_input_log_path\" --timeout-ms \"$raw_alt_input_timeout_ms\"'"
    ;;
  curses-key-logger)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_curses_key_logger.py\" --ready-marker \"$ready_marker\" --output \"$raw_curses_key_log_path\" --timeout-ms \"$raw_alt_input_timeout_ms\"'"
    ;;
  scrollback)
    if [[ "$scrollback_defer_replay" == "1" ]]; then
      shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; while [ ! -f \"$scrollback_trigger_path\" ]; do sleep 0.05; done; cat \"$fixture_path\"; printf \"$ready_marker\\n\"; exec env PS1=\"\" /bin/sh -i'"
    else
      shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; cat \"$fixture_path\"; printf \"$ready_marker\\n\"; exec env PS1=\"\" /bin/sh -i'"
    fi
    ;;
  *)
    echo "Unsupported AGTMUX_PERF_UPSTEP_FIXTURE_MODE: $fixture_mode" >&2
    exit 1
    ;;
esac

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  gate_l_cleanup_tmux
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L upscroll-step temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app "$socket_name" "$session_name" 1 "$shell_command"

bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi
gate_l_record_bootstrap_tmux_socket_path "$bootstrap_json"

window_id="$(jq -r '.windowID // empty' <<<"$bootstrap_json")"
pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
if [[ -z "$window_id" || -z "$pane_id" ]]; then
  echo "Failed to resolve bootstrap target for $target: $bootstrap_json" >&2
  exit 1
fi
target="$pane_id"
ready_line=""
if [[ "$fixture_mode" == "scrollback" && "$scrollback_defer_replay" == "1" ]]; then
  ready_line=""
elif [[ "$fixture_mode" == "scrollback" || "$fixture_mode" == "curses-history" || "$fixture_mode" == "raw-alt-input-logger" || "$fixture_mode" == "curses-key-logger" ]]; then
  if ! wait_for_scrollback_ready "$socket_name" "$target" "$ready_marker" "$settle_timeout" ready_line; then
    echo "Timed out waiting for $fixture_mode fixture to finish rendering" >&2
    exit 1
  fi
elif ! wait_for_first_visible_line_number "$socket_name" "$target" 1 "$settle_timeout" ready_line; then
  echo "Timed out waiting for transcript fixture to render the first page" >&2
  exit 1
fi
ready_capture="$(gate_l_tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)"

gate_l_activate_app
open_terminal_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id")"
surface_id="$(jq -r '.surfaceID // empty' <<<"$open_terminal_json")"
if [[ -z "$surface_id" ]]; then
  echo "Failed to resolve surface from __agtmux_open_terminal_for_pane__: $open_terminal_json" >&2
  exit 1
fi
if ! wait_for_terminal_viewport_ready "$surface_id" "$settle_timeout"; then
  exit 1
fi
gate_l_activate_app
gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$surface_id" >/dev/null
gate_l_activate_app

if [[ "$fixture_mode" == "scrollback" && "$scrollback_defer_replay" == "1" ]]; then
  : >"$scrollback_trigger_path"
  if ! wait_for_scrollback_ready "$socket_name" "$target" "$ready_marker" "$settle_timeout" ready_line; then
    echo "Timed out waiting for deferred scrollback fixture to finish rendering" >&2
    exit 1
  fi
  ready_capture="$(gate_l_tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
  gate_l_activate_app
  gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$surface_id" >/dev/null
  sleep 0.2
fi

focus_snapshot="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_focus_state__" "$surface_id")"
terminal_ax_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_snapshot")"
terminal_ax_fallback_identifier="workspace.terminalHost.${surface_id}"
resolved_terminal_ax_identifier="$terminal_ax_identifier"
if [[ -z "$resolved_terminal_ax_identifier" ]]; then
  resolved_terminal_ax_identifier="$terminal_ax_fallback_identifier"
fi

typeset -a scroll_sender_args
typeset -a measure_scroll_sender_args
scroll_point_x=""
scroll_point_y=""
scroll_sender_args=(
  --app-pid "$gate_l_app_pid"
  --x-frac "$scroll_x_frac"
  --y-frac "$scroll_y_frac"
)
case "$scroll_target_mode" in
  identifier)
    scroll_sender_args+=(--focus-scroll-identifier "$resolved_terminal_ax_identifier")
    ;;
  front-window)
    scroll_sender_args+=(--focus-scroll-front-window)
    ;;
  *)
    echo "Unsupported AGTMUX_PERF_UPSTEP_SCROLL_TARGET_MODE: $scroll_target_mode" >&2
    exit 1
    ;;
esac

initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
  "${scroll_sender_args[@]}")"
if [[ "$(jq -r '.sent // false' <<<"$initial_focus_json")" != "true" ]]; then
  echo "Failed to focus initial scroll target: $initial_focus_json" >&2
  exit 1
fi
scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
  echo "Initial scroll target focus did not report a click point: $initial_focus_json" >&2
  exit 1
fi
measure_scroll_sender_args=(
  --app-pid "$gate_l_app_pid"
  --scroll-point
  --point-x "$scroll_point_x"
  --point-y "$scroll_point_y"
)
if ! wait_for_terminal_focus_ready "$surface_id" 5 >/dev/null; then
  exit 1
fi
sleep 0.05

if [[ "$fixture_mode" != "raw-alt-input-logger" && "$fixture_mode" != "curses-key-logger" ]]; then
  for (( i = 1; i <= warmup_bursts; i++ )); do
    warmup_position_for_upscroll "$socket_name" "$target"
  done
fi

completed_burst_count=0
empty_sample_count=0
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"

for (( burst = 1; burst <= bursts; burst++ )); do
  if ! gate_l_app_is_running; then
    echo "AgtmuxTerm exited before measured burst $burst" >&2
    exit 1
  fi

  if ! gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$surface_id" >/dev/null; then
    echo "Failed to refocus terminal host before burst $burst" >&2
    exit 1
  fi
  gate_l_activate_app
  focus_restore_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    "${scroll_sender_args[@]}")"
  if [[ "$(jq -r '.sent // false' <<<"$focus_restore_json")" != "true" ]]; then
    echo "Failed to restore scroll focus before burst $burst: $focus_restore_json" >&2
    exit 1
  fi
  scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$focus_restore_json")"
  scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$focus_restore_json")"
  if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
    echo "Scroll focus restore did not report a click point before burst $burst: $focus_restore_json" >&2
    exit 1
  fi
  measure_scroll_sender_args=(
    --app-pid "$gate_l_app_pid"
    --scroll-point
    --point-x "$scroll_point_x"
    --point-y "$scroll_point_y"
  )
  if ! wait_for_terminal_focus_ready "$surface_id" 5 >/dev/null; then
    exit 1
  fi
  warmup_position_for_upscroll "$socket_name" "$target"

baseline_capture="$(visible_rows_capture "$socket_name" "$target")"
  baseline_line="$(first_visible_line_number_from_text "$baseline_capture")"
  baseline_tmux_alternate_on="$(tmux_alternate_on "$socket_name" "$target")"
  baseline_viewport_snapshot_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_terminal_viewport_text__" "$surface_id")"
  gate_l_send_bridge_command false 10 "__agtmux_reset_scroll_telemetry__" "$surface_id" >/dev/null
  burst_scroll_telemetry_before_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$surface_id")"

  sample_json_path="$gate_l_tmpdir/upscroll-samples-${burst}.json"
  burst_capture_json_path="$gate_l_tmpdir/upscroll-capture-${burst}.json"
  sample_count="$(viewport_sample_count)"
  send_json_path="$gate_l_tmpdir/upscroll-send-${burst}.json"
  send_result_json_path="$gate_l_tmpdir/upscroll-send-result-${burst}.json"
  if [[ "$fixture_mode" == "scrollback" && "$scrollback_sampler_mode" == "bridge" ]]; then
    sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$surface_id" "$sample_count" "$sample_interval_ms")"
    python3 "$RUN_SENDER_PY" \
      --output "$send_result_json_path" \
      --start-delay-ms 20 \
      --timeout-ms 8000 \
      -- \
      "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      "${measure_scroll_sender_args[@]}" \
      --scroll-pixels "$scroll_pixels_per_event" \
      --scroll-repeat "$events_per_burst" \
      --scroll-interval-ms "$scroll_interval_ms" \
      --scroll-phase-mode "$scroll_phase_mode"
    sample_timeout="$(
      awk -v count="$sample_count" -v interval="$sample_interval_ms" 'BEGIN {
        total = (count * interval) + 5000
        timeout = int((total / 1000.0) + 5.999999)
        if (timeout < 10) timeout = 10
        print timeout
      }'
    )"
    if ! gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$sample_json_path"; then
      echo "Viewport-text bridge sampler failed for burst $burst" >&2
      exit 1
    fi
    if [[ ! -f "$send_result_json_path" ]]; then
      echo "Upscroll sender did not write a result for burst $burst" >&2
      exit 1
    fi
    jq -r '.stdout // ""' "$send_result_json_path" >"$send_json_path"
    sender_returncode="$(jq -r '.returncode // "null"' "$send_result_json_path")"
    sender_timed_out="$(jq -r '.timedOut // false' "$send_result_json_path")"
    if [[ "$sender_timed_out" == "true" || "$sender_returncode" != "0" ]]; then
      echo "Upscroll sender failed for burst $burst" >&2
      jq '.' "$send_result_json_path" >&2
      exit 1
    fi
  elif [[ "$fixture_mode" == "scrollback" && "$scrollback_sampler_mode" == "ax-text" ]]; then
    typeset -a ax_text_probe_args
    ax_text_probe_args=(
      --app-pid "$gate_l_app_pid"
      --sample-count "$sample_count"
      --sample-interval-ms "$sample_interval_ms"
    )
    if [[ "$scrollback_ax_probe_identifier_mode" != "none" && -n "$resolved_terminal_ax_identifier" ]]; then
      ax_text_probe_args+=(--identifier "$resolved_terminal_ax_identifier")
    fi
    (
      "$SCRIPT_DIR/gate_l_ax_text_probe.sh" \
        "${ax_text_probe_args[@]}" >"$sample_json_path"
    ) &
    sampler_pid=$!
    python3 "$RUN_SENDER_PY" \
      --output "$send_result_json_path" \
      --start-delay-ms 20 \
      --timeout-ms 8000 \
      -- \
      "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      "${measure_scroll_sender_args[@]}" \
      --scroll-pixels "$scroll_pixels_per_event" \
      --scroll-repeat "$events_per_burst" \
      --scroll-interval-ms "$scroll_interval_ms" \
      --scroll-phase-mode "$scroll_phase_mode"
    if ! wait "$sampler_pid"; then
      echo "AX text sampler failed for burst $burst" >&2
      exit 1
    fi
    if [[ ! -f "$send_result_json_path" ]]; then
      echo "Upscroll sender did not write a result for burst $burst" >&2
      exit 1
    fi
    jq -r '.stdout // ""' "$send_result_json_path" >"$send_json_path"
    sender_returncode="$(jq -r '.returncode // "null"' "$send_result_json_path")"
    sender_timed_out="$(jq -r '.timedOut // false' "$send_result_json_path")"
    if [[ "$sender_timed_out" == "true" || "$sender_returncode" != "0" ]]; then
      echo "Upscroll sender failed for burst $burst" >&2
      jq '.' "$send_result_json_path" >&2
      exit 1
    fi
  else
    python3 "$TMUX_SCROLL_AND_SAMPLE_PY" \
      --socket-name "$socket_name" \
      --target "$target" \
      --sample-count "$sample_count" \
      --sample-interval-ms "$sample_interval_ms" \
      --sender-start-delay-ms 20 \
      -- "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      "${measure_scroll_sender_args[@]}" \
      --scroll-pixels "$scroll_pixels_per_event" \
      --scroll-repeat "$events_per_burst" \
      --scroll-interval-ms "$scroll_interval_ms" \
      --scroll-phase-mode "$scroll_phase_mode" >"$burst_capture_json_path"
    jq '{samples: .samples}' "$burst_capture_json_path" >"$sample_json_path"
    jq -r '.sender.stdout // ""' "$burst_capture_json_path" >"$send_json_path"
    sender_returncode="$(jq -r '.sender.returncode // "null"' "$burst_capture_json_path")"
    sender_timed_out="$(jq -r '.sender.timedOut // false' "$burst_capture_json_path")"
    if [[ "$sender_timed_out" == "true" || "$sender_returncode" != "0" ]]; then
      echo "Upscroll sender failed for burst $burst" >&2
      jq '.sender' "$burst_capture_json_path" >&2
      exit 1
    fi
  fi

  burst_step_metrics_path="$gate_l_tmpdir/upscroll-step-metrics-${burst}.json"
  python3 "$STEP_METRICS_PY" "$sample_json_path" >"$burst_step_metrics_path"
  jq -c --argjson burst "$burst" '.sample_metrics[] | . + {burst: $burst}' \
    "$burst_step_metrics_path" >>"$sample_metrics_path"

  baseline_line_json="$(jq -r '.summary.baseline_line // "null"' "$burst_step_metrics_path")"
  final_visible_line_json="$(jq -r '.summary.final_visible_line // "null"' "$burst_step_metrics_path")"
  upward_total_rows="$(jq -r '.summary.upward_total_rows' "$burst_step_metrics_path")"
  line_number_upward_total_rows="$(jq -r '.summary.line_number_upward_total_rows' "$burst_step_metrics_path")"
  sample_index="$(jq -r '.summary.sample_count' "$burst_step_metrics_path")"
  changed_sample_count="$(jq -r '.summary.changed_sample_count' "$burst_step_metrics_path")"
  coarse_step_count_ge_2="$(jq -r '.summary.coarse_step_count_ge_2' "$burst_step_metrics_path")"
  coarse_step_count_ge_3="$(jq -r '.summary.coarse_step_count_ge_3' "$burst_step_metrics_path")"
  max_step_rows="$(jq -r '.summary.max_step_rows' "$burst_step_metrics_path")"
  mean_lines_per_step="$(jq -r '.summary.mean_lines_per_step // "null"' "$burst_step_metrics_path")"
  line_number_mean_lines_per_step="$(jq -r '.summary.line_number_mean_lines_per_step // "null"' "$burst_step_metrics_path")"
  first_changed_elapsed_ms="$(jq -r '.summary.first_changed_elapsed_ms // "null"' "$burst_step_metrics_path")"
  last_changed_elapsed_ms="$(jq -r '.summary.last_changed_elapsed_ms // "null"' "$burst_step_metrics_path")"
  baseline_text_json="$(jq -Rs '.' < <(jq -r '.summary.baseline_text // ""' "$burst_step_metrics_path"))"
  final_text_json="$(jq -Rs '.' < <(jq -r '.summary.final_text // ""' "$burst_step_metrics_path"))"
  first_changed_text_json="$(jq -Rs '.' < <(jq -r '.summary.first_changed_text // ""' "$burst_step_metrics_path"))"
  last_changed_text_json="$(jq -Rs '.' < <(jq -r '.summary.last_changed_text // ""' "$burst_step_metrics_path"))"

  burst_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$surface_id")"
  final_tmux_alternate_on="$(tmux_alternate_on "$socket_name" "$target")"
  final_viewport_snapshot_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_terminal_viewport_text__" "$surface_id")"
  burst_alternate_scroll_delta="$(jq -n \
    --argjson prev "$burst_scroll_telemetry_before_json" \
    --argjson curr "$burst_scroll_telemetry_json" \
    '{
      preciseEventCount: (($curr.scroll.alternateScroll.preciseEventCount // 0) - ($prev.scroll.alternateScroll.preciseEventCount // 0)),
      preciseStepCount: (($curr.scroll.alternateScroll.preciseStepCount // 0) - ($prev.scroll.alternateScroll.preciseStepCount // 0)),
      preciseMessageQueueCount: (($curr.scroll.alternateScroll.preciseMessageQueueCount // 0) - ($prev.scroll.alternateScroll.preciseMessageQueueCount // 0)),
      preciseMailboxNotifyCount: (($curr.scroll.alternateScroll.preciseMailboxNotifyCount // 0) - ($prev.scroll.alternateScroll.preciseMailboxNotifyCount // 0)),
      preciseDrainTurnCount: (($curr.scroll.alternateScroll.preciseDrainTurnCount // 0) - ($prev.scroll.alternateScroll.preciseDrainTurnCount // 0)),
      preciseDrainedMessageCount: (($curr.scroll.alternateScroll.preciseDrainedMessageCount // 0) - ($prev.scroll.alternateScroll.preciseDrainedMessageCount // 0)),
      preciseDrainRequeueCount: (($curr.scroll.alternateScroll.preciseDrainRequeueCount // 0) - ($prev.scroll.alternateScroll.preciseDrainRequeueCount // 0)),
      preciseReadChunkCount: (($curr.scroll.alternateScroll.preciseReadChunkCount // 0) - ($prev.scroll.alternateScroll.preciseReadChunkCount // 0)),
      preciseReadChunkBytes: (($curr.scroll.alternateScroll.preciseReadChunkBytes // 0) - ($prev.scroll.alternateScroll.preciseReadChunkBytes // 0)),
      preciseReadChunkMaxBytes: (($curr.scroll.alternateScroll.preciseReadChunkMaxBytes // 0) - ($prev.scroll.alternateScroll.preciseReadChunkMaxBytes // 0)),
      preciseUpSequenceCount: (($curr.scroll.alternateScroll.preciseUpSequenceCount // 0) - ($prev.scroll.alternateScroll.preciseUpSequenceCount // 0)),
      preciseDownSequenceCount: (($curr.scroll.alternateScroll.preciseDownSequenceCount // 0) - ($prev.scroll.alternateScroll.preciseDownSequenceCount // 0)),
      preciseApplicationCursorSequenceCount: (($curr.scroll.alternateScroll.preciseApplicationCursorSequenceCount // 0) - ($prev.scroll.alternateScroll.preciseApplicationCursorSequenceCount // 0)),
      preciseNormalCursorSequenceCount: (($curr.scroll.alternateScroll.preciseNormalCursorSequenceCount // 0) - ($prev.scroll.alternateScroll.preciseNormalCursorSequenceCount // 0)),
      preciseReadEscapeByteCount: (($curr.scroll.alternateScroll.preciseReadEscapeByteCount // 0) - ($prev.scroll.alternateScroll.preciseReadEscapeByteCount // 0)),
      preciseReadPrintableByteCount: (($curr.scroll.alternateScroll.preciseReadPrintableByteCount // 0) - ($prev.scroll.alternateScroll.preciseReadPrintableByteCount // 0)),
      preciseReadNewlineByteCount: (($curr.scroll.alternateScroll.preciseReadNewlineByteCount // 0) - ($prev.scroll.alternateScroll.preciseReadNewlineByteCount // 0))
    }')"
  burst_scroll_delta="$(jq -n \
    --argjson prev "$burst_scroll_telemetry_before_json" \
    --argjson curr "$burst_scroll_telemetry_json" \
    '{
      scrollInputCount: (($curr.scroll.scrollInputCount // 0) - ($prev.scroll.scrollInputCount // 0)),
      preciseScrollInputCount: (($curr.scroll.preciseScrollInputCount // 0) - ($prev.scroll.preciseScrollInputCount // 0)),
      directPhaseScrollInputCount: (($curr.scroll.directPhaseScrollInputCount // 0) - ($prev.scroll.directPhaseScrollInputCount // 0)),
      momentumPhaseScrollInputCount: (($curr.scroll.momentumPhaseScrollInputCount // 0) - ($prev.scroll.momentumPhaseScrollInputCount // 0)),
      scrollPresentationDrawCount: (($curr.scroll.scrollPresentationDrawCount // 0) - ($prev.scroll.scrollPresentationDrawCount // 0)),
      layerPresentCount: (($curr.scroll.layerPresentCount // 0) - ($prev.scroll.layerPresentCount // 0))
    }')"
  jq -n \
    --argjson burst "$burst" \
    --argjson baseline_line "$baseline_line_json" \
    --argjson final_visible_line "$final_visible_line_json" \
    --argjson upward_total_rows "$upward_total_rows" \
    --argjson line_number_upward_total_rows "$line_number_upward_total_rows" \
    --argjson sample_count "$sample_index" \
    --argjson changed_sample_count "$changed_sample_count" \
    --argjson unchanged_sample_count "$(( sample_index - changed_sample_count ))" \
    --argjson coarse_step_count_ge_2 "$coarse_step_count_ge_2" \
    --argjson coarse_step_count_ge_3 "$coarse_step_count_ge_3" \
    --argjson max_step_rows "$max_step_rows" \
    --argjson mean_lines_per_step "$mean_lines_per_step" \
    --argjson line_number_mean_lines_per_step "$line_number_mean_lines_per_step" \
    --argjson first_changed_elapsed_ms "$first_changed_elapsed_ms" \
    --argjson last_changed_elapsed_ms "$last_changed_elapsed_ms" \
    --argjson baseline_text "$baseline_text_json" \
    --argjson final_text "$final_text_json" \
    --argjson first_changed_text "$first_changed_text_json" \
    --argjson last_changed_text "$last_changed_text_json" \
    --arg baseline_tmux_alternate_on "$baseline_tmux_alternate_on" \
    --arg final_tmux_alternate_on "$final_tmux_alternate_on" \
    --argjson baseline_viewport_snapshot "$baseline_viewport_snapshot_json" \
    --argjson final_viewport_snapshot "$final_viewport_snapshot_json" \
    --argjson alternate_scroll_delta "$burst_alternate_scroll_delta" \
    --argjson scroll_telemetry_delta "$burst_scroll_delta" \
    --argjson send_json "$(cat "$send_json_path")" \
    '{
      burst: $burst,
      baseline_line: $baseline_line,
      final_visible_line: $final_visible_line,
      upward_total_rows: $upward_total_rows,
      line_number_upward_total_rows: $line_number_upward_total_rows,
      sample_count: $sample_count,
      changed_sample_count: $changed_sample_count,
      unchanged_sample_count: $unchanged_sample_count,
      coarse_step_count_ge_2: $coarse_step_count_ge_2,
      coarse_step_count_ge_3: $coarse_step_count_ge_3,
      max_step_rows: $max_step_rows,
      mean_lines_per_step: $mean_lines_per_step,
      line_number_mean_lines_per_step: $line_number_mean_lines_per_step,
      first_changed_elapsed_ms: $first_changed_elapsed_ms,
      last_changed_elapsed_ms: $last_changed_elapsed_ms,
      baseline_text: $baseline_text,
      final_text: $final_text,
      first_changed_text: $first_changed_text,
      last_changed_text: $last_changed_text,
      baseline_tmux_alternate_on: $baseline_tmux_alternate_on,
      final_tmux_alternate_on: $final_tmux_alternate_on,
      baseline_viewport_snapshot: $baseline_viewport_snapshot,
      final_viewport_snapshot: $final_viewport_snapshot,
      alternate_scroll_delta: $alternate_scroll_delta,
      scroll_telemetry_delta: $scroll_telemetry_delta,
      send_json: $send_json
    }' >>"$burst_metrics_path"

  completed_burst_count=$((completed_burst_count + 1))
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"
post_scroll_focus_snapshot="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_focus_state__" "$surface_id")"
post_scroll_telemetry="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$surface_id")"

jq -n \
  --arg app_bin "$GATE_L_APP_BIN" \
  --argjson app_pid "$gate_l_app_pid" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg pane_id "$pane_id" \
  --arg surface_id "$surface_id" \
  --arg benchmark_start "$bench_start" \
  --arg benchmark_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --argjson bursts "$bursts" \
  --argjson warmup_bursts "$warmup_bursts" \
  --argjson events_per_burst "$events_per_burst" \
  --argjson scroll_pixels_per_event "$scroll_pixels_per_event" \
  --argjson scroll_interval_ms "$scroll_interval_ms" \
  --argjson sample_interval_ms "$sample_interval_ms" \
  --argjson sample_tail_ms "$sample_tail_ms" \
  --arg scroll_phase_mode "$scroll_phase_mode" \
  --argjson scroll_x_frac "$scroll_x_frac" \
  --argjson scroll_y_frac "$scroll_y_frac" \
  --argjson empty_sample_count "$empty_sample_count" \
  --argjson completed_burst_count "$completed_burst_count" \
  --slurpfile burst_metrics "$burst_metrics_path" \
  --slurpfile sample_metrics "$sample_metrics_path" \
  --argjson helper "$helper_json" \
  --argjson focus_snapshot "$focus_snapshot" \
  --argjson post_scroll_focus_snapshot "$post_scroll_focus_snapshot" \
  --argjson post_scroll_telemetry "$post_scroll_telemetry" \
  --arg terminal_ax_identifier "$terminal_ax_identifier" \
  --arg terminal_ax_fallback_identifier "$terminal_ax_fallback_identifier" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --arg raw_alt_input_log_path "$raw_alt_input_log_path" \
  --arg raw_curses_key_log_path "$raw_curses_key_log_path" \
  --arg curses_history_event_log_path "$curses_history_event_log_path" \
  --arg scroll_target_mode "$scroll_target_mode" \
  '
  def percentile($samples; $p):
    if ($samples | length) == 0 then
      null
    else
      ($samples | sort) as $sorted
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
  def summary($samples):
    if ($samples | length) == 0 then
      {count: 0, p50: null, p95: null, max: null}
    else
      {
        count: ($samples | length),
        p50: percentile($samples; 50),
        p95: percentile($samples; 95),
        max: ($samples | max)
      }
    end;
  ($sample_metrics // []) as $sample_metrics
  | ($burst_metrics // []) as $burst_metrics
  | ($sample_metrics | map(select(.step_rows > 0)) | map(.step_rows)) as $changed_steps
  | ($changed_steps | map(select(. >= 2))) as $coarse_steps_ge_2
  | ($changed_steps | map(select(. >= 3))) as $coarse_steps_ge_3
  | ($burst_metrics | map(select(.mean_lines_per_step != null)) | map(.mean_lines_per_step)) as $mean_lines_per_step_samples
  | ($burst_metrics | map(.upward_total_rows)) as $upward_total_rows_samples
  | ($burst_metrics | map(select(.first_changed_elapsed_ms != null)) | map(.first_changed_elapsed_ms)) as $first_changed_elapsed_ms_samples
  | ($burst_metrics | map(select(.last_changed_elapsed_ms != null)) | map(.last_changed_elapsed_ms)) as $last_changed_elapsed_ms_samples
  | {
      app_bin: $app_bin,
      app_pid: $app_pid,
      session_name: $session_name,
      socket_name: $socket_name,
      target: $target,
      pane_id: $pane_id,
      surface_id: $surface_id,
      benchmark_start: $benchmark_start,
      benchmark_end: $benchmark_end,
      bursts: $bursts,
      warmup_bursts: $warmup_bursts,
      events_per_burst: $events_per_burst,
      scroll_pixels_per_event: $scroll_pixels_per_event,
      scroll_interval_ms: $scroll_interval_ms,
      sample_interval_ms: $sample_interval_ms,
      sample_tail_ms: $sample_tail_ms,
      scroll_phase_mode: $scroll_phase_mode,
      scroll_x_frac: $scroll_x_frac,
      scroll_y_frac: $scroll_y_frac,
      helper: $helper,
      focus_snapshot: $focus_snapshot,
      post_scroll_focus_snapshot: $post_scroll_focus_snapshot,
      post_scroll_telemetry: $post_scroll_telemetry,
      ready_capture: $ready_capture,
      terminal_ax_identifier: $terminal_ax_identifier,
      terminal_ax_fallback_identifier: $terminal_ax_fallback_identifier,
      resolved_terminal_ax_identifier: $resolved_terminal_ax_identifier,
      raw_alt_input_log_path: $raw_alt_input_log_path,
      raw_curses_key_log_path: $raw_curses_key_log_path,
      curses_history_event_log_path: $curses_history_event_log_path,
      scroll_target_mode: $scroll_target_mode,
      metrics: {
        direction: "up",
        empty_sample_count: $empty_sample_count,
        completed_burst_count: $completed_burst_count,
        sample_count: ($sample_metrics | length),
        changed_sample_count: ($changed_steps | length),
        unchanged_sample_count: (($sample_metrics | length) - ($changed_steps | length)),
        step_rows: {
          count: (summary($changed_steps).count),
          p50_rows: (summary($changed_steps).p50),
          p95_rows: (summary($changed_steps).p95),
          max_rows: (summary($changed_steps).max)
        },
        mean_lines_per_step: {
          count: (summary($mean_lines_per_step_samples).count),
          p50_lines: (summary($mean_lines_per_step_samples).p50),
          p95_lines: (summary($mean_lines_per_step_samples).p95),
          max_lines: (summary($mean_lines_per_step_samples).max)
        },
        upward_total_rows: {
          count: (summary($upward_total_rows_samples).count),
          p50_rows: (summary($upward_total_rows_samples).p50),
          p95_rows: (summary($upward_total_rows_samples).p95),
          max_rows: (summary($upward_total_rows_samples).max)
        },
        first_changed_elapsed_ms: {
          count: (summary($first_changed_elapsed_ms_samples).count),
          p50_ms: (summary($first_changed_elapsed_ms_samples).p50),
          p95_ms: (summary($first_changed_elapsed_ms_samples).p95),
          max_ms: (summary($first_changed_elapsed_ms_samples).max)
        },
        last_changed_elapsed_ms: {
          count: (summary($last_changed_elapsed_ms_samples).count),
          p50_ms: (summary($last_changed_elapsed_ms_samples).p50),
          p95_ms: (summary($last_changed_elapsed_ms_samples).p95),
          max_ms: (summary($last_changed_elapsed_ms_samples).max)
        },
        coarse_step_count_ge_2: ($coarse_steps_ge_2 | length),
        coarse_step_ratio_ge_2: (
          if ($changed_steps | length) == 0 then
            null
          else
            (($coarse_steps_ge_2 | length) / ($changed_steps | length))
          end
        ),
        coarse_step_count_ge_3: ($coarse_steps_ge_3 | length),
        coarse_step_ratio_ge_3: (
          if ($changed_steps | length) == 0 then
            null
          else
            (($coarse_steps_ge_3 | length) / ($changed_steps | length))
          end
        )
      },
      burst_metrics: $burst_metrics,
      sample_metrics: $sample_metrics
    }
  '
