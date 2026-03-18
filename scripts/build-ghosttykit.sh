#!/bin/bash
# build-ghosttykit.sh — Rebuild GhosttyKit.xcframework from Ghostty source
# Expects any repo-required patches to already be applied to the source tree.
# Prerequisites: zig 0.15.x, Xcode (with Metal Toolchain)
#   brew install zig
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_GHOSTTY="${AGTMUX_VENDOR_GHOSTTY_DIR:-$REPO_ROOT/vendor/ghostty}"
DEST="${AGTMUX_GHOSTTYKIT_DIR:-$REPO_ROOT/GhosttyKit/GhosttyKit.xcframework}"

if [[ ! -d "$VENDOR_GHOSTTY" ]]; then
  echo "ERROR: vendor/ghostty not found. Run:" >&2
  echo "  git clone https://github.com/ghostty-org/ghostty $VENDOR_GHOSTTY" >&2
  exit 1
fi

# Prefer zig from PATH, then Homebrew's default prefix.
ZIG="${AGTMUX_ZIG_BIN:-${ZIG:-}}"
if [[ -z "$ZIG" ]]; then
  if command -v zig &>/dev/null; then
    ZIG="zig"
  elif [[ -x "/opt/homebrew/opt/zig/bin/zig" ]]; then
    ZIG="/opt/homebrew/opt/zig/bin/zig"
  else
    echo "ERROR: zig not found. Install with: brew install zig" >&2
    exit 1
  fi
fi

ZIG_VERSION="$("$ZIG" version)"
echo "Using zig $ZIG_VERSION"
if [[ "$ZIG_VERSION" != 0.15.* ]]; then
  echo "WARNING: expected zig 0.15.x, got $ZIG_VERSION — build may fail"
fi

echo "Building GhosttyKit.xcframework..."
cd "$VENDOR_GHOSTTY"
"$ZIG" build -Demit-xcframework=true

XCF_SRC="$VENDOR_GHOSTTY/macos/GhosttyKit.xcframework"
if [[ ! -d "$XCF_SRC" ]]; then
  echo "ERROR: expected xcframework at $XCF_SRC" >&2
  exit 1
fi

echo "Copying to $DEST ..."
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -r "$XCF_SRC" "$DEST"

echo "Done: $DEST"
