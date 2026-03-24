#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

bursts="${AGTMUX_PERF_UPSTEP_BURSTS:-12}"
settle_timeout=15
native_app_path=""
allow_existing=0
keep_running=0
host_mode="${AGTMUX_PERF_TERMINAL_HOST_MODE:-}"
allow_version_mismatch=0

mean_lines_p50_delta_max="${AGTMUX_PERF_UPSTEP_GATE_MEAN_LINES_P50_DELTA_MAX:-0.50}"
step_rows_p95_delta_max="${AGTMUX_PERF_UPSTEP_GATE_STEP_ROWS_P95_DELTA_MAX:-1.0}"
max_step_rows_delta_max="${AGTMUX_PERF_UPSTEP_GATE_MAX_STEP_ROWS_DELTA_MAX:-2.0}"
coarse_step_ratio_ge_2_delta_max="${AGTMUX_PERF_UPSTEP_GATE_COARSE_STEP_RATIO_GE_2_DELTA_MAX:-0.20}"
coarse_step_ratio_ge_3_delta_max="${AGTMUX_PERF_UPSTEP_GATE_COARSE_STEP_RATIO_GE_3_DELTA_MAX:-0.10}"
first_changed_elapsed_p50_delta_max="${AGTMUX_PERF_UPSTEP_GATE_FIRST_CHANGED_ELAPSED_P50_DELTA_MAX:-80.0}"
first_changed_elapsed_p95_delta_max="${AGTMUX_PERF_UPSTEP_GATE_FIRST_CHANGED_ELAPSED_P95_DELTA_MAX:-120.0}"

while (( $# > 0 )); do
  case "$1" in
    --bursts)
      bursts="$2"
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
      echo "Usage: $0 [--bursts COUNT] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--host-mode legacy|next] [--allow-existing] [--allow-version-mismatch] [--keep-running]" >&2
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

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-upstep-parity.XXXXXX")"
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
    echo "Gate-L upscroll-step parity temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

AGTMUX_PERF_TERMINAL_HOST_MODE="$host_mode" \
"$SCRIPT_DIR/gate_l_trackpad_upscroll_step_bench.sh" \
  --bursts "$bursts" \
  --timeout "$settle_timeout" >"$embedded_json_path"
normalize_bench_json "$embedded_json_path"

native_args=(
  --bursts "$bursts"
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

"$SCRIPT_DIR/gate_l_native_ghostty_trackpad_upscroll_step_bench.sh" \
  "${native_args[@]}" >"$native_json_path"
normalize_bench_json "$native_json_path"

result_json="$(jq -n \
  --slurpfile embedded "$embedded_json_path" \
  --slurpfile native "$native_json_path" \
  --arg host_mode "$host_mode" \
  --argjson embedded_ghostty "$embedded_ghostty_json" \
  --argjson native_ghostty "$native_ghostty_json" \
  --argjson version_matched "$version_matched" \
  --argjson mean_lines_p50_delta_max "$mean_lines_p50_delta_max" \
  --argjson step_rows_p95_delta_max "$step_rows_p95_delta_max" \
  --argjson max_step_rows_delta_max "$max_step_rows_delta_max" \
  --argjson coarse_step_ratio_ge_2_delta_max "$coarse_step_ratio_ge_2_delta_max" \
  --argjson coarse_step_ratio_ge_3_delta_max "$coarse_step_ratio_ge_3_delta_max" \
  --argjson first_changed_elapsed_p50_delta_max "$first_changed_elapsed_p50_delta_max" \
  --argjson first_changed_elapsed_p95_delta_max "$first_changed_elapsed_p95_delta_max" '
  ($embedded[0]) as $embedded
  | ($native[0]) as $native
  | ($embedded.metrics.mean_lines_per_step.p50_lines - $native.metrics.mean_lines_per_step.p50_lines) as $mean_lines_p50_delta
  | ($embedded.metrics.step_rows.p95_rows - $native.metrics.step_rows.p95_rows) as $step_rows_p95_delta
  | ($embedded.metrics.step_rows.max_rows - $native.metrics.step_rows.max_rows) as $max_step_rows_delta
  | ($embedded.metrics.coarse_step_ratio_ge_2 - $native.metrics.coarse_step_ratio_ge_2) as $coarse_step_ratio_ge_2_delta
  | ($embedded.metrics.coarse_step_ratio_ge_3 - $native.metrics.coarse_step_ratio_ge_3) as $coarse_step_ratio_ge_3_delta
  | (
      if ($embedded.metrics.first_changed_elapsed_ms.p50_ms != null and $native.metrics.first_changed_elapsed_ms.p50_ms != null) then
        ($embedded.metrics.first_changed_elapsed_ms.p50_ms - $native.metrics.first_changed_elapsed_ms.p50_ms)
      else
        null
      end
    ) as $first_changed_elapsed_p50_delta
  | (
      if ($embedded.metrics.first_changed_elapsed_ms.p95_ms != null and $native.metrics.first_changed_elapsed_ms.p95_ms != null) then
        ($embedded.metrics.first_changed_elapsed_ms.p95_ms - $native.metrics.first_changed_elapsed_ms.p95_ms)
      else
        null
      end
    ) as $first_changed_elapsed_p95_delta
  | [
      if $mean_lines_p50_delta > $mean_lines_p50_delta_max then
        "embedded mean_lines_per_step p50 exceeds native by \($mean_lines_p50_delta | tostring) lines"
      else empty end,
      if $step_rows_p95_delta > $step_rows_p95_delta_max then
        "embedded step_rows p95 exceeds native by \($step_rows_p95_delta | tostring) rows"
      else empty end,
      if $max_step_rows_delta > $max_step_rows_delta_max then
        "embedded max_step_rows exceeds native by \($max_step_rows_delta | tostring) rows"
      else empty end,
      if $coarse_step_ratio_ge_2_delta > $coarse_step_ratio_ge_2_delta_max then
        "embedded coarse_step_ratio_ge_2 exceeds native by \($coarse_step_ratio_ge_2_delta | tostring)"
      else empty end,
      if $coarse_step_ratio_ge_3_delta > $coarse_step_ratio_ge_3_delta_max then
        "embedded coarse_step_ratio_ge_3 exceeds native by \($coarse_step_ratio_ge_3_delta | tostring)"
      else empty end,
      if $first_changed_elapsed_p50_delta != null and $first_changed_elapsed_p50_delta > $first_changed_elapsed_p50_delta_max then
        "embedded first_changed_elapsed p50 exceeds native by \($first_changed_elapsed_p50_delta | tostring) ms"
      else empty end,
      if $first_changed_elapsed_p95_delta != null and $first_changed_elapsed_p95_delta > $first_changed_elapsed_p95_delta_max then
        "embedded first_changed_elapsed p95 exceeds native by \($first_changed_elapsed_p95_delta | tostring) ms"
      else empty end
    ] as $failures
  | {
      bursts: $embedded.bursts,
      embedded_host_mode: $host_mode,
      sample_interval_ms: $embedded.sample_interval_ms,
      sample_tail_ms: $embedded.sample_tail_ms,
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
        mean_lines_per_step_p50_delta: $mean_lines_p50_delta,
        step_rows_p95_delta: $step_rows_p95_delta,
        max_step_rows_delta: $max_step_rows_delta,
        coarse_step_ratio_ge_2_delta: $coarse_step_ratio_ge_2_delta,
        coarse_step_ratio_ge_3_delta: $coarse_step_ratio_ge_3_delta,
        first_changed_elapsed_p50_delta_ms: $first_changed_elapsed_p50_delta,
        first_changed_elapsed_p95_delta_ms: $first_changed_elapsed_p95_delta
      },
      gate: {
        passed: (($failures | length) == 0),
        thresholds: {
          mean_lines_per_step_p50_delta_max: $mean_lines_p50_delta_max,
          step_rows_p95_delta_max: $step_rows_p95_delta_max,
          max_step_rows_delta_max: $max_step_rows_delta_max,
          coarse_step_ratio_ge_2_delta_max: $coarse_step_ratio_ge_2_delta_max,
          coarse_step_ratio_ge_3_delta_max: $coarse_step_ratio_ge_3_delta_max,
          first_changed_elapsed_p50_delta_max: $first_changed_elapsed_p50_delta_max,
          first_changed_elapsed_p95_delta_max: $first_changed_elapsed_p95_delta_max
        },
        failures: $failures
      }
    }
  ')"

print -r -- "$result_json"

if [[ "$(jq -r '.gate.passed' <<<"$result_json")" != "true" ]]; then
  exit 1
fi
