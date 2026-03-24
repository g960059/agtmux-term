#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

iterations="${AGTMUX_PERF_HISTORY_ITERATIONS:-8}"
settle_timeout=15
native_app_path=""
allow_existing=0
keep_running=0
host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-}"
allow_version_mismatch=0

visible_line_p50_delta_max="${AGTMUX_PERF_HISTORY_VISIBLE_LINE_P50_DELTA_MAX:-80.0}"
visible_line_p95_delta_max="${AGTMUX_PERF_HISTORY_VISIBLE_LINE_P95_DELTA_MAX:-120.0}"
visible_line_max_delta_max="${AGTMUX_PERF_HISTORY_VISIBLE_LINE_MAX_DELTA_MAX:-200.0}"
empty_burst_count_delta_max="${AGTMUX_PERF_HISTORY_EMPTY_BURST_COUNT_DELTA_MAX:-0}"

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
      native_app_path="$2"
      shift 2
      ;;
    --host-mode)
      host_mode="$2"
      shift 2
      ;;
    --allow-existing)
      allow_existing=1
      shift
      ;;
    --allow-version-mismatch)
      allow_version_mismatch=1
      shift
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--host-mode legacy|next] [--allow-existing] [--allow-version-mismatch] [--keep-running]" >&2
      exit 1
      ;;
  esac
done

gate_l_require_explicit_terminal_host_mode "$host_mode" "$0" || exit 1

if [[ -z "$native_app_path" ]]; then
  if ! native_app_path="$(gate_l_resolve_native_ghostty_app_path)"; then
    echo "Could not locate Ghostty.app in /Applications, Spotlight, or vendor/ghostty/zig-out" >&2
    exit 1
  fi
fi

if [[ ! -d "$native_app_path" ]]; then
  echo "Ghostty.app does not exist: $native_app_path" >&2
  exit 1
fi

embedded_ghostty_json="$(gate_l_embedded_ghostty_metadata_json)"
native_ghostty_json="$(gate_l_native_ghostty_metadata_json "$native_app_path")"
embedded_ghostty_version="$(jq -r '.version // empty' <<<"$embedded_ghostty_json")"
native_ghostty_version="$(jq -r '.version // empty' <<<"$native_ghostty_json")"
version_matched=0
if [[ -n "$embedded_ghostty_version" && -n "$native_ghostty_version" && "$embedded_ghostty_version" == "$native_ghostty_version" ]]; then
  version_matched=1
fi
if (( allow_version_mismatch != 1 && version_matched != 1 )); then
  echo "Embedded GhosttyKit ($embedded_ghostty_version) and native Ghostty ($native_ghostty_version) do not match." >&2
  echo "Pass --app with a matched Ghostty build or rerun with --allow-version-mismatch for diagnostic-only output." >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-history-parity.XXXXXX")"
embedded_json_path="$tmpdir/embedded.json"
native_json_path="$tmpdir/native.json"

function normalize_bench_json() {
  local path="$1"
  /usr/bin/python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
decoder = json.JSONDecoder()

for index, char in enumerate(text):
    if char != "{":
        continue
    try:
        payload, end = decoder.raw_decode(text[index:])
    except json.JSONDecodeError:
        continue
    path.write_text(json.dumps(payload, indent=2) + "\n")
    raise SystemExit(0)

raise SystemExit(f"failed to locate JSON payload in {path}")
PY
}

cleanup() {
  local exit_status=$?
  if (( keep_running != 1 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L history-scroll parity temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

AGTMUX_PERF_TERMINAL_HOST_MODE="$host_mode" \
"$SCRIPT_DIR/gate_l_trackpad_history_scroll_bench.sh" \
  --iterations "$iterations" \
  --timeout "$settle_timeout" >"$embedded_json_path"
normalize_bench_json "$embedded_json_path"

native_args=(
  --iterations "$iterations"
  --timeout "$settle_timeout"
)
if [[ -n "$native_app_path" ]]; then
  native_args+=(--app "$native_app_path")
fi
if (( allow_existing == 1 )); then
  native_args+=(--allow-existing)
fi
if (( keep_running == 1 )); then
  native_args+=(--keep-running)
fi

"$SCRIPT_DIR/gate_l_native_ghostty_trackpad_history_scroll_bench.sh" \
  "${native_args[@]}" >"$native_json_path"
normalize_bench_json "$native_json_path"

result_json="$(jq -n \
  --slurpfile embedded "$embedded_json_path" \
  --slurpfile native "$native_json_path" \
  --arg host_mode "$host_mode" \
  --argjson embedded_ghostty "$embedded_ghostty_json" \
  --argjson native_ghostty "$native_ghostty_json" \
  --argjson version_matched "$version_matched" \
  --argjson visible_line_p50_delta_max "$visible_line_p50_delta_max" \
  --argjson visible_line_p95_delta_max "$visible_line_p95_delta_max" \
  --argjson visible_line_max_delta_max "$visible_line_max_delta_max" \
  --argjson empty_burst_count_delta_max "$empty_burst_count_delta_max" '
  ($embedded[0]) as $embedded
  | ($native[0]) as $native
  | (
      if ($embedded.metrics.tmux_visible_line_change_ms.p50_ms != null and $native.metrics.tmux_visible_line_change_ms.p50_ms != null) then
        ($embedded.metrics.tmux_visible_line_change_ms.p50_ms - $native.metrics.tmux_visible_line_change_ms.p50_ms)
      else
        null
      end
    ) as $visible_line_p50_delta
  | (
      if ($embedded.metrics.tmux_visible_line_change_ms.p95_ms != null and $native.metrics.tmux_visible_line_change_ms.p95_ms != null) then
        ($embedded.metrics.tmux_visible_line_change_ms.p95_ms - $native.metrics.tmux_visible_line_change_ms.p95_ms)
      else
        null
      end
    ) as $visible_line_p95_delta
  | (
      if ($embedded.metrics.tmux_visible_line_change_ms.max_ms != null and $native.metrics.tmux_visible_line_change_ms.max_ms != null) then
        ($embedded.metrics.tmux_visible_line_change_ms.max_ms - $native.metrics.tmux_visible_line_change_ms.max_ms)
      else
        null
      end
    ) as $visible_line_max_delta
  | (($embedded.metrics.empty_burst_count // 0) - ($native.metrics.empty_burst_count // 0)) as $empty_burst_count_delta
  | [
      if $visible_line_p50_delta != null and $visible_line_p50_delta > $visible_line_p50_delta_max then
        "embedded tmux_visible_line_change p50 exceeds native by \($visible_line_p50_delta | tostring) ms"
      else empty end,
      if $visible_line_p95_delta != null and $visible_line_p95_delta > $visible_line_p95_delta_max then
        "embedded tmux_visible_line_change p95 exceeds native by \($visible_line_p95_delta | tostring) ms"
      else empty end,
      if $visible_line_max_delta != null and $visible_line_max_delta > $visible_line_max_delta_max then
        "embedded tmux_visible_line_change max exceeds native by \($visible_line_max_delta | tostring) ms"
      else empty end,
      if $empty_burst_count_delta > $empty_burst_count_delta_max then
        "embedded empty_burst_count exceeds native by \($empty_burst_count_delta | tostring)"
      else empty end
    ] as $failures
  | [
      if ($embedded.metrics.layer_present_captured // false) != true then
        "embedded layer-present cadence was not captured"
      else empty end,
      if ($embedded.metrics.scroll_to_layer_present_ms.count // 0) == 0 then
        "embedded scroll_to_layer_present metrics are empty"
      else empty end
    ] as $diagnostics
  | {
      iterations: $embedded.iterations,
      embedded_host_mode: $host_mode,
      events_per_burst: $embedded.events_per_burst,
      scroll_pixels_per_event: $embedded.scroll_pixels_per_event,
      scroll_interval_ms: $embedded.scroll_interval_ms,
      burst_pause_ms: $embedded.burst_pause_ms,
      scroll_phase_mode: $embedded.scroll_phase_mode,
      embedded_ghostty: $embedded_ghostty,
      native_ghostty: $native_ghostty,
      ghostty_version_match: {
        embedded: $embedded_ghostty.version,
        native: $native_ghostty.version,
        matched: ($version_matched == 1)
      },
      agtmux_term: $embedded,
      native_ghostty_bench: $native,
      diff: {
        tmux_visible_line_change_p50_delta_ms: $visible_line_p50_delta,
        tmux_visible_line_change_p95_delta_ms: $visible_line_p95_delta,
        tmux_visible_line_change_max_delta_ms: $visible_line_max_delta,
        empty_burst_count_delta: $empty_burst_count_delta
      },
      embedded_cadence: {
        scroll_to_render_request_ms: $embedded.metrics.scroll_to_render_request_ms,
        scroll_to_first_draw_ms: $embedded.metrics.scroll_to_first_draw_ms,
        scroll_to_layer_present_ms: $embedded.metrics.scroll_to_layer_present_ms,
        render_request_to_draw_ms: $embedded.metrics.render_request_to_draw_ms,
        draw_gap_p50_ms: $embedded.metrics.draw_gap_p50_ms,
        draw_gap_p95_ms: $embedded.metrics.draw_gap_p95_ms,
        draw_gap_max_ms: $embedded.metrics.draw_gap_max_ms,
        draw_count: $embedded.metrics.draw_count,
        scroll_presentation_draw_gap_p50_ms: $embedded.metrics.scroll_presentation_draw_gap_p50_ms,
        scroll_presentation_draw_gap_p95_ms: $embedded.metrics.scroll_presentation_draw_gap_p95_ms,
        scroll_presentation_draw_gap_max_ms: $embedded.metrics.scroll_presentation_draw_gap_max_ms,
        scroll_presentation_draw_count: $embedded.metrics.scroll_presentation_draw_count,
        layer_present_gap_p50_ms: $embedded.metrics.layer_present_gap_p50_ms,
        layer_present_gap_p95_ms: $embedded.metrics.layer_present_gap_p95_ms,
        layer_present_gap_max_ms: $embedded.metrics.layer_present_gap_max_ms,
        layer_present_count: $embedded.metrics.layer_present_count,
        layer_present_captured: $embedded.metrics.layer_present_captured
      },
      gate: {
        passed: (($failures | length) == 0),
        thresholds: {
          tmux_visible_line_change_p50_delta_max_ms: $visible_line_p50_delta_max,
          tmux_visible_line_change_p95_delta_max_ms: $visible_line_p95_delta_max,
          tmux_visible_line_change_max_delta_max_ms: $visible_line_max_delta_max,
          empty_burst_count_delta_max: $empty_burst_count_delta_max
        },
        failures: $failures,
        diagnostics: $diagnostics
      }
    }
  ')"

print -r -- "$result_json"

if [[ "$(jq -r '.gate.passed' <<<"$result_json")" != "true" ]]; then
  exit 1
fi
