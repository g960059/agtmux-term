# Design

## Chosen Approach

Add a release-mode detection step inside `build-release` that produces job
outputs for:

- whether Apple signing/notarization secrets are complete
- whether Homebrew cask update is allowed

The build job then forks:

- signed mode keeps the current archive/export/notarize path
- unsigned mode builds a universal release app with code signing disabled and
  packages the same DMG asset name without notarization

GitHub Release creation stays common, but unsigned releases prepend a warning in
the release notes. Homebrew cask update runs only for signed releases with a
tap token present.

## Boundaries

- changes: `.github/workflows/release.yml`, release docs, release note caveat
- unchanged: CI gate, daemon build, signed/notarized path when secrets exist

## Failure Modes

- missing Apple secrets no longer fail the workflow; instead the release is
  explicitly marked unsigned
- missing Homebrew token no longer blocks unsigned release publishing
- tag re-publish must use the updated workflow definition, so the existing
  `v0.2.0` tag needs to move to the new commit before re-running
