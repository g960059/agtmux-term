#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

STEP_METRICS_PY="$SCRIPT_DIR/gate_l_step_metrics.py"

host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-legacy}"
session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-}"
pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-}"
pane_title_contains="${AGTMUX_PERF_LIVE_PANE_TITLE_CONTAINS:-}"
pane_command="${AGTMUX_PERF_LIVE_PANE_COMMAND:-}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-20}"
prime_scroll_pixels="${AGTMUX_PERF_LIVE_PRIME_SCROLL_PIXELS:-10}"
prime_scroll_repeat="${AGTMUX_PERF_LIVE_PRIME_SCROLL_REPEAT:-24}"
prime_scroll_interval_ms="${AGTMUX_PERF_LIVE_PRIME_SCROLL_INTERVAL_MS:-8}"
prime_scroll_phase_mode="${AGTMUX_PERF_LIVE_PRIME_PHASE_MODE:-trackpad-burst-momentum}"
prime_settle_ms="${AGTMUX_PERF_LIVE_PRIME_SETTLE_MS:-220}"
prime_max_rounds="${AGTMUX_PERF_LIVE_PRIME_MAX_ROUNDS:-6}"
prime_min_rounds="${AGTMUX_PERF_LIVE_PRIME_MIN_ROUNDS:-1}"
events_per_burst="${AGTMUX_PERF_UPSTEP_EVENTS_PER_BURST:-24}"
scroll_pixels_per_event="${AGTMUX_PERF_UPSTEP_PIXELS_PER_EVENT:-10}"
scroll_interval_ms="${AGTMUX_PERF_UPSTEP_SCROLL_INTERVAL_MS:-8}"
sample_interval_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_INTERVAL_MS:-16}"
sample_tail_ms="${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-180}"
scroll_phase_mode="${AGTMUX_PERF_UPSTEP_PHASE_MODE:-trackpad-burst-momentum}"
scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"
use_scroll_identifier="${AGTMUX_PERF_LIVE_USE_SCROLL_IDENTIFIER:-1}"
focus_settle_ms="${AGTMUX_PERF_FOCUS_SETTLE_MS:-120}"
registration_timeout_ms="${AGTMUX_PERF_LIVE_REGISTRATION_TIMEOUT_MS:-15000}"
frontmost_timeout_ms="${AGTMUX_PERF_LIVE_FRONTMOST_TIMEOUT_MS:-20000}"
open_retry_count="${AGTMUX_PERF_LIVE_OPEN_RETRY_COUNT:-3}"
open_retry_sleep_ms="${AGTMUX_PERF_LIVE_OPEN_RETRY_SLEEP_MS:-400}"
refresh_inventory_before_open="${AGTMUX_PERF_LIVE_REFRESH_INVENTORY_BEFORE_OPEN:-0}"
skip_bridge_host_mode_set="${AGTMUX_PERF_LIVE_SKIP_BRIDGE_HOST_MODE_SET:-0}"
use_internal_scroll_measurement="${AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT:-1}"
attach_running_app="${AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP:-0}"
agtmux_cli_bin="${AGTMUX_PERF_AGTMUX_BIN:-${AGTMUX_BIN:-$GATE_L_ROOT/../agtmux/target/release/agtmux}}"
switch_to_host_mode="${AGTMUX_PERF_LIVE_SWITCH_TO_HOST_MODE:-}"
reprime_after_switch="${AGTMUX_PERF_LIVE_REPRIME_AFTER_SWITCH:-0}"
use_active_target="${AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET:-0}"

if [[ "$attach_running_app" == "1" && -z "${AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET:-}" ]]; then
  use_active_target=1
fi

if [[ "$use_active_target" == "1" ]] && [[ -z "${AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK:-}" ]]; then
  export AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK=1
fi

if [[ "${AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX:-0}" == "1" ]] \
  && [[ -z "${AGTMUX_TMUX_SOCKET_PATH:-}" ]] \
  && [[ -n "${TMUX:-}" ]]; then
  current_tmux_socket_path="${TMUX%%,*}"
  if [[ -n "$current_tmux_socket_path" && -S "$current_tmux_socket_path" ]]; then
    export AGTMUX_TMUX_SOCKET_PATH="$current_tmux_socket_path"
  fi
fi

if [[ -z "$session_name" ]]; then
  if [[ -n "${AGTMUX_TMUX_SOCKET_PATH:-}" ]]; then
    session_name="$(tmux -S "$AGTMUX_TMUX_SOCKET_PATH" display-message -p '#S' 2>/dev/null || true)"
  elif [[ -n "${TMUX:-}" ]]; then
    session_name="$(tmux display-message -p '#S' 2>/dev/null || true)"
  fi
fi

if [[ -z "$session_name" ]]; then
  session_name="vm agtmux-term"
fi

function extract_last_json_line() {
  local raw="$1"
  local json_line
  json_line="$(printf '%s\n' "$raw" | awk '/^[[:space:]]*[{[]/ { line = $0 } END { if (line != "") print line }')"
  if [[ -z "$json_line" ]] || ! jq -e . >/dev/null 2>&1 <<<"$json_line"; then
    echo "Failed to normalize JSON payload" >&2
    print -r -- "$raw" >&2
    return 1
  fi
  print -r -- "$json_line"
}

function sleep_ms() {
  local milliseconds="$1"
  sleep "$(awk -v ms="$milliseconds" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
}

function assert_sender_succeeded() {
  local json_path="$1"
  local context="$2"

  if ! jq -e '.sent == true' "$json_path" >/dev/null 2>&1; then
    echo "Scroll sender failed during $context" >&2
    cat "$json_path" >&2
    return 1
  fi

  if jq -e 'has("trusted") and .trusted != true' "$json_path" >/dev/null 2>&1; then
    echo "Scroll sender was not trusted during $context" >&2
    cat "$json_path" >&2
    return 1
  fi
}

function resolve_live_pane_target_via_daemon_cli() {
  local session_name="$1"
  local requested_pane_id="$2"
  local timeout="${3:-15}"
  local deadline=$(( EPOCHREALTIME + timeout ))
  local last_snapshot=""

  while (( EPOCHREALTIME < deadline )); do
    if [[ -x "$agtmux_cli_bin" ]] && last_snapshot="$("$agtmux_cli_bin" --socket-path "$gate_l_daemon_socket_path" json 2>"$gate_l_tmpdir/live-resolve-daemon.last-error.log")"; then
      printf '%s\n' "$last_snapshot" >"$gate_l_tmpdir/live-resolve-daemon.json"
      local resolved
      resolved="$(jq -r \
        --arg session_name "$session_name" \
        --arg requested_pane_id "$requested_pane_id" \
        --arg pane_title_contains "$pane_title_contains" \
        --arg pane_command "$pane_command" '
        def title_text:
          (.conversation_title // .session_subtitle // .window_name // .current_cmd // "");
        def as_line($reason):
          "\(.session_name)|\(.pane_id)|\(.window_id)|0|\(.current_cmd // "")|\(title_text)|\($reason)";
        def first_line($panes; $reason):
          ($panes | first?) as $pane
          | if $pane == null then empty else ($pane | as_line($reason)) end;
        [(.panes // [])
          | .[]
          | select(((.source // "local") == "local") and (.session_name == $session_name or .session_name == null))] as $panes
        | ($panes
            | map(select(
                ((.conversation_title // "") | contains($pane_title_contains))
                or ((.session_subtitle // "") | contains($pane_title_contains))
                or ((.window_name // "") | contains($pane_title_contains))
                or ((.current_cmd // "") | contains($pane_title_contains))
            ))) as $title_matches
        | ($panes | map(select(.current_cmd == $pane_command))) as $command_matches
        | if ($requested_pane_id | length) > 0 then
            first_line(($panes | map(select(.pane_id == $requested_pane_id))); "requested")
            // if ($pane_title_contains | length) > 0 then first_line($title_matches; "title-match") else empty end
            // if ($pane_command | length) > 0 then first_line($command_matches; "command-match") else empty end
            // first_line($panes; "first-pane-fallback")
          elif ($pane_title_contains | length) > 0 then
            first_line($title_matches; "title-match")
            // if ($pane_command | length) > 0 then first_line($command_matches; "command-match") else empty end
            // first_line($panes; "first-pane-fallback")
          elif ($pane_command | length) > 0 then
            first_line($command_matches; "command-match")
            // first_line($panes; "first-pane-fallback")
          else
            first_line($panes; "first-pane-fallback")
          end
      ' <<<"$last_snapshot" | awk '/\|/ { print; exit }')"
      if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
      fi
    fi
    sleep 0.10
  done

  echo "Timed out resolving live pane target via daemon json for session=$session_name pane=$requested_pane_id title=${pane_title_contains:-<none>} command=${pane_command:-<none>}" >&2
  if [[ -n "$last_snapshot" ]]; then
    echo "Last daemon snapshot: $last_snapshot" >&2
  elif [[ -s "$gate_l_tmpdir/live-resolve-daemon.last-error.log" ]]; then
    cat "$gate_l_tmpdir/live-resolve-daemon.last-error.log" >&2
  fi
  return 1
}

function viewport_sample_count() {
  local events="${1:-$events_per_burst}"
  local interval="${2:-$scroll_interval_ms}"
  local tail="${3:-$sample_tail_ms}"
  local sample_interval="${4:-$sample_interval_ms}"
  awk -v events="$events" -v interval="$interval" -v tail="$tail" -v sample_interval="$sample_interval" \
    'BEGIN {
      total_ms = (events * interval) + tail
      samples = int((total_ms / sample_interval) + 2.999999)
      if (samples < 3) samples = 3
      print samples
    }'
}

function viewport_sample_timeout() {
  local sample_count="$1"
  local interval_ms="$2"
  awk -v count="$sample_count" -v interval="$interval_ms" 'BEGIN {
    printf "%.3f", ((count * interval) / 1000.0) + 5.0
  }'
}

function mark_stage() {
  local stage="$1"
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$stage" >>"$stage_log_path"
}

function wait_for_terminal_viewport_ready() {
  local tile_id="$1"
  local timeout="${2:-15}"
  local deadline=$((EPOCHREALTIME + timeout))

  while (( EPOCHREALTIME < deadline )); do
    if gate_l_send_bridge_json_command false 2 "__agtmux_dump_terminal_viewport_text__" "$tile_id" \
      >/dev/null 2>"$gate_l_tmpdir/viewport-ready.last-error.log"; then
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for terminal viewport readiness for tileID $tile_id" >&2
  if [[ -s "$gate_l_tmpdir/viewport-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/viewport-ready.last-error.log" >&2
  fi
  return 1
}

function wait_for_rendered_client_pane() {
  local tile_id="$1"
  local expected_pane_id="$2"
  local timeout="${3:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local output=""

  while (( EPOCHREALTIME < deadline )); do
    if output="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_rendered_terminal_target__" "$tile_id" 2>"$gate_l_tmpdir/rendered-pane.last-error.log")"; then
      local rendered_pane_id
      rendered_pane_id="$(jq -r '.renderedClientPaneID // empty' <<<"$output")"
      if [[ "$rendered_pane_id" == "$expected_pane_id" ]]; then
        printf '%s\n' "$output"
        return 0
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for rendered client pane $expected_pane_id on tile $tile_id" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  elif [[ -s "$gate_l_tmpdir/rendered-pane.last-error.log" ]]; then
    cat "$gate_l_tmpdir/rendered-pane.last-error.log" >&2
  fi
  return 1
}

function wait_for_rendered_terminal_target_ready() {
  local tile_id="$1"
  local timeout="${2:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local output=""

  while (( EPOCHREALTIME < deadline )); do
    if output="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_rendered_terminal_target__" "$tile_id" 2>"$gate_l_tmpdir/rendered-target-ready.last-error.log")"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for rendered terminal target readiness for tile $tile_id" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  elif [[ -s "$gate_l_tmpdir/rendered-target-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/rendered-target-ready.last-error.log" >&2
  fi
  return 1
}

function wait_for_tile_host_mode() {
  local tile_id="$1"
  local expected_mode="$2"
  local timeout="${3:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local output=""

  while (( EPOCHREALTIME < deadline )); do
    if output="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_rendered_terminal_target__" "$tile_id" 2>"$gate_l_tmpdir/host-mode-ready.last-error.log")"; then
      local actual_mode
      actual_mode="$(jq -r '.terminalHostMode // empty' <<<"$output")"
      if [[ "$actual_mode" == "$expected_mode" ]]; then
        printf '%s\n' "$output"
        return 0
      fi
    fi
    sleep 0.05
  done

  echo "Timed out waiting for tile $tile_id to report host mode $expected_mode" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  elif [[ -s "$gate_l_tmpdir/host-mode-ready.last-error.log" ]]; then
    cat "$gate_l_tmpdir/host-mode-ready.last-error.log" >&2
  fi
  return 1
}

function send_prime_scroll() {
  local terminal_ax_identifier="$1"
  local scroll_point_x="$2"
  local scroll_point_y="$3"

  if [[ "$use_scroll_identifier" == "1" ]]; then
    "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      --app-pid "$gate_l_app_pid" \
      --scroll-identifier "$terminal_ax_identifier" \
      --x-frac "$scroll_x_frac" \
      --y-frac "$scroll_y_frac" \
      --scroll-pixels "$prime_scroll_pixels" \
      --scroll-repeat "$prime_scroll_repeat" \
      --scroll-interval-ms "$prime_scroll_interval_ms" \
      --scroll-phase-mode "$prime_scroll_phase_mode"
  else
    "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
      --app-pid "$gate_l_app_pid" \
      --scroll-point \
      --point-x "$scroll_point_x" \
      --point-y "$scroll_point_y" \
      --scroll-pixels "$prime_scroll_pixels" \
      --scroll-repeat "$prime_scroll_repeat" \
      --scroll-interval-ms "$prime_scroll_interval_ms" \
      --scroll-phase-mode "$prime_scroll_phase_mode"
  fi
}

function measure_internal_scroll_burst() {
  local tile_id="$1"
  local scroll_pixels="$2"
  local scroll_repeat="$3"
  local scroll_interval="$4"
  local sample_count="$5"
  local sample_interval="$6"
  local phase_mode="$7"
  local timeout="$8"

  gate_l_send_bridge_json_command false "$timeout" \
    "__agtmux_measure_terminal_scroll_burst__" \
    "$tile_id" \
    "$scroll_pixels" \
    "$scroll_repeat" \
    "$scroll_interval" \
    "$sample_count" \
    "$sample_interval" \
    "$phase_mode"
}

function measure_live_scroll_burst() {
  local label="$1"
  local tile_id="$2"
  local terminal_ax_identifier="$3"
  local prefix="$4"
  local focus_json_path="$gate_l_tmpdir/${prefix}-focus-state.json"
  local post_focus_json_path="$gate_l_tmpdir/${prefix}-post-focus-state.json"
  local baseline_viewport_json_path="$gate_l_tmpdir/${prefix}-baseline-viewport.json"
  local final_viewport_json_path="$gate_l_tmpdir/${prefix}-final-viewport.json"
  local bench_json_path="$gate_l_tmpdir/${prefix}-bench.json"
  local bench_stderr_path="$gate_l_tmpdir/${prefix}-bench.stderr.log"
  local post_scroll_telemetry_json_path="$gate_l_tmpdir/${prefix}-post-scroll-telemetry.json"
  local viewport_sample_json_path="$gate_l_tmpdir/${prefix}-viewport-samples.json"
  local viewport_metrics_json_path="$gate_l_tmpdir/${prefix}-viewport-metrics.json"
  local send_json_path="$gate_l_tmpdir/${prefix}-send.json"
  local measurement_json_path="$gate_l_tmpdir/${prefix}-measurement.json"
  local summary_json_path="$gate_l_tmpdir/${prefix}-summary.json"
  local focus_json=""
  local baseline_viewport_json=""
  local final_viewport_json=""
  local post_focus_json=""
  local post_scroll_telemetry_json=""

  if ! wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"; then
    return 1
  fi

  if focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/${prefix}-focus-state.last-error.log")"; then
    printf '%s\n' "$focus_json" >"$focus_json_path"
  else
    printf '%s\n' '{"terminalAccessibilityIdentifier":null}' >"$focus_json_path"
  fi

  if baseline_viewport_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$tile_id" 2>"$gate_l_tmpdir/${prefix}-baseline-viewport.last-error.log")"; then
    printf '%s\n' "$baseline_viewport_json" >"$baseline_viewport_json_path"
  else
    printf '%s\n' '{}' >"$baseline_viewport_json_path"
  fi
  mark_stage "${prefix}-baseline-viewport"

  local sample_count
  sample_count="$(viewport_sample_count)"
  local sample_timeout
  sample_timeout="$(
    awk -v count="$sample_count" -v interval="$sample_interval_ms" 'BEGIN {
      printf "%.3f", ((count * interval) / 1000.0) + 5.0
    }'
  )"
  if [[ "$use_internal_scroll_measurement" == "1" ]]; then
    measure_internal_scroll_burst \
      "$tile_id" \
      "$scroll_pixels_per_event" \
      "$events_per_burst" \
      "$scroll_interval_ms" \
      "$sample_count" \
      "$sample_interval_ms" \
      "$scroll_phase_mode" \
      "$sample_timeout" >"$measurement_json_path"
    jq '.sender' "$measurement_json_path" >"$send_json_path"
    jq '.sampling' "$measurement_json_path" >"$viewport_sample_json_path"
    assert_sender_succeeded "$send_json_path" "${prefix}-internal-measurement"
  else
    local sample_request_id
    sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$tile_id" "$sample_count" "$sample_interval_ms")"
    sleep_ms 20
    if [[ "$use_scroll_identifier" == "1" ]]; then
      "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
        --app-pid "$gate_l_app_pid" \
        --scroll-identifier "$terminal_ax_identifier" \
        --x-frac "$scroll_x_frac" \
        --y-frac "$scroll_y_frac" \
        --scroll-pixels "$scroll_pixels_per_event" \
        --scroll-repeat "$events_per_burst" \
        --scroll-interval-ms "$scroll_interval_ms" \
        --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path" 2>"$bench_stderr_path"
    else
      "$SCRIPT_DIR/gate_l_ax_key_sender.sh" \
        --app-pid "$gate_l_app_pid" \
        --scroll-front-window \
        --x-frac "$scroll_x_frac" \
        --y-frac "$scroll_y_frac" \
        --scroll-pixels "$scroll_pixels_per_event" \
        --scroll-repeat "$events_per_burst" \
        --scroll-interval-ms "$scroll_interval_ms" \
        --scroll-phase-mode "$scroll_phase_mode" >"$send_json_path" 2>"$bench_stderr_path"
    fi
    assert_sender_succeeded "$send_json_path" "${prefix}-ax-sender"
    if ! gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$viewport_sample_json_path"; then
      printf '%s\n' '{}' >"$viewport_sample_json_path"
      printf '%s\n' '{}' >"$viewport_metrics_json_path"
      echo "Failed to collect viewport samples for $prefix" >&2
      return 1
    fi
  fi
  mark_stage "${prefix}-bench-done"

  python3 "$STEP_METRICS_PY" "$viewport_sample_json_path" >"$viewport_metrics_json_path"
  mark_stage "${prefix}-viewport-samples-done"

  if final_viewport_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_terminal_viewport_text__" "$tile_id" 2>"$gate_l_tmpdir/${prefix}-final-viewport.last-error.log")"; then
    printf '%s\n' "$final_viewport_json" >"$final_viewport_json_path"
  else
    printf '%s\n' '{}' >"$final_viewport_json_path"
  fi

  if post_focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/${prefix}-post-focus-state.last-error.log")"; then
    printf '%s\n' "$post_focus_json" >"$post_focus_json_path"
  else
    printf '%s\n' '{"terminalAccessibilityIdentifier":null}' >"$post_focus_json_path"
  fi

  if post_scroll_telemetry_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_scroll_telemetry__" "$tile_id" 2>"$gate_l_tmpdir/${prefix}-post-scroll-telemetry.last-error.log")"; then
    printf '%s\n' "$post_scroll_telemetry_json" >"$post_scroll_telemetry_json_path"
  else
    printf '%s\n' '{}' >"$post_scroll_telemetry_json_path"
  fi
  mark_stage "${prefix}-post-scroll-telemetry"

  jq -n \
    --arg label "$label" \
    --arg host_mode "$host_mode" \
    --arg rendered_client_tty "$rendered_client_tty" \
    --argjson events_per_burst "$events_per_burst" \
    --argjson sample_interval_ms "$sample_interval_ms" \
    --argjson sample_tail_ms "$sample_tail_ms" \
    --argjson scroll_interval_ms "$scroll_interval_ms" \
    --arg use_scroll_identifier "$use_scroll_identifier" \
    --arg use_internal_scroll_measurement "$use_internal_scroll_measurement" \
    --arg terminal_ax_identifier "$terminal_ax_identifier" \
    --slurpfile focus "$focus_json_path" \
    --slurpfile sender "$send_json_path" \
    --slurpfile metrics "$viewport_metrics_json_path" \
    --arg tmpdir "$gate_l_tmpdir" \
    '{
      label: $label,
      hostMode: $host_mode,
      clientTTY: (if $rendered_client_tty == "" then null else $rendered_client_tty end),
      config: {
        eventsPerBurst: $events_per_burst,
        scrollIntervalMs: $scroll_interval_ms,
        sampleIntervalMs: $sample_interval_ms,
        sampleTailMs: $sample_tail_ms,
        scrollTargetMode: (if $use_internal_scroll_measurement == "1" then "bridge-internal" elif $use_scroll_identifier == "1" then "identifier" else "front-window" end),
        terminalAccessibilityIdentifier: (if $terminal_ax_identifier == "" then null else $terminal_ax_identifier end)
      },
      focus: $focus[0],
      sender: $sender[0],
      metrics: $metrics[0],
      tmpdir: $tmpdir
    }' >"$bench_json_path"

  jq -n \
    --arg label "$label" \
    --slurpfile focus "$focus_json_path" \
    --slurpfile postFocus "$post_focus_json_path" \
    --slurpfile baselineViewport "$baseline_viewport_json_path" \
    --slurpfile finalViewport "$final_viewport_json_path" \
    --slurpfile bench "$bench_json_path" \
    --slurpfile postScrollTelemetry "$post_scroll_telemetry_json_path" \
    --slurpfile viewportSamples "$viewport_sample_json_path" \
    --slurpfile viewportMetrics "$viewport_metrics_json_path" \
    '{
      label: $label,
      focusState: $focus[0],
      postFocusState: $postFocus[0],
      baselineViewport: $baselineViewport[0],
      finalViewport: $finalViewport[0],
      bench: $bench[0],
      postScrollTelemetry: $postScrollTelemetry[0],
      viewportSamples: $viewportSamples[0],
      viewportMetrics: $viewportMetrics[0]
    }' >"$summary_json_path"

  print -r -- "$summary_json_path"
}

function prepare_live_viewport() {
  local tile_id="$1"
  local terminal_ax_identifier="$2"
  local scroll_point_x="$3"
  local scroll_point_y="$4"
  local round=0
  local prime_sample_count
  local sample_timeout
  local sample_request_id
  local prime_sample_json_path=""
  local prime_metrics_json_path=""
  local prime_measurement_json_path=""
  local changed_sample_count=0

  if ! wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"; then
    return 1
  fi

  prime_sample_count="$(viewport_sample_count "$prime_scroll_repeat" "$prime_scroll_interval_ms" "$sample_tail_ms" "$sample_interval_ms")"
  sample_timeout="$(viewport_sample_timeout "$prime_sample_count" "$sample_interval_ms")"

  while (( round < prime_max_rounds )); do
    round=$((round + 1))
    prime_sample_json_path="$gate_l_tmpdir/prime-viewport-samples.$round.json"
    prime_metrics_json_path="$gate_l_tmpdir/prime-viewport-metrics.$round.json"
    if [[ "$use_internal_scroll_measurement" == "1" ]]; then
      prime_measurement_json_path="$gate_l_tmpdir/prime-measurement.$round.json"
      measure_internal_scroll_burst \
        "$tile_id" \
        "$prime_scroll_pixels" \
        "$prime_scroll_repeat" \
        "$prime_scroll_interval_ms" \
        "$prime_sample_count" \
        "$sample_interval_ms" \
        "$prime_scroll_phase_mode" \
        "$sample_timeout" >"$prime_measurement_json_path"
      jq '.sender' "$prime_measurement_json_path" >"$gate_l_tmpdir/prime-send.$round.json"
      jq '.sampling' "$prime_measurement_json_path" >"$prime_sample_json_path"
      assert_sender_succeeded "$gate_l_tmpdir/prime-send.$round.json" "prime-round-$round"
    else
      sample_request_id="$(gate_l_start_async_bridge_command false "__agtmux_sample_terminal_viewport_text__" "$tile_id" "$prime_sample_count" "$sample_interval_ms")"
      sleep_ms 20
      send_prime_scroll "$terminal_ax_identifier" "$scroll_point_x" "$scroll_point_y" >"$gate_l_tmpdir/prime-send.$round.json"
      assert_sender_succeeded "$gate_l_tmpdir/prime-send.$round.json" "prime-round-$round"
      if ! gate_l_wait_for_async_bridge_json_result "$sample_request_id" "$sample_timeout" >"$prime_sample_json_path"; then
        echo "Failed to collect prime viewport samples for host mode $host_mode" >&2
        return 1
      fi
    fi
    python3 "$STEP_METRICS_PY" "$prime_sample_json_path" >"$prime_metrics_json_path"
    changed_sample_count="$(jq -r '.summary.changed_sample_count // 0' "$prime_metrics_json_path")"
    if (( round >= prime_min_rounds )) && (( changed_sample_count > 0 )); then
      return 0
    fi
    sleep_ms "$prime_settle_ms"
  done

  echo "Failed to prime live viewport for host mode $host_mode" >&2
  if [[ -n "$prime_metrics_json_path" && -f "$prime_metrics_json_path" ]]; then
    cat "$prime_metrics_json_path" >&2
  fi
  return 1
}

function open_terminal_for_live_pane() {
  local source="$1"
  local session_name="$2"
  local pane_id="$3"
  local last_error=""
  local raw_output normalized_output
  local attempt=1

  while (( attempt <= open_retry_count )); do
    if raw_output="$(
      gate_l_send_bridge_json_command "$refresh_inventory_before_open" "$settle_timeout" "__agtmux_open_terminal_for_pane__" "$source" "$session_name" "$pane_id" \
        2>"$gate_l_tmpdir/open-terminal.last-error.log"
    )"; then
      if normalized_output="$(extract_last_json_line "$raw_output")"; then
        print -r -- "$normalized_output"
        return 0
      fi
    fi

    if [[ -s "$gate_l_tmpdir/open-terminal.last-error.log" ]]; then
      last_error="$(<"$gate_l_tmpdir/open-terminal.last-error.log")"
    else
      last_error="open terminal command failed without stderr"
    fi

    if (( attempt < open_retry_count )) && [[ "$last_error" == *"Timed out waiting for terminal view registration"* ]]; then
      gate_l_activate_app
      sleep_ms "$open_retry_sleep_ms"
      attempt=$((attempt + 1))
      continue
    fi

    echo "$last_error" >&2
    return 1
  done

  echo "Failed to open live terminal pane after $open_retry_count attempts" >&2
  return 1
}

function wait_for_live_active_target() {
  local session_name="$1"
  local requested_pane_id="$2"
  local timeout="${3:-15}"
  local deadline=$((EPOCHREALTIME + timeout))
  local output=""

  while (( EPOCHREALTIME < deadline )); do
    if output="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_active_terminal_target__" 2>"$gate_l_tmpdir/live-active-target.last-error.log")"; then
      local got_session got_tile got_rendered_pane got_selected_pane
      got_session="$(jq -r '.sessionName // empty' <<<"$output")"
      got_tile="$(jq -r '.tileID // empty' <<<"$output")"
      got_rendered_pane="$(jq -r '.renderedClientPaneID // empty' <<<"$output")"
      got_selected_pane="$(jq -r '.paneID // empty' <<<"$output")"
      if [[ -z "$got_tile" ]]; then
        sleep 0.05
        continue
      fi
      if [[ -n "$session_name" && "$got_session" != "$session_name" ]]; then
        sleep 0.05
        continue
      fi
      if [[ -n "$requested_pane_id" && "$got_rendered_pane" != "$requested_pane_id" && "$got_selected_pane" != "$requested_pane_id" ]]; then
        sleep 0.05
        continue
      fi
      print -r -- "$output"
      return 0
    fi
    sleep 0.05
  done

  echo "Timed out waiting for active terminal target for session=$session_name pane=${requested_pane_id:-<any>}" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  elif [[ -s "$gate_l_tmpdir/live-active-target.last-error.log" ]]; then
    cat "$gate_l_tmpdir/live-active-target.last-error.log" >&2
  fi
  return 1
}

while (( $# > 0 )); do
  case "$1" in
    --host-mode)
      host_mode="$2"
      shift 2
      ;;
    --session-name)
      session_name="$2"
      shift 2
      ;;
    --pane-id)
      pane_id="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    --switch-to-host-mode)
      switch_to_host_mode="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--host-mode legacy|next] [--session-name NAME] [--pane-id %id] [--timeout SECONDS] [--switch-to-host-mode legacy|next]" >&2
      exit 1
      ;;
  esac
done

case "$host_mode" in
  legacy|next)
    ;;
  *)
    echo "Unsupported host mode: $host_mode" >&2
    exit 1
    ;;
esac

if [[ -n "$switch_to_host_mode" ]]; then
  case "$switch_to_host_mode" in
    legacy|next)
      ;;
    *)
      echo "Unsupported switch host mode: $switch_to_host_mode" >&2
      exit 1
      ;;
  esac
fi

export AGTMUX_PERF_DAEMON_SOCKET_PATH_OVERRIDE="$HOME/Library/Application Support/AGTMUXDesktop/agtmuxd.sock"
token="live-client-${host_mode}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
gate_l_setup_paths "$token"
stage_log_path="$gate_l_tmpdir/stage.log"
mark_stage setup
if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" == "1" ]]; then
  echo "Gate-L terminal-host live client-scroll temp dir: $gate_l_tmpdir" >&2
fi

export AGTMUX_PERF_USE_DEFAULT_LOCAL_TMUX=1
export AGTMUX_PERF_UITEST_INVENTORY_ONLY=0
export AGTMUX_PERF_TERMINAL_HOST_MODE="$host_mode"
export AGTMUX_UITEST_TERMINAL_VIEW_REGISTRATION_TIMEOUT_MS="$registration_timeout_ms"
export AGTMUX_UITEST_ALLOW_SESSION_ONLY_OPEN_FALLBACK=1

cleanup() {
  local exit_status=$?
  if [[ "$attach_running_app" == "1" ]]; then
    if [[ "$gate_l_bridge_defaults_active" == "1" ]]; then
      gate_l_clear_bridge_defaults
    fi
  else
    gate_l_terminate_app
  fi
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$gate_l_tmpdir"
  else
    echo "Gate-L terminal-host live client-scroll temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

if [[ "$attach_running_app" == "1" ]]; then
  mark_stage attach-running-start
  gate_l_attach_to_running_app
  mark_stage attach-running-done
else
  mark_stage launch-app-start
  gate_l_launch_app_without_bootstrap "agtmux-gate-l-$token" 0
  mark_stage launch-app-done
fi
mark_stage bridge-ready-wait-start
gate_l_wait_for_bridge_ready "$settle_timeout"
mark_stage bridge-ready-wait-done
gate_l_activate_app
mark_stage app-ready
if [[ "$skip_bridge_host_mode_set" == "1" ]]; then
  initial_runtime_host_mode="$host_mode"
else
  initial_runtime_host_mode="$(gate_l_send_bridge_command false 10 "__agtmux_set_terminal_host_mode__" "$host_mode")"
  if [[ "$initial_runtime_host_mode" != "$host_mode" ]]; then
    echo "Bridge reported unexpected initial host mode: expected=$host_mode got=$initial_runtime_host_mode" >&2
    exit 1
  fi
fi
sleep_ms "$focus_settle_ms"
mark_stage host-mode-set

open_json_path="$gate_l_tmpdir/open-terminal.json"
active_json_path="$gate_l_tmpdir/active-target.json"
retarget_json_path="$gate_l_tmpdir/retarget-rendered-target.json"
switch_transition_json_path="$gate_l_tmpdir/switch-transition.json"
switch_open_json_path="$gate_l_tmpdir/switch-open-terminal.json"
initial_summary_json_path="$gate_l_tmpdir/initial-summary.json"
switched_summary_json_path="$gate_l_tmpdir/switched-summary.json"

printf '%s\n' 'null' >"$retarget_json_path"
printf '%s\n' 'null' >"$switch_transition_json_path"
printf '%s\n' 'null' >"$switch_open_json_path"
printf '%s\n' 'null' >"$switched_summary_json_path"

if [[ "$use_active_target" == "1" ]]; then
  mark_stage active-target-start
  focus_existing_json=""
  open_json=""
  if ! active_json="$(wait_for_live_active_target "$session_name" "$pane_id" 2)"; then
    if open_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$session_name" "${pane_id:-}" 2>"$gate_l_tmpdir/open-terminal.last-error.log")"; then
      printf '%s\n' "$open_json" >"$open_json_path"
      tile_id="$(jq -r '.tileID // empty' <<<"$open_json")"
      resolved_session_name="$(jq -r '.sessionName // empty' <<<"$open_json")"
      resolution_reason="open-terminal-session-fallback"
      if [[ -n "$tile_id" ]]; then
        wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"
        active_json="$(wait_for_rendered_terminal_target_ready "$tile_id" "$settle_timeout")"
      else
        echo "open_terminal_for_pane did not return a tileID" >&2
        exit 1
      fi
    elif gate_l_send_bridge_json_command false 5 "__agtmux_focus_existing_terminal_tile__" "$session_name" \
      >"$gate_l_tmpdir/focus-existing-terminal-tile.json" 2>"$gate_l_tmpdir/focus-existing-terminal-tile.last-error.log"; then
      focus_existing_json="$(cat "$gate_l_tmpdir/focus-existing-terminal-tile.json")"
      gate_l_activate_app
      sleep_ms "$focus_settle_ms"
      if [[ -n "$focus_existing_json" ]]; then
        printf '%s\n' 'null' >"$open_json_path"
        resolved_session_name="$(jq -r '.sessionName // empty' <<<"$focus_existing_json")"
        tile_id="$(jq -r '.tileID // empty' <<<"$focus_existing_json")"
        resolution_reason="focus-existing-terminal-tile"
        if [[ -z "$tile_id" ]]; then
          echo "focus_existing_terminal_tile did not return a tileID" >&2
          exit 1
        fi
        wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"
        active_json="$(wait_for_rendered_terminal_target_ready "$tile_id" "$settle_timeout")"
      fi
    fi
    if [[ -z "$focus_existing_json" && -z "$open_json" ]]; then
      active_json="$(wait_for_live_active_target "$session_name" "$pane_id" "$settle_timeout")"
      resolution_reason="active-target"
    fi
  else
    resolution_reason="active-target"
  fi
  printf '%s\n' "$active_json" >"$active_json_path"
  active_tile_id="$(jq -r '.tileID // empty' <<<"$active_json")"
  if [[ -n "$active_tile_id" ]]; then
    tile_id="$active_tile_id"
  fi
  if [[ -z "$open_json" ]]; then
    printf '%s\n' 'null' >"$open_json_path"
  fi
  if [[ -z "${resolved_session_name:-}" ]]; then
    resolved_session_name="$(jq -r '.sessionName // empty' <<<"$active_json")"
  fi
  if [[ -z "${tile_id:-}" ]]; then
    tile_id="$(jq -r '.tileID // empty' <<<"$active_json")"
  fi
  window_id="$(jq -r '.renderedClientWindowID // .windowID // empty' <<<"$active_json")"
  pane_id="$(jq -r '.renderedClientPaneID // .paneID // empty' <<<"$active_json")"
  resolved_pane_active="1"
  resolved_pane_command=""
  resolved_pane_title=""
  mark_stage active-target-ready
else
  mark_stage resolve-pane-start
  resolved_pane_target="$(resolve_live_pane_target_via_daemon_cli "$session_name" "$pane_id" "$settle_timeout" || true)"
  if [[ -z "$resolved_pane_target" ]]; then
    echo "Failed to resolve pane target in session $session_name via daemon json" >&2
    exit 1
  fi
  resolved_session_name="${resolved_pane_target%%|*}"
  remaining_target="${resolved_pane_target#*|}"
  resolved_pane_id="${remaining_target%%|*}"
  remaining_target="${remaining_target#*|}"
  window_id="${remaining_target%%|*}"
  remaining_target="${remaining_target#*|}"
  resolved_pane_active="${remaining_target%%|*}"
  remaining_target="${remaining_target#*|}"
  resolved_pane_command="${remaining_target%%|*}"
  remaining_target="${remaining_target#*|}"
  resolved_pane_title="${remaining_target%%|*}"
  resolution_reason="${resolved_pane_target##*|}"
  [[ "$resolved_session_name" == "null" ]] && resolved_session_name="$session_name"
  [[ "$window_id" == "null" ]] && window_id=""
  [[ "$resolved_pane_active" == "null" ]] && resolved_pane_active=""
  [[ "$resolved_pane_command" == "null" ]] && resolved_pane_command=""
  [[ "$resolved_pane_title" == "null" ]] && resolved_pane_title=""
  pane_id="$resolved_pane_id"
  mark_stage resolve-pane-done

  mark_stage open-terminal-start
  open_json="$(open_terminal_for_live_pane "local" "$session_name" "$pane_id")"
  printf '%s\n' "$open_json" >"$open_json_path"
  mark_stage open-terminal-done

  reported_host_mode="$(jq -r '.terminalHostMode // empty' <<<"$open_json")"
  tile_id="$(jq -r '.tileID // empty' <<<"$open_json")"
  if [[ -z "$tile_id" ]]; then
    echo "Failed to open pane $session_name $pane_id for host mode $host_mode: $open_json" >&2
    exit 1
  fi
  if [[ "$reported_host_mode" != "$host_mode" ]]; then
    echo "Opened pane with unexpected host mode: expected=$host_mode got=$reported_host_mode" >&2
    exit 1
  fi

  wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"
  wait_for_rendered_terminal_target_ready "$tile_id" "$settle_timeout" >/dev/null
  mark_stage viewport-ready

  if [[ -n "$window_id" ]]; then
    if active_json="$(
      extract_last_json_line "$(
        gate_l_wait_for_active_target "$session_name" "$window_id" "$pane_id" "$settle_timeout"
      )"
    )"; then
      :
    elif active_json="$(
      extract_last_json_line "$(
        gate_l_wait_for_rendered_target "$session_name" "$window_id" "$pane_id" "$settle_timeout"
      )"
    )"; then
      :
    else
      active_json="$(
        extract_last_json_line "$(
          gate_l_wait_for_active_snapshot "$session_name" "$settle_timeout"
        )"
      )"
    fi
  else
    active_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_rendered_terminal_target__" "$tile_id")"
  fi
  printf '%s\n' "$active_json" >"$active_json_path"
  active_tile_id="$(jq -r '.tileID // empty' <<<"$active_json")"
  if [[ -n "$active_tile_id" ]]; then
    tile_id="$active_tile_id"
  fi
  mark_stage active-target-ready

  rendered_client_pane_id="$(jq -r '.renderedClientPaneID // empty' <<<"$active_json")"
  if [[ -n "$pane_id" && "$rendered_client_pane_id" != "$pane_id" ]]; then
    gate_l_send_bridge_command false 10 "__agtmux_focus_rendered_pane__" "$tile_id" "$pane_id" >/dev/null
    if retarget_json="$(wait_for_rendered_client_pane "$tile_id" "$pane_id" "$settle_timeout")"; then
      printf '%s\n' "$retarget_json" >"$retarget_json_path"
    fi
    sleep_ms "$focus_settle_ms"
    mark_stage retarget-rendered-pane
  fi
fi

wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"
wait_for_rendered_terminal_target_ready "$tile_id" "$settle_timeout" >/dev/null
mark_stage viewport-ready

active_host_mode="$(jq -r '.terminalHostMode // empty' <<<"$active_json")"
rendered_client_tty="$(jq -r '.renderedClientTTY // empty' <<<"$active_json")"
if [[ -z "$rendered_client_tty" ]]; then
  echo "Failed to resolve rendered client tty for $resolved_session_name $pane_id ($host_mode)" >&2
  exit 1
fi
if [[ "$active_host_mode" != "$host_mode" ]]; then
  echo "Active target reported unexpected host mode: expected=$host_mode got=$active_host_mode" >&2
  exit 1
fi

gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$tile_id" >/dev/null
gate_l_activate_app
sleep_ms "$focus_settle_ms"
mark_stage focus-host

terminal_ax_identifier="workspace.terminalHost.${tile_id}"
if focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/focus-state.last-error.log")"; then
  focus_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_json")"
  if [[ -n "$focus_identifier" ]]; then
    terminal_ax_identifier="$focus_identifier"
  fi
fi

if ! prepare_live_viewport "$tile_id" "$terminal_ax_identifier" "$scroll_x_frac" "$scroll_y_frac"; then
  exit 1
fi
mark_stage viewport-primed

initial_summary_path="$(measure_live_scroll_burst "initial" "$tile_id" "$terminal_ax_identifier" "initial")"
if [[ "$initial_summary_path" != "$initial_summary_json_path" ]]; then
  cp "$initial_summary_path" "$initial_summary_json_path"
fi

if [[ -n "$switch_to_host_mode" ]]; then
  mark_stage switch-host-mode-start
  switched_mode="$(gate_l_send_bridge_command false 10 "__agtmux_set_terminal_host_mode__" "$switch_to_host_mode")"
  if [[ "$switched_mode" != "$switch_to_host_mode" ]]; then
    echo "Bridge reported unexpected switched host mode: expected=$switch_to_host_mode got=$switched_mode" >&2
    exit 1
  fi
  if [[ -n "$resolved_session_name" && -n "$pane_id" ]]; then
    if switch_open_json="$(gate_l_send_bridge_json_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$resolved_session_name" "$pane_id" 2>"$gate_l_tmpdir/switch-open-terminal.last-error.log")"; then
      printf '%s\n' "$switch_open_json" >"$switch_open_json_path"
      reopened_tile_id="$(jq -r '.tileID // empty' <<<"$switch_open_json")"
      if [[ -n "$reopened_tile_id" ]]; then
        tile_id="$reopened_tile_id"
      fi
    fi
  fi
  switched_target_json="$(wait_for_tile_host_mode "$tile_id" "$switch_to_host_mode" "$settle_timeout")"
  printf '%s\n' "$switched_target_json" >"$switch_transition_json_path"
  switched_tile_id="$(jq -r '.tileID // empty' "$switch_transition_json_path")"
  if [[ -n "$switched_tile_id" ]]; then
    tile_id="$switched_tile_id"
  fi
  wait_for_terminal_viewport_ready "$tile_id" "$settle_timeout"
  rendered_client_tty="$(jq -r '.renderedClientTTY // empty' "$switch_transition_json_path")"
  rendered_client_pane_id="$(jq -r '.renderedClientPaneID // empty' "$switch_transition_json_path")"
  if [[ -n "$pane_id" && "$rendered_client_pane_id" != "$pane_id" ]]; then
    gate_l_send_bridge_command false 10 "__agtmux_focus_rendered_pane__" "$tile_id" "$pane_id" >/dev/null
    wait_for_rendered_client_pane "$tile_id" "$pane_id" "$settle_timeout" >"$gate_l_tmpdir/switch-retarget-rendered-target.json"
    rendered_client_tty="$(jq -r '.renderedClientTTY // empty' "$gate_l_tmpdir/switch-retarget-rendered-target.json")"
  fi
  gate_l_send_bridge_command false 10 "__agtmux_focus_terminal_host__" "$tile_id" >/dev/null
  gate_l_activate_app
  sleep_ms "$focus_settle_ms"
  if focus_json="$(gate_l_send_bridge_json_command false 5 "__agtmux_dump_focus_state__" "$tile_id" 2>"$gate_l_tmpdir/switched-focus-state.last-error.log")"; then
    focus_identifier="$(jq -r '.terminalAccessibilityIdentifier // empty' <<<"$focus_json")"
    if [[ -n "$focus_identifier" ]]; then
      terminal_ax_identifier="$focus_identifier"
    fi
  fi
  if [[ "$reprime_after_switch" == "1" ]]; then
    if ! prepare_live_viewport "$tile_id" "$terminal_ax_identifier" "$scroll_x_frac" "$scroll_y_frac"; then
      exit 1
    fi
    mark_stage viewport-reprimed
  fi
  switched_summary_path="$(measure_live_scroll_burst "switched" "$tile_id" "$terminal_ax_identifier" "switched")"
  if [[ "$switched_summary_path" != "$switched_summary_json_path" ]]; then
    cp "$switched_summary_path" "$switched_summary_json_path"
  fi
  mark_stage switch-host-mode-done
fi

jq -n \
  --arg host_mode "$host_mode" \
  --arg switched_host_mode "$switch_to_host_mode" \
  --arg session_name "$session_name" \
  --arg pane_id "$pane_id" \
  --arg window_id "$window_id" \
  --arg requested_pane_id "${AGTMUX_PERF_LIVE_PANE_ID:-}" \
  --arg resolved_session_name "$resolved_session_name" \
  --arg resolved_pane_active "$resolved_pane_active" \
  --arg resolved_pane_command "$resolved_pane_command" \
  --arg resolved_pane_title "$resolved_pane_title" \
  --arg resolution_reason "$resolution_reason" \
  --arg app_pid "$gate_l_app_pid" \
  --arg tmpdir "$gate_l_tmpdir" \
  --slurpfile open "$open_json_path" \
  --slurpfile active "$active_json_path" \
  --slurpfile retarget "$retarget_json_path" \
  --slurpfile initial "$initial_summary_json_path" \
  --slurpfile switched "$switched_summary_json_path" \
  --slurpfile switchOpen "$switch_open_json_path" \
  --slurpfile switchTransition "$switch_transition_json_path" \
  '($initial[0]) as $initialMeasurement |
   {
     hostMode: $host_mode,
     switchedHostMode: ($switched_host_mode | if length > 0 then . else null end),
     sessionName: $session_name,
     paneID: $pane_id,
     windowID: $window_id,
     requestedPaneID: ($requested_pane_id | if length > 0 then . else null end),
     resolvedPane: {
       sessionName: $resolved_session_name,
       paneID: $pane_id,
       windowID: $window_id,
       paneActive: ($resolved_pane_active == "1"),
       paneCurrentCommand: (if $resolved_pane_command == "" then null else $resolved_pane_command end),
       paneTitle: (if $resolved_pane_title == "" then null else $resolved_pane_title end),
       reason: $resolution_reason
     },
     appPID: ($app_pid | tonumber),
     tmpdir: $tmpdir,
     open: $open[0],
     activeTarget: $active[0],
     retargetedRenderedTarget: ($retarget[0] // null),
     switchOpen: ($switchOpen[0] // null),
     focusState: $initialMeasurement.focusState,
     postFocusState: $initialMeasurement.postFocusState,
     baselineViewport: $initialMeasurement.baselineViewport,
     finalViewport: $initialMeasurement.finalViewport,
     bench: $initialMeasurement.bench,
     postScrollTelemetry: $initialMeasurement.postScrollTelemetry,
     viewportSamples: $initialMeasurement.viewportSamples,
     viewportMetrics: $initialMeasurement.viewportMetrics,
     initialMeasurement: $initialMeasurement,
     switchedMeasurement: ($switched[0] // null),
     switchTransition: ($switchTransition[0] // null)
   }'
