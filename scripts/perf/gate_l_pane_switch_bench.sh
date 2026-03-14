#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=20
settle_timeout=15
source_name="local"
session_name=""

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

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="agtmux-gate-l-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-${token}"
fi

gate_l_setup_paths "$token"

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
initial_snapshot="$(gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout")"
first_pane_id="$(jq -r '.renderedClientPaneID' <<<"$initial_snapshot")"

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
  gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "$source_name" "$session_name" "$target_pane_id" >/dev/null
  gate_l_activate_app
  gate_l_wait_for_active_target "$session_name" "$window_id" "$target_pane_id" "$settle_timeout" >/dev/null
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
  --arg window_id "$window_id" \
  --arg first_pane_id "$first_pane_id" \
  --arg second_pane_id "$second_pane_id" \
  --arg bench_start "$bench_start" \
  --arg bench_end "$bench_end" \
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
    window_id: $window_id,
    first_pane_id: $first_pane_id,
    second_pane_id: $second_pane_id,
    benchmark_start: $bench_start,
    benchmark_end: $bench_end,
    iterations: $iterations,
    latencies_ms: ($latencies | map(round3)),
    p50_ms: (($latencies | percentile(50)) | round3),
    p95_ms: (($latencies | percentile(95)) | round3),
    max_ms: (($latencies | max) | round3),
    signposts: $signposts
  }
  '
