#!/usr/bin/env python3

import argparse
import sys
import time
from pathlib import Path


def wait_for_ready(path: Path, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for ready file: {path}")


def make_line(index: int, wrap_columns: int) -> str:
    prefix = f"{index:06d} "
    sections = [
        f"loaded-history-{index % 97:02d}",
        f"phase={index % 5}",
        f"agent={(index // 7) % 4}",
        f"status={'running' if index % 6 else 'idle'}",
        f"path=/tmp/fixture/{index % 11}/segment/{index % 19}",
        f"json={{\"row\":{index},\"mod\":{index % 13},\"bucket\":{(index * 7) % 29}}}",
        "code=for(i=0;i<8;i++){buffer[i]=rows[index+i];}",
    ]
    filler = " | ".join(sections)
    target = max(wrap_columns * 2, 160)
    repeated = filler
    while len(prefix) + len(repeated) < target:
        repeated += " || " + filler
    return prefix + repeated


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--done-file", required=True)
    parser.add_argument("--lines", type=int, default=12000)
    parser.add_argument("--wrap-columns", type=int, default=180)
    parser.add_argument("--idle-seconds", type=float, default=600.0)
    parser.add_argument("--ready-timeout-seconds", type=float, default=60.0)
    parser.add_argument("--marker", default="AGTMUX_LOADED_HISTORY_DONE")
    args = parser.parse_args()

    ready_file = Path(args.ready_file)
    done_file = Path(args.done_file)
    done_file.unlink(missing_ok=True)

    wait_for_ready(ready_file, args.ready_timeout_seconds)

    for index in range(1, args.lines + 1):
        sys.stdout.write(make_line(index, args.wrap_columns))
        sys.stdout.write("\n")
        if index % 64 == 0:
            sys.stdout.flush()
    sys.stdout.write(f"{args.lines + 1:06d} {args.marker}\n")
    sys.stdout.flush()

    done_file.write_text("done\n", encoding="utf-8")

    if args.idle_seconds > 0:
        time.sleep(args.idle_seconds)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
