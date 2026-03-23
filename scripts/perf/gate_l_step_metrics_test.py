#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import gate_l_step_metrics


class GateLStepMetricsTests(unittest.TestCase):
    def test_physical_row_shift_detects_scroll_below_stable_header(self):
        previous = "\n".join(
            [
                " gate-normal-scroll  1:[tmux]",
                " status line",
                "────────────────",
                "    100 alpha",
                "    101 beta",
                "    102 gamma",
                "    103 delta",
            ]
        )
        current = "\n".join(
            [
                " gate-normal-scroll  1:[tmux]",
                " status line",
                "────────────────",
                "     99 zeta",
                "    100 alpha",
                "    101 beta",
                "    102 gamma",
            ]
        )

        self.assertEqual(gate_l_step_metrics.physical_row_shift(previous, current), 1)

    def test_main_counts_line_number_only_movement_as_change(self):
        payload = {
            "samples": [
                {
                    "sampleIndex": 0,
                    "elapsedMs": 0,
                    "snapshot": {
                        "text": "\n".join(
                            [
                                " gate-normal-scroll  1:[tmux]",
                                "    3218 alpha",
                                "    3219 beta",
                                "    3220 gamma",
                            ]
                        )
                    },
                },
                {
                    "sampleIndex": 1,
                    "elapsedMs": 120,
                    "snapshot": {
                        "text": "\n".join(
                            [
                                " gate-normal-scroll  1:[tmux]",
                                "    3213 alpha",
                                "    3214 beta",
                                "    3215 gamma",
                            ]
                        )
                    },
                },
            ]
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            payload_path = Path(tmpdir) / "samples.json"
            payload_path.write_text(json.dumps(payload))
            output = subprocess.check_output(
                ["python3", str(Path(__file__).with_name("gate_l_step_metrics.py")), str(payload_path)],
                text=True,
            )

        result = json.loads(output)
        summary = result["summary"]
        self.assertEqual(summary["changed_sample_count"], 1)
        self.assertEqual(summary["line_number_upward_total_rows"], 5)
        self.assertEqual(summary["first_changed_elapsed_ms"], 120)

    def test_main_reports_empty_input_cleanly(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            payload_path = Path(tmpdir) / "samples.json"
            payload_path.write_text("")
            completed = subprocess.run(
                ["python3", str(Path(__file__).with_name("gate_l_step_metrics.py")), str(payload_path)],
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("invalid samples json: empty input", completed.stderr)


if __name__ == "__main__":
    unittest.main()
