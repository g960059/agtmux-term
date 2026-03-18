#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

git -C "$repo_root" config core.hooksPath .githooks

configured_path="$(git -C "$repo_root" config --local --get core.hooksPath)"
echo "Configured repository-local core.hooksPath=$configured_path"
echo "Git will now run repo-managed hooks from $repo_root/$configured_path"
