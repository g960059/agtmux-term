#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time


def capture_visible_text(socket_name: str, target: str) -> str:
    command = [
        "tmux",
        "-f",
        "/dev/null",
        "-L",
        socket_name,
        "capture-pane",
        "-p",
        "-t",
        target,
    ]
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=0.25,
        )
    except subprocess.TimeoutExpired:
        return ""
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket-name", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--sample-count", type=int, required=True)
    parser.add_argument("--sample-interval-ms", type=float, required=True)
    args = parser.parse_args()

    sample_count = max(1, args.sample_count)
    interval_seconds = max(0.0, args.sample_interval_ms / 1000.0)
    start = time.perf_counter()
    samples: list[dict[str, object]] = []

    for index in range(sample_count):
        text = capture_visible_text(args.socket_name, args.target)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        samples.append(
            {
                "sampleIndex": index,
                "elapsedMs": elapsed_ms,
                "snapshot": {
                    "text": text,
                },
            }
        )

        if index + 1 >= sample_count:
            break

        target_time = start + ((index + 1) * interval_seconds)
        sleep_duration = target_time - time.perf_counter()
        if sleep_duration > 0:
            time.sleep(sleep_duration)

    json.dump({"samples": samples}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
