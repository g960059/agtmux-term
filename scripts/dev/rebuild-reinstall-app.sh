#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "$repo_root"

app_name="AgtmuxTerm.app"
install_path="/Applications/$app_name"
derived_data_path="${AGTMUX_REINSTALL_DERIVED_DATA_PATH:-$repo_root/.derived-install-release}"
configuration="${AGTMUX_REINSTALL_CONFIGURATION:-Release}"
scheme="${AGTMUX_REINSTALL_SCHEME:-AgtmuxTerm}"
project_path="${AGTMUX_REINSTALL_PROJECT_PATH:-AgtmuxTerm.xcodeproj}"
native_arch="${AGTMUX_REINSTALL_ARCH:-$(uname -m)}"

if [[ "$configuration" != "Release" ]]; then
  echo "Refusing non-Release reinstall configuration: $configuration" >&2
  exit 1
fi

"$repo_root/scripts/dev/prepare-ghosttykit.sh"

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data_path" \
  ARCHS="$native_arch" \
  ONLY_ACTIVE_ARCH=YES \
  build

built_app="$derived_data_path/Build/Products/$configuration/$app_name"
if [[ ! -d "$built_app" ]]; then
  echo "Built app not found at $built_app" >&2
  exit 1
fi

if [[ -d "$install_path" ]]; then
  trash_dir="${HOME}/.Trash/agtmux-term-reinstall-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$trash_dir"
  mv "$install_path" "$trash_dir/$app_name.previous"
fi

cp -R "$built_app" "$install_path"
xattr -dr com.apple.quarantine "$install_path" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$install_path"

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$install_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$install_path/Contents/Info.plist"
