#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=20
settle_timeout=15
app_path=""
keep_running=0
allow_existing=0
key_code=0
key_hex="61"
key_label="a"

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

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
  echo "Existing native Ghostty processes would make keypress attribution ambiguous; rerun after closing them or pass --allow-existing: ${prelaunch_pids[*]}" >&2
  exit 1
fi

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="gate-l-native-key-${token}"
session_name="gate-l-native-key-${token}"
target="${session_name}:main"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-key.XXXXXX")"
keypress_driver_path="$tmpdir/gate-l-keypress-driver.py"

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
    echo "Gate-L native keypress temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

tmux -f /dev/null -L "$socket_name" new-session -d -s "$session_name" -n main "python3 -u $keypress_driver_path"

ready_capture=""
if ! wait_for_pane_text "$socket_name" "$target" "__GATE_L_READY__" "$settle_timeout" ready_capture; then
  echo "Timed out waiting for native keypress driver readiness banner" >&2
  exit 1
fi

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
  --y-frac 0.5)"
keypress_point_x="$(jq -r '.clickPoint.x // empty' <<<"$initial_focus_json")"
keypress_point_y="$(jq -r '.clickPoint.y // empty' <<<"$initial_focus_json")"
if [[ -z "$keypress_point_x" || -z "$keypress_point_y" ]]; then
  echo "Failed to resolve native initial keypress target point" >&2
  exit 1
fi
sleep 0.2

latencies_file="$tmpdir/keypress-latencies.txt"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"
last_sequence="$(latest_key_sequence "$socket_name" "$target")"
last_send_json='null'
last_capture="$ready_capture"

for (( i = 1; i <= iterations; i++ )); do
  expected_sequence=$((last_sequence + 1))
  expected_marker="__GATE_L_KEY__:${expected_sequence}:${key_hex}"
  start_realtime="$EPOCHREALTIME"
  last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$launched_pid" \
    --focus-key-point \
    --point-x "$keypress_point_x" \
    --point-y "$keypress_point_y" \
    --key-code "$key_code")"
  if ! wait_for_pane_text "$socket_name" "$target" "$expected_marker" "$settle_timeout" last_capture; then
    echo "Timed out waiting for native keypress marker $expected_marker" >&2
    exit 1
  fi
  latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  print -r -- "$latency_ms" >>"$latencies_file"
  last_sequence="$expected_sequence"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"

latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$latencies_file")"

jq -n \
  --arg app_path "$app_path" \
  --arg display_name "$display_name" \
  --arg bundle_id "$bundle_id" \
  --arg executable "$app_bin" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg key_label "$key_label" \
  --arg key_hex "$key_hex" \
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
  --arg ready_capture "$ready_capture" \
  --arg final_capture "$last_capture" \
  --arg activate_stderr "$(cat "$tmpdir/activate.stderr" 2>/dev/null || true)" \
  --argjson helper "$helper_json" \
  --argjson last_send "$last_send_json" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --arg launched_pid "${launched_pid:-}" \
  --argjson launch_reused_existing "$launch_reused_existing" \
  --argjson iterations "$iterations" \
  --argjson latencies "$latencies_json" '
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
      launched_pid: (if $launched_pid == "" then null else ($launched_pid | tonumber) end),
      reused_existing_process: ($launch_reused_existing == 1),
      prelaunch_pids: ($prelaunch_pids | map(tonumber)),
      postlaunch_pids: ($postlaunch_pids | map(tonumber)),
      activate_stderr: $activate_stderr
    },
    key_label: $key_label,
    key_hex: $key_hex,
    benchmark_start: $bench_start,
    benchmark_end: $bench_end,
    iterations: $iterations,
    latencies_ms: $latencies,
    p50_ms: (($latencies | percentile(50)) | round3),
    p95_ms: (($latencies | percentile(95)) | round3),
    max_ms: (($latencies | max) | round3),
    helper: $helper,
    last_send: $last_send,
    ready_capture: $ready_capture,
    final_capture: $final_capture
  }'
