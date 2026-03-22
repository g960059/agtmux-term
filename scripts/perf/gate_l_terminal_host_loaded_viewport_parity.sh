#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"

settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-30}"
first_changed_tolerance_ms="${AGTMUX_PERF_HOST_MODE_FIRST_CHANGED_TOLERANCE_MS:-25}"
max_step_rows_tolerance="${AGTMUX_PERF_HOST_MODE_MAX_STEP_ROWS_TOLERANCE:-0}"
changed_sample_tolerance="${AGTMUX_PERF_HOST_MODE_CHANGED_SAMPLE_TOLERANCE:-2}"
upward_total_rows_tolerance="${AGTMUX_PERF_HOST_MODE_UPWARD_TOTAL_ROWS_TOLERANCE:-2}"

while (( $# > 0 )); do
  case "$1" in
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-host-mode-loaded-viewport-parity.XXXXXX")"
cleanup() {
  local exit_status=$?
  if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L terminal-host loaded viewport parity temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

legacy_json_path="$tmpdir/legacy.json"
next_json_path="$tmpdir/next.json"

"$SCRIPT_DIR/gate_l_terminal_host_loaded_viewport_bench.sh" \
  --host-mode legacy \
  --timeout "$settle_timeout" >"$legacy_json_path"

"$SCRIPT_DIR/gate_l_terminal_host_loaded_viewport_bench.sh" \
  --host-mode next \
  --timeout "$settle_timeout" >"$next_json_path"

jq -n \
  --argjson first_changed_tolerance_ms "$first_changed_tolerance_ms" \
  --argjson max_step_rows_tolerance "$max_step_rows_tolerance" \
  --argjson changed_sample_tolerance "$changed_sample_tolerance" \
  --argjson upward_total_rows_tolerance "$upward_total_rows_tolerance" \
  --slurpfile legacy "$legacy_json_path" \
  --slurpfile next "$next_json_path" \
  '
  def summary($payload; $key): ($payload | getpath(["metrics", "summary", $key]));
  def comparison($legacy; $next): {
    first_changed_elapsed_delta_ms:
      ((summary($next; "first_changed_elapsed_ms") // 0) - (summary($legacy; "first_changed_elapsed_ms") // 0)),
    changed_sample_count_delta:
      ((summary($next; "changed_sample_count") // 0) - (summary($legacy; "changed_sample_count") // 0)),
    max_step_rows_delta:
      ((summary($next; "max_step_rows") // 0) - (summary($legacy; "max_step_rows") // 0)),
    upward_total_rows_delta:
      ((summary($next; "upward_total_rows") // 0) - (summary($legacy; "upward_total_rows") // 0))
  };
  ($legacy[0]) as $legacyPayload |
  ($next[0]) as $nextPayload |
  (comparison($legacyPayload; $nextPayload)) as $comparison |
  ((summary($legacyPayload; "changed_sample_count") // 0) > 0) as $legacyMoved |
  ((summary($nextPayload; "changed_sample_count") // 0) > 0) as $nextMoved |
  {
    thresholds: {
      first_changed_elapsed_tolerance_ms: $first_changed_tolerance_ms,
      max_step_rows_tolerance: $max_step_rows_tolerance,
      changed_sample_tolerance: $changed_sample_tolerance,
      upward_total_rows_tolerance: $upward_total_rows_tolerance
    },
    legacy: $legacyPayload,
    next: $nextPayload,
    valid: ($legacyMoved and $nextMoved),
    validity: {
      legacyMoved: $legacyMoved,
      nextMoved: $nextMoved
    },
    comparison: $comparison,
    passed:
      ($legacyMoved and $nextMoved and
       ($comparison.first_changed_elapsed_delta_ms // 0) <= $first_changed_tolerance_ms and
       ($comparison.max_step_rows_delta // 0) <= $max_step_rows_tolerance and
       ($comparison.changed_sample_count_delta // 0) >= (0 - $changed_sample_tolerance) and
       ($comparison.upward_total_rows_delta // 0) >= (0 - $upward_total_rows_tolerance))
  }'
