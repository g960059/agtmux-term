#!/usr/bin/env python3

import argparse
import curses
import json
import textwrap
import time
from pathlib import Path


def build_wrapped_rows(lines: list[str], width: int) -> list[str]:
    content_width = max(1, width)
    wrapped: list[str] = []
    for line in lines:
        expanded = line.expandtabs(4)
        pieces = textwrap.wrap(
            expanded,
            width=content_width,
            replace_whitespace=False,
            drop_whitespace=False,
            break_long_words=True,
            break_on_hyphens=False,
        )
        if pieces:
            wrapped.extend(pieces)
        else:
            wrapped.append("")
    return wrapped


def clamp(value: int, lower: int, upper: int) -> int:
    return max(lower, min(value, upper))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--ready-marker", required=True)
    parser.add_argument("--event-log", default="")
    args = parser.parse_args()

    with open(args.fixture, "r", encoding="utf-8") as handle:
        source_lines = [line.rstrip("\n") for line in handle]

    event_log_path = Path(args.event_log) if args.event_log else None
    started_at = time.monotonic()
    events: list[dict[str, object]] = []

    def flush_events() -> None:
        if event_log_path is None:
            return
        payload = {"eventCount": len(events), "events": events}
        event_log_path.parent.mkdir(parents=True, exist_ok=True)
        event_log_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def run(stdscr: curses.window) -> int:
        curses.noecho()
        curses.cbreak()
        stdscr.keypad(True)
        stdscr.nodelay(False)
        try:
            curses.curs_set(0)
        except curses.error:
            pass

        rows = []
        top = 0
        last_dims = (-1, -1)

        while True:
            height, width = stdscr.getmaxyx()
            if (height, width) != last_dims:
                last_dims = (height, width)
                content_height = max(1, height - 1)
                previous_bottom_distance = max(0, len(rows) - content_height - top)
                rows = build_wrapped_rows(source_lines, max(1, width))
                max_top = max(0, len(rows) - content_height)
                top = clamp(max_top - previous_bottom_distance, 0, max_top)
                events.append(
                    {
                        "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                        "kind": "resize",
                        "height": height,
                        "width": width,
                        "top": top,
                        "rows": len(rows),
                    }
                )
                flush_events()

            content_height = max(1, height - 1)
            max_top = max(0, len(rows) - content_height)
            top = clamp(top, 0, max_top)

            stdscr.erase()
            status = f"{args.ready_marker} top={top} rows={len(rows)}"
            stdscr.addnstr(0, 0, status, max(1, width - 1))
            for index in range(content_height):
                row_index = top + index
                if row_index >= len(rows):
                    break
                stdscr.addnstr(index + 1, 0, rows[row_index], max(1, width - 1))
            stdscr.refresh()

            key = stdscr.getch()
            if key == curses.KEY_UP:
                top = clamp(top - 1, 0, max_top)
                events.append(
                    {
                        "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                        "kind": "key",
                        "key": key,
                        "keyName": "KEY_UP",
                        "top": top,
                        "rows": len(rows),
                    }
                )
                flush_events()
            elif key == curses.KEY_DOWN:
                top = clamp(top + 1, 0, max_top)
                events.append(
                    {
                        "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                        "kind": "key",
                        "key": key,
                        "keyName": "KEY_DOWN",
                        "top": top,
                        "rows": len(rows),
                    }
                )
                flush_events()
            elif key in (ord("q"), ord("Q")):
                events.append(
                    {
                        "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                        "kind": "key",
                        "key": key,
                        "keyName": chr(key),
                        "top": top,
                        "rows": len(rows),
                    }
                )
                flush_events()
                return 0
            elif key == curses.KEY_RESIZE:
                events.append(
                    {
                        "elapsedMs": round((time.monotonic() - started_at) * 1000.0, 3),
                        "kind": "key",
                        "key": key,
                        "keyName": "KEY_RESIZE",
                        "top": top,
                        "rows": len(rows),
                    }
                )
                flush_events()
                continue

    return curses.wrapper(run)


if __name__ == "__main__":
    raise SystemExit(main())
