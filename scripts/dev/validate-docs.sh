#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "$repo_root"

required_files=(
  "docs/README.md"
  "docs/product/overview.md"
  "docs/product/background.md"
  "docs/product/objectives.md"
  "docs/product/principles.md"
  "docs/product/personas.md"
  "docs/product/goals-non-goals.md"
  "docs/runbooks/change-lifecycle.md"
  "docs/runbooks/release.md"
  "docs/changes/README.md"
  "docs/changes/_template/README.md"
  "docs/changes/_template/requirements.md"
  "docs/changes/_template/design.md"
  "docs/changes/_template/plan.md"
  "docs/changes/_template/tasks.md"
)

for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || {
    echo "Missing required file: $path" >&2
    exit 1
  }
done

shopt -s nullglob

for file in docs/decisions/*.md; do
  base="$(basename "$file")"
  [[ "$base" =~ ^ADR-[0-9]{4}-[a-z0-9-]+\.md$ ]] || {
    echo "Invalid ADR filename: $file" >&2
    exit 1
  }
done

for file in docs/research/*.md; do
  base="$(basename "$file")"
  [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md$ ]] || {
    echo "Invalid research filename: $file" >&2
    exit 1
  }
done

for dir in docs/changes/*/; do
  base="$(basename "$dir")"
  [[ "$base" == "_template" ]] && continue
  [[ "$base" =~ ^(0000|[0-9]{4})-[a-z0-9][a-z0-9-]*$ ]] || {
    echo "Invalid change-pack directory name: $dir" >&2
    exit 1
  }
  for name in README.md requirements.md design.md plan.md tasks.md; do
    [[ -f "${dir}${name}" ]] || {
      echo "Missing ${name} in ${dir}" >&2
      exit 1
    }
  done
done

echo "Docs validation passed."
