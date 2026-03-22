#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations=8
settle_timeout=15
session_name=""
line_count="${AGTMUX_PERF_LINES:-12000}"
warmup_bursts="${AGTMUX_PERF_TRACKPAD_WARMUP_BURSTS:-2}"
events_per_burst="${AGTMUX_PERF_TRACKPAD_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_TRACKPAD_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_TRACKPAD_INTERVAL_MS:-8}"
burst_pause_ms="${AGTMUX_PERF_TRACKPAD_BURST_PAUSE_MS:-120}"
burst_metrics_path=""
scroll_phase_mode="${AGTMUX_PERF_TRACKPAD_PHASE_MODE:-trackpad-burst-momentum}"
fixture_mode="${AGTMUX_PERF_TRACKPAD_FIXTURE_MODE:-less}"
fixture_source_file="${AGTMUX_PERF_TRACKPAD_FIXTURE_FILE:-}"

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

function gate_l_app_is_running() {
  [[ -n "${gate_l_app_pid:-}" ]] && kill -0 "$gate_l_app_pid" >/dev/null 2>&1
}

function gate_l_tmux_target_exists() {
  local target="$1"
  gate_l_tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
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
    elif ! gate_l_tmux_target_exists "$target"; then
      typeset -g "$output_var_name=$latest"
      return 2
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
socket_name="agtmux-gate-l-trackpad-${token}"
if [[ -z "$session_name" ]]; then
  session_name="agtmux-gate-l-trackpad-${token}"
fi
target=""

gate_l_cleanup_stale_perf_processes
gate_l_setup_paths "$token"
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0
burst_metrics_path="$gate_l_tmpdir/trackpad-burst-metrics.jsonl"
rm -f "$burst_metrics_path"

fixture_path="$gate_l_tmpdir/trackpad-history-fixture.txt"
if [[ -n "$fixture_source_file" ]]; then
  cp "$fixture_source_file" "$fixture_path"
else
AGTMUX_PERF_TRACKPAD_FIXTURE_LINES="$line_count" python3 - <<'PY' >"$fixture_path"
import os
import itertools

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
fi

ready_marker="AGTMUX_SCROLLBACK_READY_${token}"
case "$fixture_mode" in
  less)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; exec less -R -N \"$fixture_path\"'"
    ;;
  scrollback)
    shell_command="/bin/sh -lc 'tput civis >/dev/null 2>&1 || true; cat \"$fixture_path\"; printf \"$ready_marker\\n\"; exec sleep 600'"
    ;;
  *)
    echo "Unsupported AGTMUX_PERF_TRACKPAD_FIXTURE_MODE: $fixture_mode" >&2
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
    echo "Gate-L trackpad temp dir: $gate_l_tmpdir" >&2
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

pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
target="$pane_id"
ready_line=""
if [[ "$fixture_mode" == "scrollback" ]]; then
  if ! wait_for_scrollback_ready "$socket_name" "$target" "$ready_marker" "$settle_timeout" ready_line; then
    echo "Timed out waiting for scrollback fixture to finish rendering" >&2
    exit 1
  fi
elif ! wait_for_first_visible_line_number "$socket_name" "$target" 1 "$settle_timeout" ready_line; then
  echo "Timed out waiting for transcript fixture to render the first page" >&2
  exit 1
fi
ready_capture="$(gate_l_tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)"

gate_l_activate_app
gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "$pane_id" >/dev/null
gate_l_activate_app

gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout" >/dev/null
# Read the successful bridge response directly from the result file so the bench
# does not depend on a large JSON snapshot surviving a shell round-trip.
tile_id="$(jq -r '.stdout | fromjson | .tileID' "$gate_l_command_result_path")"
gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$tile_id" >/dev/null
gate_l_activate_app
focus_snapshot="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_focus_state__" "$tile_id")"
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
if [[ "$(jq -r '.sent // false' <<<"$initial_focus_json")" != "true" ]]; then
  echo "Failed to focus initial scroll target: $initial_focus_json" >&2
  exit 1
fi
sleep 0.2

for (( i = 1; i <= warmup_bursts; i++ )); do
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-identifier "$resolved_terminal_ax_identifier" \
    --x-frac 0.5 \
    --y-frac 0.5 \
    --scroll-pixels "$((-scroll_pixels_per_event))" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode" >/dev/null
  sleep 0.2
done

gate_l_send_bridge_command false 10 "__agtmux_reset_scroll_telemetry__" "$tile_id" >/dev/null
sleep 0.2

empty_burst_count=0
completed_iteration_count=0
terminated_early=false
termination_reason=""
last_send_json='null'
last_visible_line=""
previous_scroll_to_first_draw_sample_count=0
previous_scroll_to_layer_present_sample_count=0
previous_scroll_presentation_draw_gap_sample_count=0
previous_scroll_presentation_immediate_queue_delay_sample_count=0
previous_scroll_presentation_pump_wake_lateness_sample_count=0
previous_scroll_presentation_recovery_probe_wake_lateness_sample_count=0
previous_layer_present_gap_sample_count=0
bench_start="$(date '+%Y-%m-%d %H:%M:%S%z')"
last_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$tile_id")"

for (( i = 1; i <= iterations; i++ )); do
  if ! gate_l_app_is_running; then
    terminated_early=true
    termination_reason="app-exited-before-burst-${i}"
    break
  fi

  scroll_pixels="$((-scroll_pixels_per_event))"
  direction="down"
  if (( i % 2 == 0 )); then
    scroll_pixels="$scroll_pixels_per_event"
    direction="up"
  fi

  baseline_line="$(first_visible_line_number "$socket_name" "$target")"
  if [[ -z "$baseline_line" ]]; then
    if ! gate_l_tmux_target_exists "$target"; then
      terminated_early=true
      termination_reason="tmux-target-unavailable-before-burst-${i}"
      break
    fi
    echo "Skipping trackpad burst $i because baseline visible line could not be read" >&2
    empty_burst_count=$((empty_burst_count + 1))
    sleep "$(awk "BEGIN { printf \"%.3f\", (${burst_pause_ms} / 1000.0) }")"
    continue
  fi

  if ! gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$tile_id" >/dev/null; then
    terminated_early=true
    termination_reason="focus-terminal-host-failed-before-burst-${i}"
    break
  fi
  gate_l_activate_app
  burst_started_at="$EPOCHREALTIME"
  last_send_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
    --app-pid "$gate_l_app_pid" \
    --focus-scroll-identifier "$resolved_terminal_ax_identifier" \
    --x-frac 0.5 \
    --y-frac 0.5 \
    --scroll-pixels "$scroll_pixels" \
    --scroll-repeat "$events_per_burst" \
    --scroll-interval-ms "$scroll_interval_ms" \
    --scroll-phase-mode "$scroll_phase_mode")"

  burst_latency_ms="null"
  wait_status=0
  wait_for_first_visible_line_change "$socket_name" "$target" "$baseline_line" "$direction" "$settle_timeout" last_visible_line || wait_status=$?
  if (( wait_status == 0 )); then
    burst_latency_ms="$(awk "BEGIN { printf \"%.3f\", ((${EPOCHREALTIME} - ${burst_started_at}) * 1000.0) }")"
  elif (( wait_status == 2 )); then
    empty_burst_count=$((empty_burst_count + 1))
    terminated_early=true
    termination_reason="tmux-target-unavailable-after-burst-${i}"
  else
    empty_burst_count=$((empty_burst_count + 1))
  fi

  if ! burst_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$tile_id")"; then
    terminated_early=true
    termination_reason="scroll-telemetry-bridge-failed-after-burst-${i}"
    break
  fi
  last_scroll_telemetry_json="$burst_scroll_telemetry_json"
  current_scroll_to_first_draw_sample_count="$(jq '(.scroll.scrollToFirstDrawSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_scroll_to_layer_present_sample_count="$(jq '(.scroll.scrollToLayerPresentSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_scroll_presentation_draw_gap_sample_count="$(jq '(.scroll.scrollPresentationDrawGapSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_scroll_presentation_immediate_queue_delay_sample_count="$(jq '(.scroll.scrollPresentationImmediateQueueDelaySamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_scroll_presentation_pump_wake_lateness_sample_count="$(jq '(.scroll.scrollPresentationPumpWakeLatenessSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_scroll_presentation_recovery_probe_wake_lateness_sample_count="$(jq '(.scroll.scrollPresentationRecoveryProbeWakeLatenessSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"
  current_layer_present_gap_sample_count="$(jq '(.scroll.layerPresentGapSamplesMs // []) | length' <<<"$burst_scroll_telemetry_json")"

  jq -n \
    --argjson iteration "$i" \
    --arg direction "$direction" \
    --argjson baseline_line "$baseline_line" \
    --argjson visible_line "${last_visible_line:-null}" \
    --argjson latency_ms "$burst_latency_ms" \
    --argjson telemetry "$burst_scroll_telemetry_json" \
    --argjson scroll_to_first_draw_start "$previous_scroll_to_first_draw_sample_count" \
    --argjson scroll_to_layer_present_start "$previous_scroll_to_layer_present_sample_count" \
    --argjson scroll_presentation_draw_gap_start "$previous_scroll_presentation_draw_gap_sample_count" \
    --argjson scroll_presentation_immediate_queue_delay_start "$previous_scroll_presentation_immediate_queue_delay_sample_count" \
    --argjson scroll_presentation_pump_wake_lateness_start "$previous_scroll_presentation_pump_wake_lateness_sample_count" \
    --argjson scroll_presentation_recovery_probe_wake_lateness_start "$previous_scroll_presentation_recovery_probe_wake_lateness_sample_count" \
    --argjson layer_present_gap_start "$previous_layer_present_gap_sample_count" \
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
          {count: 0, p50_ms: null, p95_ms: null, max_ms: null}
        else
          {
            count: ($samples | length),
            p50_ms: percentile($samples; 50),
            p95_ms: percentile($samples; 95),
            max_ms: ($samples | max)
          }
        end;
      def suffix($samples; $start):
        if $start <= 0 then
          $samples
        elif $start >= ($samples | length) then
          []
        else
          $samples[$start:]
        end;
      ($telemetry.scroll.scrollToFirstDrawSamplesMs // []) as $scroll_to_first_draw_samples
      | ($telemetry.scroll.scrollToLayerPresentSamplesMs // []) as $scroll_to_layer_present_samples
      | ($telemetry.scroll.scrollPresentationDrawGapSamplesMs // []) as $scroll_presentation_draw_gap_samples
      | ($telemetry.scroll.scrollPresentationImmediateQueueDelaySamplesMs // []) as $scroll_presentation_immediate_queue_delay_samples
      | ($telemetry.scroll.scrollPresentationPumpWakeLatenessSamplesMs // []) as $scroll_presentation_pump_wake_lateness_samples
      | ($telemetry.scroll.scrollPresentationRecoveryProbeWakeLatenessSamplesMs // []) as $scroll_presentation_recovery_probe_wake_lateness_samples
      | ($telemetry.scroll.layerPresentGapSamplesMs // []) as $layer_present_gap_samples
      | (suffix($scroll_to_first_draw_samples; $scroll_to_first_draw_start)) as $burst_scroll_to_first_draw_samples
      | (suffix($scroll_to_layer_present_samples; $scroll_to_layer_present_start)) as $burst_scroll_to_layer_present_samples
      | (suffix($scroll_presentation_draw_gap_samples; $scroll_presentation_draw_gap_start)) as $burst_scroll_presentation_draw_gap_samples
      | (suffix($scroll_presentation_immediate_queue_delay_samples; $scroll_presentation_immediate_queue_delay_start)) as $burst_scroll_presentation_immediate_queue_delay_samples
      | (suffix($scroll_presentation_pump_wake_lateness_samples; $scroll_presentation_pump_wake_lateness_start)) as $burst_scroll_presentation_pump_wake_lateness_samples
      | (suffix($scroll_presentation_recovery_probe_wake_lateness_samples; $scroll_presentation_recovery_probe_wake_lateness_start)) as $burst_scroll_presentation_recovery_probe_wake_lateness_samples
      | (suffix($layer_present_gap_samples; $layer_present_gap_start)) as $burst_layer_present_gap_samples
      | {
          iteration: $iteration,
          direction: $direction,
          baseline_line: $baseline_line,
          visible_line: $visible_line,
          latency_ms: $latency_ms,
          scroll_to_first_draw_ms: summary($burst_scroll_to_first_draw_samples),
          scroll_to_first_draw_samples_ms: $burst_scroll_to_first_draw_samples,
          scroll_to_layer_present_ms: summary($burst_scroll_to_layer_present_samples),
          scroll_to_layer_present_samples_ms: $burst_scroll_to_layer_present_samples,
          scroll_presentation_draw_gap_ms: summary($burst_scroll_presentation_draw_gap_samples),
          scroll_presentation_draw_gap_samples_ms: $burst_scroll_presentation_draw_gap_samples,
          scroll_presentation_immediate_queue_delay_ms: summary($burst_scroll_presentation_immediate_queue_delay_samples),
          scroll_presentation_immediate_queue_delay_samples_ms: $burst_scroll_presentation_immediate_queue_delay_samples,
          scroll_presentation_pump_wake_lateness_ms: summary($burst_scroll_presentation_pump_wake_lateness_samples),
          scroll_presentation_pump_wake_lateness_samples_ms: $burst_scroll_presentation_pump_wake_lateness_samples,
          scroll_presentation_recovery_probe_wake_lateness_ms: summary($burst_scroll_presentation_recovery_probe_wake_lateness_samples),
          scroll_presentation_recovery_probe_wake_lateness_samples_ms: $burst_scroll_presentation_recovery_probe_wake_lateness_samples,
          layer_present_gap_ms: summary($burst_layer_present_gap_samples),
          layer_present_gap_samples_ms: $burst_layer_present_gap_samples
        }
    ' >>"$burst_metrics_path"
  completed_iteration_count=$((completed_iteration_count + 1))

  previous_scroll_to_first_draw_sample_count="$current_scroll_to_first_draw_sample_count"
  previous_scroll_to_layer_present_sample_count="$current_scroll_to_layer_present_sample_count"
  previous_scroll_presentation_draw_gap_sample_count="$current_scroll_presentation_draw_gap_sample_count"
  previous_scroll_presentation_immediate_queue_delay_sample_count="$current_scroll_presentation_immediate_queue_delay_sample_count"
  previous_scroll_presentation_pump_wake_lateness_sample_count="$current_scroll_presentation_pump_wake_lateness_sample_count"
  previous_scroll_presentation_recovery_probe_wake_lateness_sample_count="$current_scroll_presentation_recovery_probe_wake_lateness_sample_count"
  previous_layer_present_gap_sample_count="$current_layer_present_gap_sample_count"

  if [[ "$terminated_early" == "true" ]]; then
    break
  fi

  sleep "$(awk "BEGIN { printf \"%.3f\", (${burst_pause_ms} / 1000.0) }")"
done

bench_end="$(date '+%Y-%m-%d %H:%M:%S%z')"
sleep 1

scroll_telemetry_json="$last_scroll_telemetry_json"
if gate_l_app_is_running; then
  if final_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_dump_scroll_telemetry__" "$tile_id")"; then
    scroll_telemetry_json="$final_scroll_telemetry_json"
  elif [[ "$terminated_early" == "false" ]]; then
    terminated_early=true
    termination_reason="final-scroll-telemetry-bridge-failed"
  fi
elif [[ "$terminated_early" == "false" ]]; then
  terminated_early=true
  termination_reason="app-exited-before-final-scroll-telemetry"
fi

if (( completed_iteration_count == 0 )); then
  echo "No burst telemetry was captured during the trackpad bench" >&2
  exit 1
fi

signpost_json="$("$SCRIPT_DIR/gate_l_signpost_summary.sh" --start "$bench_start" --end "$bench_end" --pid "$gate_l_app_pid" --allow-empty)"

jq -n \
  --arg app_bin "$GATE_L_APP_BIN" \
  --argjson app_pid "$gate_l_app_pid" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg pane_id "$pane_id" \
  --arg tile_id "$tile_id" \
  --arg benchmark_start "$bench_start" \
  --arg benchmark_end "$bench_end" \
  --argjson iterations "$iterations" \
  --argjson warmup_bursts "$warmup_bursts" \
  --argjson events_per_burst "$events_per_burst" \
  --argjson scroll_pixels_per_event "$scroll_pixels_per_event" \
  --argjson scroll_interval_ms "$scroll_interval_ms" \
  --argjson burst_pause_ms "$burst_pause_ms" \
  --arg scroll_phase_mode "$scroll_phase_mode" \
  --argjson empty_burst_count "$empty_burst_count" \
  --argjson completed_iteration_count "$completed_iteration_count" \
  --argjson terminated_early "$terminated_early" \
  --arg termination_reason "$termination_reason" \
  --slurpfile burst_metrics "$burst_metrics_path" \
  --argjson scroll_telemetry "$scroll_telemetry_json" \
  --argjson signposts "$signpost_json" \
  --argjson helper "$helper_json" \
  --argjson focus_snapshot "$focus_snapshot" \
  --argjson last_send "$last_send_json" \
  --arg terminal_ax_identifier "$terminal_ax_identifier" \
  --arg terminal_ax_fallback_identifier "$terminal_ax_fallback_identifier" \
  --arg resolved_terminal_ax_identifier "$resolved_terminal_ax_identifier" \
  --arg ready_capture "$ready_capture" \
  --arg last_visible_line "$last_visible_line" '
  def interval($category; $name):
    ([ $signposts.intervals[]? | select(.category == $category and .name == $name) ] | first);
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
  | ($burst_metrics | map(.latency_ms) | map(select(. != null))) as $burst_latency_samples

  | {
    app_bin: $app_bin,
    app_pid: $app_pid,
    session_name: $session_name,
    socket_name: $socket_name,
    target: $target,
    pane_id: $pane_id,
    tile_id: $tile_id,
    benchmark_start: $benchmark_start,
    benchmark_end: $benchmark_end,
    iterations: $iterations,
    warmup_bursts: $warmup_bursts,
    events_per_burst: $events_per_burst,
    scroll_pixels_per_event: $scroll_pixels_per_event,
    scroll_interval_ms: $scroll_interval_ms,
    burst_pause_ms: $burst_pause_ms,
    scroll_phase_mode: $scroll_phase_mode,
    empty_burst_count: $empty_burst_count,
    completed_iteration_count: $completed_iteration_count,
    terminated_early: $terminated_early,
    termination_reason: (if $termination_reason == "" then null else $termination_reason end),
    helper: $helper,
    focus_snapshot: $focus_snapshot,
    last_send: $last_send,
    ready_capture: $ready_capture,
    last_visible_line: ($last_visible_line | tonumber?),
    terminal_ax_identifier: $terminal_ax_identifier,
    terminal_ax_fallback_identifier: $terminal_ax_fallback_identifier,
    resolved_terminal_ax_identifier: $resolved_terminal_ax_identifier,
    metrics: {
      tmux_visible_line_change_ms: summary($burst_latency_samples),
      scroll_to_render_request_ms: {
        count: $scroll_telemetry.scroll.scrollToRenderRequest.count,
        p50_ms: $scroll_telemetry.scroll.scrollToRenderRequest.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollToRenderRequest.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollToRenderRequest.maxMs
      },
      scroll_to_first_draw_ms: {
        count: $scroll_telemetry.scroll.scrollToFirstDraw.count,
        p50_ms: $scroll_telemetry.scroll.scrollToFirstDraw.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollToFirstDraw.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollToFirstDraw.maxMs
      },
      scroll_to_layer_present_ms: {
        count: $scroll_telemetry.scroll.scrollToLayerPresent.count,
        p50_ms: $scroll_telemetry.scroll.scrollToLayerPresent.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollToLayerPresent.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollToLayerPresent.maxMs
      },
      render_request_to_draw_ms: {
        count: $scroll_telemetry.scroll.renderRequestToDraw.count,
        p50_ms: $scroll_telemetry.scroll.renderRequestToDraw.p50Ms,
        p95_ms: $scroll_telemetry.scroll.renderRequestToDraw.p95Ms,
        max_ms: $scroll_telemetry.scroll.renderRequestToDraw.maxMs
      },
      draw_gap_p50_ms: $scroll_telemetry.scroll.drawGap.p50Ms,
      draw_gap_p95_ms: $scroll_telemetry.scroll.drawGap.p95Ms,
      draw_gap_max_ms: $scroll_telemetry.scroll.drawGap.maxMs,
      draw_count: $scroll_telemetry.scroll.drawCount,
      scroll_presentation_draw_gap_p50_ms: $scroll_telemetry.scroll.scrollPresentationDrawGap.p50Ms,
      scroll_presentation_draw_gap_p95_ms: $scroll_telemetry.scroll.scrollPresentationDrawGap.p95Ms,
      scroll_presentation_draw_gap_max_ms: $scroll_telemetry.scroll.scrollPresentationDrawGap.maxMs,
      scroll_presentation_draw_count: $scroll_telemetry.scroll.scrollPresentationDrawCount,
      scroll_presentation_immediate_queue_delay_ms: {
        count: $scroll_telemetry.scroll.scrollPresentationImmediateQueueDelay.count,
        p50_ms: $scroll_telemetry.scroll.scrollPresentationImmediateQueueDelay.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollPresentationImmediateQueueDelay.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollPresentationImmediateQueueDelay.maxMs
      },
      scroll_presentation_pump_wake_lateness_ms: {
        count: $scroll_telemetry.scroll.scrollPresentationPumpWakeLateness.count,
        p50_ms: $scroll_telemetry.scroll.scrollPresentationPumpWakeLateness.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollPresentationPumpWakeLateness.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollPresentationPumpWakeLateness.maxMs
      },
      scroll_presentation_recovery_probe_wake_lateness_ms: {
        count: $scroll_telemetry.scroll.scrollPresentationRecoveryProbeWakeLateness.count,
        p50_ms: $scroll_telemetry.scroll.scrollPresentationRecoveryProbeWakeLateness.p50Ms,
        p95_ms: $scroll_telemetry.scroll.scrollPresentationRecoveryProbeWakeLateness.p95Ms,
        max_ms: $scroll_telemetry.scroll.scrollPresentationRecoveryProbeWakeLateness.maxMs
      },
      layer_present_gap_p50_ms: $scroll_telemetry.scroll.layerPresentGap.p50Ms,
      layer_present_gap_p95_ms: $scroll_telemetry.scroll.layerPresentGap.p95Ms,
      layer_present_gap_max_ms: $scroll_telemetry.scroll.layerPresentGap.maxMs,
      layer_present_count: $scroll_telemetry.scroll.layerPresentCount,
      empty_burst_count: $empty_burst_count,
      completed_burst_count: ($burst_metrics | length),
      tmux_proxy_completed_burst_count: ($burst_latency_samples | length),
      pending_scroll_to_render_count: $scroll_telemetry.scroll.pendingScrollToRenderCount,
      pending_scroll_to_draw_count: $scroll_telemetry.scroll.pendingScrollToDrawCount,
      pending_scroll_to_layer_present_count: $scroll_telemetry.scroll.pendingScrollToLayerPresentCount,
      pending_render_to_draw_count: $scroll_telemetry.scroll.pendingRenderToDrawCount,
      render_callback_captured: ($scroll_telemetry.scroll.scrollToRenderRequest.count > 0),
      first_draw_captured: ($scroll_telemetry.scroll.scrollToFirstDraw.count > 0),
      layer_present_captured: ($scroll_telemetry.scroll.scrollToLayerPresent.count > 0),
      island_update_count: $scroll_telemetry.island.updateCount,
      island_command_change_count: $scroll_telemetry.island.commandChangeCount,
      island_surface_context_change_count: $scroll_telemetry.island.surfaceContextChangeCount,
      island_focus_change_count: $scroll_telemetry.island.focusChangeCount,
      island_focus_restore_change_count: $scroll_telemetry.island.focusRestoreChangeCount,
      island_apply_command_count: $scroll_telemetry.island.applyCommandCount,
      island_retry_count: $scroll_telemetry.island.retryCount,
      publish_invocation_count: $scroll_telemetry.publish.invocationCount,
      publish_store_mutation_count: $scroll_telemetry.publish.storeMutationCount,
      publish_noop_count: $scroll_telemetry.publish.noOpCount,
      publish_panes_changed_count: $scroll_telemetry.publish.panesChangedCount,
      publish_live_pane_session_keys_change_count: $scroll_telemetry.publish.livePaneSessionKeysChangeCount,
      publish_offline_hosts_change_count: $scroll_telemetry.publish.offlineHostsChangeCount,
      signpost_scroll_to_render_request_ms: interval("ScrollLatency"; "scrollToRenderRequest"),
      signpost_scroll_to_first_draw_ms: interval("ScrollLatency"; "scrollToFirstDraw"),
      signpost_scroll_to_layer_present_ms: interval("ScrollLatency"; "scrollToLayerPresent"),
      signpost_render_request_to_draw_ms: interval("ScrollLatency"; "renderRequestToDraw"),
      signpost_draw_ms: interval("SurfaceDraw"; "draw"),
      signpost_draw_gap_ms: interval("SurfaceDraw"; "drawGap")
    },
    burst_metrics: $burst_metrics,
    scroll_telemetry: $scroll_telemetry,
    signposts: $signposts
  }
'
