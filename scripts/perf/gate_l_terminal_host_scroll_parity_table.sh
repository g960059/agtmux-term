#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

live_session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-gate-normal-scroll}"
live_pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-%1}"
live_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-25}"
upstep_bursts="${AGTMUX_PERF_UPSTEP_BURSTS:-12}"
upstep_timeout="${AGTMUX_PERF_UPSTEP_TIMEOUT:-15}"
native_app_path=""
allow_version_mismatch=0

while (( $# > 0 )); do
  case "$1" in
    --live-session-name)
      live_session_name="$2"
      shift 2
      ;;
    --live-pane-id)
      live_pane_id="$2"
      shift 2
      ;;
    --live-timeout)
      live_timeout="$2"
      shift 2
      ;;
    --upstep-bursts)
      upstep_bursts="$2"
      shift 2
      ;;
    --upstep-timeout)
      upstep_timeout="$2"
      shift 2
      ;;
    --app)
      native_app_path="$2"
      shift 2
      ;;
    --allow-version-mismatch)
      allow_version_mismatch=1
      shift
      ;;
    *)
      echo "Usage: $0 [--live-session-name NAME] [--live-pane-id %id] [--live-timeout SECONDS] [--upstep-bursts COUNT] [--upstep-timeout SECONDS] [--app /path/to/Ghostty.app] [--allow-version-mismatch]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$native_app_path" ]]; then
  local_vendored_app="$GATE_L_ROOT/vendor/ghostty/zig-out/Ghostty.app"
  if [[ -d "$local_vendored_app" ]]; then
    native_app_path="$local_vendored_app"
  elif ! native_app_path="$(gate_l_resolve_native_ghostty_app_path)"; then
    echo "Could not locate Ghostty.app in /Applications, Spotlight, or vendor/ghostty/zig-out" >&2
    exit 1
  fi
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-terminal-host-scroll-table.XXXXXX")"
live_json_path="$tmpdir/live-host-mode-parity.json"
legacy_native_json_path="$tmpdir/legacy-vs-native.json"
next_native_json_path="$tmpdir/next-vs-native.json"

cleanup() {
  local exit_status=$?
  if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L terminal-host scroll parity table temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP="${AGTMUX_PERF_LIVE_ATTACH_RUNNING_APP:-0}" \
AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT="${AGTMUX_PERF_LIVE_USE_INTERNAL_SCROLL_MEASUREMENT:-1}" \
AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET="${AGTMUX_PERF_LIVE_USE_ACTIVE_TARGET:-1}" \
"$SCRIPT_DIR/gate_l_terminal_host_live_client_scroll_parity.sh" \
  --session-name "$live_session_name" \
  --pane-id "$live_pane_id" \
  --timeout "$live_timeout" >"$live_json_path"

legacy_args=(
  --host-mode legacy
  --bursts "$upstep_bursts"
  --timeout "$upstep_timeout"
  --app "$native_app_path"
)
next_args=(
  --host-mode next
  --bursts "$upstep_bursts"
  --timeout "$upstep_timeout"
  --app "$native_app_path"
)
if (( allow_version_mismatch == 1 )); then
  legacy_args+=(--allow-version-mismatch)
  next_args+=(--allow-version-mismatch)
fi

"$SCRIPT_DIR/gate_l_trackpad_upscroll_step_parity.sh" "${legacy_args[@]}" >"$legacy_native_json_path"
"$SCRIPT_DIR/gate_l_trackpad_upscroll_step_parity.sh" "${next_args[@]}" >"$next_native_json_path"

jq -n \
  --arg live_session_name "$live_session_name" \
  --arg live_pane_id "$live_pane_id" \
  --arg native_app_path "$native_app_path" \
  --argjson upstep_bursts "$upstep_bursts" \
  --slurpfile live "$live_json_path" \
  --slurpfile legacy_native "$legacy_native_json_path" \
  --slurpfile next_native "$next_native_json_path" \
  '
  ($live[0]) as $live_payload |
  ($legacy_native[0]) as $legacy_native_payload |
  ($next_native[0]) as $next_native_payload |
  {
    live_target: {
      session_name: $live_session_name,
      pane_id: $live_pane_id
    },
    native_app_path: $native_app_path,
    upstep_bursts: $upstep_bursts,
    live_host_mode_parity: $live_payload,
    native_trackpad_upscroll_step_parity: {
      legacy: $legacy_native_payload,
      next: $next_native_payload
    },
    summary: {
      embedded_ghostty_version: ($legacy_native_payload.embedded_ghostty.version // $next_native_payload.embedded_ghostty.version // null),
      native_ghostty_version: ($legacy_native_payload.native_ghostty.version // $next_native_payload.native_ghostty.version // null),
      native_version_matched: (($legacy_native_payload.ghostty_version_match.matched // false) and ($next_native_payload.ghostty_version_match.matched // false)),
      live_host_mode_valid: ($live_payload.valid // false),
      live_host_mode_passed: ($live_payload.passed // false),
      legacy_native_passed: ($legacy_native_payload.gate.passed // false),
      next_native_passed: ($next_native_payload.gate.passed // false),
      next_minus_legacy_native_deltas: {
        mean_lines_per_step_p50_delta:
          (($next_native_payload.diff.mean_lines_per_step_p50_delta // 0) - ($legacy_native_payload.diff.mean_lines_per_step_p50_delta // 0)),
        step_rows_p95_delta:
          (($next_native_payload.diff.step_rows_p95_delta // 0) - ($legacy_native_payload.diff.step_rows_p95_delta // 0)),
        max_step_rows_delta:
          (($next_native_payload.diff.max_step_rows_delta // 0) - ($legacy_native_payload.diff.max_step_rows_delta // 0)),
        coarse_step_ratio_ge_2_delta:
          (($next_native_payload.diff.coarse_step_ratio_ge_2_delta // 0) - ($legacy_native_payload.diff.coarse_step_ratio_ge_2_delta // 0)),
        coarse_step_ratio_ge_3_delta:
          (($next_native_payload.diff.coarse_step_ratio_ge_3_delta // 0) - ($legacy_native_payload.diff.coarse_step_ratio_ge_3_delta // 0)),
        first_changed_elapsed_p50_delta_ms:
          (($next_native_payload.diff.first_changed_elapsed_p50_delta_ms // 0) - ($legacy_native_payload.diff.first_changed_elapsed_p50_delta_ms // 0)),
        first_changed_elapsed_p95_delta_ms:
          (($next_native_payload.diff.first_changed_elapsed_p95_delta_ms // 0) - ($legacy_native_payload.diff.first_changed_elapsed_p95_delta_ms // 0))
      }
    }
  }'
