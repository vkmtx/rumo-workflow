---
name: review
description: 'Pre-PR review gate, tiered by diff size and risk: Bugs, Standards and Spec axes run in parallel by clean-context reviewers on fixed SHAs, findings replayed before any fix, issue criteria checked mechanically, a review stamp tied to HEAD. Use before any PR, at the close of any build, or when asked to review a branch/diff.'
---

Each axis reports under its own heading and is **never merged or reranked** with another — a diff can pass one axis and fail another. Axes are independent read-only passes on fixed SHAs, so they run **in parallel**.

## 0. Pin the range, pick the tier

Fixed point = whatever the user names (SHA, branch, tag, PR); unstated → `origin/dev`, or `origin/HEAD` in a repo without `dev` (reviewing is read-only). Pin `BASE=$(git merge-base <fixed-point> HEAD)` and `HEAD=$(git rev-parse HEAD)`; every axis gets those two SHAs. `git diff --stat $BASE..$HEAD` non-empty, or stop. Leave the code untouched until the review reports.

Find the spec: the **issue** is the authority (an issue number in the commits or branch, or the plan's `Issue:` line; a ticketless build's `.rumo/spec.md` stands in for it); `.rumo/plan.md` in this worktree is the secondary spec. A plan is stale — and is not used as spec — when `git log <Planned at>..HEAD` has commits that no `Done:` line names.

| Tier | When | Axes |
|---|---|---|
| **light** | < 50 changed lines (`git diff --shortstat $BASE..$HEAD`), no sensitive risk, no change to an agent definition or SKILL.md frontmatter | bugs, then spec inline (§3) |
| **standard** | everything else | bugs ∥ standards ∥ spec |
| **sensitive** | label `risk:sensitive`, any plan step with `Risk` ≠ `none`, or the path scan hits — the scan wins over a plan that says `none` | standard ∥ security |

Path scan: `git diff --name-only $BASE..$HEAD | rg -i '((^|/)(auth|migrations?)/|\.env|schema\.(prisma|sql)$|secret|passw|crypt|payment|billing|stripe|checkout|\.github/workflows/|dockerfile|docker-compose|(^|/)rls|polic(y|ies)\.sql$)|^scripts/hooks-staged/|^hooks/|^skills/review/|^agents/[^/]+\.md$|(^|/)\.claude/settings[^/]*\.json$|^\.claude-plugin/marketplace\.json$|^scripts/(install|install-hooks|sync-host|host-lib)\.sh$'` — any hit → sensitive. Also sensitive by reading the diff: shell exec, money/entitlement, public input parsing, a dependency with native code.

The user naming one axis ("just standards") or asking for the built-in engine (`/code-review`) overrides the tier: run exactly that, same report shape. On the sensitive tier, security runs too.

## 1. Dispatch the axes — one message

Every axis is `Agent(subagent_type: "rumo:reviewer")` — only the fix re-review outside the sensitive tier (Fixes below) goes to `rumo:reviewer-sonnet` — no `model` param, with `RANGE: $BASE..$HEAD`, `REPO: <path>`, `TIER: <tier>` and its `AXIS:`. Dispatch all of the tier's axes **in a single message** so they run in parallel; each starts from a clean context, so none inherits the reasons the builder had.

- **bugs** — nothing else in the brief.
- **security** — nothing else in the brief.
- **standards** — the brief inlines the smell baseline below. The repo overrides the baseline; an ADR'd tradeoff is by-design.
- **spec** — first run the issue's `[cmd]` criteria mechanically, then put the table in the brief with the issue number and the plan path when not stale:
  1. `bash <rumo>/skills/rumo/scripts/issue-trust.sh <owner/repo> <N>` — exit 0 only when the author and every editor of the body have write access. Anything else (1 untrusted, 2 can't verify) means the body could carry someone else's commands.
  2. Save the body (`gh issue view N --json body -q .body > "$TMPDIR/issue-N.md"`) and run `bash <rumo>/skills/rumo/scripts/issue-criteria.sh <repo> "$TMPDIR/issue-N.md" $HEAD`, adding `--trusted` **only** after exit 0 above. Untrusted → the table shows `NOT RUN` rows; read those commands yourself before running any by hand. A ticketless build's `.rumo/spec.md` was written from the user's own prose: pass `--trusted`. `<rumo>` = this plugin's root, two levels above this skill's base directory.
- **wave lane** — add `BRIEF: <wave brief path>` to the standards, spec and fix briefs: its contract is part of the scope.

Fowler smell baseline (*Refactoring*, ch.3 — name → fix cue): **Mysterious Name** → rename · **Duplicated Code** → extract · **Feature Envy** → move the method · **Data Clumps** → bundle into a type · **Primitive Obsession** → give it a type · **Repeated Switches** → polymorphism or a shared map · **Shotgun Surgery** → gather into one module · **Divergent Change** → split by reason · **Speculative Generality** → delete it · **Message Chains** → hide behind one method · **Middle Man** → call the target direct · **Refused Bequest** → compose.

## 2. Replay every blocker and major

Before reporting, for each blocker/major finding with a `proof:` command, run it in an archive copy of `$HEAD` (`d=$(mktemp -d) && git archive $HEAD | tar -x -C "$d"`). Reproduces → keep. Doesn't → demote to a QUESTION and say so; for the stamp it stays an Open finding until a fix reviewer writes `WITHDRAWN`. A finding without a runnable proof stays as reported, marked `unreplayed`. A proof that needs env gets a minimal `.env.local` (test values only) in the copy; real `.env` files are copied only after the user's `#env-ok`.

## 3. Light-tier spec, inline

Run `issue-criteria.sh` when an issue exists, then list each remaining criterion as met · not met · not checkable, plus any changed file the spec didn't call for. No spec found → print exactly: `Spec axis skipped — no originating issue or plan found for this diff.`

## Report and close

Headings `## Bugs`, `## Standards`, `## Spec`, `## Security` (those that ran), most-severe first within each. Each finding keeps its id `<axis>#<n>` and the reviewer's model: build logs them with the finding event (build §9). Then one line: `TIER: <tier> · RANGE: <BASE7>..<HEAD7>` and the worst finding per axis.

**Stamp**: `bash <rumo>/skills/review/scripts/review-stamp.sh --tier <tier> --base $BASE` (add `--axes <list>` when the user named the axes; `$BASE` must be the fork point — the merge-base with `origin/dev`, or `origin/HEAD` without `dev` — or the script refuses). It needs network (`git ls-remote`): offline → exit 2, rerun once online. It is the only writer of `rumo-review.ok`: it requires a finished `rumo:reviewer*` run of this session for each of the tier's axes on `RANGE: $BASE..$HEAD`, and refuses while an **Open finding** remains — a blocker or major that no fix reviewer marked `RESOLVED`/`WITHDRAWN` and the user did not waive (**Waiver**: the user types `#waive <axis>#<n>`; no skill writes it). The PR/merge hook denies any other write to the stamp and any HEAD the stamp doesn't cover.

**No blocker or major → stamp now**; minors never get a fix round. **Fixes** get a fix re-review of the fix range only, against the findings by id: `AXIS: fix` lists each as `RESOLVED`/`NOT RESOLVED`/`WITHDRAWN <axis>#<n>`. No stamp (refused for an Open finding) → `RANGE: <R>..$HEAD`, R = the HEAD the axes reviewed (every round), then the same `--tier` command. With a stamp, a fix range < 30 lines touching no §0-scan path, closing minors only, is checked inline on any tier and stamped with `--fix --inline-fix` (the script re-checks size, the path scan and Open findings); anything larger gets `RANGE: <stamp>..$HEAD` (`<stamp>` = `awk 'NR==1{print $1}' "$(git rev-parse --git-dir)/rumo-review.ok"`), then `--fix`. Checking a finding against its proof is replay, not judgment.

**Base merge** — after `git merge origin/<base>` (+ any version bump): `bash <rumo>/skills/review/scripts/review-stamp.sh --base-merge` re-stamps with no reviewer if the merge is mechanical (first parent = stamp; conflicts kept ours/theirs/both, lines untouched; only `"version"` added). Refused → fix re-review.

End the turn with the NEXT line.
