#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=20
settle_timeout=15
source_name="local"
session_name=""
mode="bridge"
terminal_ax_identifier=""
terminal_ax_fallback_identifier=""
tile_id=""
rendered_client_tty=""
helper_json='null'

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

function send_tmux_next_pane_keys() {
  local sequence_json
  if ! sequence_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --app-pid "$gate_l_app_pid" --sequence tmux-next-pane)"; then
    echo "Failed to send tmux pane-switch sequence: $sequence_json" >&2
    return 1
  fi
}

function switch_rendered_client_to_pane() {
  local client_tty="$1"
  local target_pane_id="$2"
  (
    unset TMUX TMUX_PANE
    gate_l_tmux select-pane -t "$target_pane_id"
  )
}

function focus_front_window_terminal() {
  local target_identifier="$1"
  local fallback_identifier="${2:-}"
  local click_json
  local attempts=10
  local attempt=1
  while (( attempt <= attempts )); do
    if click_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --app-pid "$gate_l_app_pid" --click-identifier "$target_identifier" --x-frac 0.5 --y-frac 0.5 2>&1)"; then
      return 0
    fi
    if [[ -n "$fallback_identifier" ]] && click_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --app-pid "$gate_l_app_pid" --click-identifier "$fallback_identifier" --x-frac 0.5 --y-frac 0.5 2>&1)"; then
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
    --session-name)
      session_name="$2"
      shift 2
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--session-name NAME] [--mode bridge|key|client]" >&2
      exit 1
      ;;
  esac
done

if [[ "$mode" != "bridge" && "$mode" != "key" && "$mode" != "client" ]]; then
  echo "Unsupported pane-switch mode: $mode" >&2
  exit 1
fi

gate_l_require_app_bin

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="agtmux-gate-l-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-${token}"
fi

gate_l_setup_paths "$token"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  gate_l_cleanup_tmux
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L pane-switch temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app "$socket_name" "$session_name" 1 "/bin/sleep 600"
gate_l_activate_app

bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
  echo "App-side bootstrap failed: $(jq -r '.error // "unknown error"' <<<"$bootstrap_json")" >&2
  exit 1
fi
gate_l_record_bootstrap_tmux_socket_path "$bootstrap_json"

if [[ "$mode" == "key" ]]; then
  gate_l_send_bridge_command true 10 set-option -g prefix C-a >/dev/null
  gate_l_send_bridge_command true 10 set-option -s escape-time 0 >/dev/null
  gate_l_send_bridge_command true 10 unbind C-b >/dev/null
fi

window_id="$(jq -r '.windowID' <<<"$bootstrap_json")"
bootstrap_first_pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"

gate_l_send_bridge_command true 10 split-window -t "${session_name}:main" -h /bin/sleep 600 >/dev/null
pane_rows="$(gate_l_send_bridge_command false 10 list-panes -t "${session_name}:main" -F '#{window_id}|#{pane_id}')"

first_pane_id=""
second_pane_id=""
pane_ids=()
while IFS='|' read -r current_window current_pane; do
  [[ -z "$current_pane" ]] && continue
  if [[ "$current_window" != "$window_id" ]]; then
    echo "Unexpected window drift during pane enumeration: expected $window_id got $current_window" >&2
    exit 1
  fi
  pane_ids+=("$current_pane")
done <<<"$pane_rows"

if (( ${#pane_ids[@]} != 2 )); then
  echo "Expected exactly two panes for pane-switch benchmark, got ${#pane_ids[@]}" >&2
  exit 1
fi

gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "$source_name" "$session_name" "$bootstrap_first_pane_id" >/dev/null
gate_l_activate_app
initial_rendered_snapshot="$(gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout")"
first_pane_id="$(jq -r '.renderedClientPaneID' <<<"$initial_rendered_snapshot")"
initial_snapshot="$(gate_l_wait_for_active_target "$session_name" "$window_id" "$first_pane_id" "$settle_timeout")"
tile_id="$(jq -r '.tileID' <<<"$initial_snapshot")"
rendered_client_tty="$(jq -r '.renderedClientTTY // empty' <<<"$initial_snapshot")"
if [[ "$mode" == "client" && -z "$rendered_client_tty" ]]; then
  echo "Could not resolve rendered client tty for client-mode pane-switch benchmark" >&2
  exit 1
fi

for current_pane in "${pane_ids[@]}"; do
  if [[ "$current_pane" != "$first_pane_id" ]]; then
    second_pane_id="$current_pane"
  fi
done

if [[ -z "$second_pane_id" ]]; then
  echo "Could not resolve second pane after initial rendered target settled" >&2
  echo "Bootstrap first pane: $bootstrap_first_pane_id" >&2
  echo "Rendered initial pane: $first_pane_id" >&2
  exit 1
fi

latencies_file="$gate_l_tmpdir/pane-switch-latencies.txt"
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"

for (( i = 1; i <= iterations; i++ )); do
  target_pane_id="$second_pane_id"
  if (( i % 2 == 0 )); then
    target_pane_id="$first_pane_id"
  fi

  start_realtime="$EPOCHREALTIME"
  if [[ "$mode" == "bridge" ]]; then
    gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "$source_name" "$session_name" "$target_pane_id" >/dev/null
    gate_l_activate_app
  elif [[ "$mode" == "key" ]]; then
    gate_l_send_bridge_command false 10 "__agtmux_send_tmux_next_pane_keys__" "$tile_id" >/dev/null
  else
    switch_rendered_client_to_pane "$rendered_client_tty" "$target_pane_id"
  fi
  gate_l_wait_for_rendered_target "$session_name" "$window_id" "$target_pane_id" "$settle_timeout" >/dev/null
  latency_ms="$(awk "BEGIN { printf \"%.3f\", (($EPOCHREALTIME - $start_realtime) * 1000.0) }")"
  print -r -- "$latency_ms" >>"$latencies_file"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"
sleep 1

latencies_json="$(jq -Rsc 'split("\n")[:-1] | map(select(length > 0) | tonumber)' <"$latencies_file")"
signpost_json="$("$SCRIPT_DIR/gate_l_signpost_summary.sh" --start "$bench_start" --end "$bench_end" --pid "$gate_l_app_pid")"

jq -n \
  --arg app_bin "$GATE_L_APP_BIN" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg source_name "$source_name" \
  --arg mode "$mode" \
  --arg window_id "$window_id" \
  --arg first_pane_id "$first_pane_id" \
  --arg second_pane_id "$second_pane_id" \
  --arg rendered_client_tty "$rendered_client_tty" \
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
  --argjson helper "$helper_json" \
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
    source_name: $source_name,
    mode: $mode,
    window_id: $window_id,
    first_pane_id: $first_pane_id,
    second_pane_id: $second_pane_id,
    rendered_client_tty: (if $rendered_client_tty == "" then null else $rendered_client_tty end),
    benchmark_start: $bench_start,
    benchmark_end: $bench_end,
    iterations: $iterations,
    helper: $helper,
    latencies_ms: ($latencies | map(round3)),
    p50_ms: (($latencies | percentile(50)) | round3),
    p95_ms: (($latencies | percentile(95)) | round3),
    max_ms: (($latencies | max) | round3),
    signposts: $signposts
  }
  '
