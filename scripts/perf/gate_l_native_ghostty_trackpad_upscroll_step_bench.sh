#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"
STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"
TMUX_TEXT_SAMPLER_PY="$SCRIPT_DIR/gate_l_tmux_text_sampler.py"
TMUX_SCROLL_AND_SAMPLE_PY="$SCRIPT_DIR/gate_l_tmux_scroll_and_sample.py"

bursts="${AGTMUX_PERF_UPSTEP_BURSTS:-12}"
settle_timeout=15
app_path=""
keep_running=0
allow_existing=0
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

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

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

function visible_rows_capture() {
  local socket_name="$1"
  local target="$2"
  tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" 2>/dev/null || true
}

function tmux_alternate_on() {
  local socket_name="$1"
  local target="$2"
  tmux -f /dev/null -L "$socket_name" display-message -p -t "$target" '#{alternate_on}' 2>/dev/null || true
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

function viewport_sample_count() {
  awk -v events="$events_per_burst" -v interval="$scroll_interval_ms" -v tail="$sample_tail_ms" -v sample_interval="$sample_interval_ms" \
    'BEGIN {
      total_ms = (events * interval) + tail
      samples = int((total_ms / sample_interval) + 2.999999)
      if (samples < 3) samples = 3
      print samples
    }'
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
    captured="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
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
    --app-pid "$launched_pid" \
    --focus-scroll-front-window \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac" \
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
      tmux -f /dev/null -L "$socket_name" send-keys -t "$target" -N "$events_per_burst" Down
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
    captured="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
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
    --app)
      app_path="$2"
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    --allow-existing)
      allow_existing=1
      shift
      ;;
    *)
      echo "Usage: $0 [--bursts COUNT] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--keep-running] [--allow-existing]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$app_path" ]]; then
  if ! app_path="$(gate_l_resolve_native_ghostty_app_path)"; then
    echo "Could not locate Ghostty.app in /Applications, Spotlight, or vendor/ghostty/zig-out" >&2
    exit 1
  fi
fi

if [[ ! -d "$app_path" ]]; then
  echo "Ghostty.app does not exist: $app_path" >&2
  exit 1
fi

plist_path="$app_path/Contents/Info.plist"
bundle_id="$(gate_l_read_plist_value "$plist_path" "CFBundleIdentifier")"
display_name="$(gate_l_read_plist_value "$plist_path" "CFBundleDisplayName")"
executable_name="$(gate_l_read_plist_value "$plist_path" "CFBundleExecutable")"

if [[ -z "$bundle_id" || -z "$executable_name" ]]; then
  echo "Failed to read Ghostty bundle metadata from $plist_path" >&2
  exit 1
fi

app_bin="$app_path/Contents/MacOS/$executable_name"
if [[ ! -x "$app_bin" ]]; then
  echo "Ghostty executable is not runnable: $app_bin" >&2
  exit 1
fi

helper_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --dry-run)"
if [[ "$(jq -r '.trusted' <<<"$helper_json")" != "true" ]]; then
  echo "AX helper is not trusted: $helper_json" >&2
  exit 2
fi

typeset -A existing_pids
prelaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
prelaunch_pids=(${prelaunch_pids:#})
for pid in "${prelaunch_pids[@]}"; do
  [[ -n "$pid" ]] && existing_pids[$pid]=1
done

if (( allow_existing != 1 && ${#prelaunch_pids[@]} > 0 )); then
  echo "Existing native Ghostty processes would make trackpad attribution ambiguous; rerun after closing them or pass --allow-existing: ${prelaunch_pids[*]}" >&2
  exit 1
fi

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="gate-l-native-upstep-${token}"
session_name="gate-l-native-upstep-${token}"
target="${session_name}:main"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-upstep.XXXXXX")"
burst_metrics_path="$tmpdir/upscroll-step-burst-metrics.jsonl"
sample_metrics_path="$tmpdir/upscroll-step-sample-metrics.jsonl"
fixture_path="$tmpdir/trackpad-history-fixture.txt"
raw_curses_key_log_path="$tmpdir/curses-key-log.json"
curses_history_event_log_path="$tmpdir/curses-history-events.json"
scrollback_trigger_path="$tmpdir/scrollback-trigger.ready"

prepare_fixture "$fixture_path"
ready_marker="AGTMUX_SCROLLBACK_READY_${token}"
case "$fixture_mode" in
  less)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec less -R -N \"$fixture_path\"'"
    ;;
  curses-history)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_curses_history_viewer.py\" --fixture \"$fixture_path\" --ready-marker \"$ready_marker\" --event-log \"$curses_history_event_log_path\"'"
    ;;
  curses-key-logger)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_curses_key_logger.py\" --ready-marker \"$ready_marker\" --output \"$raw_curses_key_log_path\" --timeout-ms \"$raw_alt_input_timeout_ms\"'"
    ;;
  raw-alt-input-logger)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec python3 \"$SCRIPT_DIR/gate_l_raw_alt_input_logger.py\" --ready-marker \"$ready_marker\" --output \"$tmpdir/raw-alt-input.log\" --timeout-ms \"$raw_alt_input_timeout_ms\"'"
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

launched_pid=""
launch_reused_existing=0

cleanup() {
  local exit_status=$?
  if [[ -n "$launched_pid" && "$keep_running" != "1" ]]; then
    kill "$launched_pid" 2>/dev/null || true
  fi
  tmux -f /dev/null -L "$socket_name" kill-server >/dev/null 2>&1 || true
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L native upscroll-step temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

tmux -f /dev/null -L "$socket_name" new-session -d -s "$session_name" -n main "$shell_command"

ready_line=""
if [[ "$fixture_mode" == "scrollback" && "$scrollback_defer_replay" == "1" ]]; then
  ready_line=""
elif [[ "$fixture_mode" == "scrollback" || "$fixture_mode" == "curses-history" || "$fixture_mode" == "raw-alt-input-logger" || "$fixture_mode" == "curses-key-logger" ]]; then
  if ! wait_for_scrollback_ready "$socket_name" "$target" "$ready_marker" "$settle_timeout" ready_line; then
    echo "Timed out waiting for native $fixture_mode fixture to finish rendering" >&2
    exit 1
  fi
elif ! wait_for_first_visible_line_number "$socket_name" "$target" 1 "$settle_timeout" ready_line; then
  echo "Timed out waiting for native transcript fixture to render the first page" >&2
  exit 1
fi
ready_capture="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"

open -na "$app_path" --args -e tmux -f /dev/null -L "$socket_name" attach-session -t "$session_name" >/dev/null 2>&1
sleep 2

postlaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
postlaunch_pids=(${postlaunch_pids:#})
for pid in "${postlaunch_pids[@]}"; do
  [[ -z "$pid" ]] && continue
  if [[ -z "${existing_pids[$pid]-}" ]]; then
    launched_pid="$pid"
    break
  fi
done

if [[ -z "$launched_pid" && ${#postlaunch_pids[@]} -gt 0 ]]; then
  launched_pid="${postlaunch_pids[-1]}"
  launch_reused_existing=1
fi

if [[ -z "$launched_pid" ]]; then
  echo "Failed to resolve a native Ghostty pid after launch" >&2
  exit 1
fi

if ! perl -e 'alarm 5; exec @ARGV' osascript -e "tell application id \"$bundle_id\" to activate" >/dev/null 2>"$tmpdir/activate.stderr"; then
  echo "Failed to activate native Ghostty ($bundle_id); stderr follows" >&2
  cat "$tmpdir/activate.stderr" >&2 || true
  exit 1
fi
sleep 1

if [[ "$fixture_mode" == "scrollback" && "$scrollback_defer_replay" == "1" ]]; then
  : >"$scrollback_trigger_path"
  if ! wait_for_scrollback_ready "$socket_name" "$target" "$ready_marker" "$settle_timeout" ready_line; then
    echo "Timed out waiting for deferred native scrollback fixture to finish rendering" >&2
    exit 1
  fi
  ready_capture="$(tmux -f /dev/null -L "$socket_name" capture-pane -p -t "$target" -S -200 2>/dev/null || true)"
fi

initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
  --app-pid "$launched_pid" \
  --focus-scroll-front-window \
  --x-frac 0.5 \
  --y-frac 0.5)"
if [[ "$(jq -r '.sent // false' <<<"$initial_focus_json")" != "true" ]]; then
  echo "Failed to focus native Ghostty scroll target: $initial_focus_json" >&2
  exit 1
fi
scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
  echo "Native Ghostty initial focus did not report a click point: $initial_focus_json" >&2
  exit 1
fi
sleep 0.2

if [[ "$fixture_mode" != "raw-alt-input-logger" && "$fixture_mode" != "curses-key-logger" ]]; then
  for (( i = 1; i <= warmup_bursts; i++ )); do
    warmup_position_for_upscroll "$socket_name" "$target"
  done
fi

completed_burst_count=0
empty_sample_count=0
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"

for (( burst = 1; burst <= bursts; burst++ )); do
  if ! kill -0 "$launched_pid" >/dev/null 2>&1; then
    echo "Native Ghostty exited before measured burst $burst" >&2
    exit 1
  fi

  focus_restore_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$launched_pid" \
    --focus-scroll-front-window \
    --x-frac "$scroll_x_frac" \
    --y-frac "$scroll_y_frac")"
  if [[ "$(jq -r '.sent // false' <<<"$focus_restore_json")" != "true" ]]; then
    echo "Failed to refocus native Ghostty before burst $burst: $focus_restore_json" >&2
    exit 1
  fi
  scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$focus_restore_json")"
  scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$focus_restore_json")"
  if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
    echo "Native Ghostty focus restore did not report a click point before burst $burst: $focus_restore_json" >&2
    exit 1
  fi
  warmup_position_for_upscroll "$socket_name" "$target"

  baseline_capture="$(visible_rows_capture "$socket_name" "$target")"
  baseline_line="$(first_visible_line_number_from_text "$baseline_capture")"
  baseline_tmux_alternate_on="$(tmux_alternate_on "$socket_name" "$target")"

  sample_json_path="$tmpdir/upscroll-samples-${burst}.json"
  burst_capture_json_path="$tmpdir/upscroll-capture-${burst}.json"
  sample_count="$(viewport_sample_count)"
  send_json_path="$tmpdir/upscroll-send-${burst}.json"
  if [[ "$fixture_mode" == "scrollback" && "$scrollback_sampler_mode" == "ax-text" ]]; then
    (
      sleep_ms 20
      perl -e 'alarm shift @ARGV; exec @ARGV' 8 \
        "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
        --app-pid "$launched_pid" \
        --scroll-point \
        --point-x "$scroll_point_x" \
        --point-y "$scroll_point_y" \
        --scroll-pixels "$scroll_pixels_per_event" \
        --scroll-repeat "$events_per_burst" \
        --scroll-interval-ms "$scroll_interval_ms" \
        --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path" 2>&1
    ) &
    sender_pid=$!
    if ! "$SCRIPT_DIR/gate_l_ax_text_probe.sh" \
      --app-pid "$launched_pid" \
      --sample-count "$sample_count" \
      --sample-interval-ms "$sample_interval_ms" >"$sample_json_path"; then
      kill "$sender_pid" >/dev/null 2>&1 || true
      wait "$sender_pid" >/dev/null 2>&1 || true
      echo "Native AX text sampler failed for burst $burst" >&2
      exit 1
    fi
    if ! wait "$sender_pid"; then
      echo "Native upscroll sender failed for burst $burst" >&2
      [[ -f "$send_json_path" ]] && cat "$send_json_path" >&2
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
      --app-pid "$launched_pid" \
      --scroll-point \
      --point-x "$scroll_point_x" \
      --point-y "$scroll_point_y" \
      --scroll-pixels "$scroll_pixels_per_event" \
      --scroll-repeat "$events_per_burst" \
      --scroll-interval-ms "$scroll_interval_ms" \
      --scroll-phase-mode "$scroll_phase_mode" >"$burst_capture_json_path"
    jq '{samples: .samples}' "$burst_capture_json_path" >"$sample_json_path"
    jq -r '.sender.stdout // ""' "$burst_capture_json_path" >"$send_json_path"
    sender_returncode="$(jq -r '.sender.returncode // "null"' "$burst_capture_json_path")"
    sender_timed_out="$(jq -r '.sender.timedOut // false' "$burst_capture_json_path")"
    if [[ "$sender_timed_out" == "true" || "$sender_returncode" != "0" ]]; then
      echo "Native upscroll sender failed for burst $burst" >&2
      jq '.sender' "$burst_capture_json_path" >&2
      exit 1
    fi
  fi

  burst_step_metrics_path="$tmpdir/upscroll-step-metrics-${burst}.json"
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
  final_tmux_alternate_on="$(tmux_alternate_on "$socket_name" "$target")"

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
      send_json: $send_json
    }' >>"$burst_metrics_path"

  completed_burst_count=$((completed_burst_count + 1))
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"

jq -n \
  --arg app_path "$app_path" \
  --arg bundle_id "$bundle_id" \
  --arg display_name "$display_name" \
  --arg raw_curses_key_log_path "$raw_curses_key_log_path" \
  --arg curses_history_event_log_path "$curses_history_event_log_path" \
  --arg app_bin "$app_bin" \
  --argjson app_pid "$launched_pid" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
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
  --argjson helper "$helper_json" \
  --argjson reused_existing_process "$launch_reused_existing" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --slurpfile burst_metrics "$burst_metrics_path" \
  --slurpfile sample_metrics "$sample_metrics_path" \
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
      app_path: $app_path,
      bundle_id: $bundle_id,
      display_name: $display_name,
      raw_curses_key_log_path: $raw_curses_key_log_path,
      curses_history_event_log_path: $curses_history_event_log_path,
      app_bin: $app_bin,
      app_pid: $app_pid,
      session_name: $session_name,
      socket_name: $socket_name,
      target: $target,
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
      ready_capture: $ready_capture,
      launch: {
        reused_existing_process: ($reused_existing_process == 1),
        prelaunch_pids: ($prelaunch_pids | map(tonumber)),
        postlaunch_pids: ($postlaunch_pids | map(tonumber))
      },
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
