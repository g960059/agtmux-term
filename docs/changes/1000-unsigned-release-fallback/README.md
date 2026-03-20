# Change Pack

- **Issue:** `#1000` placeholder until a real GitHub issue exists
- **Status:** In Progress
- **Related PRs:** none yet
- **Related ADRs / research:** none

This pack tracks a temporary release-pipeline fallback that still publishes a
GitHub Release DMG when Apple signing/notarization secrets are unavailable.

Current state:

- `release.yml` now detects whether Apple signing secrets are present before the
  signing/notarization steps
- the signed/notarized path stays intact when secrets exist
- when Apple signing secrets are absent, the workflow builds an unsigned app
  bundle, packages an unsigned DMG, publishes a GitHub Release, and skips the
  Homebrew tap update
- local validation is green for docs validation, workflow YAML parsing, and a
  manual unsigned universal DMG build
- `v0.2.0` was re-published successfully via workflow run `23322785794`
- the published GitHub Release now carries `AgtmuxTerm-v0.2.0.dmg` and
  `AgtmuxTerm-v0.2.0.dmg.sha256`, while `update-homebrew-cask` is skipped
  intentionally in unsigned mode
