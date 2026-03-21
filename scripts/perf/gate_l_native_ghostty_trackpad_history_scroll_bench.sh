#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=8
settle_timeout=15
app_path=""
keep_running=0
allow_existing=0
line_count="${AGTMUX_PERF_LINES:-12000}"
warmup_bursts="${AGTMUX_PERF_TRACKPAD_WARMUP_BURSTS:-2}"
events_per_burst="${AGTMUX_PERF_TRACKPAD_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_TRACKPAD_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_TRACKPAD_INTERVAL_MS:-8}"
burst_pause_ms="${AGTMUX_PERF_TRACKPAD_BURST_PAUSE_MS:-120}"
scroll_phase_mode="${AGTMUX_PERF_TRACKPAD_PHASE_MODE:-trackpad-burst-momentum}"

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
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--keep-running] [--allow-existing]" >&2
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
socket_name="gate-l-native-trackpad-${token}"
session_name="gate-l-native-trackpad-${token}"
target="${session_name}:main"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-trackpad.XXXXXX")"
burst_metrics_path="$tmpdir/trackpad-burst-metrics.jsonl"
fixture_path="$tmpdir/trackpad-history-fixture.txt"

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

shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec less -R -N \"$fixture_path\"'"

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
    echo "Gate-L native trackpad temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

tmux -f /dev/null -L "$socket_name" new-session -d -s "$session_name" -n main "$shell_command"

ready_line=""
if ! wait_for_first_visible_line_number "$socket_name" "$target" 1 "$settle_timeout" ready_line; then
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

perl -e 'alarm 5; exec @ARGV' osascript -e "tell application id \"$bundle_id\" to activate" >/dev/null 2>"$tmpdir/activate.stderr"
sleep 1

initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
  --app-pid "$launched_pid" \
  --click-front-window \
  --x-frac 0.75 \
  --y-frac 0.50)"
scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
  echo "Failed to resolve native initial scroll target point" >&2
  exit 1
fi
sleep 0.2

for (( i = 1; i <= warmup_bursts; i++ )); do
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$launched_pid" \
    --focus-scroll-point \
    --point-x "$scroll_point_x" \
    --point-y "$scroll_point_y" \
    --scroll-pixels "$((-scroll_pixels_per_event))" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode" >/dev/null
  sleep 0.2
done

empty_burst_count=0
last_send_json='null'
last_visible_line=""
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"

for (( i = 1; i <= iterations; i++ )); do
  scroll_pixels="$((-scroll_pixels_per_event))"
  direction="down"
  if (( i % 2 == 0 )); then
    scroll_pixels="$scroll_pixels_per_event"
    direction="up"
  fi

  baseline_line="$(first_visible_line_number "$socket_name" "$target")"
  if [[ -z "$baseline_line" ]]; then
    echo "Failed to resolve native baseline visible line number before trackpad burst $i" >&2
    exit 1
  fi

  burst_started_at="$EPOCHREALTIME"
  last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$launched_pid" \
    --focus-scroll-point \
    --point-x "$scroll_point_x" \
    --point-y "$scroll_point_y" \
    --scroll-pixels "$scroll_pixels" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode")"

  burst_latency_ms="null"
  if ! wait_for_first_visible_line_change "$socket_name" "$target" "$baseline_line" "$direction" "$settle_timeout" last_visible_line; then
    empty_burst_count=$((empty_burst_count + 1))
  else
    burst_latency_ms="$(awk "BEGIN { printf \"%.3f\", ((${EPOCHREALTIME} - ${burst_started_at}) * 1000.0) }")"
  fi

  jq -n \
    --argjson iteration "$i" \
    --arg direction "$direction" \
    --argjson baseline_line "$baseline_line" \
    --argjson visible_line "${last_visible_line:-null}" \
    --argjson latency_ms "$burst_latency_ms" \
    '{
      iteration: $iteration,
      direction: $direction,
      baseline_line: $baseline_line,
      visible_line: $visible_line,
      latency_ms: $latency_ms
    }' >>"$burst_metrics_path"

  sleep "$(awk "BEGIN { printf \"%.3f\", (${burst_pause_ms} / 1000.0) }")"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"

jq -n \
  --arg app_path "$app_path" \
  --arg display_name "$display_name" \
  --arg bundle_id "$bundle_id" \
  --arg executable "$app_bin" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg benchmark_start "$bench_start" \
  --arg benchmark_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --arg last_visible_line "$last_visible_line" \
  --arg activate_stderr "$(cat "$tmpdir/activate.stderr" 2>/dev/null || true)" \
  --argjson helper "$helper_json" \
  --argjson last_send "$last_send_json" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --argjson launched_pid "${launched_pid:-null}" \
  --argjson launch_reused_existing "$launch_reused_existing" \
  --argjson iterations "$iterations" \
  --argjson line_count "$line_count" \
  --argjson warmup_bursts "$warmup_bursts" \
  --argjson events_per_burst "$events_per_burst" \
  --argjson scroll_pixels_per_event "$scroll_pixels_per_event" \
  --argjson scroll_interval_ms "$scroll_interval_ms" \
  --argjson burst_pause_ms "$burst_pause_ms" \
  --arg scroll_phase_mode "$scroll_phase_mode" \
  --argjson empty_burst_count "$empty_burst_count" \
  --slurpfile burst_metrics "$burst_metrics_path" '
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
      {count: 0, p50_ms: null, p95_ms: null, max_ms: null}
    else
      {
        count: ($samples | length),
        p50_ms: percentile($samples; 50),
        p95_ms: percentile($samples; 95),
        max_ms: ($samples | max)
      }
    end;
  ($burst_metrics // []) as $burst_metrics
  | ($burst_metrics | map(.latency_ms) | map(select(. != null))) as $visible_line_samples
  | {
      app_path: $app_path,
      display_name: $display_name,
      bundle_id: $bundle_id,
      executable: $executable,
      tmux: {
        session_name: $session_name,
        socket_name: $socket_name,
        target: $target
      },
      launch: {
        launched_pid: $launched_pid,
        reused_existing_process: ($launch_reused_existing == 1),
        prelaunch_pids: ($prelaunch_pids | map(tonumber)),
        postlaunch_pids: ($postlaunch_pids | map(tonumber)),
        activate_stderr: $activate_stderr
      },
      line_count: $line_count,
      warmup_bursts: $warmup_bursts,
      events_per_burst: $events_per_burst,
      scroll_pixels_per_event: $scroll_pixels_per_event,
      scroll_interval_ms: $scroll_interval_ms,
      burst_pause_ms: $burst_pause_ms,
      scroll_phase_mode: $scroll_phase_mode,
      benchmark_start: $benchmark_start,
      benchmark_end: $benchmark_end,
      iterations: $iterations,
      helper: $helper,
      last_send: $last_send,
      ready_capture: $ready_capture,
      last_visible_line: ($last_visible_line | tonumber?),
      metrics: {
        tmux_visible_line_change_ms: summary($visible_line_samples),
        empty_burst_count: $empty_burst_count,
        completed_burst_count: ($visible_line_samples | length)
      },
      burst_metrics: $burst_metrics
    }
  '
