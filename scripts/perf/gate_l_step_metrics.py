#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path


LINE_NUMBER_RE = re.compile(r"^\s*(\d+)\s")


def first_visible_line_number(text: str):
    for line in text.splitlines():
        match = LINE_NUMBER_RE.match(line)
        if match:
            return int(match.group(1))
    return None


def physical_row_shift(previous_text: str, current_text: str) -> int:
    previous_rows = previous_text.splitlines()
    current_rows = current_text.splitlines()

    if not previous_rows or not current_rows:
        return 0
    if previous_rows[0] == current_rows[0]:
        return 0

    max_shift = min(12, len(previous_rows) - 1)
    max_probe = 3

    for shift in range(1, max_shift + 1):
        if shift >= len(previous_rows):
            break
        if previous_rows[shift] != current_rows[0]:
            continue
        matched = True
        for probe in range(1, max_probe + 1):
            previous_index = shift + probe
            current_index = probe
            if previous_index >= len(previous_rows) or current_index >= len(current_rows):
                break
            if previous_rows[previous_index] != current_rows[current_index]:
                matched = False
                break
        if matched:
            return shift

    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gate_l_step_metrics.py <samples-json>", file=sys.stderr)
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    samples = payload.get("samples", [])

    sample_metrics = []
    baseline_line = None
    final_visible_line = None
    upward_total_rows = 0
    line_number_upward_total_rows = 0
    changed_sample_count = 0
    coarse_step_count_ge_2 = 0
    coarse_step_count_ge_3 = 0
    max_step_rows = 0
    baseline_text = None
    final_text = None
    first_changed_text = None
    last_changed_text = None
    first_changed_elapsed_ms = None
    last_changed_elapsed_ms = None

    def sample_text(sample: dict) -> str:
        snapshot = sample.get("snapshot")
        if isinstance(snapshot, dict):
            return snapshot.get("text", "") or ""
        value = sample.get("value")
        if isinstance(value, str):
            return value
        return ""

    if samples:
        baseline_text = sample_text(samples[0])
        baseline_line = first_visible_line_number(baseline_text)
        previous_text = baseline_text
        previous_line = baseline_line
        final_text = baseline_text

        for sample in samples[1:]:
            current_text = sample_text(sample)
            current_line = first_visible_line_number(current_text)
            step_rows = physical_row_shift(previous_text, current_text)
            line_number_step_rows = 0
            if previous_line is not None and current_line is not None and current_line < previous_line:
                line_number_step_rows = previous_line - current_line

            if step_rows > 0:
                changed_sample_count += 1
                upward_total_rows += step_rows
                if step_rows >= 2:
                    coarse_step_count_ge_2 += 1
                if step_rows >= 3:
                    coarse_step_count_ge_3 += 1
                max_step_rows = max(max_step_rows, step_rows)
                if first_changed_text is None:
                    first_changed_text = current_text
                    first_changed_elapsed_ms = sample.get("elapsedMs")
                last_changed_text = current_text
                last_changed_elapsed_ms = sample.get("elapsedMs")

            line_number_upward_total_rows += line_number_step_rows
            sample_metrics.append(
                {
                    "sample_index": sample.get("sampleIndex"),
                    "before_line": previous_line,
                    "visible_line": current_line,
                    "step_rows": step_rows,
                    "line_number_step_rows": line_number_step_rows,
                    "elapsed_ms": sample.get("elapsedMs"),
                }
            )
            previous_text = current_text
            previous_line = current_line
            final_visible_line = current_line
            final_text = current_text

        if final_visible_line is None:
            final_visible_line = baseline_line
        if final_text is None:
            final_text = baseline_text

    sample_count = len(sample_metrics)
    unchanged_sample_count = sample_count - changed_sample_count
    mean_lines_per_step = (
        float(upward_total_rows) / float(changed_sample_count)
        if changed_sample_count > 0
        else None
    )
    line_number_mean_lines_per_step = (
        float(line_number_upward_total_rows) / float(changed_sample_count)
        if changed_sample_count > 0
        else None
    )

    result = {
        "sample_metrics": sample_metrics,
        "summary": {
            "baseline_line": baseline_line,
            "final_visible_line": final_visible_line,
            "upward_total_rows": upward_total_rows,
            "line_number_upward_total_rows": line_number_upward_total_rows,
            "sample_count": sample_count,
            "changed_sample_count": changed_sample_count,
            "unchanged_sample_count": unchanged_sample_count,
            "coarse_step_count_ge_2": coarse_step_count_ge_2,
            "coarse_step_count_ge_3": coarse_step_count_ge_3,
            "max_step_rows": max_step_rows,
            "mean_lines_per_step": mean_lines_per_step,
            "line_number_mean_lines_per_step": line_number_mean_lines_per_step,
            "baseline_text": baseline_text,
            "final_text": final_text,
            "first_changed_elapsed_ms": first_changed_elapsed_ms,
            "last_changed_elapsed_ms": last_changed_elapsed_ms,
            "first_changed_text": first_changed_text,
            "last_changed_text": last_changed_text,
        },
    }
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
