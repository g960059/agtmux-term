#!/usr/bin/env python3

import argparse
import os
import select
import sys
import termios
import tty


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-marker", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-ms", type=int, default=3000)
    args = parser.parse_args()

    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    out_path = args.output
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    with open(out_path, "wb") as handle:
        try:
            tty.setraw(fd)
            sys.stdout.write("\x1b[?1049h\x1b[?1h")
            sys.stdout.write(f"{args.ready_marker}\r\n")
            sys.stdout.write("raw-alt-input-logger waiting...\r\n")
            sys.stdout.flush()

            deadline = os.times().elapsed + (args.timeout_ms / 1000.0)
            read_count = 0
            while os.times().elapsed < deadline:
                timeout = max(0.0, deadline - os.times().elapsed)
                readable, _, _ = select.select([fd], [], [], timeout)
                if not readable:
                    continue
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                handle.write(chunk)
                handle.flush()
                read_count += 1
                sys.stdout.write(f"\x1b[2;1Hchunks={read_count} bytes={handle.tell():<8}")
                sys.stdout.flush()
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, original)
            sys.stdout.write("\x1b[?1l\x1b[?1049l")
            sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
