# Tasks

- [x] implementation
- [x] tests / workflow validation
- [x] durable-knowledge promotion
- [x] re-publish `v0.2.0` and confirm GitHub Release assets
- [ ] remove `docs/changes/1000-unsigned-release-fallback/` before merge

Validation so far:

- `./scripts/dev/validate-docs.sh`
- `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml"); puts "workflow yaml ok"'`
- local unsigned universal DMG build at
  `build/dmg/AgtmuxTerm-v0.2.0-local-unsigned.dmg`
- GitHub Actions release rerun `23322785794` completed successfully with the
  unsigned fallback path:
  - `build-release` skipped Developer ID / notarization steps
  - `github-release` published `AgtmuxTerm-v0.2.0.dmg`
  - `update-homebrew-cask` was skipped because `unsigned_release == true`
