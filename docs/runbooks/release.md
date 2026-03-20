# Release

## Trigger

Push a semantic version tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

`release.yml` builds the app, bundles the daemon, and then:

- signs, notarizes, creates the DMG, publishes a GitHub Release, and updates
  the Homebrew tap when Apple signing secrets are present
- falls back to an unsigned, non-notarized DMG GitHub Release and skips the
  Homebrew tap update when those Apple signing secrets are absent

## Required Preconditions

- `ci.yml` is green
- `docs-validate.yml` is green
- release notes and version bump are ready
- the daemon version pin in `release.yml` is correct

## Required Secrets

- `APPLE_DEVELOPER_CERTIFICATE_P12`
- `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `HOMEBREW_TAP_TOKEN`

If the Apple signing secrets above are missing, the workflow now intentionally
publishes an unsigned fallback DMG instead of failing the release entirely.
`HOMEBREW_TAP_TOKEN` is only required for the signed/notarized path because the
unsigned fallback skips the Homebrew tap update.

## Notes

- the release workflow depends on macOS runners and signing/notarization setup
- unsigned fallback releases require the same first-launch workaround as local
  builds:

```bash
xattr -dr com.apple.quarantine /Applications/AgtmuxTerm.app
```

- if release behavior changes, update this runbook and the workflow in the same PR
