#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"

settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-30}"
iterations="${AGTMUX_PERF_HOST_MODE_PARITY_ITERATIONS:-1}"
first_changed_tolerance_ms="${AGTMUX_PERF_HOST_MODE_FIRST_CHANGED_TOLERANCE_MS:-25}"
max_step_rows_tolerance="${AGTMUX_PERF_HOST_MODE_MAX_STEP_ROWS_TOLERANCE:-0}"
changed_sample_tolerance="${AGTMUX_PERF_HOST_MODE_CHANGED_SAMPLE_TOLERANCE:-2}"
upward_total_rows_tolerance="${AGTMUX_PERF_HOST_MODE_UPWARD_TOTAL_ROWS_TOLERANCE:-2}"

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
    *)
      echo "Usage: $0 [--iterations COUNT] [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$iterations" =~ '^[0-9]+$' ]] || (( iterations < 1 )); then
  echo "Iterations must be a positive integer: $iterations" >&2
  exit 1
fi

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

typeset -a legacy_paths next_paths
for (( iteration = 1; iteration <= iterations; iteration++ )); do
  legacy_json_path="$tmpdir/legacy-$iteration.json"
  next_json_path="$tmpdir/next-$iteration.json"

  "$SCRIPT_DIR/gate_l_terminal_host_loaded_viewport_bench.sh" \
    --host-mode legacy \
    --timeout "$settle_timeout" >"$legacy_json_path"

  "$SCRIPT_DIR/gate_l_terminal_host_loaded_viewport_bench.sh" \
    --host-mode next \
    --timeout "$settle_timeout" >"$next_json_path"

  legacy_paths+=("$legacy_json_path")
  next_paths+=("$next_json_path")
done

legacy_runs_json_path="$tmpdir/legacy-runs.json"
next_runs_json_path="$tmpdir/next-runs.json"
jq -s '.' "${legacy_paths[@]}" >"$legacy_runs_json_path"
jq -s '.' "${next_paths[@]}" >"$next_runs_json_path"

jq -n \
  --argjson iterations "$iterations" \
  --argjson first_changed_tolerance_ms "$first_changed_tolerance_ms" \
  --argjson max_step_rows_tolerance "$max_step_rows_tolerance" \
  --argjson changed_sample_tolerance "$changed_sample_tolerance" \
  --argjson upward_total_rows_tolerance "$upward_total_rows_tolerance" \
  --slurpfile legacy_runs "$legacy_runs_json_path" \
  --slurpfile next_runs "$next_runs_json_path" \
  '
  def median:
    if length == 0 then null
    else
      sort as $sorted
      | (length) as $count
      | if ($count % 2) == 1
        then $sorted[($count / 2 | floor)]
        else (($sorted[($count / 2) - 1] + $sorted[$count / 2]) / 2)
        end
    end;
  def summary($payload; $key): ($payload | getpath(["metrics", "summary", $key]));
  def telemetry($payload; $path): ($payload | getpath($path));
  def diagnostics($payload): {
    scrollFirstInputElapsedMs:
      (telemetry($payload; ["scrollTelemetry", "scroll", "firstScrollInputElapsedMs"]) // null),
    scrollToFirstDrawP50Ms:
      (telemetry($payload; ["scrollTelemetry", "scroll", "scrollToFirstDraw", "p50Ms"]) // null),
    scrollToLayerPresentP50Ms:
      (telemetry($payload; ["scrollTelemetry", "scroll", "scrollToLayerPresent", "p50Ms"]) // null),
    layerPresentCount:
      (telemetry($payload; ["scrollTelemetry", "scroll", "layerPresentCount"]) // null),
    scrollPresentationDrawCount:
      (telemetry($payload; ["scrollTelemetry", "scroll", "scrollPresentationDrawCount"]) // null),
    islandRetryCount:
      (telemetry($payload; ["scrollTelemetry", "island", "retryCount"]) // null),
    islandApplyCommandCount:
      (telemetry($payload; ["scrollTelemetry", "island", "applyCommandCount"]) // null),
    appRenderCallbackCount:
      (telemetry($payload; ["scrollTelemetry", "app", "renderCallbackCount"]) // null),
    appScheduledDirectDrawPassCount:
      (telemetry($payload; ["scrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // null),
    appImmediateDirectDrawPassCount:
      (telemetry($payload; ["scrollTelemetry", "app", "immediateDirectDrawPassCount"]) // null),
    appDirtyDrawPassCount:
      (telemetry($payload; ["scrollTelemetry", "app", "dirtyDrawPassCount"]) // null),
    appDirtyDrawnSurfaceCount:
      (telemetry($payload; ["scrollTelemetry", "app", "dirtyDrawnSurfaceCount"]) // null),
    appGhosttyAppTickSampleCount:
      (telemetry($payload; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // null),
    appGhosttyAppTickP95Ms:
      (telemetry($payload; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // null),
    appDirtyDrawPassDurationSampleCount:
      (telemetry($payload; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // null),
    appDirtyDrawPassDurationP95Ms:
      (telemetry($payload; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // null),
    scrollRenderRequestCount:
      (telemetry($payload; ["scrollTelemetry", "scroll", "renderRequestCount"]) // null),
    scrollRefreshDrawRequestCount:
      (telemetry($payload; ["scrollTelemetry", "scroll", "refreshDrawRequestCount"]) // null),
    scrollImmediatePresentationDrawCount:
      (telemetry($payload; ["scrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // null),
    fixtureFirstKeyUpElapsedMs:
      (telemetry($payload; ["fixtureEventSummary", "firstKeyUpElapsedMs"]) // null),
    fixtureKeyUpCount:
      (telemetry($payload; ["fixtureEventSummary", "keyUpCount"]) // null),
    fixtureFinalTop:
      (telemetry($payload; ["fixtureEventSummary", "finalTop"]) // null)
  };
  def comparison($legacy; $next): {
    first_changed_elapsed_delta_ms:
      ((summary($next; "first_changed_elapsed_ms") // 0) - (summary($legacy; "first_changed_elapsed_ms") // 0)),
    changed_sample_count_delta:
      ((summary($next; "changed_sample_count") // 0) - (summary($legacy; "changed_sample_count") // 0)),
    max_step_rows_delta:
      ((summary($next; "max_step_rows") // 0) - (summary($legacy; "max_step_rows") // 0)),
    upward_total_rows_delta:
      ((summary($next; "upward_total_rows") // 0) - (summary($legacy; "upward_total_rows") // 0)),
    scrollFirstInputElapsedDeltaMs:
      ((telemetry($next; ["scrollTelemetry", "scroll", "firstScrollInputElapsedMs"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "firstScrollInputElapsedMs"]) // 0)),
    scrollToFirstDrawP50DeltaMs:
      ((telemetry($next; ["scrollTelemetry", "scroll", "scrollToFirstDraw", "p50Ms"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "scrollToFirstDraw", "p50Ms"]) // 0)),
    scrollToLayerPresentP50DeltaMs:
      ((telemetry($next; ["scrollTelemetry", "scroll", "scrollToLayerPresent", "p50Ms"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "scrollToLayerPresent", "p50Ms"]) // 0)),
    islandRetryCountDelta:
      ((telemetry($next; ["scrollTelemetry", "island", "retryCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "island", "retryCount"]) // 0)),
    islandApplyCommandCountDelta:
      ((telemetry($next; ["scrollTelemetry", "island", "applyCommandCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "island", "applyCommandCount"]) // 0)),
    appRenderCallbackCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "renderCallbackCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "renderCallbackCount"]) // 0)),
    appScheduledDirectDrawPassCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // 0)),
    appImmediateDirectDrawPassCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "immediateDirectDrawPassCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "immediateDirectDrawPassCount"]) // 0)),
    appDirtyDrawPassCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "dirtyDrawPassCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "dirtyDrawPassCount"]) // 0)),
    appDirtyDrawnSurfaceCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "dirtyDrawnSurfaceCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "dirtyDrawnSurfaceCount"]) // 0)),
    appGhosttyAppTickSampleCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // 0)),
    appGhosttyAppTickP95DeltaMs:
      ((telemetry($next; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // 0)),
    appDirtyDrawPassDurationSampleCountDelta:
      ((telemetry($next; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // 0)),
    appDirtyDrawPassDurationP95DeltaMs:
      ((telemetry($next; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // 0)),
    scrollRenderRequestCountDelta:
      ((telemetry($next; ["scrollTelemetry", "scroll", "renderRequestCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "renderRequestCount"]) // 0)),
    scrollRefreshDrawRequestCountDelta:
      ((telemetry($next; ["scrollTelemetry", "scroll", "refreshDrawRequestCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "refreshDrawRequestCount"]) // 0)),
    scrollImmediatePresentationDrawCountDelta:
      ((telemetry($next; ["scrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // 0) -
       (telemetry($legacy; ["scrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // 0)),
    fixtureFirstKeyUpElapsedDeltaMs:
      ((telemetry($next; ["fixtureEventSummary", "firstKeyUpElapsedMs"]) // 0) -
       (telemetry($legacy; ["fixtureEventSummary", "firstKeyUpElapsedMs"]) // 0))
  };
  ($legacy_runs[0]) as $legacyPayloads |
  ($next_runs[0]) as $nextPayloads |
  [range(0; ($legacyPayloads | length)) as $index | {
    iteration: ($index + 1),
    legacy: $legacyPayloads[$index],
    next: $nextPayloads[$index],
    comparison: comparison($legacyPayloads[$index]; $nextPayloads[$index]),
    valid:
      ((summary($legacyPayloads[$index]; "changed_sample_count") // 0) > 0 and
       (summary($nextPayloads[$index]; "changed_sample_count") // 0) > 0)
  }] as $runs |
  {
    first_changed_elapsed_delta_ms:
      ($runs | map(.comparison.first_changed_elapsed_delta_ms) | median),
    changed_sample_count_delta:
      ($runs | map(.comparison.changed_sample_count_delta) | median),
    max_step_rows_delta:
      ($runs | map(.comparison.max_step_rows_delta) | median),
    upward_total_rows_delta:
      ($runs | map(.comparison.upward_total_rows_delta) | median),
    scrollFirstInputElapsedDeltaMs:
      ($runs | map(.comparison.scrollFirstInputElapsedDeltaMs) | median),
    scrollToFirstDrawP50DeltaMs:
      ($runs | map(.comparison.scrollToFirstDrawP50DeltaMs) | median),
    scrollToLayerPresentP50DeltaMs:
      ($runs | map(.comparison.scrollToLayerPresentP50DeltaMs) | median),
    islandRetryCountDelta:
      ($runs | map(.comparison.islandRetryCountDelta) | median),
    islandApplyCommandCountDelta:
      ($runs | map(.comparison.islandApplyCommandCountDelta) | median),
    appRenderCallbackCountDelta:
      ($runs | map(.comparison.appRenderCallbackCountDelta) | median),
    appScheduledDirectDrawPassCountDelta:
      ($runs | map(.comparison.appScheduledDirectDrawPassCountDelta) | median),
    appImmediateDirectDrawPassCountDelta:
      ($runs | map(.comparison.appImmediateDirectDrawPassCountDelta) | median),
    appDirtyDrawPassCountDelta:
      ($runs | map(.comparison.appDirtyDrawPassCountDelta) | median),
    appDirtyDrawnSurfaceCountDelta:
      ($runs | map(.comparison.appDirtyDrawnSurfaceCountDelta) | median),
    appGhosttyAppTickSampleCountDelta:
      ($runs | map(.comparison.appGhosttyAppTickSampleCountDelta) | median),
    appGhosttyAppTickP95DeltaMs:
      ($runs | map(.comparison.appGhosttyAppTickP95DeltaMs) | median),
    appDirtyDrawPassDurationSampleCountDelta:
      ($runs | map(.comparison.appDirtyDrawPassDurationSampleCountDelta) | median),
    appDirtyDrawPassDurationP95DeltaMs:
      ($runs | map(.comparison.appDirtyDrawPassDurationP95DeltaMs) | median),
    scrollRenderRequestCountDelta:
      ($runs | map(.comparison.scrollRenderRequestCountDelta) | median),
    scrollRefreshDrawRequestCountDelta:
      ($runs | map(.comparison.scrollRefreshDrawRequestCountDelta) | median),
    scrollImmediatePresentationDrawCountDelta:
      ($runs | map(.comparison.scrollImmediatePresentationDrawCountDelta) | median),
    fixtureFirstKeyUpElapsedDeltaMs:
      ($runs | map(.comparison.fixtureFirstKeyUpElapsedDeltaMs) | median)
  } as $comparison |
  {
    legacy: {
      runs: $legacyPayloads,
      medianDiagnostics: {
        scrollFirstInputElapsedMs:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "firstScrollInputElapsedMs"]) // empty) | median),
        scrollToFirstDrawP50Ms:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "scrollToFirstDraw", "p50Ms"]) // empty) | median),
        scrollToLayerPresentP50Ms:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "scrollToLayerPresent", "p50Ms"]) // empty) | median),
        appRenderCallbackCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "renderCallbackCount"]) // empty) | median),
        appScheduledDirectDrawPassCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // empty) | median),
        appImmediateDirectDrawPassCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "immediateDirectDrawPassCount"]) // empty) | median),
        appDirtyDrawPassCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassCount"]) // empty) | median),
        appGhosttyAppTickSampleCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // empty) | median),
        appGhosttyAppTickP95Ms:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // empty) | median),
        appDirtyDrawPassDurationSampleCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // empty) | median),
        appDirtyDrawPassDurationP95Ms:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // empty) | median),
        scrollRenderRequestCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "renderRequestCount"]) // empty) | median),
        scrollRefreshDrawRequestCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "refreshDrawRequestCount"]) // empty) | median),
        scrollImmediatePresentationDrawCount:
          ($legacyPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // empty) | median),
        fixtureFirstKeyUpElapsedMs:
          ($legacyPayloads | map(telemetry(.; ["fixtureEventSummary", "firstKeyUpElapsedMs"]) // empty) | median)
      }
    },
    next: {
      runs: $nextPayloads,
      medianDiagnostics: {
        scrollFirstInputElapsedMs:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "firstScrollInputElapsedMs"]) // empty) | median),
        scrollToFirstDrawP50Ms:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "scrollToFirstDraw", "p50Ms"]) // empty) | median),
        scrollToLayerPresentP50Ms:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "scrollToLayerPresent", "p50Ms"]) // empty) | median),
        appRenderCallbackCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "renderCallbackCount"]) // empty) | median),
        appScheduledDirectDrawPassCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // empty) | median),
        appImmediateDirectDrawPassCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "immediateDirectDrawPassCount"]) // empty) | median),
        appDirtyDrawPassCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassCount"]) // empty) | median),
        appGhosttyAppTickSampleCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // empty) | median),
        appGhosttyAppTickP95Ms:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // empty) | median),
        appDirtyDrawPassDurationSampleCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // empty) | median),
        appDirtyDrawPassDurationP95Ms:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // empty) | median),
        scrollRenderRequestCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "renderRequestCount"]) // empty) | median),
        scrollRefreshDrawRequestCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "refreshDrawRequestCount"]) // empty) | median),
        scrollImmediatePresentationDrawCount:
          ($nextPayloads | map(telemetry(.; ["scrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // empty) | median),
        fixtureFirstKeyUpElapsedMs:
          ($nextPayloads | map(telemetry(.; ["fixtureEventSummary", "firstKeyUpElapsedMs"]) // empty) | median)
      }
    }
  } as $payloads |
  (($runs | all(.valid))) as $allValid |
  {
    iterations: $iterations,
    thresholds: {
      first_changed_elapsed_tolerance_ms: $first_changed_tolerance_ms,
      max_step_rows_tolerance: $max_step_rows_tolerance,
      changed_sample_tolerance: $changed_sample_tolerance,
      upward_total_rows_tolerance: $upward_total_rows_tolerance
    },
    runs: $runs,
    legacy: $payloads.legacy,
    next: $payloads.next,
    valid: $allValid,
    validity: {
      allRunsMoved: $allValid,
      runValidity: ($runs | map({iteration, valid}))
    },
    comparison: $comparison,
    passed:
      ($allValid and
       ($comparison.first_changed_elapsed_delta_ms // 0) <= $first_changed_tolerance_ms and
       ($comparison.max_step_rows_delta // 0) <= $max_step_rows_tolerance and
       ($comparison.changed_sample_count_delta // 0) >= (0 - $changed_sample_tolerance) and
       ($comparison.upward_total_rows_delta // 0) >= (0 - $upward_total_rows_tolerance))
  }'
