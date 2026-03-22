#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"

pane_target=""
history_lines="${AGTMUX_PERF_CAPTURE_HISTORY_LINES:-4000}"
fixture_path=""
keep_fixture=0

while (( $# > 0 )); do
  case "$1" in
    --pane-target)
      pane_target="$2"
      shift 2
      ;;
    --history-lines)
      history_lines="$2"
      shift 2
      ;;
    --fixture-file)
      fixture_path="$2"
      shift 2
      ;;
    --keep-fixture)
      keep_fixture=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

cleanup() {
  local exit_status=$?
  if (( keep_fixture != 1 )) && [[ -n "$fixture_path" && -f "$fixture_path" ]]; then
    rm -f "$fixture_path"
  elif [[ -n "$fixture_path" && -f "$fixture_path" ]]; then
    echo "Gate-L live curses-history fixture: $fixture_path" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

if [[ -z "$fixture_path" ]]; then
  capture_args=(--history-lines "$history_lines")
  if [[ -n "$pane_target" ]]; then
    capture_args=(--pane-target "$pane_target" "${capture_args[@]}")
  fi
  capture_args+=(--no-join-wrapped)
  fixture_json="$("$SCRIPT_DIR/gate_l_capture_live_pane_fixture.sh" "${capture_args[@]}")"
  fixture_path="$(jq -r '.output_path' <<<"$fixture_json")"
fi

if [[ -z "${AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS:-}" ]]; then
  export AGTMUX_PERF_UPSTEP_SAMPLE_TAIL_MS=1200
fi

if [[ -z "${AGTMUX_PERF_UPSTEP_SCROLL_TARGET_MODE:-}" ]]; then
  export AGTMUX_PERF_UPSTEP_SCROLL_TARGET_MODE=front-window
fi

AGTMUX_PERF_UPSTEP_FIXTURE_FILE="$fixture_path" \
AGTMUX_PERF_UPSTEP_FIXTURE_MODE=curses-history \
"$SCRIPT_DIR/gate_l_trackpad_upscroll_step_parity.sh" "$@"
