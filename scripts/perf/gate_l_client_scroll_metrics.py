#!/usr/bin/env python3

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gate_l_client_scroll_metrics.py <samples-json>", file=sys.stderr)
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    samples = payload.get("samples", [])

    sample_metrics = []
    baseline_scroll_position = None
    final_scroll_position = None
    net_scroll_delta = 0
    absolute_scroll_delta = 0
    changed_sample_count = 0
    unchanged_sample_count = 0
    coarse_step_count_ge_2 = 0
    coarse_step_count_ge_3 = 0
    max_step_rows = 0
    first_changed_elapsed_ms = None
    last_changed_elapsed_ms = None
    first_changed_snapshot = None
    last_changed_snapshot = None
    copy_mode_sample_count = 0
    scroll_position_sample_count = 0
    first_copy_mode_elapsed_ms = None
    first_scroll_position_elapsed_ms = None

    if samples:
        baseline_snapshot = samples[0].get("snapshot", {})
        baseline_scroll_position = baseline_snapshot.get("scrollPosition")
        previous_scroll_position = baseline_scroll_position
        final_scroll_position = baseline_scroll_position
        if baseline_snapshot.get("paneInMode") == 1:
            copy_mode_sample_count += 1
            first_copy_mode_elapsed_ms = samples[0].get("elapsedMs")
        if isinstance(baseline_scroll_position, int):
            scroll_position_sample_count += 1
            first_scroll_position_elapsed_ms = samples[0].get("elapsedMs")

        for sample in samples[1:]:
            snapshot = sample.get("snapshot", {})
            current_scroll_position = snapshot.get("scrollPosition")
            if snapshot.get("paneInMode") == 1:
                copy_mode_sample_count += 1
                if first_copy_mode_elapsed_ms is None:
                    first_copy_mode_elapsed_ms = sample.get("elapsedMs")
            if isinstance(current_scroll_position, int):
                scroll_position_sample_count += 1
                if first_scroll_position_elapsed_ms is None:
                    first_scroll_position_elapsed_ms = sample.get("elapsedMs")
            step_rows = 0
            if (
                isinstance(previous_scroll_position, int)
                and isinstance(current_scroll_position, int)
            ):
                step_rows = abs(current_scroll_position - previous_scroll_position)

            if step_rows > 0:
                changed_sample_count += 1
                absolute_scroll_delta += step_rows
                if (
                    isinstance(previous_scroll_position, int)
                    and isinstance(current_scroll_position, int)
                ):
                    net_scroll_delta += current_scroll_position - previous_scroll_position
                if step_rows >= 2:
                    coarse_step_count_ge_2 += 1
                if step_rows >= 3:
                    coarse_step_count_ge_3 += 1
                max_step_rows = max(max_step_rows, step_rows)
                if first_changed_elapsed_ms is None:
                    first_changed_elapsed_ms = sample.get("elapsedMs")
                    first_changed_snapshot = snapshot
                last_changed_elapsed_ms = sample.get("elapsedMs")
                last_changed_snapshot = snapshot
            else:
                unchanged_sample_count += 1

            sample_metrics.append(
                {
                    "sample_index": sample.get("sampleIndex"),
                    "before_scroll_position": previous_scroll_position,
                    "scroll_position": current_scroll_position,
                    "step_rows": step_rows,
                    "elapsed_ms": sample.get("elapsedMs"),
                }
            )
            previous_scroll_position = current_scroll_position
            final_scroll_position = current_scroll_position

    mean_lines_per_step = (
        float(absolute_scroll_delta) / float(changed_sample_count)
        if changed_sample_count > 0
        else None
    )

    result = {
        "sample_metrics": sample_metrics,
        "summary": {
            "raw_sample_count": len(samples),
            "baseline_scroll_position": baseline_scroll_position,
            "final_scroll_position": final_scroll_position,
            "net_scroll_delta": net_scroll_delta,
            "absolute_scroll_delta": absolute_scroll_delta,
            "sample_count": len(sample_metrics),
            "copy_mode_sample_count": copy_mode_sample_count,
            "scroll_position_sample_count": scroll_position_sample_count,
            "changed_sample_count": changed_sample_count,
            "unchanged_sample_count": unchanged_sample_count,
            "coarse_step_count_ge_2": coarse_step_count_ge_2,
            "coarse_step_count_ge_3": coarse_step_count_ge_3,
            "max_step_rows": max_step_rows,
            "mean_lines_per_step": mean_lines_per_step,
            "first_copy_mode_elapsed_ms": first_copy_mode_elapsed_ms,
            "first_scroll_position_elapsed_ms": first_scroll_position_elapsed_ms,
            "first_changed_elapsed_ms": first_changed_elapsed_ms,
            "last_changed_elapsed_ms": last_changed_elapsed_ms,
            "first_changed_snapshot": first_changed_snapshot,
            "last_changed_snapshot": last_changed_snapshot,
        },
    }
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
