# Contributing to rumo

Thanks for your interest. rumo is a Claude Code plugin (skills, typed subagents, hooks and helper
scripts) and a single-plugin marketplace. Read `CLAUDE.md` first: it holds the maintenance rules
this file summarizes, and `CONTEXT.md` defines the terms used across the repo (Stamp, Open finding,
Launch prompt, Mandato, ...).

## Development setup

You need `bash`, `git`, `python3`, `jq` and the [Claude Code](https://claude.com/claude-code) CLI
(for `claude plugin validate`). The `gh` CLI is needed for the parts of the workflow that talk to
GitHub. There is no build step and no package install.

```bash
git clone https://github.com/vkmtx/rumo-workflow.git
cd <repo>
bash scripts/test-all.sh          # every *_test.sh, *.test.sh and *_test.py; exit 1 on any FAIL
claude plugin validate .          # manifests (without --strict, see CLAUDE.md for accepted warnings)
./scripts/install.sh              # optional: install this checkout as the user-scope plugin
```

`scripts/test-all.sh` discovers tests on its own, so a new test file needs no registration. A test
that needs git history exits 77 and is reported as `SKIP`.

Also run, when you touch the matching files:

```bash
python3 -I skills/learn/scripts/learn.py budget agents/*.md skills/*/SKILL.md   # byte budgets
bash scripts/smoke-agents.sh --plugin-dir .                                      # after editing agents/ (live run)
bash scripts/leak-scan.sh                                                        # no personal data or credentials
```

## Ground rules

- **Tests first.** A behavior change comes with a test that failed before the change. Prefer the
  repo's existing test style (plain bash or Python scripts, no framework).
- **Skill types.** A skill is either user-invoked (`disable-model-invocation: true`) or
  model-invoked. A user-invoked skill may call model-invoked ones, never another user-invoked one.
- **Load `writing-for-agents`** (under `skills/discipline/`) before editing any `SKILL.md`, and keep
  the byte budgets.
- **Agents.** `agents/*.md` are the typed subagents. Model and effort live only in their frontmatter.
  `builder.md`/`builder-opus.md` share one body, and so do `reviewer.md`/`reviewer-sonnet.md`: edit
  each pair in the same commit.
- **Hooks are security gates.** Changes under `scripts/hooks-staged/` need tests for the deny case
  and for the shape you are loosening or tightening; fail closed when unsure. They are installed by
  the owner of a machine, never by a build.
- **GitHub through the `gh` CLI only.** No skill here may assume a GitHub MCP server.
- **Discipline skills** under `skills/discipline/` are ported from
  [mattpocock/skills](https://github.com/mattpocock/skills) 1.2.3 (MIT) with the mechanism intact.
  Edit them only to fix references to renamed or retired commands; behavior changes belong upstream.
  See `THIRD_PARTY_NOTICES.md`.
- **Router honesty.** When a skill's behavior changes, update the case map in
  `skills/rumo/references/help.md`.

## Versioning and changelog

Every behavior change bumps `version` in `.claude-plugin/plugin.json`, because Claude Code runs a
cached copy of the plugin and an unbumped edit never reaches a session. The bump is made only in the
pre-merge base-merge commit (see `skills/rumo/references/wave.md`, section Merging), so a pull request
normally does not touch `plugin.json`: say in the PR whether behavior changed and the maintainer
applies the bump. Add a line under `## [Unreleased]` in `CHANGELOG.md` (Keep a Changelog format).
After touching either manifest, run `claude plugin validate .`.

## Commits and pull requests

- Branch from `main` as `feat/<topic>` or `fix/<topic>`; open the pull request against `main`.
- Commit subjects follow Conventional Commits: `feat(scope): ...`, `fix(scope): ...`, `docs: ...`,
  `test: ...`, `refactor: ...`, `chore: ...`. Keep the subject under about 72 characters and explain
  the why in the body.
- The PR description says what changed and why, links its issue with `Closes #N`, and lists the
  checks you ran.
- Findings that describe a vulnerability go through private reporting, never a public issue: see
  `SECURITY.md`.
- Everything in this repository is written in English, including comments and messages. The only
  exceptions are literal protocol strings that scripts match as data (documented where they occur).

By contributing you agree that your contribution is licensed under the MIT License of this project.
