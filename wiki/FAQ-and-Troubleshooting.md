# FAQ and Troubleshooting

Symptoms first, cause second, what to do third. For the concepts behind the answers see [[Core Concepts]]; for each hook's rules see [[Hooks]].

## I edited a skill or agent and the session still behaves the old way

Claude Code runs a **cached copy** of the plugin under `~/.claude/plugins/cache/rumo/`, not your checkout. A session reads new text only after the plugin's `version` changes. In a rumo checkout:

1. Bump `version` in `.claude-plugin/plugin.json` (the maintainers do this inside the pre-merge base-merge commit; see [[Contributing]]).
2. Run:

   ```bash
   claude plugin update rumo@rumo
   ```

3. Start a new session. A session already open keeps what it loaded.

Two related cases:

- The installed plugin's agents shadow `--plugin-dir`, so a **new** agent can be verified only after the bump and the update, with a bare run of `scripts/smoke-agents.sh` (see [[Agents]]).
- `/rumo help` must print the case map after an install; if the command is unknown, the plugin is not installed or not enabled for this scope (see [[Getting Started]]).

## `gh` is not authenticated, or is too old

Every tracker operation goes through the `gh` CLI (issues, sub-issues, blocking links, PRs, merges); rumo never assumes a GitHub MCP server.

- Symptom: `/rumo ticket` cannot publish, a build cannot push or open its PR, or `gh` prints an authentication error.
- Check: `gh auth status`. Fix: `gh auth login`, run by you in your own terminal (credentials never go through the chat), then repeat the command.
- Access: the account needs write access to the repository (issues and pull requests), and a `gh` recent enough to support the sub-issue and blocking-link options (`--parent`, `--blocked-by`).
- Old `gh`: the `pr-base-guard` hook reads the PR head with `gh pr view --json headRefOid,headRefName,baseRefName,isCrossRepository`. A `gh` that lacks those fields makes a merge fail closed; see "Blocked: the installed gh ..." below.
- Without a working `gh`, the stages that need GitHub stop. A build keeps its worktree and branch, so you can fix `gh` and resume from the plan.

## What does a `NEXT:` line mean?

Every orchestrator turn of `/rumo`, `/setup-repo`, `review` and `/learn` ends with exactly one literal line telling you what to do with the window:

| Line | Meaning |
|---|---|
| `NEXT: clear` | The work of this window is finished (and merged, if a worktree was involved). Type `/clear` before the next task. |
| `NEXT: keep-open until <condition>` | Something still depends on this window's context, for example an answer you owe or a step that continues here. Stay until the condition holds. |
| `NEXT: rewind to <point>` | The conversation took a wrong turn; rewind to that point instead of correcting forward. |

The line is a convention, not a command: nothing runs because of it. Launchers such as `/rumo wave` read a separate machine-readable `RELATÓRIO:` (report) line instead. See [[Core Concepts]].

## Why did a build stop and ask me a question?

A build runs from start to merge without asking. It stops only on a **Critical question**: one where a wrong default could not be taken back by a later commit, or where the answer would have to be invented. Typical triggers:

- a production deploy, a production database write, deleting data, moving money, or a message to a client or third party;
- copying a real `.env` or any secret into a worktree;
- a value nobody wrote down: a price, a legal text, a credential, a provider or hostname;
- the issue contradicts itself or `CONTEXT.md`, so two readings give different products;
- a Waiver, which only you can grant by typing `#waive`.

What you see: the build sets its Orca card to `BLOCKED: question — <one line>`, ends with status `waiting`, and puts the question in the Relatório (report). An unattended run (no human in the session) follows the same rule and ends `BLOCKED: question`. A Critical question is asked once, in one message, with the default the build would take and the cost of being wrong. Answer it and rerun the build on the same target: it resumes from its plan file, and steps already marked `Done: <sha>` are skipped.

Everything that is not critical becomes an **Assumption**: one line in the plan's `## Assumptions`, copied verbatim into the PR body, where you can reopen what you disagree with. If a build keeps asking about something cosmetic, record a `/learn` lesson. See [[Mode build]].

## A build ended `waiting` after opening the PR

The PR is open but a ship step did not pass: `ship.sh` prints one `SHIP <step> ok|fail|skip` line per step and stops at the first fail. Common reasons are failing checks on the PR, a base other than `dev` (the PR stays open for you), a visual step that did not pass, or a pending Critical question. Read the failing `SHIP` line in the Relatório, fix the cause and run the ship step again. See [[Mode build]].

## A hook denied my command

The hooks are opt-in (see [[Hooks]] for the install). When one denies, the reason text is shown to the agent verbatim. The most common ones, with the real message text from `scripts/hooks-staged/`:

### pr-base-guard

| Message begins | Meaning and what to do |
|---|---|
| `Review does not cover the current HEAD (no stamp vs <sha>).` | A PR or merge was attempted and no review stamp exists for that commit. Run the `review` skill to its end; `review-stamp.sh` writes the stamp. The message adds that "a 'merge tudo' authorizes the merge, it does not skip the review." |
| `Review does not cover the current HEAD (<stamp> vs <sha>).` | The stamp is older than the target. If the later commits are your own, run the review's fix axis over `<stamp>..<sha>` and stamp with `review-stamp.sh --fix`; if it is the merge of `origin/<base>` before the PR merge, use `review-stamp.sh --base-merge`. If the stamp is not an ancestor (another branch or a rebase), run the full review again. |
| `Blocked: the review stamp (rumo-review.ok) is written only by review-stamp.sh ...` | Something tried to write the stamp by hand. Never do this: run the review, then the script, which requires the reviewer's transcript from this session. |
| `Blocked: PRODUCTION DEPLOY/PUBLISH with no deploy request from the user in this session.` | A deploy command ran without you asking for a deploy. Ask in one line what will ship and where, and run it only after the owner asks. To validate without publishing: `vercel build` or `firebase deploy --dry-run`. |
| `Blocked: DESTRUCTIVE WRITE TO THE PRODUCTION DATABASE (no PITR = no undo).` | Restate the scope, show the per-table count of affected rows, save them to the scratchpad, then the owner replies `confirmo` ("I confirm"). With that word in the latest message the command passes. |
| `Blocked: this seed script writes straight to the PRODUCTION RTDB ...` and `Blocked: this publishes a BLOCKING version FLOOR ...` | Production Firebase writes also need `confirmo` (or a deploy request, for the app-version node). `--dry-run` shows the write without sending it. |
| `Blocked: unattended automation does not open PRs; leave the PR body in the report.` | A headless (`claude -p`) build tried `gh pr create`. Put the PR body in the report and let the owner open it. |
| `Blocked: this is an Orca automation worktree running with no human in the session.` | Unattended automation does not merge, push to `dev`/`main` or deploy. Record what would be done in the final report. |
| `Release <base>←dev blocked: ...` | A release merge (`dev` into `main`/`master`) could not prove that every commit came from a PR merged into `dev`: the PR head is not in the checkout (`git fetch origin`), more than 200 commits (split the release or ask for `#sem-review`), or the listed commits were pushed directly. |
| `Blocked: the installed gh does not accept gh pr view --json ...` | `gh` is too old to let the hook read the PR head. Upgrade it (`brew upgrade gh` or your package manager) and merge again. |
| `Blocked: gh did not resolve the PR URL ...` | Network trouble, or a URL the hook cannot check. Run `gh pr merge <N>` with the number, in a checkout of the PR's repo. |
| `Blocked: the merge target comes from a substitution/variable ...` | Pass the literal PR number. A `--base` taken from a variable is refused the same way: `Blocked: the PR base comes from a variable/substitution; pass a literal --base (main/master/dev).` |
| `Blocked: Mandato refused (<reason>) ...` | The Mandato (mandate) a wave host signed for this lane is tampered with, from another worktree or branch, or unreadable. Stop and report; only the host rewrites it. See [[Mode wave]]. |
| `Blocked: this lane's Mandato has alcance=pr ...` | The lane may open a PR but not merge or push to `dev`/`main`/`master`; those belong to the owner. |
| `Blocked: the Mandato (rumo-mandato.json) and the key ... belong to the host ...` | Only the host writes or deletes the Mandato file or its signing key; nothing else may write them or name them in a command. |

The override words are matched as typed input and stay in Portuguese: `#sem-review` ("no review") and `confirmo` ("I confirm"). `#sem-review` in your latest message unlocks the review gate for that command; use it only for work you consciously accept unreviewed. Launch prompts (`AUTHORIZED:`, `WAVE BRIEF:`, `LAUNCHED-BY:`) never count as your message.

### worktree-guard

| Message begins | Meaning and what to do |
|---|---|
| `Builders/worktrees do not copy .env from another checkout.` | Prefer a `.env.local` with only what changes (local database, ports). If the owner really wants the copy, they reply with `#env-ok` and it passes. |
| `supabase db push in a worktree without --local ...` | The default target is the linked (remote) project. Run with `--local` or ask. |
| `supabase against the remote project (--linked/non-local --db-url) in a worktree ...` | Run it locally or stop and ask. |
| `Migration in a worktree pointing at a non-local database <host> ...` | Run the migration against the local database. Only the host is printed, never credentials. |
| `<N> test runs are already running ... (limit <L> on this machine, by memory; PIDs: ...) and none finished within <S> s of waiting.` | Test slots are full. Run the same command again (the hook waits again); do not poll with `ps` or `sleep`. `kill <pid>` only for a stuck PID of your own. Use `--maxWorkers=2` on jest and vitest. Limits are listed in [[Configuration]]. |
| `worktree-guard did not finish reading this command within its time budget and blocks instead of allowing.` | The command was too complex to analyse in time; split it into smaller parts. |

### Stop hooks and context-nudge

- **check-verify** (blocks once): `Source files changed and nothing verified them: <files>.` Run the command it names, paste the output, and fix what it reports. If the diff genuinely has no runnable check, say so in one line and continue.
- **render-verify** (blocks once): `Visual files changed (<files>) but only <n> image(s) were screenshotted and Read AFTER the last visual edit (need 2 distinct images: desktop 1440 and phone 390).` Render the page, take both screenshots and read them. For a repository where this never applies (video compositions, print documents) create `.claude/no-render-verify`.
- **context-nudge**: `A build starts in a fresh window: this one is already at ~<N>k tokens and every build turn would re-read all of it. Type /clear and repeat: ...` Do what it says, or add `#same-window` to keep the window on purpose.

## A hook is silently not doing anything

All hooks fail open on malformed input, a missing `jq` or a git error, except at irreversible boundaries (merge-head verification, an unverifiable Mandato, unreadable reviewer reports). Check that `jq` is installed, that the hook is registered in `~/.claude/settings.json`, and that the libraries `owner_message.py` and `mandato.py` sit **beside** the hooks that import them. Run the hook's test (`bash scripts/hooks-staged/tests/<name>.test.sh`) to see whether the copy you installed behaves like the staged one.

## Where else to look

- Terms: [[Glossary]].
- A review that blocks: [[Review Gate]], section "Open findings, fixes and Waivers".
- A wave lane that stalled or died: [[Mode wave]], sections "Watch" and "Recover".
- Bugs and feature requests: open an issue in the repository. Anything that names a vulnerability or credential location goes through private reporting (see `SECURITY.md`), never a public issue.

Next: [[Contributing]]
