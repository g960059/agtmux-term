#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

history_iterations="${AGTMUX_PERF_HISTORY_ITERATIONS:-8}"
history_timeout="${AGTMUX_PERF_HISTORY_TIMEOUT:-15}"
native_app_path=""
allow_version_mismatch=0

while (( $# > 0 )); do
  case "$1" in
    --history-iterations)
      history_iterations="$2"
      shift 2
      ;;
    --history-timeout)
      history_timeout="$2"
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
      echo "Usage: $0 [--history-iterations COUNT] [--history-timeout SECONDS] [--app /path/to/Ghostty.app] [--allow-version-mismatch]" >&2
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

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-terminal-host-cadence-table.XXXXXX")"
legacy_json_path="$tmpdir/legacy-vs-native-history.json"
next_json_path="$tmpdir/next-vs-native-history.json"

cleanup() {
  local exit_status=$?
  if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L terminal-host cadence parity table temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

legacy_args=(
  --host-mode legacy
  --iterations "$history_iterations"
  --timeout "$history_timeout"
  --app "$native_app_path"
)
next_args=(
  --host-mode next
  --iterations "$history_iterations"
  --timeout "$history_timeout"
  --app "$native_app_path"
)
if (( allow_version_mismatch == 1 )); then
  legacy_args+=(--allow-version-mismatch)
  next_args+=(--allow-version-mismatch)
fi

"$SCRIPT_DIR/gate_l_trackpad_history_scroll_parity.sh" "${legacy_args[@]}" >"$legacy_json_path"
"$SCRIPT_DIR/gate_l_trackpad_history_scroll_parity.sh" "${next_args[@]}" >"$next_json_path"

jq -n \
  --arg native_app_path "$native_app_path" \
  --argjson history_iterations "$history_iterations" \
  --slurpfile legacy "$legacy_json_path" \
  --slurpfile next "$next_json_path" \
  '
  ($legacy[0]) as $legacy_payload |
  ($next[0]) as $next_payload |
  {
    native_app_path: $native_app_path,
    history_iterations: $history_iterations,
    history_scroll_native_parity: {
      legacy: $legacy_payload,
      next: $next_payload
    },
    summary: {
      embedded_ghostty_version: ($legacy_payload.embedded_ghostty.version // $next_payload.embedded_ghostty.version // null),
      native_ghostty_version: ($legacy_payload.native_ghostty.version // $next_payload.native_ghostty.version // null),
      native_version_matched: (($legacy_payload.ghostty_version_match.matched // false) and ($next_payload.ghostty_version_match.matched // false)),
      legacy_native_passed: ($legacy_payload.gate.passed // false),
      next_native_passed: ($next_payload.gate.passed // false),
      next_minus_legacy_proxy_deltas: {
        tmux_visible_line_change_p50_delta_ms:
          (($next_payload.diff.tmux_visible_line_change_p50_delta_ms // 0) - ($legacy_payload.diff.tmux_visible_line_change_p50_delta_ms // 0)),
        tmux_visible_line_change_p95_delta_ms:
          (($next_payload.diff.tmux_visible_line_change_p95_delta_ms // 0) - ($legacy_payload.diff.tmux_visible_line_change_p95_delta_ms // 0)),
        tmux_visible_line_change_max_delta_ms:
          (($next_payload.diff.tmux_visible_line_change_max_delta_ms // 0) - ($legacy_payload.diff.tmux_visible_line_change_max_delta_ms // 0)),
        empty_burst_count_delta:
          (($next_payload.diff.empty_burst_count_delta // 0) - ($legacy_payload.diff.empty_burst_count_delta // 0))
      },
      next_minus_legacy_embedded_cadence_deltas: {
        scroll_to_layer_present_p50_delta_ms:
          (($next_payload.embedded_cadence.scroll_to_layer_present_ms.p50_ms // 0) - ($legacy_payload.embedded_cadence.scroll_to_layer_present_ms.p50_ms // 0)),
        scroll_to_layer_present_p95_delta_ms:
          (($next_payload.embedded_cadence.scroll_to_layer_present_ms.p95_ms // 0) - ($legacy_payload.embedded_cadence.scroll_to_layer_present_ms.p95_ms // 0)),
        scroll_to_layer_present_max_delta_ms:
          (($next_payload.embedded_cadence.scroll_to_layer_present_ms.max_ms // 0) - ($legacy_payload.embedded_cadence.scroll_to_layer_present_ms.max_ms // 0)),
        layer_present_gap_p95_delta_ms:
          (($next_payload.embedded_cadence.layer_present_gap_p95_ms // 0) - ($legacy_payload.embedded_cadence.layer_present_gap_p95_ms // 0)),
        layer_present_gap_max_delta_ms:
          (($next_payload.embedded_cadence.layer_present_gap_max_ms // 0) - ($legacy_payload.embedded_cadence.layer_present_gap_max_ms // 0)),
        scroll_presentation_draw_gap_p95_delta_ms:
          (($next_payload.embedded_cadence.scroll_presentation_draw_gap_p95_ms // 0) - ($legacy_payload.embedded_cadence.scroll_presentation_draw_gap_p95_ms // 0)),
        scroll_presentation_draw_gap_max_delta_ms:
          (($next_payload.embedded_cadence.scroll_presentation_draw_gap_max_ms // 0) - ($legacy_payload.embedded_cadence.scroll_presentation_draw_gap_max_ms // 0)),
        scroll_presentation_draw_count_delta:
          (($next_payload.embedded_cadence.scroll_presentation_draw_count // 0) - ($legacy_payload.embedded_cadence.scroll_presentation_draw_count // 0)),
        layer_present_count_delta:
          (($next_payload.embedded_cadence.layer_present_count // 0) - ($legacy_payload.embedded_cadence.layer_present_count // 0))
      }
    }
  }'
