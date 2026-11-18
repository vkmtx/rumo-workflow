---
name: setup-repo
description: One-pass bootstrap of a repo for this workflow — CONTEXT.md, docs/agents/ (GitHub tracker, triage labels, domain rules, lessons), and the CLAUDE.md agent-skills block. Makes /rumo and review work on first invocation.
disable-model-invocation: true
---

**ADOPT-MODE, strictly additive**: never overwrite a file that already exists. Every pre-existing target is reported as a literal `kept: <path>` line — never silently skipped, never silently left alone without saying so.

## 0. Recon

- `git rev-parse --show-toplevel` — not a repo → stop, tell the user.
- `git remote -v` and `gh repo view --json nameWithOwner` — this repo's `owner/name`. No GitHub remote → still write the tracker doc (Section 1), note in the report that `gh` calls will fail until a remote is added.
- `git rev-parse -q --verify origin/HEAD` — the built-in `/security-review` diffs against it and fails without it. Missing with a GitHub remote → `git remote set-head origin --auto`, report `fixed: origin/HEAD`. Missing with no remote → report `origin/HEAD missing (no remote)` and leave it: pointing it at `dev` locally is the user's call.
- For each target path below, `test -e` it first. Exists → `kept: <path>`, do not touch. Missing → write it per its section.

Targets: `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, `docs/agents/domain.md`, `CONTEXT.md`, `docs/agents/lessons.md`, the `## Agent skills` block in `CLAUDE.md`.

## 1. `docs/agents/issue-tracker.md`

This workflow has one tracker, always: GitHub issues via `gh`. No interview, no other backend. Write, substituting the real `owner/name`:

```markdown
# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Owner/repo: `<owner>/<name>`.

## Conventions
- Create: `gh issue create --title "..." --body "..."` (heredoc for multi-line bodies).
- Read: `gh issue view <n> --comments`.
- List: `gh issue list --state open --json number,title,body,labels,comments`.
- Comment / label / close: `gh issue comment`, `gh issue edit --add-label/--remove-label`, `gh issue close --comment "..." --reason <reason>`.

## When a skill says "publish to the tracker" / "fetch the ticket"
Create / `gh issue view <n> --comments`, respectively.
```

## 2. `docs/agents/triage-labels.md`

The three canonical roles, label string = role name unless this repo already uses other strings (check `gh label list` first — reuse existing labels, don't fork the vocabulary):

```markdown
# Triage Labels

| Role              | Label in this repo | Meaning                                  |
|--------------------|---------------------|-------------------------------------------|
| ready-for-agent    | ready-for-agent     | Fully specified, safe for the builders    |
| ready-for-human    | ready-for-human     | Requires human implementation              |
| wontfix            | wontfix             | Will not be actioned                       |
```

## 3. `docs/agents/domain.md`

```markdown
# Domain Docs

Before exploring this repo, read `CONTEXT.md` (or `CONTEXT-MAP.md` if this is a multi-context
repo, then each linked per-context `CONTEXT.md`) and any `docs/adr/` entries touching the area.
Missing files → proceed silently, don't propose creating them upfront; `domain-modeling`
creates them lazily when a term or decision actually resolves.

Layout: single-context (`CONTEXT.md` + `docs/adr/` at root) unless this repo shows real
monorepo signals (`pnpm-workspace.yaml`, a `workspaces` field, populated `packages/*/src`) —
then multi-context (root `CONTEXT-MAP.md` + per-package `CONTEXT.md`/`docs/adr/`).

Use the glossary's terms exactly in output that names a domain concept — no drifting to a
synonym the glossary avoids. Output that contradicts a standing ADR must say so explicitly
("Contradicts ADR-000N — reopening because…"); a recorded tradeoff is by-design, not a finding.
```

## 4. `CONTEXT.md`

Only if absent, and only from what the repo actually shows — README, entry points, model/schema files. Purpose in two lines, then a glossary in the codebase's own terms (its own language, e.g. PT-BR if the code is). Mark anything inferred rather than read with `<!-- inferido -->` so it invites correction. Repo too thin to say anything true → write the skeleton with empty sections and say so; an honest stub beats invented vocabulary.

## 5. `docs/agents/lessons.md`

The repo's learned rules: `rumo:planner` quotes the relevant ones into plan steps, the standards reviewer checks them, `/learn` adds and promotes them. Write:

```markdown
# Lessons

Rules this repo learned the hard way — each one cost a failed step, a review finding, or a
correction. Planner quotes the relevant ones into plan steps; reviewer checks them. Maintained
by `/learn`; hand edits welcome. Budget 8 KB — over it, `/learn review` promotes or archives.

<!-- entry format: see the /learn skill -->
```

No `plans/` scaffold: `/rumo build` writes each plan to `.rumo/plan.md` inside its feature worktree, never committed — append `.rumo/` to the repo's `.gitignore` (create it if missing; report `updated: .gitignore`) so no checkout or worktree can stage it. An existing `plans/README.md` is left alone (`kept`).

## 6. `CLAUDE.md` agent-skills block

Target is always `CLAUDE.md` (this workflow's convention, never `AGENTS.md`). If `CLAUDE.md` doesn't exist but `AGENTS.md` does, edit `AGENTS.md` instead — don't create a second file duplicating its role. If neither exists, create `CLAUDE.md` with just this block.

If an `## Agent skills` section already exists, update it in place — don't append a duplicate, don't touch surrounding sections. Otherwise append:

```markdown
## Agent skills

### Issue tracker
GitHub issues, PRs-as-request-surface off. See `docs/agents/issue-tracker.md`.

### Triage labels
Canonical three-role vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs
[single-context | multi-context — pick the one you wrote in step 3]. See `docs/agents/domain.md`.

### Lessons
Learned rules, read by `/rumo build`'s planner and reviewer. See `docs/agents/lessons.md`.
```

## Report

Table: file → `created` / `kept: <path>` / `skipped-with-reason`, plus the `origin/HEAD` line from recon. One line naming which skills now read from these files (`/rumo`, `review`), and that `docs/agents/*.md` can be hand-edited later without re-running this. Do not commit — the user commits.

End with the NEXT line (`clear` / `keep-open until <X>` / `rewind to <Y>`).
