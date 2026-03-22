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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-tty", required=True)
    parser.add_argument("--sample-count", type=int, required=True)
    parser.add_argument("--sample-interval-ms", type=float, required=True)
    parser.add_argument("--sender-start-delay-ms", type=float, default=20.0)
    parser.add_argument("--sender-timeout-ms", type=float, default=8000.0)
    parser.add_argument("sender_command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.sender_command[:1] == ["--"]:
        args.sender_command = args.sender_command[1:]
    if not args.sender_command:
        parser.error("missing sender command after --")
    return args


def main() -> int:
    args = parse_args()
    sample_count = max(1, args.sample_count)
    sample_interval_seconds = max(0.0, args.sample_interval_ms / 1000.0)
    sender_start_delay_seconds = max(0.0, args.sender_start_delay_ms / 1000.0)
    sender_timeout_seconds = max(0.25, args.sender_timeout_ms / 1000.0)

    start = time.perf_counter()
    sender_process: subprocess.Popen[str] | None = None
    sender_started_at_ms: float | None = None
    sender_stdout = ""
    sender_stderr = ""
    sender_timed_out = False
    samples: list[dict[str, object]] = []

    def maybe_start_sender() -> None:
        nonlocal sender_process, sender_started_at_ms
        if sender_process is not None:
            return
        if time.perf_counter() - start < sender_start_delay_seconds:
            return
        sender_process = subprocess.Popen(
            args.sender_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        sender_started_at_ms = (time.perf_counter() - start) * 1000.0

    for index in range(sample_count):
        maybe_start_sender()
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

        next_sample_time = start + ((index + 1) * sample_interval_seconds)
        while True:
            now = time.perf_counter()
            maybe_start_sender()
            remaining = next_sample_time - now
            if remaining <= 0:
                break
            sleep_for = remaining
            if sender_process is None:
                sender_delay_remaining = (start + sender_start_delay_seconds) - now
                if sender_delay_remaining > 0:
                    sleep_for = min(sleep_for, sender_delay_remaining)
            if sleep_for > 0:
                time.sleep(sleep_for)

    maybe_start_sender()
    if sender_process is not None:
        try:
            sender_stdout, sender_stderr = sender_process.communicate(timeout=sender_timeout_seconds)
        except subprocess.TimeoutExpired:
            sender_timed_out = True
            sender_process.kill()
            sender_stdout, sender_stderr = sender_process.communicate()

    payload = {
        "samples": samples,
        "sender": {
            "command": args.sender_command,
            "startedAtMs": sender_started_at_ms,
            "timedOut": sender_timed_out,
            "returncode": sender_process.returncode if sender_process is not None else None,
            "stdout": sender_stdout,
            "stderr": sender_stderr,
        },
    }
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
