#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time


def capture_client_scroll(client_tty: str) -> dict[str, object]:
    command = [
        "tmux",
        "display-message",
        "-p",
        "-c",
        client_tty,
        "#{client_tty}|#{scroll_position}|#{pane_in_mode}|#{window_id}|#{pane_id}",
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
        return {
            "clientTTY": client_tty,
            "scrollPosition": None,
            "paneInMode": None,
            "windowID": None,
            "paneID": None,
            "raw": "",
        }

    raw = result.stdout.strip()
    parts = raw.split("|")
    while len(parts) < 5:
        parts.append("")

    def parse_int(value: str):
        value = value.strip()
        if not value:
            return None
        try:
            return int(value)
        except ValueError:
            return None

    return {
        "clientTTY": parts[0] or client_tty,
        "scrollPosition": parse_int(parts[1]),
        "paneInMode": parse_int(parts[2]),
        "windowID": parts[3] or None,
        "paneID": parts[4] or None,
        "raw": raw,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-tty", required=True)
    parser.add_argument("--sample-count", type=int, required=True)
    parser.add_argument("--sample-interval-ms", type=float, required=True)
    args = parser.parse_args()

    sample_count = max(1, args.sample_count)
    interval_seconds = max(0.0, args.sample_interval_ms / 1000.0)
    start = time.perf_counter()
    samples: list[dict[str, object]] = []

    for index in range(sample_count):
        snapshot = capture_client_scroll(args.client_tty)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        samples.append(
            {
                "sampleIndex": index,
                "elapsedMs": elapsed_ms,
                "snapshot": snapshot,
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
