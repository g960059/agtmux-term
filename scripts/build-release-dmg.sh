#!/usr/bin/env bash
# Build a release DMG for AgtmuxTerm.
#
# Usage:
#   ./scripts/build-release-dmg.sh [--skip-cargo]
#
# Prerequisites:
#   - ../agtmux/ must be cloned next to this repo
#   - create-dmg: brew install create-dmg
#   - xcodegen: brew install xcodegen
#
# The script:
#   1. Builds the agtmux Rust daemon in release mode (../agtmux)
#   2. Builds AgtmuxTerm in Release configuration (xcodebuild)
#      - Bundle agtmux daemon script picks target/release/agtmux automatically
#   3. Creates a DMG from the built .app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_REPO="$REPO_ROOT/../agtmux"
BUILD_DIR="$REPO_ROOT/build/Release"
DMG_DIR="$REPO_ROOT/build/dmg"
APP_NAME="AgtmuxTerm"
MARKETING_VERSION=$(grep 'MARKETING_VERSION:' "$REPO_ROOT/project.yml" | head -1 | awk '{print $2}' | tr -d '"')
DMG_NAME="${APP_NAME} ${MARKETING_VERSION}.dmg"

echo "=== Building AgtmuxTerm ${MARKETING_VERSION} ==="

# ── Step 1: Build the Rust daemon ────────────────────────────────────────────

if [[ "${1:-}" != "--skip-cargo" ]]; then
    echo "[1/3] Building agtmux daemon (release)..."
    if [ ! -d "$DAEMON_REPO" ]; then
        echo "error: daemon repo not found at $DAEMON_REPO" >&2
        echo "       Clone agtmux next to agtmux-term, or use --skip-cargo with AGTMUX_BIN set." >&2
        exit 1
    fi
    (cd "$DAEMON_REPO" && cargo build -p agtmux --release)
    DAEMON_BIN="$DAEMON_REPO/target/release/agtmux"
else
    echo "[1/3] Skipping cargo build (--skip-cargo)"
    DAEMON_BIN="${AGTMUX_BIN:-$DAEMON_REPO/target/release/agtmux}"
fi

if [ ! -x "$DAEMON_BIN" ]; then
    echo "error: daemon binary not found at $DAEMON_BIN" >&2
    exit 1
fi
echo "      daemon: $DAEMON_BIN"

# ── Step 2: Build the Swift app ──────────────────────────────────────────────

echo "[2/3] Building AgtmuxTerm (Release)..."
rm -rf "$BUILD_DIR/${APP_NAME}.app"

xcodebuild \
    -project "$REPO_ROOT/AgtmuxTerm.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$REPO_ROOT/build" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=NO \
    AGTMUX_BIN="$DAEMON_BIN" \
    build 2>&1 | grep -E 'error:|warning:|Build succeeded|** BUILD'

APP_PATH="$BUILD_DIR/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi

# Verify daemon was bundled
BUNDLED_DAEMON="$APP_PATH/Contents/Resources/Tools/agtmux"
if [ ! -x "$BUNDLED_DAEMON" ]; then
    echo "error: daemon binary not bundled at $BUNDLED_DAEMON" >&2
    exit 1
fi
echo "      app:    $APP_PATH"
echo "      daemon: $BUNDLED_DAEMON ($(file "$BUNDLED_DAEMON" | awk -F': ' '{print $2}'))"

# ── Step 3: Create DMG ───────────────────────────────────────────────────────

echo "[3/3] Creating DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

create-dmg \
    --volname "${APP_NAME} ${MARKETING_VERSION}" \
    --window-size 600 380 \
    --icon-size 160 \
    --icon "${APP_NAME}.app" 200 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    --hide-extension "${APP_NAME}.app" \
    "$DMG_DIR/$DMG_NAME" \
    "$APP_PATH"

echo ""
echo "=== Done ==="
echo "DMG: $DMG_DIR/$DMG_NAME"
