#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "$repo_root"

dry_run=0
declare -a explicit_files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --files)
      shift
      while [[ $# -gt 0 ]]; do
        explicit_files+=("$1")
        shift
      done
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

declare -a changed_files=()
if [[ ${#explicit_files[@]} -gt 0 ]]; then
  changed_files=("${explicit_files[@]}")
else
  while IFS= read -r file; do
    [[ -n "$file" ]] && changed_files+=("$file")
  done < <(git diff --cached --name-only --diff-filter=ACMR)
fi

if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "No staged files. Skipping pre-commit checks."
  exit 0
fi

needs_macos_ci=0
declare -a shell_files=()

for file in "${changed_files[@]}"; do
  case "$file" in
    *.sh|.githooks/*)
      shell_files+=("$file")
      ;;
  esac

  case "$file" in
    Sources/*|Tests/*|project.yml|Package.swift|AgtmuxTerm.entitlements|AgtmuxDaemonService.entitlements|.github/workflows/ci.yml|scripts/dev/*|.githooks/*)
      needs_macos_ci=1
      ;;
  esac
done

if [[ $dry_run -eq 1 ]]; then
  echo "pre-commit dry-run"
  printf 'changed_files:\n'
  printf '  %s\n' "${changed_files[@]}"
  printf 'run_docs_validate: yes\n'
  printf 'run_shell_syntax: %s\n' "$([[ ${#shell_files[@]} -gt 0 ]] && echo yes || echo no)"
  printf 'run_macos_ci: %s\n' "$([[ $needs_macos_ci -eq 1 ]] && echo yes || echo no)"
  exit 0
fi

echo "Checking staged diff for whitespace/conflict markers"
git diff --cached --check

if [[ ${#shell_files[@]} -gt 0 ]]; then
  echo "Checking shell syntax"
  for file in "${shell_files[@]}"; do
    bash -n "$file"
  done
fi

echo "Running docs validation"
"$repo_root/scripts/dev/validate-docs.sh"

if [[ $needs_macos_ci -eq 1 ]]; then
  echo "Running macOS CI parity checks"
  "$repo_root/scripts/dev/validate-macos-ci.sh"
fi

echo "Pre-commit checks passed."
