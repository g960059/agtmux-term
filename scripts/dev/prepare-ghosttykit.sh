#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "$repo_root"

ghostty_ref="${AGTMUX_GHOSTTY_REF:-v1.3.1}"
ghostty_url="${AGTMUX_GHOSTTY_REPO_URL:-https://github.com/ghostty-org/ghostty}"
vendor_dir="${AGTMUX_VENDOR_GHOSTTY_DIR:-$repo_root/vendor/ghostty}"
xcframework_dir="${AGTMUX_GHOSTTYKIT_DIR:-$repo_root/GhosttyKit/GhosttyKit.xcframework}"
marker_file="${AGTMUX_GHOSTTYKIT_MARKER_FILE:-$repo_root/GhosttyKit/.ghostty-source-ref}"
patch_file="${AGTMUX_GHOSTTY_PATCH_FILE:-$repo_root/scripts/patches/ghostty-custom-osc.patch}"
temp_vendor_root=""

if [[ ! -f "$patch_file" ]]; then
  echo "Missing required Ghostty patch at $patch_file" >&2
  exit 1
fi

patch_sha256="$(shasum -a 256 "$patch_file" | awk '{print $1}')"
marker_value="${ghostty_ref}+ghostty-custom-osc@${patch_sha256}"

cleanup() {
  if [[ -n "$temp_vendor_root" && -d "$temp_vendor_root" ]]; then
    rm -rf "$temp_vendor_root"
  fi
}
trap cleanup EXIT

is_lfs_pointer() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  [[ "$(head -n 1 "$path" 2>/dev/null || true)" == "version https://git-lfs.github.com/spec/v1" ]]
}

ghosttykit_materialized() {
  local macos_lib="$xcframework_dir/macos-arm64_x86_64/libghostty.a"
  local header="$xcframework_dir/macos-arm64_x86_64/Headers/ghostty.h"
  local info_plist="$xcframework_dir/Info.plist"

  [[ -f "$macos_lib" && -f "$header" && -f "$info_plist" ]] || return 1
  ! is_lfs_pointer "$macos_lib" || return 1
  ! is_lfs_pointer "$header" || return 1
  ! is_lfs_pointer "$info_plist" || return 1
}

ghosttykit_has_custom_osc() {
  local header="$xcframework_dir/macos-arm64_x86_64/Headers/ghostty.h"

  [[ -f "$header" ]] || return 1
  grep -q 'GHOSTTY_ACTION_CUSTOM_OSC' "$header"
}

ghosttykit_ready() {
  ghosttykit_materialized || return 1
  ghosttykit_has_custom_osc || return 1
  [[ -f "$marker_file" ]] || return 1
  [[ "$(tr -d '\n' < "$marker_file")" == "$marker_value" ]] || return 1
}

ghostty_source_has_custom_osc() {
  local header="$vendor_dir/include/ghostty.h"
  local osc_file="$vendor_dir/src/terminal/osc.zig"

  [[ -f "$header" && -f "$osc_file" ]] || return 1
  grep -q 'GHOSTTY_ACTION_CUSTOM_OSC' "$header" &&
    grep -q 'AGTMUX_BRIDGE_OSC' "$osc_file"
}

apply_custom_patch() {
  if ghostty_source_has_custom_osc; then
    echo "Ghostty custom OSC patch already present in $vendor_dir"
    return 0
  fi

  echo "Applying Ghostty custom OSC patch to $vendor_dir"
  if ! git -C "$vendor_dir" apply -p0 --check "$patch_file"; then
    echo "Ghostty custom OSC patch no longer applies cleanly to $ghostty_ref." >&2
    echo "Update $patch_file or choose a compatible Ghostty ref." >&2
    exit 1
  fi

  git -C "$vendor_dir" apply -p0 "$patch_file"

  ghostty_source_has_custom_osc || {
    echo "Ghostty custom OSC patch applied, but expected symbols are still missing." >&2
    exit 1
  }
}

clone_vendor_checkout() {
  local target_dir="$1"
  echo "Cloning Ghostty $ghostty_ref into $target_dir"
  mkdir -p "$(dirname "$target_dir")"
  git clone --depth 1 --branch "$ghostty_ref" "$ghostty_url" "$target_dir"
}

use_fresh_temp_checkout() {
  temp_vendor_root="$(mktemp -d "${TMPDIR:-/tmp}/agtmux-ghostty-${ghostty_ref}.XXXXXX")"
  vendor_dir="$temp_vendor_root/ghostty"
  clone_vendor_checkout "$vendor_dir"
}

if ghosttykit_ready; then
  echo "GhosttyKit is ready at $xcframework_dir for $ghostty_ref"
  exit 0
fi

command -v git >/dev/null 2>&1 || {
  echo "Missing required dependency: git" >&2
  exit 1
}
command -v zig >/dev/null 2>&1 || {
  echo "Missing required dependency: zig (expected 0.15.x)." >&2
  echo "Install with: brew install zig" >&2
  exit 1
}

if [[ -n "${AGTMUX_VENDOR_GHOSTTY_DIR:-}" ]]; then
  if [[ -e "$vendor_dir" && ! -d "$vendor_dir/.git" ]]; then
    echo "Expected $vendor_dir to be a git checkout, but it is not." >&2
    exit 1
  fi
  if [[ ! -d "$vendor_dir/.git" ]]; then
    clone_vendor_checkout "$vendor_dir"
  fi
else
  if [[ ! -d "$vendor_dir/.git" ]]; then
    clone_vendor_checkout "$vendor_dir"
  else
    current_ref="$(git -C "$vendor_dir" describe --tags --always 2>/dev/null || git -C "$vendor_dir" rev-parse --short HEAD)"
    if [[ "$current_ref" == "$ghostty_ref" ]] && [[ -z "$(git -C "$vendor_dir" status --porcelain 2>/dev/null)" ]]; then
      echo "Using clean vendor/ghostty checkout at $current_ref"
    else
      echo "Skipping existing vendor/ghostty checkout at $current_ref because it is dirty or not on $ghostty_ref"
      use_fresh_temp_checkout
    fi
  fi
fi

apply_custom_patch

AGTMUX_VENDOR_GHOSTTY_DIR="$vendor_dir" \
AGTMUX_GHOSTTYKIT_DIR="$xcframework_dir" \
"$repo_root/scripts/build-ghosttykit.sh"

ghosttykit_materialized || {
  echo "GhosttyKit build completed, but the xcframework still looks incomplete." >&2
  exit 1
}

ghosttykit_has_custom_osc || {
  echo "GhosttyKit build completed, but custom OSC symbols are missing from the header." >&2
  exit 1
}

printf '%s\n' "$marker_value" > "$marker_file"

echo "GhosttyKit prepared successfully for $ghostty_ref."
