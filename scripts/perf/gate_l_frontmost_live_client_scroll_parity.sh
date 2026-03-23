#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"

embedded_app_pid=""
native_app_pid=""
embedded_bundle_id=""
native_bundle_id=""
embedded_client_tty=""
native_client_tty=""
reset_scroll_pixels="${AGTMUX_PERF_LIVE_RESET_SCROLL_PIXELS:--10}"
reset_scroll_repeat="${AGTMUX_PERF_LIVE_RESET_SCROLL_REPEAT:-8}"
reset_scroll_interval_ms="${AGTMUX_PERF_LIVE_RESET_SCROLL_INTERVAL_MS:-8}"
reset_scroll_phase_mode="${AGTMUX_PERF_LIVE_RESET_PHASE_MODE:-trackpad-burst-momentum}"
reset_scroll_x_frac="${AGTMUX_PERF_SCROLL_X_FRAC:-0.5}"
reset_scroll_y_frac="${AGTMUX_PERF_SCROLL_Y_FRAC:-0.5}"
reset_settle_ms="${AGTMUX_PERF_LIVE_RESET_SETTLE_MS:-220}"
reset_max_rounds="${AGTMUX_PERF_LIVE_RESET_MAX_ROUNDS:-3}"
use_reset="${AGTMUX_PERF_LIVE_USE_RESET:-0}"
prepare_reset_threshold="${AGTMUX_PERF_LIVE_PREPARE_RESET_THRESHOLD:-64}"
prepare_reset_rounds="${AGTMUX_PERF_LIVE_PREPARE_RESET_ROUNDS:-1}"
prime_scroll_pixels="${AGTMUX_PERF_LIVE_PRIME_SCROLL_PIXELS:-10}"
prime_scroll_repeat="${AGTMUX_PERF_LIVE_PRIME_SCROLL_REPEAT:-24}"
prime_scroll_interval_ms="${AGTMUX_PERF_LIVE_PRIME_SCROLL_INTERVAL_MS:-8}"
prime_scroll_phase_mode="${AGTMUX_PERF_LIVE_PRIME_PHASE_MODE:-trackpad-burst-momentum}"
prime_settle_ms="${AGTMUX_PERF_LIVE_PRIME_SETTLE_MS:-220}"
prime_max_rounds="${AGTMUX_PERF_LIVE_PRIME_MAX_ROUNDS:-6}"
prime_min_rounds="${AGTMUX_PERF_LIVE_PRIME_MIN_ROUNDS:-1}"

while (( $# > 0 )); do
  case "$1" in
    --embedded-app-pid)
      embedded_app_pid="$2"
      shift 2
      ;;
    --native-app-pid)
      native_app_pid="$2"
      shift 2
      ;;
    --embedded-bundle-id)
      embedded_bundle_id="$2"
      shift 2
      ;;
    --native-bundle-id)
      native_bundle_id="$2"
      shift 2
      ;;
    --embedded-client-tty)
      embedded_client_tty="$2"
      shift 2
      ;;
    --native-client-tty)
      native_client_tty="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$embedded_app_pid" && -z "$embedded_bundle_id" ]]; then
  echo "gate_l_frontmost_live_client_scroll_parity.sh requires --embedded-app-pid or --embedded-bundle-id" >&2
  exit 2
fi
if [[ -z "$native_app_pid" && -z "$native_bundle_id" ]]; then
  echo "gate_l_frontmost_live_client_scroll_parity.sh requires --native-app-pid or --native-bundle-id" >&2
  exit 2
fi
if [[ -z "$embedded_client_tty" || -z "$native_client_tty" ]]; then
  echo "gate_l_frontmost_live_client_scroll_parity.sh requires --embedded-client-tty and --native-client-tty" >&2
  exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-live-client-scroll-parity.XXXXXX")"
cleanup() {
  local exit_status=$?
  if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L live client-scroll parity temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

embedded_json_path="$tmpdir/embedded.json"
native_json_path="$tmpdir/native.json"

function sample_client_scroll_position() {
  local client_tty="$1"
  tmux display-message -p -c "$client_tty" '#{scroll_position}' 2>/dev/null | tr -d '\r\n'
}

function sample_client_pane_in_mode() {
  local client_tty="$1"
  tmux display-message -p -c "$client_tty" '#{pane_in_mode}' 2>/dev/null | tr -d '\r\n'
}

function sample_tmux_mouse_mode() {
  env -u TMUX -u TMUX_PANE tmux show-options -gv mouse 2>/dev/null | tr -d '\r\n'
}

tmux_mouse_mode="$(sample_tmux_mouse_mode)"
if [[ "$tmux_mouse_mode" != "on" ]]; then
  echo "gate_l_frontmost_live_client_scroll_parity.sh requires tmux mouse on; current mouse=$tmux_mouse_mode" >&2
  exit 1
fi

function append_target_args() {
  local array_name="$1"
  local app_pid="$2"
  local bundle_id="$3"
  if [[ -n "$app_pid" ]]; then
    eval "$array_name+=(--app-pid \"\$app_pid\")"
  fi
  if [[ -n "$bundle_id" ]]; then
    eval "$array_name+=(--bundle-id \"\$bundle_id\")"
  fi
}

function reset_client_scroll() {
  local app_pid="$1"
  local bundle_id="$2"
  local scroll_pixels="$3"
  local scroll_repeat="$4"
  local scroll_interval_ms="$5"
  local scroll_phase_mode="$6"
  local reset_args=(
    --focus-scroll-front-window
    --x-frac "$reset_scroll_x_frac"
    --y-frac "$reset_scroll_y_frac"
    --scroll-pixels "$scroll_pixels"
    --scroll-repeat "$scroll_repeat"
    --scroll-interval-ms "$scroll_interval_ms"
    --scroll-phase-mode "$scroll_phase_mode"
  )
  append_target_args reset_args "$app_pid" "$bundle_id"
  "$SCRIPT_DIR/gate_l_ax_key_sender.sh" "${reset_args[@]}"
}

function prepare_live_clients() {
  embedded_prime_before_mode="$(sample_client_pane_in_mode "$embedded_client_tty")"
  native_prime_before_mode="$(sample_client_pane_in_mode "$native_client_tty")"
  embedded_prime_after_mode="$embedded_prime_before_mode"
  native_prime_after_mode="$native_prime_before_mode"
  embedded_prime_after_scroll="$(sample_client_scroll_position "$embedded_client_tty")"
  native_prime_after_scroll="$(sample_client_scroll_position "$native_client_tty")"
  embedded_prime_previous_scroll=""
  native_prime_previous_scroll=""
  prime_rounds=0

  while (( prime_rounds < prime_max_rounds )); do
    if (( prime_rounds >= prime_min_rounds )) && [[ "$embedded_prime_after_mode" == "1" \
          && "$native_prime_after_mode" == "1" \
          && -n "$embedded_prime_after_scroll" \
          && -n "$native_prime_after_scroll" \
          && "$embedded_prime_after_scroll" == "$embedded_prime_previous_scroll" \
          && "$native_prime_after_scroll" == "$native_prime_previous_scroll" ]]; then
      break
    fi
    prime_rounds=$((prime_rounds + 1))
    embedded_prime_previous_scroll="$embedded_prime_after_scroll"
    native_prime_previous_scroll="$native_prime_after_scroll"
    reset_client_scroll "$embedded_app_pid" "$embedded_bundle_id" "$prime_scroll_pixels" "$prime_scroll_repeat" "$prime_scroll_interval_ms" "$prime_scroll_phase_mode" >/dev/null
    reset_client_scroll "$native_app_pid" "$native_bundle_id" "$prime_scroll_pixels" "$prime_scroll_repeat" "$prime_scroll_interval_ms" "$prime_scroll_phase_mode" >/dev/null
    sleep "$(awk -v ms="$prime_settle_ms" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
    embedded_prime_after_mode="$(sample_client_pane_in_mode "$embedded_client_tty")"
    native_prime_after_mode="$(sample_client_pane_in_mode "$native_client_tty")"
    embedded_prime_after_scroll="$(sample_client_scroll_position "$embedded_client_tty")"
    native_prime_after_scroll="$(sample_client_scroll_position "$native_client_tty")"
  done

  if [[ "$embedded_prime_after_mode" != "1" || "$native_prime_after_mode" != "1" ]]; then
    echo "Failed to prime live clients into tmux copy mode: embedded_mode=$embedded_prime_after_mode native_mode=$native_prime_after_mode" >&2
    exit 1
  fi

  embedded_reset_before="$(sample_client_scroll_position "$embedded_client_tty")"
  native_reset_before="$(sample_client_scroll_position "$native_client_tty")"
  embedded_reset_after="$embedded_reset_before"
  native_reset_after="$native_reset_before"
  reset_rounds=0
  reset_enabled=0
  reset_target_rounds=0

  if [[ "$use_reset" == "1" ]]; then
    reset_enabled=1
    reset_target_rounds="$reset_max_rounds"
  elif [[ -n "$embedded_reset_before" && -n "$native_reset_before" ]]; then
    reset_enabled=1
    reset_target_rounds="$prepare_reset_rounds"
  fi

  if (( reset_enabled )); then
    while (( reset_rounds < reset_target_rounds )); do
      reset_rounds=$((reset_rounds + 1))
      reset_client_scroll "$embedded_app_pid" "$embedded_bundle_id" "$reset_scroll_pixels" "$reset_scroll_repeat" "$reset_scroll_interval_ms" "$reset_scroll_phase_mode" >/dev/null
      reset_client_scroll "$native_app_pid" "$native_bundle_id" "$reset_scroll_pixels" "$reset_scroll_repeat" "$reset_scroll_interval_ms" "$reset_scroll_phase_mode" >/dev/null
      sleep "$(awk -v ms="$reset_settle_ms" 'BEGIN { printf "%.3f", (ms / 1000.0) }')"
      embedded_reset_after="$(sample_client_scroll_position "$embedded_client_tty")"
      native_reset_after="$(sample_client_scroll_position "$native_client_tty")"
    done

    if [[ -z "$embedded_reset_after" || -z "$native_reset_after" ]]; then
      echo "Failed to sample client scroll positions during reset" >&2
      exit 1
    fi
    if [[ "$embedded_reset_after" != "$native_reset_after" ]]; then
      echo "Client scroll reset did not converge: embedded=$embedded_reset_after native=$native_reset_after" >&2
      exit 1
    fi
  else
    embedded_reset_before="$embedded_prime_after_scroll"
    native_reset_before="$native_prime_after_scroll"
    embedded_reset_after="$embedded_prime_after_scroll"
    native_reset_after="$native_prime_after_scroll"
  fi
}

function capture_prepare_snapshot() {
  local prefix="$1"
  typeset -g "${prefix}_prime_rounds=$prime_rounds"
  typeset -g "${prefix}_embedded_prime_before_mode=$embedded_prime_before_mode"
  typeset -g "${prefix}_native_prime_before_mode=$native_prime_before_mode"
  typeset -g "${prefix}_embedded_prime_after_mode=$embedded_prime_after_mode"
  typeset -g "${prefix}_native_prime_after_mode=$native_prime_after_mode"
  typeset -g "${prefix}_embedded_prime_after_scroll=$embedded_prime_after_scroll"
  typeset -g "${prefix}_native_prime_after_scroll=$native_prime_after_scroll"
  typeset -g "${prefix}_reset_enabled=$reset_enabled"
  typeset -g "${prefix}_reset_target_rounds=$reset_target_rounds"
  typeset -g "${prefix}_reset_rounds=$reset_rounds"
  typeset -g "${prefix}_embedded_reset_before=$embedded_reset_before"
  typeset -g "${prefix}_native_reset_before=$native_reset_before"
  typeset -g "${prefix}_embedded_reset_after=$embedded_reset_after"
  typeset -g "${prefix}_native_reset_after=$native_reset_after"
}

prepare_live_clients
capture_prepare_snapshot embedded_run

embedded_args=(--label embedded --client-tty "$embedded_client_tty")
if [[ -n "$embedded_app_pid" ]]; then
  embedded_args+=(--app-pid "$embedded_app_pid")
fi
if [[ -n "$embedded_bundle_id" ]]; then
  embedded_args+=(--bundle-id "$embedded_bundle_id")
fi
"$SCRIPT_DIR/gate_l_frontmost_live_client_scroll_bench.sh" "${embedded_args[@]}" "$@" >"$embedded_json_path"
if [[ "$(jq -r '.valid // false' "$embedded_json_path")" != "true" ]]; then
  echo "Embedded live client-scroll bench was invalid: $(jq -r '.invalid_reason // \"unknown\"' "$embedded_json_path")" >&2
  exit 1
fi

native_args=(--label native --client-tty "$native_client_tty")
if [[ -n "$native_app_pid" ]]; then
  native_args+=(--app-pid "$native_app_pid")
fi
if [[ -n "$native_bundle_id" ]]; then
  native_args+=(--bundle-id "$native_bundle_id")
fi
prepare_live_clients
capture_prepare_snapshot native_run
"$SCRIPT_DIR/gate_l_frontmost_live_client_scroll_bench.sh" "${native_args[@]}" "$@" >"$native_json_path"
if [[ "$(jq -r '.valid // false' "$native_json_path")" != "true" ]]; then
  echo "Native live client-scroll bench was invalid: $(jq -r '.invalid_reason // \"unknown\"' "$native_json_path")" >&2
  exit 1
fi

jq -n \
  --arg embedded_client_tty "$embedded_client_tty" \
  --arg native_client_tty "$native_client_tty" \
  --arg tmux_mouse_mode "$tmux_mouse_mode" \
  --arg use_reset "$use_reset" \
  --arg prepare_reset_threshold "$prepare_reset_threshold" \
  --arg reset_scroll_pixels "$reset_scroll_pixels" \
  --argjson reset_scroll_repeat "$reset_scroll_repeat" \
  --argjson reset_scroll_interval_ms "$reset_scroll_interval_ms" \
  --arg reset_scroll_phase_mode "$reset_scroll_phase_mode" \
  --argjson embedded_run_prime_rounds "$embedded_run_prime_rounds" \
  --arg embedded_run_embedded_prime_before_mode "$embedded_run_embedded_prime_before_mode" \
  --arg embedded_run_native_prime_before_mode "$embedded_run_native_prime_before_mode" \
  --arg embedded_run_embedded_prime_after_mode "$embedded_run_embedded_prime_after_mode" \
  --arg embedded_run_native_prime_after_mode "$embedded_run_native_prime_after_mode" \
  --arg embedded_run_embedded_prime_after_scroll "$embedded_run_embedded_prime_after_scroll" \
  --arg embedded_run_native_prime_after_scroll "$embedded_run_native_prime_after_scroll" \
  --argjson embedded_run_reset_enabled "$embedded_run_reset_enabled" \
  --argjson embedded_run_reset_target_rounds "$embedded_run_reset_target_rounds" \
  --argjson embedded_run_reset_rounds "$embedded_run_reset_rounds" \
  --arg embedded_run_embedded_reset_before "$embedded_run_embedded_reset_before" \
  --arg embedded_run_native_reset_before "$embedded_run_native_reset_before" \
  --arg embedded_run_embedded_reset_after "$embedded_run_embedded_reset_after" \
  --arg embedded_run_native_reset_after "$embedded_run_native_reset_after" \
  --argjson native_run_prime_rounds "$native_run_prime_rounds" \
  --arg native_run_embedded_prime_before_mode "$native_run_embedded_prime_before_mode" \
  --arg native_run_native_prime_before_mode "$native_run_native_prime_before_mode" \
  --arg native_run_embedded_prime_after_mode "$native_run_embedded_prime_after_mode" \
  --arg native_run_native_prime_after_mode "$native_run_native_prime_after_mode" \
  --arg native_run_embedded_prime_after_scroll "$native_run_embedded_prime_after_scroll" \
  --arg native_run_native_prime_after_scroll "$native_run_native_prime_after_scroll" \
  --argjson native_run_reset_enabled "$native_run_reset_enabled" \
  --argjson native_run_reset_target_rounds "$native_run_reset_target_rounds" \
  --argjson native_run_reset_rounds "$native_run_reset_rounds" \
  --arg native_run_embedded_reset_before "$native_run_embedded_reset_before" \
  --arg native_run_native_reset_before "$native_run_native_reset_before" \
  --arg native_run_embedded_reset_after "$native_run_embedded_reset_after" \
  --arg native_run_native_reset_after "$native_run_native_reset_after" \
  --slurpfile embedded "$embedded_json_path" \
  --slurpfile native "$native_json_path" \
  '{
    reset: {
      client_ttys: {
        embedded: $embedded_client_tty,
        native: $native_client_tty
      },
      tmux_mouse_mode: $tmux_mouse_mode,
      config: {
        scroll_pixels: ($reset_scroll_pixels | tonumber),
        scroll_repeat: $reset_scroll_repeat,
        scroll_interval_ms: $reset_scroll_interval_ms,
        scroll_phase_mode: $reset_scroll_phase_mode,
        prepare_threshold: ($prepare_reset_threshold | tonumber)
      },
      embedded_run: {
        prime: {
          rounds: $embedded_run_prime_rounds,
          before_mode: {
            embedded: ($embedded_run_embedded_prime_before_mode | if length > 0 then tonumber else null end),
            native: ($embedded_run_native_prime_before_mode | if length > 0 then tonumber else null end)
          },
          after_mode: {
            embedded: ($embedded_run_embedded_prime_after_mode | tonumber),
            native: ($embedded_run_native_prime_after_mode | tonumber)
          },
          after_scroll_position: {
            embedded: ($embedded_run_embedded_prime_after_scroll | tonumber),
            native: ($embedded_run_native_prime_after_scroll | tonumber)
          }
        },
        enabled: ($embedded_run_reset_enabled == 1),
        target_rounds: $embedded_run_reset_target_rounds,
        rounds: $embedded_run_reset_rounds,
        before: {
          embedded: ($embedded_run_embedded_reset_before | tonumber),
          native: ($embedded_run_native_reset_before | tonumber)
        },
        after: {
          embedded: ($embedded_run_embedded_reset_after | tonumber),
          native: ($embedded_run_native_reset_after | tonumber)
        }
      },
      native_run: {
        prime: {
          rounds: $native_run_prime_rounds,
          before_mode: {
            embedded: ($native_run_embedded_prime_before_mode | if length > 0 then tonumber else null end),
            native: ($native_run_native_prime_before_mode | if length > 0 then tonumber else null end)
          },
          after_mode: {
            embedded: ($native_run_embedded_prime_after_mode | tonumber),
            native: ($native_run_native_prime_after_mode | tonumber)
          },
          after_scroll_position: {
            embedded: ($native_run_embedded_prime_after_scroll | tonumber),
            native: ($native_run_native_prime_after_scroll | tonumber)
          }
        },
        enabled: ($native_run_reset_enabled == 1),
        target_rounds: $native_run_reset_target_rounds,
        rounds: $native_run_reset_rounds,
        before: {
          embedded: ($native_run_embedded_reset_before | tonumber),
          native: ($native_run_native_reset_before | tonumber)
        },
        after: {
          embedded: ($native_run_embedded_reset_after | tonumber),
          native: ($native_run_native_reset_after | tonumber)
        }
      }
    },
    embedded: $embedded[0],
    native: $native[0],
    comparison: {
      first_changed_elapsed_p50_delta_ms:
        (if ($embedded[0].metrics.summary.first_changed_elapsed_ms != null and $native[0].metrics.summary.first_changed_elapsed_ms != null)
         then ($embedded[0].metrics.summary.first_changed_elapsed_ms - $native[0].metrics.summary.first_changed_elapsed_ms)
         else null
         end),
      coarse_step_count_ge_3_delta:
        (($embedded[0].metrics.summary.coarse_step_count_ge_3 // 0) - ($native[0].metrics.summary.coarse_step_count_ge_3 // 0)),
      max_step_rows_delta:
        (($embedded[0].metrics.summary.max_step_rows // 0) - ($native[0].metrics.summary.max_step_rows // 0)),
      changed_sample_count_delta:
        (($embedded[0].metrics.summary.changed_sample_count // 0) - ($native[0].metrics.summary.changed_sample_count // 0)),
      net_scroll_delta_delta:
        (($embedded[0].metrics.summary.net_scroll_delta // 0) - ($native[0].metrics.summary.net_scroll_delta // 0))
    }
  }'
