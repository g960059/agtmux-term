#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

fixture_loader="$repo_root/Tests/AgtmuxTermCoreTests/AgtmuxSyncV3FixtureLoader.swift"
fixture_commit="$(sed -n 's/.*daemonFixtureCommit = "\(.*\)".*/\1/p' "$fixture_loader")"
if [[ -z "$fixture_commit" ]]; then
  echo "Failed to resolve daemon fixture commit from $fixture_loader" >&2
  exit 1
fi

daemon_repo="${AGTMUX_DAEMON_REPO:-$repo_root/../agtmux}"

if [[ ! -d "$daemon_repo/.git" ]]; then
  echo "Cloning agtmux fixtures repo into $daemon_repo"
  git clone --filter=blob:none --sparse \
    https://github.com/g960059/agtmux.git \
    "$daemon_repo"
fi

git -C "$daemon_repo" sparse-checkout set fixtures
git -C "$daemon_repo" fetch --depth 1 origin "$fixture_commit"
git -C "$daemon_repo" checkout "$fixture_commit" -- fixtures

fixtures_root="$daemon_repo/fixtures/sync-v3"
[[ -d "$fixtures_root" ]] || {
  echo "Expected fixtures at $fixtures_root after checkout" >&2
  exit 1
}

echo "Prepared agtmux fixtures at $fixtures_root"
