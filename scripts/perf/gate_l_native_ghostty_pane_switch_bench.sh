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
mode="key"

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

function wait_for_active_pane() {
  local socket_name="$1"
  local target="$2"
  local pane_id="$3"
  local timeout="$4"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest=""

  while (( EPOCHREALTIME < deadline )); do
    latest="$(tmux -f /dev/null -L "$socket_name" display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)"
    if [[ "$latest" == "$pane_id" ]]; then
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for active pane $pane_id in $target; latest=$latest" >&2
  return 1
}

function send_tmux_next_pane_keys() {
  local sequence_json
  if ! sequence_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --sequence tmux-next-pane)"; then
    echo "Failed to send tmux pane-switch sequence: $sequence_json" >&2
    return 1
  fi
}

function wait_for_client_tty() {
  local socket_name="$1"
  local session_name="$2"
  local timeout="$3"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local latest=""

  while (( EPOCHREALTIME < deadline )); do
    latest="$(tmux -f /dev/null -L "$socket_name" list-clients -F '#{client_tty}|#{session_name}|#{window_id}|#{pane_id}' 2>/dev/null | awk -F'|' -v session="$session_name" '$1 != "" && $2 == session { print $1; exit }')"
    if [[ -n "$latest" ]]; then
      print -r -- "$latest"
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for native Ghostty client tty in session $session_name" >&2
  return 1
}

function focus_front_window_terminal() {
  local click_json
  local attempts=10
  local attempt=1
  while (( attempt <= attempts )); do
    if click_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --app-pid "$launched_pid" --click-front-window --x-frac 0.75 --y-frac 0.5 2>&1)"; then
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  echo "Failed to focus front window terminal: $click_json" >&2
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
    --mode)
      mode="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--keep-running] [--allow-existing] [--mode key|client]" >&2
      exit 1
      ;;
  esac
done

if [[ "$mode" != "key" && "$mode" != "client" ]]; then
  echo "Unsupported pane-switch mode: $mode" >&2
  exit 1
fi

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
if [[ "$mode" == "key" && "$(jq -r '.trusted' <<<"$helper_json")" != "true" ]]; then
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
  echo "Existing native Ghostty processes would make pane-switch attribution ambiguous; rerun after closing them or pass --allow-existing: ${prelaunch_pids[*]}" >&2
  exit 1
fi

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="gate-l-native-switch-${token}"
session_name="gate-l-native-switch-${token}"
target="${session_name}:main"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-switch.XXXXXX")"

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
    echo "Gate-L native pane-switch temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

tmux -f /dev/null -L "$socket_name" new-session -d -s "$session_name" -n main /bin/sleep 600
tmux -f /dev/null -L "$socket_name" set-option -g prefix C-a
tmux -f /dev/null -L "$socket_name" set-option -s escape-time 0
tmux -f /dev/null -L "$socket_name" unbind C-b
tmux -f /dev/null -L "$socket_name" split-window -t "$target" -h /bin/sleep 600

pane_rows="$(tmux -f /dev/null -L "$socket_name" list-panes -t "$target" -F '#{window_id}|#{pane_id}')"
pane_ids=()
window_id=""
while IFS='|' read -r current_window current_pane; do
  [[ -z "$current_pane" ]] && continue
  pane_ids+=("$current_pane")
  window_id="$current_window"
done <<<"$pane_rows"

if (( ${#pane_ids[@]} != 2 )); then
  echo "Expected exactly two panes for native pane-switch benchmark, got ${#pane_ids[@]}" >&2
  exit 1
fi

first_pane_id="${pane_ids[1]}"
second_pane_id="${pane_ids[2]}"
tmux -f /dev/null -L "$socket_name" select-pane -t "$first_pane_id"

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
focus_front_window_terminal
wait_for_active_pane "$socket_name" "$target" "$first_pane_id" "$settle_timeout"
rendered_client_tty="$(wait_for_client_tty "$socket_name" "$session_name" "$settle_timeout")"

latencies_file="$tmpdir/pane-switch-latencies.txt"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"

for (( i = 1; i <= iterations; i++ )); do
  target_pane_id="$second_pane_id"
  if (( i % 2 == 0 )); then
    target_pane_id="$first_pane_id"
  fi

  start_realtime="$EPOCHREALTIME"
  if [[ "$mode" == "key" ]]; then
    focus_front_window_terminal
    send_tmux_next_pane_keys
  else
    tmux -f /dev/null -L "$socket_name" select-pane -t "$target_pane_id"
  fi
  wait_for_active_pane "$socket_name" "$target" "$target_pane_id" "$settle_timeout"
  latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  print -r -- "$latency_ms" >>"$latencies_file"
done

latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$latencies_file")"

jq -n \
  --arg app_path "$app_path" \
  --arg app_bin "$app_bin" \
  --arg display_name "$display_name" \
  --arg bundle_id "$bundle_id" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg mode "$mode" \
  --arg window_id "$window_id" \
  --arg first_pane_id "$first_pane_id" \
  --arg second_pane_id "$second_pane_id" \
  --arg rendered_client_tty "$rendered_client_tty" \
  --argjson iterations "$iterations" \
  --argjson latencies "$latencies_json" \
  --argjson helper "$helper_json" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --arg launched_pid "${launched_pid:-}" \
  --argjson launch_reused_existing "$launch_reused_existing" '
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
    app_bin: $app_bin,
    display_name: $display_name,
    bundle_id: $bundle_id,
    tmux: {
      session_name: $session_name,
      socket_name: $socket_name,
      target: $target,
      mode: $mode,
      window_id: $window_id,
      first_pane_id: $first_pane_id,
      second_pane_id: $second_pane_id,
      rendered_client_tty: $rendered_client_tty
    },
    helper: $helper,
    launch: {
      launched_pid: (if $launched_pid == "" then null else ($launched_pid | tonumber) end),
      reused_existing_process: ($launch_reused_existing == 1),
      prelaunch_pids: ($prelaunch_pids | map(tonumber)),
      postlaunch_pids: ($postlaunch_pids | map(tonumber))
    },
    iterations: $iterations,
    latencies_ms: ($latencies | map(round3)),
    p50_ms: (($latencies | percentile(50)) | round3),
    p95_ms: (($latencies | percentile(95)) | round3),
    max_ms: (($latencies | max) | round3)
  }
  '
