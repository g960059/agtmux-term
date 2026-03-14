#!/bin/zsh
set -euo pipefail

pid=""
duration=30
interval=1

while (( $# > 0 )); do
  case "$1" in
    --pid)
      pid="$2"
      shift 2
      ;;
    --duration)
      duration="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 --pid PID [--duration SECONDS] [--interval SECONDS]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$pid" ]]; then
  echo "--pid is required" >&2
  exit 1
fi

if ! ps -p "$pid" -o pid= >/dev/null 2>&1; then
  echo "Process $pid is not running" >&2
  exit 1
fi

sample_count="$(awk -v duration="$duration" -v interval="$interval" '
  BEGIN {
    if (duration <= 0 || interval <= 0) {
      exit 2
    }
    samples = int(duration / interval)
    if ((samples * interval) < duration) {
      samples += 1
    }
    if (samples < 1) {
      samples = 1
    }
    print samples
  }
')"

if [[ -z "$sample_count" ]]; then
  echo "Could not derive sample count from duration=$duration interval=$interval" >&2
  exit 1
fi

top_samples=$((sample_count + 1))
top_file="$(mktemp "${TMPDIR:-/tmp}/agtmux-gate-l-idle-top.XXXXXX.txt")"
sample_file="$(mktemp "${TMPDIR:-/tmp}/agtmux-gate-l-idle-samples.XXXXXX.txt")"
trap 'rm -f "$top_file" "$sample_file"' EXIT INT TERM

top -l "$top_samples" -pid "$pid" -n 1 -stats pid,cpu,mem -s "$interval" >"$top_file"

awk '
  BEGIN {
    sample = 0
  }
  /^Processes:/ {
    sample += 1
    next
  }
  sample > 1 && /^[[:space:]]*[0-9]+[[:space:]]/ {
    print $1 "\t" $2 "\t" $3
  }
' "$top_file" >"$sample_file"

actual_samples="$(awk 'END { print NR }' "$sample_file")"
if [[ "$actual_samples" != "$sample_count" ]]; then
  echo "Expected $sample_count valid top samples for pid $pid, got $actual_samples" >&2
  exit 1
fi

sample_json="$(jq -Rsc '
  split("\n")[:-1]
  | map(select(length > 0) | split("\t"))
  | map(
      if length != 3 then
        error("invalid top sample row")
      else
        {
          pid: (.[0] | tonumber),
          cpu_pct: (.[1] | tonumber),
          mem_raw: .[2]
        }
      end
    )
' <"$sample_file")"

jq -n \
  --argjson samples "$sample_json" \
  --argjson duration "$duration" \
  --argjson interval "$interval" \
  --argjson pid "$pid" '
  def round3:
    ((. * 1000.0) | round) / 1000.0;
  def mem_to_mib:
    capture("^(?<value>[0-9]+(?:\\.[0-9]+)?)(?<unit>[BKMGTPE])$") as $m
    | ($m.value | tonumber) as $value
    | if $m.unit == "B" then
        $value / (1024.0 * 1024.0)
      elif $m.unit == "K" then
        $value / 1024.0
      elif $m.unit == "M" then
        $value
      elif $m.unit == "G" then
        $value * 1024.0
      elif $m.unit == "T" then
        $value * 1024.0 * 1024.0
      elif $m.unit == "P" then
        $value * 1024.0 * 1024.0 * 1024.0
      elif $m.unit == "E" then
        $value * 1024.0 * 1024.0 * 1024.0 * 1024.0
      else
        error("unsupported memory unit: \($m.unit)")
      end;

  {
    pid: $pid,
    duration_s: $duration,
    interval_s: $interval,
    cpu_method: "top delta samples",
    memory_method: "top mem footprint",
    samples: ($samples | length),
    cpu_pct: ($samples | map(.cpu_pct | round3)),
    mem_mib: ($samples | map(.mem_raw | mem_to_mib | round3)),
    avg_cpu_pct: ((($samples | map(.cpu_pct) | add) / ($samples | length)) | round3),
    max_cpu_pct: (($samples | map(.cpu_pct) | max) | round3),
    avg_mem_mib: ((($samples | map(.mem_raw | mem_to_mib) | add) / ($samples | length)) | round3),
    max_mem_mib: (($samples | map(.mem_raw | mem_to_mib) | max) | round3)
  }
  '
