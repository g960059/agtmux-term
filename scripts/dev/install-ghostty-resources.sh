#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

vendor_dir="${AGTMUX_VENDOR_GHOSTTY_DIR:-$repo_root/vendor/ghostty}"
share_dir="$vendor_dir/zig-out/share"
resources_dir="${TARGET_BUILD_DIR:?missing TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?missing UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [[ ! -d "$share_dir" ]]; then
  echo "error: Ghostty resources are missing at $share_dir" >&2
  echo "Run scripts/dev/prepare-ghosttykit.sh before building the app." >&2
  exit 1
fi

sync_dir() {
  local source_path="$1"
  local destination_path="$2"
  mkdir -p "$(dirname "$destination_path")"
  rsync -a --delete "$source_path/" "$destination_path/"
}

sync_dir "$share_dir/ghostty" "$resources_dir/ghostty"
sync_dir "$share_dir/terminfo" "$resources_dir/terminfo"

if [[ -d "$share_dir/man" ]]; then
  sync_dir "$share_dir/man" "$resources_dir/man"
fi

if [[ -d "$share_dir/locale" ]]; then
  sync_dir "$share_dir/locale" "$resources_dir/locale"
fi
