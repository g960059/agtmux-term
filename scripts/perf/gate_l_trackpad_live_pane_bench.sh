#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"
STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"

session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-vm agtmux-term}"
pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-}"
bursts="${AGTMUX_PERF_LIVE_BURSTS:-1}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-20}"
events_per_burst="${AGTMUX_PERF_LIVE_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_LIVE_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_LIVE_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_LIVE_SAMPLE_INTERVAL_MS:-50}"
sample_tail_ms="${AGTMUX_PERF_LIVE_SAMPLE_TAIL_MS:-2600}"
scroll_phase_mode="${AGTMUX_PERF_LIVE_PHASE_MODE:-trackpad-burst-momentum}"
scroll_target_mode="${AGTMUX_PERF_LIVE_SCROLL_TARGET_MODE:-identifier}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"

function sleep_ms() {
  local milliseconds="$1"
  sleep "$(awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
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

function gate_l_start_async_bridge_command() {
  local refresh="$1"
  shift

  local request_id
  request_id="$(uuidgen)"

  rm -f "$gate_l_command_path" "$gate_l_command_result_path"
  jq -n \
    --arg id "$request_id" \
    --argjson refresh "$refresh" \
    '{id:$id, args:$ARGS.positional, refreshInventory:$refresh}' \
    --args -- "$@" \
    >"$gate_l_command_path"

  print -r -- "$request_id"
}

function gate_l_wait_for_async_bridge_json_result() {
  local request_id="$1"
  local timeout="$2"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if [[ -s "$gate_l_command_result_path" ]]; then
      local response_id
      response_id="$(jq -r '.id // empty' "$gate_l_command_result_path" 2>/dev/null || true)"
      if [[ "$response_id" == "$request_id" ]]; then
        local ok
        ok="$(jq -r '.ok' "$gate_l_command_result_path")"
        if [[ "$ok" == "true" ]]; then
          local output
          output="$(jq -r '.stdout' "$gate_l_command_result_path")"
          if ! jq -e . >/dev/null 2>&1 <<<"$output"; then
            echo "App-side tmux command returned non-JSON stdout for request $request_id" >&2
            print -r -- "$output" >&2
            return 1
          fi
          print -r -- "$output"
          return 0
        fi

        local error_message
        error_message="$(jq -r '.error // "unknown error"' "$gate_l_command_result_path")"
        echo "App-side tmux command failed: $error_message" >&2
        return 1
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for app-side tmux command result: $request_id" >&2
  return 1
}

while (( $# > 0 )); do
  case "$1" in
    --session-name)
      session_name="$2"
      shift 2
      ;;
    --pane-id)
      pane_id="$2"
      shift 2
      ;;
    --bursts)
      bursts="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--session-name NAME] [--pane-id %id] [--bursts N] [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$pane_id" ]]; then
  pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

if [[ -z "$pane_id" ]]; then
  echo "Failed to resolve pane id; pass --pane-id explicitly" >&2
  exit 1
fi

token="live-pane-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
gate_l_setup_paths "$token"
export AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX=1
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0

cleanup() {
  local exit_status=$?
  gate_l_terminate_app
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L live pane temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

gate_l_launch_app_without_bootstrap "agtmux-gate-l-$token" 0
gate_l_wait_for_bridge_ready "$settle_timeout"
gate_l_activate_app

open_json="$(gate_l_send_bridge_json_command true "$settle_timeout" "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id")"
surface_id="$(jq -r '.surfaceID // empty' <<<"$open_json")"
if [[ -z "$surface_id" ]]; then
  echo "Failed to open live pane $session_name $pane_id: $open_json" >&2
  exit 1
fi

if ! wait_for_terminal_viewport_ready "$surface_id" "$settle_timeout"; then
  exit 1
fi
gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$surface_id" >/dev/null
gate_l_activate_app

focus_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_focus_state__" "$surface_id")"
terminal_ax_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_json")"
resolved_terminal_ax_identifier="$terminal_ax_identifier"
if [[ -z "$resolved_terminal_ax_identifier" ]]; then
  resolved_terminal_ax_identifier="workspace.terminalHost.${surface_id}"
fi

typeset -a scroll_sender_args
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
    echo "Unsupported AGTMUX_PERF_LIVE_SCROLL_TARGET_MODE: $scroll_target_mode" >&2
    exit 1
    ;;
esac

initial_focus_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" "${scroll_sender_args[@]}")"
if [[ "$(jq -r '.sent // false' <<<"$initial_focus_json")" != "true" ]]; then
  echo "Failed to focus live pane scroll target: $initial_focus_json" >&2
  exit 1
fi
sleep 0.2

burst_metrics_path="$gate_l_tmpdir/live-pane-burst-metrics.jsonl"
rm -f "$burst_metrics_path"

for (( burst = 1; burst <= bursts; burst++ )); do
  gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$surface_id" >/dev/null
  gate_l_activate_app

  gate_l_send_bridge_command false 10 "__agtmux_reset_scroll_telemetry__" "$surface_id" >/dev/null

  sample_json_path="$gate_l_tmpdir/live-pane-samples-${burst}.json"
  sample_count="$(viewport_sample_count)"
  send_json_path="$gate_l_tmpdir/live-pane-send-${burst}.json"
  sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$surface_id" "$sample_count" "$sample_interval_ms")"
  sleep_ms 20
  if ! perl -e 'alarm shift @ARGV; exec @ARGV' 8 \
    "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    "${scroll_sender_args[@]}" \
    --scroll-pixels "$scroll_pixels_per_event" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path" 2>&1; then
    echo "Live-pane sender failed for burst $burst" >&2
    [[ -f "$send_json_path" ]] && cat "$send_json_path" >&2
    exit 1
  fi
  sample_timeout="$(
    awk -v count="$sample_count" -v interval="$sample_interval_ms" 'BEGIN {
      printf "%.3f", ((count * interval) / 1000.0) + 5.0
    }'
  )"
  if ! gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$sample_json_path"; then
    echo "Live-pane bridge sampler failed for burst $burst" >&2
    exit 1
  fi

  step_metrics_path="$gate_l_tmpdir/live-pane-step-metrics-${burst}.json"
  python3 "$STEP_METRICS_PY" "$sample_json_path" >"$step_metrics_path"
  scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$surface_id")"

  python3 - "$burst" "$step_metrics_path" "$scroll_telemetry_json" <<'PY' >>"$burst_metrics_path"
import json
import sys
burst = int(sys.argv[1])
step_path = sys.argv[2]
telemetry = json.loads(sys.argv[3])
with open(step_path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)
sample_metrics = payload.get('sample_metrics', [])
changed_elapsed = [m.get('elapsed_ms') for m in sample_metrics if (m.get('step_rows') or 0) > 0 and m.get('elapsed_ms') is not None]
gaps = []
for idx in range(1, len(changed_elapsed)):
    gaps.append(changed_elapsed[idx] - changed_elapsed[idx - 1])
gaps_sorted = sorted(gaps)
def percentile(values, p):
    if not values:
        return None
    if len(values) == 1:
        return float(values[0])
    idx = int(round((len(values) - 1) * p))
    return float(values[idx])
summary = payload.get('summary', {})
result = {
    'burst': burst,
    'first_changed_ms': changed_elapsed[0] if changed_elapsed else None,
    'last_changed_ms': changed_elapsed[-1] if changed_elapsed else None,
    'changed_transition_count': len(changed_elapsed),
    'change_gap_p50_ms': percentile(gaps_sorted, 0.50),
    'change_gap_p95_ms': percentile(gaps_sorted, 0.95),
    'change_gap_max_ms': max(gaps) if gaps else None,
    'changed_sample_count': summary.get('changed_sample_count'),
    'coarse_step_count_ge_2': summary.get('coarse_step_count_ge_2'),
    'coarse_step_count_ge_3': summary.get('coarse_step_count_ge_3'),
    'max_step_rows': summary.get('max_step_rows'),
    'mean_lines_per_step': summary.get('mean_lines_per_step'),
    'scrollPresentationDrawCount': telemetry.get('scroll', {}).get('scrollPresentationDrawCount'),
    'layerPresentCount': telemetry.get('scroll', {}).get('layerPresentCount'),
    'scrollInputCount': telemetry.get('scroll', {}).get('scrollInputCount'),
    'preciseScrollInputCount': telemetry.get('scroll', {}).get('preciseScrollInputCount'),
    'directPhaseScrollInputCount': telemetry.get('scroll', {}).get('directPhaseScrollInputCount'),
    'momentumPhaseScrollInputCount': telemetry.get('scroll', {}).get('momentumPhaseScrollInputCount'),
}
print(json.dumps(result))
PY
done

python3 - "$burst_metrics_path" "$session_name" "$pane_id" "$gate_l_tmpdir" <<'PY'
import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
session_name = sys.argv[2]
pane_id = sys.argv[3]
tmpdir = sys.argv[4]

bursts = [json.loads(line) for line in metrics_path.read_text().splitlines() if line.strip()]

def percentile(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return float(vals[0])
    idx = int(round((len(vals) - 1) * p))
    return float(vals[idx])

summary = {
    "first_changed_ms": {
        "p50": percentile([b.get("first_changed_ms") for b in bursts], 0.50),
        "p95": percentile([b.get("first_changed_ms") for b in bursts], 0.95),
        "max": max((b.get("first_changed_ms") for b in bursts if b.get("first_changed_ms") is not None), default=None),
    },
    "change_gap_p95_ms": {
        "p50": percentile([b.get("change_gap_p95_ms") for b in bursts], 0.50),
        "p95": percentile([b.get("change_gap_p95_ms") for b in bursts], 0.95),
        "max": max((b.get("change_gap_p95_ms") for b in bursts if b.get("change_gap_p95_ms") is not None), default=None),
    },
    "changed_transition_count": {
        "p50": percentile([b.get("changed_transition_count") for b in bursts], 0.50),
        "p95": percentile([b.get("changed_transition_count") for b in bursts], 0.95),
        "min": min((b.get("changed_transition_count") for b in bursts if b.get("changed_transition_count") is not None), default=None),
    },
    "max_step_rows": {
        "p50": percentile([b.get("max_step_rows") for b in bursts], 0.50),
        "p95": percentile([b.get("max_step_rows") for b in bursts], 0.95),
        "max": max((b.get("max_step_rows") for b in bursts if b.get("max_step_rows") is not None), default=None),
    },
}

print(json.dumps({
    "sessionName": session_name,
    "paneID": pane_id,
    "tmpdir": tmpdir,
    "bursts": bursts,
    "metrics": summary,
}, ensure_ascii=False))
PY
