# Build mode

`/rumo build <target>` — turn an aligned work item into shipped code. The only `/rumo` mode that writes source. Every build starts in a **fresh window**: if the align phase that produced `<target>` is still open here, `/clear` first.

In build, the main session is the **orchestrator**: it plans through `rumo:planner`, dispatches typed builders, accepts each step with a command, and runs the review gate. It keeps its own context thin — briefs, reports, `--stat`, command results — and leaves full diffs to the reviewer.

## 1. Resolve the target

- **T1** (`#42`, issue URL) → `gh issue view <N> --json title,body,comments,labels,updatedAt,url`.
- **Plan path** (`<worktree>/.rumo/plan.md` from an earlier session, or its copy in `~/.claude/learn/plans/`) → resume: `git -C <wt> status --porcelain -- . ':!.rumo'` must be empty (dirty → reset the uncommitted step per §6's reset rule), steps carrying `Done: <sha>` are skipped, then the drift stop in §3.3 and §4.
- **Free text** → judge honestly. Trivial → inline lane (§2), the reading you took recorded in the PR body. Already **ready** by align's five checks (behaviour, tagged criteria, out of scope, risk answered, terms in CONTEXT.md) → build it as a ticketless T1: save the prose as `<wt>/.rumo/spec.md` (its criteria tagged like a ticket's), which the review reads as the issue body; the PR body carries it, no issue stamp. Anything fuzzier → point at `/rumo` (align) and stop.

**The lane comes from a command, not from you**: save the issue JSON and run `bash <this skill dir>/scripts/build-size.sh <issue.json>`. Its one line decides:

- `SIZE fast` (≤ 2 criteria, all `[cmd]`, no risk) or `SIZE visual` (no `[cmd]` criterion: the planner would only write `orchestrator` steps) → **skip the planner**. Still create the worktree (§3.1); write a one-step plan in the template's shape yourself, with `Planned at:` and `Issue:` filled — the review still needs a spec — and continue at §5 (builder) or §2 (inline). The step turns out to need more than 2 files or ~150 lines → dispatch the planner then.
- `SIZE small` → §3.2 with `SIZE: small` in the brief.
- `SIZE normal` → §3.2.

## 2. Inline lane — what only the main session can do

These run inline, in the main session, with `tdd` at agreed seams and `review` at the close:

- **Trivial T0**: one clear file, one clear change, ≤ ~30 lines.
- **Visual steps** (`Type: visual`) — render-verify and `design-taste` only see the main session.
- **Judgment steps** (`Type: judgment`) — "done" is your call: decide, and record the call under Assumptions.
- **Hard bugs** — `diagnosing-bugs` needs its red loop in hand. Once the loop is red and the fix is specified, the fix itself can go to a builder.

Inline work on a T1 still happens in the feature worktree (§3.1) on `feat/…`/`fix/…` — the `build-guard` hook denies edits and commits in the main checkout once `/rumo build` ran in the session (override: the user writes `#main-ok`).

**Visual brief before the first visual edit.** Load `design-taste` — and `dataviz` too when the page shows metrics, charts or a dashboard — then write `<wt>/.rumo/visual-brief.md` (no worktree, as in a trivial T0: the session scratchpad), one short section each:

- **Purpose** — what the page is for, in the user's words ("billing dashboard", not "overview").
- **Content inventory** — every block the page carries, the step's and the ones already there.
- **Dominant element** — the one thing the eye lands on first.
- **Reference** — the approved prototype or a competitor screen as an absolute path to a local image (a URL → screenshot it into `<wt>/.rumo/` first, since the judge reads only files); none in the issue → write `none given`, name it under Assumptions in the PR body, and go on.
- **Rules that apply** — each `design-taste` lesson, `taste-log.md` rejection and project visual contract line this page can break (brand color as text, unstyled native controls, touch targets < 44px, flat layout, sticky bar over content…), quoted with its source.

**Lint and shoot in one command.** With the page served, run `bash <this skill dir>/scripts/visual-lint.sh --project <wt> --scheme both --shots <wt>/.rumo/shots [--name <slug>] <url>` on each changed page (a page with no dark theme: `--scheme light`), one served page and one browser at a time. It checks, at 390 with touch and at 1440: touch targets ≥ 44px (390 only), no horizontal scroll, an opaque sticky/fixed header with nothing under it, no unstyled native `select`/date/time control, no clipped or truncated text, text contrast (4.5:1, 3:1 for large text). Then it freezes animations, confirms the viewport width and saves one full-page image per viewport and scheme, printing a `SHOT <path>` line each: those files are the judge's evidence, always newer than the last edit. A state the URL alone doesn't show (open dialog, filled form, empty list) is shot by hand the same way — animations settled, width confirmed by eval — into the same directory. Exit 1 prints `FAIL <rule> @<viewport> <element> — <detail>` lines: fix them and log a `revise` before dispatching the judge — a lint failure never spends a judge run. Exit 2 with `visual-lint: env:` means no usable node or Playwright: say so in the step report and go on to the judge. Any other exit 2 (`cannot load <url>`, `check failed`) means the lint never checked the page: fix the serving or the URL and rerun, and never send the judge a page the lint could not load; still failing on a page that renders in the browser → say so in the step report, shoot by hand and go on to the self-check.

**Self-check before the judge.** Read the 390 shot and one 1440 shot yourself and write `<wt>/.rumo/visual-check.md`: one line per rule of the brief's *Rules that apply*, per inventory block and for the dominant element — `ok — <what the shot shows, which file>` or `broken — <what>`. Any `broken` → fix, rerun the lint command, rewrite the file. The judge is dispatched only when every line reads `ok` on shots taken after the last edit: 62% of judge FAILs broke a rule the brief itself listed. The file stays with you; the judge never sees it.

**Visual steps get an independent judge** before they are accepted: `Agent(subagent_type: "rumo:visual-judge")` with only the `SHOT` image paths (every viewport and scheme, plus the hand-shot states), the `design-taste` SKILL.md path, the absolute `visual-brief.md` path and the issue's `[visual]` criteria quoted — never your reasoning about the design. The judge's last line is `VERDICT: PASS` or `VERDICT: FAIL`; a reply without it is malformed, not a verdict — re-dispatch once, and a second malformed reply counts as a FAIL round. `VERDICT: FAIL` → fix, redo the lint command and the self-check, and dispatch a **fresh** judge with the same brief — never SendMessage the one that failed you: a resumed judge passes 82% of second looks, a fresh one 35%, and only the fresh one is independent. A third FAIL ends the visual step as not passed: the build goes on to review and opens its PR with the judge's FAIL lines under **Visual — not passed**, skips the merge (§8) and ends `waiting`. The user's own rejection still wins over a judge's PASS.

**A visual complaint about what this build just delivered is a fix in this build** — append it to the brief's rules, fix, re-screenshot, re-judge. It becomes a new ticket only when it asks for new scope (a page or behaviour the issue never named).

## 3. Plan

### 3.1 Worktree

Base = `dev`; no `dev` → the repo's documented base branch, else its default branch — `ship.sh` merges only into `dev`, so a PR on any other base stays open for the owner. Then:

```
git -C <repo> fetch origin <base>
git -C <repo> worktree add --no-track -b feat/<slug> ~/orca/workspaces/<repo>/<slug> origin/<base>
grep -qx '.rumo/' <repo>/.git/info/exclude || echo '.rumo/' >> <repo>/.git/info/exclude
```

`fix/<slug>` for bugs. `--no-track` keeps the feature branch from tracking `<base>` (a bare `git push` would land on it). Install deps once here (lockfile command); builders share this tree.

**Already in a worktree for this issue** (a `wave` launched you, or Orca created it under `~/orca/workspaces/<repo>/`): that directory is the worktree — skip the `worktree add`, rename the branch before the first commit (`git branch -m feat/<N>-<slug>`), add `.rumo/` to the exclude file as above.

Run each main-checkout command (`git -C <main> …`) as its own Bash call: `build-guard` denies the whole chain when one clause touches the main checkout.

**Env**: the worktree gets a `.env.local` holding only what differs (local DB, slot port). Build and test on `.env.local` with test values; copying the main checkout's real `.env` is a Critical question (§4), asked only when a step cannot run without the real keys — the owner's `#env-ok` lets `worktree-guard` pass the copy.

### 3.2 Dispatch the planner

`Agent(subagent_type: "rumo:planner")`, no `model` param (§3 of the router). Brief:

- the issue JSON (title, body, comments, labels);
- `PLAN PATH: <worktree>/.rumo/plan.md`, `TEMPLATE: <this skill dir>/references/plan-template.md` and `CHECK: <this skill dir>/scripts/plan-check.sh` (absolute) — it runs the check, never reads its source;
- `REPO: <worktree>` — it reads `CONTEXT.md`, ADRs and `docs/agents/lessons.md` itself.
- `FACTS ALREADY KNOWN:` the facts you already hold (a `rumo:scout` report, file sizes, line numbers, the lane's in-scope and out-of-scope files) — the planner treats them as settled instead of re-deriving them; omit the line when you hold none.
- `SIZE: small` when `build-size.sh` printed `SIZE small` (ticketless: the spec's risk answer is none and it has at most 3 criteria). The planner still runs; only its plan shrinks (≤ 2 steps, ≤ 8000 characters). Omit the line otherwise.

**While the planner runs** (it reads only; p50 7 min), do what never depends on the plan, each as a background command: the lockfile install, the repo's typecheck on the untouched tree (a red baseline is known before any builder is blamed for it), and for a UI issue the dev server on the slot port. Start nothing that writes tracked files.

It writes the plan and returns a summary block (STEPS, WAVES, RISK, SEAMS, OPEN QUESTIONS). Copy the plan to `~/.claude/learn/plans/<repo>-<slug>.md` (`<slug>` = the worktree's directory name, which wt-gc and `wave` look up) right away — removing the worktree from Orca's UI must not lose it.

### 3.3 Check the plan's form — not its content

`bash <this skill dir>/scripts/plan-check.sh <plan>` — add `--small` before `<plan>` when the brief carried `SIZE: small` — one call, not a read of the plan. It checks every step's nine fields, plain Files paths, Verify as a command with an expected output, the planner's Model rule (cited condition, `(4)` for any Risk), Rule A (a step whose Does names a push/merge/deploy/delete/shell command, or whose Files touch a hook dir or hook config, is `Risk: security`), Rule B (a `Risk: security` step's Test first lists `hook:`, `third-party input:`, `check-to-use:` and `deletion:` before `happy:`, each followed by a case or `n/a — <why>`), at most six steps (two with `--small`), disjoint Files between parallel steps, and the plan's size (≤ 24000 characters, 8000 with `--small`; the template aims at ~20k). `PLAN OK` → go on. Any `PLAN FAIL` line → send those lines back to the same planner (SendMessage) and re-run the check. `STEPS: NOT SMALL` in the planner's reply, or a `--small` limit still failing after one round → the issue is not small: the plan keeps the normal limits (when the limit failed and the planner did not say `NOT SMALL`, SendMessage it: not small, replan if a limit made you cut work) and every later check runs without `--small`; this is not a Critical question.

Stamp origin: `gh issue comment <N> --body "Plan: <plan path> (branch feat/<slug>)"`, and record in the plan's Status `Planned at: <SHA>` + `Ticket-synced-at: <updatedAt>`.

**Resuming a plan from an earlier session** → two-axis drift stop first: `git diff --stat <Planned at>..origin/<base> -- <all step Files>` and the issue's current `updatedAt` vs `Ticket-synced-at`. Either moved → re-dispatch the planner with the old plan and the drift, before any builder.

## 4. Gate — decide, record, go on

The issue and the brief are the design; the build runs on them. First run the review's path scan over the union of every step's Files (`printf '%s\n' <Files…> | rg -i '<review §0 pattern>'`): a hit on a step marked `Risk: none` counts as RISK — the planner doesn't grade its own risk unchecked.

SEAMS, RISK and OPEN QUESTIONS in the planner's summary are **Assumptions**, not stops: take the planner's recommended default for each, and write one line per item into the plan under `## Assumptions` — `<what was open> → <default taken> (<why>)`. That section goes into the PR body verbatim (§8), where the owner reads it after the fact and reopens what they disagree with. RISK needs no line: it routes the step to opus and the review to the sensitive tier.

Stop for the owner only on a **Critical question** — one where the wrong default cannot be taken back by a later commit, or where the answer has to be invented:

- a production deploy, a production DB write, deleting data, moving money, a message to a client or third party;
- copying a real `.env` or any secret into a worktree (`#env-ok`);
- a value nobody wrote down and the code can't supply: a price, a legal or contractual text, a credential, a provider or hostname choice;
- the issue contradicts itself or `CONTEXT.md` so that two readings give different products;
- a Waiver (only the owner's `#waive`).

A Critical question is asked once, in one message, with the default you would take and what it costs to be wrong; set the card to `BLOCKED: question — <one line>` first, and end `waiting` with it as `--pergunta`. Everything else — naming, structure, library choice inside the stack, a seam's shape, test strategy, which of two reasonable UX readings, whether to go on — is yours: decide and record. "May I go on?", "Do you authorize the next round?" and "Shall I open the PR?" are never Critical.

**Unattended** (an Orca automation, `claude -p`, a Worker with no human): the same rule; a Critical question ends the build with `BLOCKED: question` and the question as the Relatório's (report's) `--pergunta`.

## 5. Build in waves

Waves come from the planner's WAVES line; run them in order.

- **Model by step**: `Model: sonnet` → `rumo:builder`; `Model: opus` → `rumo:builder-opus`; `Model: orchestrator` → inline (§2). No `model` param.
- **Model limit**: a typed agent that dies on a usage limit (`rate_limit`, HTTP 429, "reached your … limit") is re-dispatched at once with the same brief, never waited on: a builder or planner → `general-purpose` with `model: "opus"` (the brief names the plan step and the contract the typed agent would have followed); a reviewer → `rumo:reviewer-sonnet` with the same `AXIS`/`RANGE` (it is review evidence; an untyped run is not); a visual judge → `general-purpose` with `model: "opus"` and the judge's whole brief plus the path of `agents/visual-judge.md` to follow. Name the fallback in the PR body under Assumptions.
- **Parallel**: dispatch every builder of a wave in one message, **5 at most at once** — a builder is cheap in RAM (it runs inside the `claude` process); what runs out of memory is the test suites and servers it starts, which `worktree-guard` caps machine-wide at 3 logical test runs when free memory is 30% or more, otherwise 2 (`RUMO_MAX_TEST_RUNS`, when set, is the exact limit) (it waits up to ~50 s for a slot before denying); they share the feature worktree because their Files are disjoint. A step whose Verify needs a database, a dev server or a fixed port runs in a wave of its own — those are shared state that disjoint Files don't separate.
- **Dependencies** are installed once in §3.1; a new one arrives as a `Model: orchestrator` step that you run inline between waves. Builders never install.
- **Builder brief** (the whole brief; the builder reads the rest from disk):

  ```
  WORKTREE: <abs path>
  PLAN: <abs plan path> — execute Step <n> only.
  COMMANDS: see the plan's "Commands you will need".
  PARALLEL: steps <m,…> are being built concurrently in other files of this worktree.
  ISOLATION: PORT=<base+n> TEST_DB=<name>_<n>   (only when steps in this wave touch a server or DB)
  FAILURE NOTES: <only on escalation: what the previous builder tried, the failing output>
  ```

## 6. Accept each step — by command

Wait until **every builder of the wave** has reported — a Verify run mid-wave sees a sibling's half-written files. Then one call accepts the whole wave:

```
bash <this skill dir>/scripts/accept-wave.sh <wt> <plan> --copy <plan copy> '<n>=<repo style>: <step title>' ['<m>=…' …]
```

It checks, then acts, per step:

1. **Scope**: every changed or untracked path of the worktree belongs to exactly one named step's Files; an extra or shared path, or an ignored `.env*` created after the plan file, prints `WAVE FAIL scope <path>` and nothing is accepted. A real need for the extra file → amend that step's Files in the plan (and its copy) and rerun; an accident → remove it. `git -C <repo> status --porcelain` on the main checkout stays as it was before the build.
2. **Accept**: `accept-step.sh` with the step's Verify, its code Files and its test Files — the Verify passes, runs more than zero tests, was not won by weakening tests, and goes red **on an assertion** without the step's code. A builder's RED→GREEN line is a claim; this is the evidence. A `judgment`/`orchestrator` step with no test is accepted on its Verify alone; a `visual` step also needs the judge's PASS (§2).
3. **Commit by path** and the `- Done: <sha>` line in the plan and its copy.

`STEP <n> ACCEPT OK <sha>` steps are done; a `STEP <n> ACCEPT FAIL: …` line goes to the rejection ladder while its siblings stay committed. A step that needs flags the wave call can't express (`--red` because its Verify chains typecheck or lint, `--expect`) is accepted alone with `accept-step.sh` and committed by hand.

Between waves, run the repo's typecheck and the test files of every step accepted so far — a cross-step break shows here first. After the last wave, start the typecheck and the full suite **in the background** on the committed HEAD and dispatch the review (§7) in the same turn: reviewers read fixed SHAs and nothing edits the tree while both run. A red suite is a fix step of the first fix round, with the review's findings. Long output goes to a file under `$TMPDIR`; read `tail -40` or `rg` it, never the whole log, into this window. A background command reports when it ends: never `sleep`, `pgrep` or re-read its log to wait for it.

**Rejection ladder** — one rung per failure, each rung recorded for the §9 batch:

1. **revise** — SendMessage to the same builder (cache is warm): the failing command and its output, nothing else. Once.
2. **escalate** — fresh `rumo:builder-opus` with FAILURE NOTES. A failed sonnet step never goes back to sonnet.
3. **replan** — the planner gets the step, both failures and outputs, and rewrites that step (or the plan).
4. **block** — a failure after replan stops the build: `failed`, with what failed, what was tried, and the planner's read.

Before a rung that restarts the step from scratch, reset only that step's Files: `git -C <wt> checkout -- <its tracked Files>` and `rm -f` the ones it marked `(create)` — other builders' files in the tree stay as they are.

## 7. Review

Run the `review` skill with fixed point `origin/<base>` (it picks the tier from the diff, a path scan and the plan's Risk fields; the issue — or `.rumo/spec.md` when ticketless — is the spec, the plan only while not stale). Leave the code untouched while it runs.

**Fixes**: only findings that survived the review's replay (review §2) become fix steps — a demoted one goes to the PR body as a question. Each fix step is written by you in the plan's step format (Model by the planner's rule) and goes through §5–6. Then the **fix re-review** as the review skill routes it, and a fresh stamp. **Minors and questions never open a round**: no fix builder and no fix reviewer for them. A review with no blocker or major is stamped as it stands; its minors go to the PR body and the Follow-up issue (§8), except the ones you fix inline in under 30 lines total, stamped with `--fix --inline-fix` (the script accepts the sensitive tier too when the fix touches no path of the review's §0 scan). **Rounds run on progress, not permission**: go on to the next fix round by yourself while each round closes at least one Open finding, up to four rounds; a round that closes none, or a fourth that leaves one open → block (§6 rung 4), naming the ids. A fix that changes a rule on one path greps every caller of the same operation first — 30 of the fixed majors were a fix that covered one call site. Never close a major yourself: an inline fix closes only minors, and a replay-demoted major stays open until a fix reviewer writes `WITHDRAWN`. A Waiver is the user's alone — `#waive <axis>#<n>` typed by them, never by you; log it as a finding `dismissed` with `"reason":"owner-waived"`. An unattended run whose stamp is refused for an Open finding opens no PR: it ends with `BLOCKED: open finding <ids>` and the PR body as text, and the user unblocks it from the lane's pane.

## 8. Ship

**CI red on the PR** → `rumo:extractor` reads `gh run view <id> --log-failed` and returns the failing job · step · test · first error line; the log never enters this window.

**Mandato first.** Before shipping run `python3 -I <rumo>/scripts/hooks-staged/mandato.py check <wt>` — it reads `<git-dir>/rumo-mandato.json`, the host's signed Mandato (mandate). `MANDATO valid alcance=<a> issue=<n>` (exit 0) → that alcance replaces the `AUTHORIZED:` extent: `pr` = push + PR, stop before the merge; `merge` = on through `wave.md` §Merging. `MANDATO refused <reason>` (exit 1) → ship nothing (the hook denies push, PR and merge anyway) and end `BLOCKED: mandato <reason>`. `MANDATO absent` (exit 3) → the rule below as it stands. A valid Mandato also has to name this build: its `issue` (printed by `check`) ≠ `#<N>` or its `repo` (read from the file) ≠ this repo's `owner/name` → ship nothing and end `BLOCKED: mandato scope` (Relatório `--motivo mandato`) — fields and an example in `wave.md` §4 (Mandato). A Mandato only narrows: it never unlocks a production deploy or production DB write.

**Ship is part of the build, not a question.** With the stamp on HEAD and the suite green, run `bash <this skill dir>/scripts/ship.sh <wt> --base <base> --issue <N> --title "<title>" --body-file <wt>/.rumo/pr-body.md [--followup-file <wt>/.rumo/followup.md] [--slot-env <the slot file you wrote>] [--no-merge] [--merge-default-branch]` after §9 (after a merge it deletes that slot file and removes the worktree). It performs the steps below and prints one `SHIP <step> ok|fail|skip` line each; `SHIP checks fail` → the CI rule above, `BASE MOVED` → the base-merge sequence in `wave.md` §Merging, then rerun it. The steps, in order:

1. `git -C <wt> push -u origin feat/<slug>` and `gh pr create --base <base>`; body = summary · `Closes #<N>` · **Assumptions** (the plan's section, verbatim; `none` when empty) · table step × model × first-try result · review findings and how each was handled · **Visual — not passed** when §2 ended that way.
2. The Follow-up issue (below).
3. **Merge** when every line holds: `<base>` is `dev` — or the repo's default branch in a repo with no `dev` whose CLAUDE.md says a stamped PR merges there without asking (only then pass `--merge-default-branch`; the script skips every other base); the PR's checks are green (`gh pr checks <PR> --watch` as a background command; no checks configured counts as green); no visual step ended not passed and no Critical question is pending (either one → pass `--no-merge`). Then the base-merge sequence in `wave.md` §Merging and `gh pr merge <PR> --merge`. A line that fails → the PR stays open and the build ends `waiting`, the Relatório's `--pergunta` naming the line.
4. **Clean up right after the merge**, from the main checkout, each its own Bash call: `git -C <repo> worktree remove <wt>`, `git -C <repo> branch -d feat/<slug>`, `git -C <repo> fetch --prune`, `rm ~/.claude/learn/plans/<repo>-<slug>.md`, and drop what §3.1 or the wave brief created for this slot (slot DB, dev server on the slot port). A worktree holding an env file the main checkout doesn't have keeps it (`SHIP cleanup skip`): `--slot-env` already removed the slot file you wrote, and any other env file waits for `wt-gc.sh --apply --with-env`, the owner's. Run §9 before this step — the plan and the transcript paths go with the worktree.

What stays the owner's, always: a PR into `main`/`master` of a repo that integrates in `dev` (a release), any production deploy, any production DB write — the hooks ignore every launch prompt for those, so a lane that needs one stops and reports. What narrows the above: a Mandato (`alcance=pr` stops after step 2), a wave go that said "até o PR" ("up to the PR", as the owner types it; its `AUTHORIZED:` line), or the owner saying so in this session. A headless run (`claude -p`) is denied `gh pr create` by the hook: it ends with the PR body and the Follow-up issue text.

**Follow-up issue** — right after `gh pr create`: every finding the PR body records as not fixed (each open minor, each question, each blocker or major a Waiver left open) goes into one issue, so it outlives the merge. A minor fixed inline stays out. `ship.sh` creates it from `--followup-file` (title `Follow-up #<PR>: <PR title>`, no label) and appends `Follow-up: #<issue>` to the live PR body; write that file with the body opening `Follow-up de #<PR>`, then three sections — **Minors**, **Questions**, **Dispensados (Waiver)** — one checklist line per finding: `- [ ] <axis>#<n> <severity> · path:line · summary`. `Follow-up:` is a plain reference, so the merge leaves the issue open; it lives in the tracker like any other, closed by whoever resolves it. A PR with no open minor, question or Waiver creates no issue and gets no `Follow-up:` line. An unattended run hands this issue text alongside the PR body; the issue is created when the owner opens the PR from the lane's pane.

A PR left open (`waiting`) is cleaned later by `bash <rumo>/scripts/wt-gc.sh --apply` (the owner's to run): it removes merged worktrees with their plan copies, and plans whose issue closed; a worktree holding an env file main doesn't have shows as ENV and needs `--apply --with-env`. Name it in PENDING.

## 9. Learn — before closing

Log through the script — it validates the schema, stamps `ts`, redacts secrets and rotates the file monthly. **One call per build**: every event as one JSON line on stdin, the `run` line last. All lines are validated before any is written, so a rejected batch is fixed and re-sent whole:

```
python3 -I <rumo>/skills/learn/scripts/learn.py event - <<'EOF'
{"repo":"<name>","issue":42,"kind":"escalate","step":2,"model":"sonnet","category":"api","why":"<gist of the failing output>","files":["src/x.ts"]}
{"repo":"<name>","issue":42,"kind":"finding","severity":"major","outcome":"fixed","axis":"bugs","model":"opus","category":"api","why":"<the finding in one line>","files":["src/x.ts"]}
{"repo":"<name>","issue":42,"kind":"run","steps":{"sonnet":3,"opus":2,"orchestrator":1},"first_try":{"sonnet":2,"opus":2,"orchestrator":1},"by_category":{"api":{"sonnet":{"steps":3,"first_try":2}},"auth/risk":{"opus":{"steps":2,"first_try":2}},"visual":{"orchestrator":{"steps":1,"first_try":1}}},"findings":{"blocker":0,"major":1,"minor":0,"question":0}}
EOF
```

(`<rumo>` = this skill's plugin root: two levels above this skill's base directory.) In `"model"`, `steps` and `first_try`, `opus` is the judgment tier's key, whatever model its agents pin (opus; fable was the whole tier's pin 2026-11-11..12 and the planner's 2026-11-15..17): a `rumo:reviewer`, `rumo:planner` or `rumo:builder-opus` result logs as `opus` — `learn.py` refuses `fable`. Event kinds: `revise · escalate · replan · block · scope · finding · run`. Every line except `run` requires `"category"`, one of `test · ui-logic · api · db-migration · data-model · config · build-tooling · refactor · integration · auth · perf · docs · visual · other` (`learn.py` `CATEGORIES`) — the step's Category, or the touched files' for a finding. A build that ends without this call leaves `/learn` calibrating blind — log before the closing block, also when the build stopped. A finding carries `"severity"` (required: `blocker · major · minor · question`), `"outcome"` (required: `fixed · dismissed · open`), `"axis"` (`bugs · standards · spec · security · fix · visual`), the reviewer's `"model"` (`opus · sonnet · haiku · orchestrator`). A `dismissed` finding also carries `"reason"` — `pre-existing` (real, but already at BASE outside the diff) · `by-design` (an ADR'd or documented tradeoff) · `owner-waived` (the user declined the fix) · `wrong` (the code or a command refutes it) · `unreplayed` (demoted to a question by replay, or left as one nobody reproduced); `event` refuses a dismissed finding without it. A red CI is not a finding: log it as a revise with `"env": true` — there is no `ci` axis or model. Add `"env": true` when the failure came from the environment (missing service, flaky infra, OOM) rather than the model — it keeps the Model-rule calibration honest. Then one `run` line per build, shaped like the example's last line: `"steps"` and `"first_try"` are objects `{sonnet|opus|haiku|orchestrator: n}` with `first_try` ≤ `steps` per model; `"by_category"` keys are the step Category or `<Category>/risk`, each model cell `{"steps":n,"first_try":m}`. A step with Risk ≠ `none` counts under `"<cat>/risk"`: risk routed it, so `stats` keeps it out of the Model-rule calibration. A step of Type `visual` counts under `"visual"` whatever its Category, so visual work is measured apart from `ui-logic`; its events carry `"category":"visual"` too, and each judge FAIL is a finding with `"axis":"visual"` whose `why` names the brief rule it broke, when one did.

Findings carry their fate: `"outcome":"fixed"` when a fix step resolved them, `"dismissed"` when demoted by replay, left as a question, or set aside (its `"reason"` says which), `"open"` when shipped as known — `/learn review` uses the dismissal rate to tell which reviewer habits waste rounds. When this build logged any revise/escalate/replan/block/finding, print up to 3 **lesson candidates** (one imperative line each, with the event that earned it) and point at `/learn`; a clean build prints none. Nothing is promoted from here.

## Closing every build

```
DONE: what shipped (commits, PR + merge state, tests passing)
REVIEW: which tier ran on which range — or "review did not run"
PENDING: what remains, what was NOT verified end-to-end (or "nothing")
```

Then the Relatório — in every end, each `BLOCKED:` included — printed by `python3 -I <rumo>/skills/rumo/scripts/relatorio.py emit --estado <e> [--issue <N>] [--pr <url>] [--merged] [--motivo <slug>] [--pergunta "<one line>"]` (exit 2 names the invalid field; fix and rerun):

- merged and cleaned up → `ready` with `--merged` (only with `--pr`);
- PR open and a merge line of §8 failed, or a Critical question → `waiting` with `--pergunta`;
- `BLOCKED: question` → `"estado":"waiting"` with the question as `--pergunta`; any other `BLOCKED: <x>` → `"estado":"blocked"`, `--motivo` = `<x>` slugged to `[a-z0-9-]+` (`gate`, `lint`, `judge`, `open-finding`, `mandato`);
- tests or CI red past the rejection ladder → `failed` with `--motivo` (`tests`, `ci`);
- path abandoned → `dropped`; review still running → `progress`.

```
RELATÓRIO: {"estado":"blocked","issue":98,"pr":null,"merged":false,"motivo":"gate","pergunta":"Approve the Mandato seam?"}
```

Then the literal final line: `NEXT: clear` (merged, closed, or stopped) · `NEXT: keep-open until <X>` (a Critical question, a PR waiting on the owner) · `NEXT: rewind to <Y>` (path abandoned). Merge happens before `clear` whenever a worktree is in play.
