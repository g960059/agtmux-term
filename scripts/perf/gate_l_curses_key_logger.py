#!/usr/bin/env python3

import argparse
import curses
import json
import os
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-marker", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-ms", type=int, default=15000)
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + (args.timeout_ms / 1000.0)
    started_at = time.monotonic()

    def write_payload(term_value: str, events: list[dict[str, object]]) -> None:
        payload = {
            "term": term_value,
            "eventCount": len(events),
            "events": events,
        }
        output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def run(stdscr: curses.window) -> int:
        curses.noecho()
        curses.cbreak()
        stdscr.keypad(True)
        stdscr.timeout(100)
        try:
            curses.curs_set(0)
        except curses.error:
            pass

        events: list[dict[str, object]] = []
        term_value = os.environ.get("TERM", "")
        write_payload(term_value, events)
        while time.monotonic() < deadline:
            stdscr.erase()
            stdscr.addnstr(0, 0, args.ready_marker, max(1, curses.COLS - 1))
            stdscr.addnstr(1, 0, f"TERM={term_value}", max(1, curses.COLS - 1))
            stdscr.addnstr(2, 0, f"events={len(events)}", max(1, curses.COLS - 1))
            stdscr.refresh()

            key = stdscr.getch()
            if key == -1:
                continue

            try:
                key_name = curses.keyname(key).decode("utf-8", "replace")
            except Exception:
                key_name = str(key)

            events.append(
                {
                    "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                    "key": key,
                    "keyName": key_name,
                }
            )
            write_payload(term_value, events)
        write_payload(term_value, events)
        return 0

    return curses.wrapper(run)


if __name__ == "__main__":
    raise SystemExit(main())
