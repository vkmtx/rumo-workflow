## What and why

<!-- What changed, and the reason. Link the issue: Closes #N -->

## Checks

- [ ] `bash scripts/test-all.sh` passes (or the affected test files, if the full run is impractical)
- [ ] New behavior has a test that failed before the change
- [ ] `claude plugin validate .` passes, if a manifest changed
- [ ] `bash scripts/leak-scan.sh` is clean (no personal paths, hosts, emails or credentials)
- [ ] User-visible change: a line under `## [Unreleased]` in `CHANGELOG.md`, and the case map in `skills/rumo/references/help.md` still tells the truth
- [ ] Behavior change: noted here so the maintainer can bump `version` in `.claude-plugin/plugin.json`
