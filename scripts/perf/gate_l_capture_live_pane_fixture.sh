#!/bin/zsh
set -euo pipefail

pane_target="${AGTMUX_PERF_CAPTURE_PANE_TARGET:-}"
history_lines="${AGTMUX_PERF_CAPTURE_HISTORY_LINES:-2000}"
output_path="${AGTMUX_PERF_CAPTURE_OUTPUT_PATH:-}"
join_wrapped=1
preserve_ansi=0

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
    --output)
      output_path="$2"
      shift 2
      ;;
    --no-join-wrapped)
      join_wrapped=0
      shift
      ;;
    --preserve-ansi)
      preserve_ansi=1
      shift
      ;;
    *)
      echo "Usage: $0 [--pane-target %id] [--history-lines N] [--output /path/file] [--no-join-wrapped] [--preserve-ansi]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$pane_target" ]]; then
  pane_target="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

if [[ -z "$pane_target" ]]; then
  echo "Failed to resolve pane target; pass --pane-target explicitly" >&2
  exit 1
fi

if [[ -z "$output_path" ]]; then
  output_path="$(mktemp "${TMPDIR:-/tmp}/agtmux-live-pane-fixture.XXXXXX")"
fi

capture_args=(-p -S "-$history_lines" -t "$pane_target")
if (( join_wrapped == 1 )); then
  capture_args=(-J "${capture_args[@]}")
fi
if (( preserve_ansi == 1 )); then
  capture_args=(-e "${capture_args[@]}")
fi

tmux capture-pane "${capture_args[@]}" >"$output_path"

jq -n \
  --arg pane_target "$pane_target" \
  --arg output_path "$output_path" \
  --argjson history_lines "$history_lines" \
  --argjson join_wrapped "$join_wrapped" \
  --argjson preserve_ansi "$preserve_ansi" \
  --arg first_row "$(sed -n '1p' "$output_path")" \
  --argjson line_count "$(wc -l <"$output_path" | tr -d ' ')" \
  --argjson byte_count "$(wc -c <"$output_path" | tr -d ' ')" \
  '{
    pane_target: $pane_target,
    output_path: $output_path,
    history_lines: $history_lines,
    join_wrapped: ($join_wrapped == 1),
    preserve_ansi: ($preserve_ansi == 1),
    line_count: $line_count,
    byte_count: $byte_count,
    first_row: $first_row
  }'
