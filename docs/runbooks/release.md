# Release

## Trigger

Push a semantic version tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

`release.yml` builds the app, bundles the daemon, signs, notarizes, creates the
DMG, publishes a GitHub Release, and updates the Homebrew tap.

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

## Notes

- the release workflow depends on macOS runners and signing/notarization setup
- if release behavior changes, update this runbook and the workflow in the same PR
