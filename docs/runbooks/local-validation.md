# Local Validation

Use the repo-managed git hooks to catch the same failures that currently show up
in CI before you push.

## Install

From the repo root:

```bash
./scripts/install-git-hooks.sh
```

This sets `core.hooksPath=.githooks` for the repository.

## What The Pre-Commit Hook Runs

- `git diff --cached --check`
- `scripts/dev/validate-docs.sh`
- `bash -n` for staged shell or hook files
- `scripts/dev/validate-macos-ci.sh` when staged files touch:
  - `Sources/`
  - `Tests/`
  - `project.yml`
  - `Package.swift`
  - Xcode entitlements
  - `.github/workflows/ci.yml`
  - `scripts/dev/`
  - `.githooks/`

## Prerequisites

The macOS CI parity script expects:

- `xcodegen` installed
- `../agtmux/fixtures/sync-v3` present, or `AGTMUX_SYNC_V3_FIXTURES_ROOT` set

If `GhosttyKit/GhosttyKit.xcframework` is missing or only present as Git LFS
pointers, the parity script will try to rebuild it from `ghostty v1.3.1`. For
that path you also need:

- `zig 0.15.2` installed
- network access to clone `https://github.com/ghostty-org/ghostty`

Prepare the fixture checkout with:

```bash
./scripts/dev/prepare-agtmux-fixtures.sh
```

Prepare or rebuild `GhosttyKit` explicitly with:

```bash
./scripts/dev/prepare-ghosttykit.sh
```

That helper also applies the repo's custom Ghostty OSC bridge patch before the
xcframework is rebuilt.

## Manual Commands

Run the checks directly when you want CI parity without committing:

```bash
./scripts/dev/validate-docs.sh
./scripts/dev/validate-macos-ci.sh
```

Preview what the hook would do for a set of files:

```bash
./scripts/dev/pre-commit-check.sh --dry-run --files Sources/AgtmuxTerm/AppViewModel.swift
```
