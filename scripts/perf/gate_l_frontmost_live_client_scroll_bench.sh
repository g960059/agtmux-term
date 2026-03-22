#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
METRICS_PY="$SCRIPT_DIR/gate_l_client_scroll_metrics.py"
SCROLL_AND_SEND_PY="$SCRIPT_DIR/gate_l_tmux_client_scroll_and_send.py"

app_pid=""
bundle_id=""
client_tty=""
label="${AGTMUX_PERF_LIVE_LABEL:-live}"
events_per_burst="${AGTMUX_PERF_UPSTEP_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_UPSTEP_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_UPSTEP_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_INTERVAL_MS:-16}"
sample_tail_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-180}"
scroll_phase_mode="${AGTMUX_PERF_UPSTEP_PHASE_MODE:-trackpad-burst-momentum}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"
focus_settle_ms="${AGTMUX_PERF_FOCUS_SETTLE_MS:-120}"
keep_tmp="${AGTMUX_PERF_KEEP_TMP:-0}"

while (( $# > 0 )); do
  case "$1" in
    --app-pid)
      app_pid="$2"
      shift 2
      ;;
    --bundle-id)
      bundle_id="$2"
      shift 2
      ;;
    --client-tty)
      client_tty="$2"
      shift 2
      ;;
    --label)
      label="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$app_pid" && -z "$bundle_id" ]]; then
  echo "gate_l_frontmost_live_client_scroll_bench.sh requires --app-pid or --bundle-id" >&2
  exit 2
fi
if [[ -z "$client_tty" ]]; then
  echo "gate_l_frontmost_live_client_scroll_bench.sh requires --client-tty" >&2
  exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-live-client-scroll.XXXXXX")"
cleanup() {
  local exit_status=$?
  if (( exit_status == 0 )) && [[ "$keep_tmp" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L live client-scroll temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

function append_app_target_args() {
  local array_name="$1"
  if [[ -n "$app_pid" ]]; then
    eval "$array_name+=(--app-pid \"\$app_pid\")"
  fi
  if [[ -n "$bundle_id" ]]; then
    eval "$array_name+=(--bundle-id \"\$bundle_id\")"
  fi
}

function sample_count_for_burst() {
  awk -v events="$events_per_burst" -v interval="$scroll_interval_ms" -v tail="$sample_tail_ms" -v sample_interval="$sample_interval_ms" \
    'BEGIN {
      total_ms = (events * interval) + tail
      samples = int((total_ms / sample_interval) + 2.999999)
      if (samples < 3) samples = 3
      print samples
    }'
}

focus_args=(--focus-scroll-front-window --x-frac "$scroll_x_frac" --y-frac "$scroll_y_frac")
append_app_target_args focus_args
focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" "${focus_args[@]}")"
if [[ "$(jq -r '.sent // false' <<<"$focus_json")" != "true" ]]; then
  echo "Failed to focus live frontmost target: $focus_json" >&2
  exit 1
fi
focus_json_path="$tmpdir/focus.json"
printf '%s\n' "$focus_json" >"$focus_json_path"

scroll_point_x="$(jq -r '.clickPoint.x // empty' <<<"$focus_json")"
scroll_point_y="$(jq -r '.clickPoint.y // empty' <<<"$focus_json")"
if [[ -z "$scroll_point_x" || -z "$scroll_point_y" ]]; then
  echo "Focus action did not report a click point: $focus_json" >&2
  exit 1
fi

sleep "$(awk -v ms="$focus_settle_ms" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"

sample_count="$(sample_count_for_burst)"
sample_json_path="$tmpdir/live-client-scroll-samples.json"
metrics_path="$tmpdir/live-client-scroll-metrics.json"

send_args=(--scroll-point --point-x "$scroll_point_x" --point-y "$scroll_point_y" --scroll-pixels "$scroll_pixels_per_event" --scroll-repeat "$events_per_burst" --scroll-interval-ms "$scroll_interval_ms" --scroll-phase-mode "$scroll_phase_mode")
append_app_target_args send_args
python3 "$SCROLL_AND_SEND_PY" \
  --client-tty "$client_tty" \
  --sample-count "$sample_count" \
  --sample-interval-ms "$sample_interval_ms" \
  --sender-start-delay-ms 20 \
  --sender-timeout-ms 8000 \
  -- \
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
  "${send_args[@]}" >"$sample_json_path"

sender_returncode="$(jq -r '.sender.returncode // "null"' "$sample_json_path")"
sender_timed_out="$(jq -r '.sender.timedOut // false' "$sample_json_path")"
if [[ "$sender_timed_out" == "true" || "$sender_returncode" != "0" ]]; then
  echo "Live frontmost sender failed" >&2
  jq '.sender' "$sample_json_path" >&2
  exit 1
fi

python3 "$METRICS_PY" "$sample_json_path" >"$metrics_path"

send_payload="null"
sender_stdout="$(jq -r '.sender.stdout // empty' "$sample_json_path")"
if [[ -n "$sender_stdout" ]] && jq -e . >/dev/null 2>&1 <<<"$sender_stdout"; then
  send_payload="$sender_stdout"
fi
sender_json_path="$tmpdir/sender.json"
send_json_path="$tmpdir/send.json"
jq '.sender' "$sample_json_path" >"$sender_json_path"
printf '%s\n' "$send_payload" >"$send_json_path"

jq -n \
  --arg label "$label" \
  --arg app_pid "${app_pid:-}" \
  --arg bundle_id "${bundle_id:-}" \
  --arg client_tty "$client_tty" \
  --slurpfile focus "$focus_json_path" \
  --slurpfile sender "$sender_json_path" \
  --slurpfile send "$send_json_path" \
  --slurpfile samples "$sample_json_path" \
  --slurpfile metrics "$metrics_path" \
  --arg tmpdir "$tmpdir" \
  '{
    label: $label,
    app_pid: ($app_pid | if length > 0 then . else null end),
    bundle_id: ($bundle_id | if length > 0 then . else null end),
    client_tty: $client_tty,
    focus: $focus[0],
    sender: $sender[0],
    send_json: $send[0],
    samples: $samples[0],
    metrics: $metrics[0],
    tmpdir: $tmpdir
  }'
