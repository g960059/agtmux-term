#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd -- "${0:A:h}/../.." && pwd -P)"
SOURCE_PATH="$REPO_ROOT/scripts/perf/GateLWindowProbe.swift"
BIN_DIR="$REPO_ROOT/scripts/perf/.bin"
BIN_PATH="$BIN_DIR/gate_l_window_probe"

mkdir -p "$BIN_DIR"

if [[ ! -x "$BIN_PATH" || "$SOURCE_PATH" -nt "$BIN_PATH" ]]; then
  swiftc \
    -g \
    -framework ApplicationServices \
    "$SOURCE_PATH" \
    -o "$BIN_PATH"
fi

exec "$BIN_PATH" "$@"
