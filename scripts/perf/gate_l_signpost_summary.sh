#!/bin/zsh
set -euo pipefail

start_time=""
end_time=""
pid=""
subsystem="local.agtmux.term"
allow_empty=0

while (( $# > 0 )); do
  case "$1" in
    --start)
      start_time="$2"
      shift 2
      ;;
    --end)
      end_time="$2"
      shift 2
      ;;
    --pid)
      pid="$2"
      shift 2
      ;;
    --subsystem)
      subsystem="$2"
      shift 2
      ;;
    --allow-empty)
      allow_empty=1
      shift
      ;;
    *)
      echo "Usage: $0 --start 'YYYY-MM-DD HH:MM:SS+/-ZZZZ' --end '...' [--pid PID] [--subsystem SUBSYSTEM] [--allow-empty]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$start_time" || -z "$end_time" ]]; then
  echo "--start and --end are required" >&2
  exit 1
fi

predicate="subsystem == \"$subsystem\""

raw_file="$(mktemp "${TMPDIR:-/tmp}/agtmux-gate-l-signposts.raw.XXXXXX")"
filtered_file="$(mktemp "${TMPDIR:-/tmp}/agtmux-gate-l-signposts.filtered.XXXXXX")"
trap 'rm -f "$raw_file" "$filtered_file"' EXIT INT TERM

command log show \
  --start "$start_time" \
  --end "$end_time" \
  --style ndjson \
  --signpost \
  --info \
  --debug \
  --predicate "$predicate" \
  >"$raw_file"

if [[ -n "$pid" ]]; then
  jq -c --argjson expected_pid "$pid" 'select(.processID == $expected_pid)' "$raw_file" >"$filtered_file"
else
  cp "$raw_file" "$filtered_file"
fi

if [[ ! -s "$filtered_file" ]]; then
  if (( allow_empty == 0 )); then
    if [[ -n "$pid" ]]; then
      echo "No signpost events matched predicate: $predicate and processID=$pid" >&2
    else
      echo "No signpost events matched predicate: $predicate" >&2
    fi
    exit 1
  fi
  jq -n --arg start "$start_time" --arg end "$end_time" --arg subsystem "$subsystem" \
    '{start:$start, end:$end, subsystem:$subsystem, intervals:[], categories:[]}'
  exit 0
fi

jq -s \
  --arg start "$start_time" \
  --arg end "$end_time" \
  --arg subsystem "$subsystem" '
  def round3:
    ((. * 1000.0) | round) / 1000.0;
  def percentile($p):
    if length == 0 then null
    else
      sort as $sorted
      | ($sorted | length) as $n
      | (((($p / 100.0) * $n) | ceil) - 1) as $index
      | $sorted[
          if $index < 0 then
            0
          elif $index >= $n then
            ($n - 1)
          else
            $index
          end
        ]
    end;

  map(select(.eventType == "signpostEvent"))
  | reduce .[] as $event (
      {begins: {}, samples: []};
      (($event.processID | tostring) + ":" +
       ($event.signpostID | tostring) + ":" +
       $event.category + ":" +
       $event.signpostName) as $key
      | if $event.signpostType == "begin" then
          .begins[$key] = $event.machTimestamp
        elif $event.signpostType == "end" and (.begins[$key] != null) then
          .samples += [{
            category: $event.category,
            name: $event.signpostName,
            duration_ms: ((($event.machTimestamp - .begins[$key]) / 1000000.0) | round3)
          }]
          | del(.begins[$key])
        else
          .
        end
    )
  | .samples as $samples
  | {
      start: $start,
      end: $end,
      subsystem: $subsystem,
      intervals: (
        $samples
        | sort_by(.category, .name)
        | group_by(.category + "|" + .name)
        | map({
            category: .[0].category,
            name: .[0].name,
            count: length,
            total_ms: ((map(.duration_ms) | add) | round3),
            avg_ms: (((map(.duration_ms) | add) / length) | round3),
            p50_ms: ((map(.duration_ms) | percentile(50)) | round3),
            p95_ms: ((map(.duration_ms) | percentile(95)) | round3),
            max_ms: ((map(.duration_ms) | max) | round3)
          })
      ),
      categories: (
        $samples
        | group_by(.category)
        | map({
            category: .[0].category,
            count: length,
            total_ms: ((map(.duration_ms) | add) | round3),
            avg_ms: (((map(.duration_ms) | add) / length) | round3),
            p50_ms: ((map(.duration_ms) | percentile(50)) | round3),
            p95_ms: ((map(.duration_ms) | percentile(95)) | round3),
            max_ms: ((map(.duration_ms) | max) | round3)
          })
        | sort_by(-.total_ms)
      )
    }
  ' "$filtered_file"
