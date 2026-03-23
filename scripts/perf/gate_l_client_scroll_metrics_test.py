#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


class GateLClientScrollMetricsTests(unittest.TestCase):
    def run_metrics(self, payload: dict) -> dict:
        with tempfile.TemporaryDirectory() as tmpdir:
            payload_path = Path(tmpdir) / "samples.json"
            payload_path.write_text(json.dumps(payload))
            output = subprocess.check_output(
                ["python3", str(Path(__file__).with_name("gate_l_client_scroll_metrics.py")), str(payload_path)],
                text=True,
            )
        return json.loads(output)

    def test_summary_reports_copy_mode_and_scroll_position_observation(self):
        payload = {
            "samples": [
                {
                    "sampleIndex": 0,
                    "elapsedMs": 10,
                    "snapshot": {
                        "paneInMode": 0,
                        "scrollPosition": None,
                    },
                },
                {
                    "sampleIndex": 1,
                    "elapsedMs": 20,
                    "snapshot": {
                        "paneInMode": 1,
                        "scrollPosition": 0,
                    },
                },
                {
                    "sampleIndex": 2,
                    "elapsedMs": 40,
                    "snapshot": {
                        "paneInMode": 1,
                        "scrollPosition": 5,
                    },
                },
            ]
        }

        result = self.run_metrics(payload)
        summary = result["summary"]
        self.assertEqual(summary["raw_sample_count"], 3)
        self.assertEqual(summary["sample_count"], 2)
        self.assertEqual(summary["copy_mode_sample_count"], 2)
        self.assertEqual(summary["scroll_position_sample_count"], 2)
        self.assertEqual(summary["first_copy_mode_elapsed_ms"], 20)
        self.assertEqual(summary["first_scroll_position_elapsed_ms"], 20)
        self.assertEqual(summary["changed_sample_count"], 1)
        self.assertEqual(summary["net_scroll_delta"], 5)

    def test_summary_counts_baseline_copy_mode_sample(self):
        payload = {
            "samples": [
                {
                    "sampleIndex": 0,
                    "elapsedMs": 5,
                    "snapshot": {
                        "paneInMode": 1,
                        "scrollPosition": 12,
                    },
                },
                {
                    "sampleIndex": 1,
                    "elapsedMs": 15,
                    "snapshot": {
                        "paneInMode": 1,
                        "scrollPosition": 12,
                    },
                },
            ]
        }

        result = self.run_metrics(payload)
        summary = result["summary"]
        self.assertEqual(summary["copy_mode_sample_count"], 2)
        self.assertEqual(summary["scroll_position_sample_count"], 2)
        self.assertEqual(summary["first_copy_mode_elapsed_ms"], 5)
        self.assertEqual(summary["first_scroll_position_elapsed_ms"], 5)
        self.assertEqual(summary["changed_sample_count"], 0)


if __name__ == "__main__":
    unittest.main()
