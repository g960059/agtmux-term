# Requirements

## Problem

`release.yml` currently hard-fails when Apple Developer signing secrets are not
configured. That blocks GitHub Releases entirely even though an unsigned DMG is
acceptable as a temporary distribution path.

## Goals

- publish a GitHub Release DMG even when Apple signing secrets are absent
- keep the signed/notarized path unchanged when secrets are present
- avoid updating Homebrew cask metadata for temporary unsigned releases
- confirm `v0.2.0` completes end-to-end after the fallback lands

## Non-Goals

- replacing the future signed/notarized distribution path
- changing app runtime behavior
- preserving release automation for Homebrew when the DMG is unsigned

## Acceptance

- [ ] `release.yml` detects whether signing/notarization secrets are present
- [ ] missing Apple secrets produce an unsigned DMG and a GitHub Release instead of a failed workflow
- [ ] signed/notarized mode still uses the existing Apple certificate and notary flow
- [ ] Homebrew tap update is skipped when the release is unsigned
- [ ] `v0.2.0` finishes as a published GitHub Release with DMG asset(s)
