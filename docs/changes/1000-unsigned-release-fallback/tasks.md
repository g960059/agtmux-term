# Tasks

- [x] implementation
- [ ] tests / workflow validation
- [x] durable-knowledge promotion
- [ ] re-publish `v0.2.0` and confirm GitHub Release assets
- [ ] remove `docs/changes/1000-unsigned-release-fallback/` before merge

Validation so far:

- `./scripts/dev/validate-docs.sh`
- `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml"); puts "workflow yaml ok"'`
- local unsigned universal DMG build at
  `build/dmg/AgtmuxTerm-v0.2.0-local-unsigned.dmg`
