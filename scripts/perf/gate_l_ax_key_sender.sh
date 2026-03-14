#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd -- "${0:A:h}/../.." && pwd -P)"
SOURCE_PATH="$REPO_ROOT/scripts/perf/GateLAXKeySender.swift"
PLIST_TEMPLATE="$REPO_ROOT/scripts/perf/GateLAXKeySender-Info.plist"
APP_DIR="$REPO_ROOT/scripts/perf/.apps"
APP_BUNDLE="$APP_DIR/GateLAXKeySender.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BIN_PATH="$MACOS_DIR/gate_l_ax_key_sender"
PLIST_PATH="$CONTENTS_DIR/Info.plist"

if [[ "${1:-}" == "--print-app-path" ]]; then
  print -r -- "$APP_BUNDLE"
  exit 0
fi

mkdir -p "$MACOS_DIR"

if [[ ! -f "$PLIST_PATH" || "$PLIST_TEMPLATE" -nt "$PLIST_PATH" ]]; then
  cp "$PLIST_TEMPLATE" "$PLIST_PATH"
fi

if [[ ! -x "$BIN_PATH" || "$SOURCE_PATH" -nt "$BIN_PATH" || "$PLIST_TEMPLATE" -nt "$BIN_PATH" ]]; then
  swiftc \
    -O \
    -framework ApplicationServices \
    "$SOURCE_PATH" \
    -o "$BIN_PATH"
fi

exec "$BIN_PATH" "$@"
