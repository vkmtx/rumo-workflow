# Handoff Plan Template

Every plan is written for builders with **zero context** (`rumo:builder` is sonnet): they have not seen the issue thread or any prior conversation, and each one reads only the step it was given plus the shared sections. Assume a builder is competent at following explicit instructions and weak at filling gaps, recovering from ambiguity, or knowing when to stop.

Three properties make a plan executable by a weaker model:

1. **Self-contained context** — everything needed is in the file: paths, code excerpts, conventions, commands.
2. **Verification gates** — every step ends with a command and its expected result. The builder never has to *judge* whether it succeeded.
3. **Hard boundaries and escape hatches** — explicit out-of-scope list, and "STOP and report" conditions instead of letting the model improvise when reality doesn't match the plan.

File: `<feature worktree>/.rumo/plan.md` — one plan per worktree, never committed (`.rumo/` is in `.git/info/exclude`); it dies with the worktree after merge. The planner writes it; the orchestrator never edits its steps except to append fix steps after review.

Size: the whole plan stays ≤ ~20k characters; `plan-check.sh` fails it over 24000. Current-state excerpts are what inflate plans — keep each to a signature plus the few lines a step changes, and say a fact once (Current state or the step, not both).

---

## Template

```markdown
# Plan: <Imperative title — what will be true after this plan>

> **Builder instructions**: execute only the step your brief names. Read
> "Why this matters", "Current state", "Commands" and "STOP conditions"
> first — they apply to every step. If anything in "STOP conditions"
> occurs, stop and report.

## Status

- **Priority**: P1 | P2 | P3
- **Effort**: S | M | L
- **Risk**: LOW | MED | HIGH
- **Category**: bug | security | perf | tests | tech-debt | migration | dx | docs | direction
- **Planned at**: commit `<short SHA>`, <YYYY-MM-DD>
- **Branch / worktree**: `feat/<slug>` at `<abs worktree path>`
- **Issue**: <URL of the T1 issue this plan was promoted from
  (`/rumo build <issue-url>`); omit only for a plan with no originating issue>
- **Ticket-synced-at**: <ISO timestamp of the issue's `updated_at` at the
  moment this plan was written or last refreshed — present only alongside a
  ticket-born **Issue**; omit otherwise>

## Why this matters

2–5 sentences. The problem, its concrete cost, and what improves when this
lands. Written so the builder (and a human reviewer) understands the intent —
intent is what lets a correct judgment call happen when a detail is off.

## Current state

The facts the builders need, inlined — never "as discussed" or "see the issue":

- The relevant files, each with one line on its role:
  - `src/orders/api.ts` — order-list endpoint; contains the N+1 (lines 130–160)
- Excerpts of the code as it exists today: a signature plus the few lines a
  step changes (≤ ~8 lines, with `file:line` markers) — enough that a builder
  can confirm it's looking at the right thing; it reads the rest in the repo.
- The repo conventions that apply here, with a pointer to one exemplar file:
  "Error handling follows the Result pattern — see `src/lib/result.ts` and its
  use in `src/users/api.ts:40-60`. Match it."
- Any documented vocabulary or design constraints the plan must honor, inlined
  from the intent/design docs found in recon: the relevant `CONTEXT.md` terms
  builders should use in names and comments, the `DESIGN.md` tokens/components
  to reuse, or the ADR whose decision this work must stay consistent with. Quote
  the specific lines — builders have not read those docs.

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Install   | `pnpm install`           | exit 0              |
| Typecheck | `pnpm typecheck`         | exit 0, no errors   |
| Tests     | `pnpm test -- <filter>`  | all pass            |
| Lint      | `pnpm lint`              | exit 0              |

(Exact commands from this repo — verified during recon, not guessed. Test runners always capped: `--maxWorkers=2` (jest and vitest; Vitest 5 rejects `--poolOptions…`). A step's test command runs only that step's test file; the full suite runs once after the last wave.)

## Suggested builder toolkit

(Optional — include only when relevant skills/tools plausibly exist in the
builders' environment. Skip the section otherwise.)

- Skills the builders should invoke if available, and for what:
  "use `vercel-react-best-practices` when writing the memoization in step 3".
- Reference docs worth reading before starting, by path or URL.

## Scope

**In scope** (the only files you should modify):
- `src/orders/api.ts`
- `src/orders/api.test.ts` (create)

**Out of scope** (do NOT touch, even though they look related):
- `src/orders/legacy-api.ts` — deprecated path, scheduled for deletion;
  changing it wastes effort and risks the v1 clients still pinned to it.
- Any change to the public response shape — clients depend on it.

## Commit style

One example from `git log` (the orchestrator commits each step with it).

## Steps

### Step 1: <imperative title>
- Files: <exact paths; "(create)" for new ones>
- Does: <exact behaviour; symbols named; target shape when load-bearing>
- Test first: <the case(s) that go red before the code exists, and in which file; a new export of an existing module gets a stub first, so red is an assertion; Risk security: abuse cases first — `hook:` `third-party input:` `check-to-use:` `deletion:` (`n/a — <why>` when one does not apply), then `happy:`>
- Verify: `<command>` → <expected output>
- Type: cmd | visual | judgment
- Risk: none | money | auth | data | security | prod
- Category: test | ui-logic | api | db-migration | data-model | config | build-tooling | refactor | integration | auth | perf | docs | other
- Parallel with: <steps with disjoint Files and no dependency> | —
- Model: sonnet | opus | orchestrator — <reason; opus cites the failed condition, `(4) <risk>` for any Risk>

### Step 2: ...

(≤ 6 steps, each ≤ ~150 changed lines. Order them so the codebase is never
broken between steps — add the new path, switch callers, then remove the old.)

## Waves

`[1] → [2,3] → [4]` — derived from Parallel with; steps in one wave never share a file.

## Test plan

- New tests to write, in which file, covering which cases (list them:
  happy path, the specific bug/regression this plan fixes, named edge cases).
- Which existing test to use as the structural pattern:
  "model after `src/users/api.test.ts`".
- Verification: `<test command>` → all pass, including N new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `pnpm typecheck` exits 0
- [ ] `pnpm test` exits 0; new tests for <X> exist and pass
- [ ] `grep -rn "<old pattern>" src/` returns no matches
- [ ] No files outside the in-scope list are modified (`git status`)

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" doesn't match the excerpts
  (the codebase has drifted since this plan was written).
- A step's verification fails twice after a reasonable fix attempt.
- The fix appears to require touching an out-of-scope file.
- You discover the assumption "<key assumption>" is false.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- What future changes will interact with this (e.g. "if pagination is added
  to this endpoint, the batching in step 2 must be revisited").
- What a reviewer should scrutinize in the PR.
- Any follow-up explicitly deferred out of this plan (and why).
```

---

## Quality bar — check before finishing each plan

- Could a sonnet builder that has never seen this repo execute any single step with only that step, the shared sections, and the repo? If a step needs knowledge from elsewhere, inline it.
- Every lesson from `docs/agents/lessons.md` that bears on a step is quoted in that step.
- Is every verification a command with an expected result, not a judgment ("make sure it works")?
- Does every step name exact files and symbols, not "the relevant module"?
- Are the STOP conditions specific to this plan's actual risks, not boilerplate?
- Would a reviewer reading only "Why this matters" + "Done criteria" understand what they're approving?
- No secret values anywhere in the file — locations and credential types only.
- "Planned at" SHA is filled in, and the union of every step's Files equals the Scope section's in-scope list.
- Does every step that pushes, merges, deploys, deletes files, runs a command built from input, or that a hook must see carry `Risk: security` and the four abuse-case labels before `happy:`?
- Is the plan ≤ ~20k characters (`wc -m <plan>`)? plan-check fails it over 24000.
