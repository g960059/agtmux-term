#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "$repo_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This validation requires macOS because it runs xcodebuild." >&2
  exit 1
fi

command -v xcodegen >/dev/null 2>&1 || {
  echo "Missing required dependency: xcodegen. Install with: brew install xcodegen" >&2
  exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
  echo "Missing required dependency: xcodebuild (install Xcode command line tools)." >&2
  exit 1
}

fixtures_root="${AGTMUX_SYNC_V3_FIXTURES_ROOT:-$repo_root/../agtmux/fixtures/sync-v3}"
[[ -d "$fixtures_root" ]] || {
  echo "Missing agtmux sync-v3 fixtures at $fixtures_root" >&2
  echo "Run: $repo_root/scripts/dev/prepare-agtmux-fixtures.sh" >&2
  exit 1
}

[[ -d "$repo_root/GhosttyKit/GhosttyKit.xcframework" ]] || {
  echo "Missing GhosttyKit/GhosttyKit.xcframework" >&2
  echo "Run: $repo_root/scripts/build-ghosttykit.sh" >&2
  exit 1
}

run_xcodebuild() {
  if command -v xcpretty >/dev/null 2>&1; then
    set -o pipefail
    env AGTMUX_SYNC_V3_FIXTURES_ROOT="$fixtures_root" xcodebuild "$@" | xcpretty
    set +o pipefail
  else
    env AGTMUX_SYNC_V3_FIXTURES_ROOT="$fixtures_root" xcodebuild "$@"
  fi
}

echo "Generating Xcode project"
xcodegen generate --spec project.yml

common_args=(
  -project AgtmuxTerm.xcodeproj
  -scheme AgtmuxTerm
  -configuration Debug
  -destination "platform=macOS"
  CODE_SIGN_IDENTITY=-
  CODE_SIGNING_REQUIRED=NO
  AGTMUX_BIN=/usr/bin/true
)

echo "Running macOS CI parity build"
run_xcodebuild build "${common_args[@]}"

echo "Running macOS CI parity unit tests"
run_xcodebuild test "${common_args[@]}" -only-testing:AgtmuxTermCoreTests

echo "macOS CI validation passed."
