# Contributing

The full guide is [`CONTRIBUTING.md`](https://github.com/vkmtx/rumo-workflow/blob/main/CONTRIBUTING.md) in the repository; read `CLAUDE.md` (maintenance rules) and `CONTEXT.md` (terms) first. This page is the short version.

## Setup

You need `bash`, `git`, `python3`, `jq` and the Claude Code CLI (for `claude plugin validate`); `gh` for the parts of the workflow that talk to GitHub. There is no build step and no package install.

## Checks to run

```bash
bash scripts/test-all.sh                                                        # every *_test.sh, *.test.sh, *_test.py; exit 1 on any FAIL
claude plugin validate .                                                        # manifests (without --strict; see CLAUDE.md for accepted warnings)
python3 -I skills/learn/scripts/learn.py budget agents/*.md skills/*/SKILL.md   # byte budgets
bash scripts/smoke-agents.sh --plugin-dir .                                     # after editing agents/ (live run)
bash scripts/leak-scan.sh                                                       # no personal data or credentials
```

`test-all.sh` discovers tests by name, so a new test needs no registration; a test that needs git history exits 77 and shows as `SKIP`. A behaviour change comes with a test that failed before the change.

## Leak scan

`scripts/leak-scan.sh` scans the tree for personal data, hostnames and credential shapes. Run it before opening a PR; deliberate exceptions live in `.leak-scan-allow`. It can also scan a single directory, for example `bash scripts/leak-scan.sh --dir wiki`.

## Version bump rule

Every behaviour change bumps `version` in `.claude-plugin/plugin.json`, because Claude Code runs a cached copy of the plugin and an unbumped edit never reaches a session (see [[FAQ and Troubleshooting]]). The bump is made only in the pre-merge base-merge commit, so a pull request normally does not touch `plugin.json`: say in the PR whether behaviour changed and the maintainer applies the bump. Add a line under `## [Unreleased]` in `CHANGELOG.md`, and when a skill's behaviour changes, update the case map in `skills/rumo/references/help.md`.

## Ground rules in one list

- Skills are user-invoked or model-invoked; a user-invoked skill never calls another user-invoked one.
- Load `writing-for-agents` before editing a `SKILL.md`, and keep the byte budgets.
- Agent pairs (`builder`/`builder-opus`, `reviewer`/`reviewer-sonnet`) are edited in the same commit; model and effort live only in frontmatter.
- Hooks are security gates: tests for the deny case, fail closed when unsure, installed by a machine's owner, never by a build (see [[Hooks]]).
- GitHub through the `gh` CLI only. Everything in the repository is written in English, except protocol strings that scripts match as data.
- Branch from `main` as `feat/<topic>` or `fix/<topic>`, use Conventional Commits, and close the issue with `Closes #N`. Vulnerabilities go through private reporting (`SECURITY.md`), never a public issue.

Contributions are licensed under the project's MIT License.

Next: [[Home]]
