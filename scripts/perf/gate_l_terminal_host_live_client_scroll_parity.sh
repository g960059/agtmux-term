#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

session_name="${AGTMUX_PERF_LIVE_SESSION_NAME:-vm agtmux-term}"
pane_id="${AGTMUX_PERF_LIVE_PANE_ID:-}"
settle_timeout="${AGTMUX_PERF_LIVE_TIMEOUT:-20}"
first_changed_tolerance_ms="${AGTMUX_PERF_HOST_MODE_FIRST_CHANGED_TOLERANCE_MS:-25}"
max_step_rows_tolerance="${AGTMUX_PERF_HOST_MODE_MAX_STEP_ROWS_TOLERANCE:-0}"
coarse_step_ge3_tolerance="${AGTMUX_PERF_HOST_MODE_COARSE_STEP_GE3_TOLERANCE:-0}"

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
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--session-name NAME] [--pane-id %id] [--timeout SECONDS]" >&2
      exit 1
      ;;
  esac
done

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-host-mode-live-client-scroll-parity.XXXXXX")"
cleanup() {
  local exit_status=$?
  if [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$tmpdir"
  else
    echo "Gate-L terminal-host live client-scroll parity temp dir: $tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

legacy_json_path="$tmpdir/legacy.json"
next_json_path="$tmpdir/next.json"

"$SCRIPT_DIR/gate_l_terminal_host_live_client_scroll_bench.sh" \
  --host-mode legacy \
  --session-name "$session_name" \
  --pane-id "$pane_id" \
  --timeout "$settle_timeout" >"$legacy_json_path"

"$SCRIPT_DIR/gate_l_terminal_host_live_client_scroll_bench.sh" \
  --host-mode next \
  --session-name "$session_name" \
  --pane-id "$pane_id" \
  --timeout "$settle_timeout" >"$next_json_path"

jq -n \
  --arg session_name "$session_name" \
  --arg pane_id "$pane_id" \
  --argjson first_changed_tolerance_ms "$first_changed_tolerance_ms" \
  --argjson max_step_rows_tolerance "$max_step_rows_tolerance" \
  --argjson coarse_step_ge3_tolerance "$coarse_step_ge3_tolerance" \
  --slurpfile legacy "$legacy_json_path" \
  --slurpfile next "$next_json_path" \
  '
  def metric($payload; $path): ($payload | getpath($path));
  def summary($payload; $key): metric($payload; ["bench", "metrics", "summary", $key]);
  def wheelMoved($payload): ((summary($payload; "changed_sample_count") // 0) > 0);
  def sameResolvedPane($legacy; $next):
    (($legacy.resolvedPane.sessionName // null) == ($next.resolvedPane.sessionName // null) and
     ($legacy.resolvedPane.windowID // null) == ($next.resolvedPane.windowID // null) and
     ($legacy.resolvedPane.paneID // null) == ($next.resolvedPane.paneID // null));
  def comparison($legacy; $next): {
    first_changed_elapsed_delta_ms:
      ((summary($next; "first_changed_elapsed_ms") // 0) - (summary($legacy; "first_changed_elapsed_ms") // 0)),
    changed_sample_count_delta:
      ((summary($next; "changed_sample_count") // 0) - (summary($legacy; "changed_sample_count") // 0)),
    max_step_rows_delta:
      ((summary($next; "max_step_rows") // 0) - (summary($legacy; "max_step_rows") // 0)),
    coarse_step_count_ge_3_delta:
      ((summary($next; "coarse_step_count_ge_3") // 0) - (summary($legacy; "coarse_step_count_ge_3") // 0)),
    net_scroll_delta_delta:
      ((summary($next; "net_scroll_delta") // 0) - (summary($legacy; "net_scroll_delta") // 0)),
    appRenderCallbackCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "renderCallbackCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "renderCallbackCount"]) // 0)),
    appScheduledDirectDrawPassCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "scheduledDirectDrawPassCount"]) // 0)),
    appImmediateDirectDrawPassCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "immediateDirectDrawPassCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "immediateDirectDrawPassCount"]) // 0)),
    appDirtyDrawPassCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "dirtyDrawPassCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "dirtyDrawPassCount"]) // 0)),
    appGhosttyAppTickSampleCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "ghosttyAppTickDuration", "count"]) // 0)),
    appGhosttyAppTickP95DeltaMs:
      ((metric($next; ["postScrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "ghosttyAppTickDuration", "p95Ms"]) // 0)),
    appDirtyDrawPassDurationSampleCountDelta:
      ((metric($next; ["postScrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "dirtyDrawPassDuration", "count"]) // 0)),
    appDirtyDrawPassDurationP95DeltaMs:
      ((metric($next; ["postScrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "app", "dirtyDrawPassDuration", "p95Ms"]) // 0)),
    scrollRenderRequestCountDelta:
      ((metric($next; ["postScrollTelemetry", "scroll", "renderRequestCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "scroll", "renderRequestCount"]) // 0)),
    scrollRefreshDrawRequestCountDelta:
      ((metric($next; ["postScrollTelemetry", "scroll", "refreshDrawRequestCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "scroll", "refreshDrawRequestCount"]) // 0)),
    scrollImmediatePresentationDrawCountDelta:
      ((metric($next; ["postScrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // 0) -
       (metric($legacy; ["postScrollTelemetry", "scroll", "immediatePresentationDrawCount"]) // 0))
  };
  ($legacy[0]) as $legacyPayload |
  ($next[0]) as $nextPayload |
  (comparison($legacyPayload; $nextPayload)) as $comparison |
  (wheelMoved($legacyPayload)) as $legacyWheelMoved |
  (wheelMoved($nextPayload)) as $nextWheelMoved |
  (sameResolvedPane($legacyPayload; $nextPayload)) as $sameResolvedPane |
  (($legacyWheelMoved and $nextWheelMoved and $sameResolvedPane)) as $valid |
  {
    sessionName: $session_name,
    paneID: $pane_id,
    thresholds: {
      first_changed_elapsed_tolerance_ms: $first_changed_tolerance_ms,
      max_step_rows_tolerance: $max_step_rows_tolerance,
      coarse_step_count_ge_3_tolerance: $coarse_step_ge3_tolerance
    },
    legacy: $legacyPayload,
    next: $nextPayload,
    valid: $valid,
    validity: {
      sameResolvedPane: $sameResolvedPane,
      legacyWheelMoved: $legacyWheelMoved,
      nextWheelMoved: $nextWheelMoved
    },
    comparison: $comparison,
    passed:
      ($valid and
       ($comparison.first_changed_elapsed_delta_ms // 0) <= $first_changed_tolerance_ms and
       ($comparison.max_step_rows_delta // 0) <= $max_step_rows_tolerance and
       ($comparison.coarse_step_count_ge_3_delta // 0) <= $coarse_step_ge3_tolerance)
  }'
