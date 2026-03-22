#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--start-delay-ms", type=float, default=0.0)
    parser.add_argument("--timeout-ms", type=float, default=8000.0)
    parser.add_argument("sender_command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.sender_command[:1] == ["--"]:
        args.sender_command = args.sender_command[1:]
    if not args.sender_command:
        parser.error("missing sender command after --")
    return args


def main() -> int:
    args = parse_args()
    output_path = Path(args.output)
    payload: dict[str, object] = {
        "command": args.sender_command,
        "startedAtMs": None,
        "timedOut": False,
        "returncode": None,
        "stdout": "",
        "stderr": "",
        "spawnError": None,
    }

    start = time.perf_counter()
    delay_seconds = max(0.0, args.start_delay_ms / 1000.0)
    timeout_seconds = max(0.25, args.timeout_ms / 1000.0)

    if delay_seconds > 0:
        time.sleep(delay_seconds)

    try:
        payload["startedAtMs"] = (time.perf_counter() - start) * 1000.0
        completed = subprocess.run(
            args.sender_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        payload["returncode"] = completed.returncode
        payload["stdout"] = completed.stdout
        payload["stderr"] = completed.stderr
    except subprocess.TimeoutExpired as error:
        payload["timedOut"] = True
        payload["returncode"] = None
        payload["stdout"] = error.stdout or ""
        payload["stderr"] = error.stderr or ""
    except Exception as error:  # pragma: no cover - defensive helper path
        payload["spawnError"] = str(error)

    output_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
