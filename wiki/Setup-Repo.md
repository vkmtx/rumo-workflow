# Setup Repo

`/setup-repo` is a one-pass bootstrap that makes `/rumo` and `review` work on their first invocation in a repository. It writes the tracker conventions, the label vocabulary, the domain-docs rule, a `CONTEXT.md`, the repo's lessons file and an `## Agent skills` block in `CLAUDE.md`, and fixes a missing `origin/HEAD`. It runs in **adopt-mode**: strictly additive, it never overwrites an existing file, and every pre-existing target is reported as `kept: <path>`. It never commits; you do.

## Recon

| Check | Result |
|---|---|
| `git rev-parse --show-toplevel` | not a repo → stop |
| `git remote -v`, `gh repo view --json nameWithOwner` | the repo's `owner/name`; no GitHub remote → the tracker doc is still written, and the report notes that `gh` calls fail until a remote exists |
| `git rev-parse -q --verify origin/HEAD` | missing with a remote → `git remote set-head origin --auto` (`fixed: origin/HEAD`); missing with no remote → reported and left alone. The built-in `/security-review` diffs against `origin/HEAD`. |
| `test -e` on each target | exists → `kept: <path>`; missing → written |

## Targets

| File | Content |
|---|---|
| `docs/agents/issue-tracker.md` | GitHub issues via `gh`, always; the real `owner/name`; create / read / list / comment / label / close commands |
| `docs/agents/triage-labels.md` | three canonical roles, `ready-for-agent`, `ready-for-human`, `wontfix`; existing label strings from `gh label list` are reused, not forked |
| `docs/agents/domain.md` | read `CONTEXT.md` (or `CONTEXT-MAP.md` for a multi-context repo) and relevant ADRs first; single- vs multi-context layout by monorepo signals (`pnpm-workspace.yaml`, a `workspaces` field, populated `packages/*/src`); use glossary terms exactly; output that contradicts an ADR says so |
| `CONTEXT.md` | only if absent, only from what the repo shows (README, entry points, schema files): purpose in two lines, then a glossary in the codebase's own terms and language. Inferred entries are marked `<!-- inferido -->` (inferred) to invite correction. A repo too thin to say anything true gets an honest skeleton. |
| `docs/agents/lessons.md` | the repo's learned rules: quoted into plan steps by the planner, checked by the standards reviewer, maintained by `/learn`; 8 KB budget |
| `.gitignore` | `.rumo/` appended (file created if missing; `updated: .gitignore`), so no checkout or worktree can stage a plan |
| `CLAUDE.md` `## Agent skills` block | pointers to the four `docs/agents/*` files; updated in place if the section exists; written into `AGENTS.md` instead when only that file exists |

There is no `plans/` scaffold: plans live in `.rumo/plan.md` inside each feature worktree. An existing `plans/README.md` is left alone.

The block appended to `CLAUDE.md`:

```markdown
## Agent skills

### Issue tracker
GitHub issues, PRs-as-request-surface off. See `docs/agents/issue-tracker.md`.

### Triage labels
Canonical three-role vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs
[single-context | multi-context]. See `docs/agents/domain.md`.

### Lessons
Learned rules, read by `/rumo build`'s planner and reviewer. See `docs/agents/lessons.md`.
```

## Report

A table of file → `created` / `kept: <path>` / `skipped-with-reason`, the `origin/HEAD` line, and one line naming which skills now read these files. The `docs/agents/*.md` files can be hand-edited later without re-running the command. The turn ends with `NEXT:`.

## Self-healing from `ticket`

`/rumo ticket` does not dead-end when `docs/agents/issue-tracker.md` or `docs/agents/triage-labels.md` is missing: it scaffolds just that file from this skill's template (adopt-mode, uncommitted) and continues. `/setup-repo` remains the full bootstrap.

Next: [[Agents]]
