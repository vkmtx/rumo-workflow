# Hooks

rumo's skills describe the workflow; its hooks enforce the parts that must not depend on a model remembering a rule. The hooks live in `scripts/hooks-staged/` and are **opt-in**: installing the plugin does not install them, and no build ever writes to `~/.claude/hooks/`. You copy them there and register them in `~/.claude/settings.json` yourself. Without them every skill still runs, but nothing mechanically blocks a PR without a stamp, an env file copied into a worktree, or a test run beyond the machine's slots.

## What each hook guards

| Hook | Event (matcher) | Guards | Owner override |
|---|---|---|---|
| `pr-base-guard.sh` | `PreToolUse` (`mcp__github__create_pull_request\|mcp__github__merge_pull_request\|Bash\|Write\|Edit\|MultiEdit`) | PR and merge gates, production deploys and writes, the stamp and Mandato files | `#sem-review`, `confirmo`, a deploy request in the session |
| `worktree-guard.py` | `PreToolUse` (`Bash`) | env copies and remote migrations inside feature worktrees; machine-wide test concurrency; long `sleep` polling | `#env-ok` |
| `check-verify.sh` | `Stop` | JS-family edits finished without a passing verification | none needed: blocks once |
| `render-verify.sh` | `Stop` | visual edits finished without fresh desktop and phone screenshots that were read | `.claude/no-render-verify` in the repo |
| `context-nudge.py` | `UserPromptSubmit` | context growth; a build or wave started in a full window | `#same-window` in the prompt |
| `owner_message.py` | library | the single rule for which transcript text is the owner's own message | — |
| `mandato.py` | library + CLI | Mandato signing and checking | — |

The two libraries are installed **beside** the hooks that import them. A hook installed without `owner_message.py` fails closed (no override counts); `pr-base-guard` fails closed (refused) when a Mandato file exists but `mandato.py` can't be imported.

### pr-base-guard

Two intensities: **note** (context the agent reads and acts on, such as the PR base or a reminder to review) and **deny** (blocked with a reason). Deny works under `--dangerously-skip-permissions`. It denies, among others:

- PR creation or merge when the review stamp does not cover the target commit, except a docs-only diff (`*.md`, `*.mdx`, `docs/`) or `#sem-review` ("no review") in your latest message;
- any write to `rumo-review.ok` other than `review-stamp.sh`;
- a production deploy (for example `vercel deploy`/`--prod`, `firebase deploy`, `eas submit`) without a deploy request from you in this session;
- destructive production database writes and production seeds without the word `confirmo` ("I confirm") in your latest message;
- any deploy, merge, or push to `dev`/`main` in an unattended automation worktree, and `gh pr create` from a headless (`claude -p`) build;
- under a Mandato: a refused Mandato blocks PR, merge and push; `alcance=pr` blocks merges and pushes to `dev`/`main`/`master`; writing or deleting the Mandato file, writing the key, or any Bash command naming the key or `~/.config/rumo`.

Launch prompts (messages with a line starting `AUTHORIZED:`, `WAVE BRIEF:` or `LAUNCHED-BY:`) never count as your request. The override words are matched as typed input and stay in Portuguese where you would type them (`confirmo`, `#sem-review`). It fails open without `jq`, on empty or malformed input, or on a git error, except for named fail-closed cases around merges.

### worktree-guard

Scope: commands whose cwd is under `~/orca/workspaces/` or that name that root (override the home with `WORKTREE_GUARD_HOME` for tests). Rules in precedence order:

1. **Env copy:** `cp`/`ln`/`rsync`/`install` with a `.env` or `.env.*` source (except `.example`, `.sample`, `.template`), `cat .env > x`, and many indirect forms (heredocs fed to interpreters, `xargs cp`, pipes into `tee`) are denied. `#env-ok` in your latest real message allows it.
2. **Migrations** (prisma, drizzle, rails, knex, sequelize, alembic, typeorm, `npm db:*`, `supabase db push|reset`) are denied when the target database is not local. Only the host is printed, never credentials.
3. **Test concurrency** (all scopes): jest, vitest, `<pm> test`, or rumo's `accept-step.sh` wait for a slot (polling every `RUMO_TEST_POLL_S`, default 3 s, for up to `RUMO_TEST_WAIT_S`, default 50 s), then are denied naming the PIDs holding the slots. The limit is `RUMO_MAX_TEST_RUNS` when set, else 3 with free memory ≥ 30%, else 2. Stale, stopped or idle runners don't count. jest/vitest without a worker cap in a worktree gets a nudge.
4. **Sleep polling** (nudge only): `sleep N` with N ≥ 120 s.

The hook's settings `timeout` must exceed `RUMO_TEST_WAIT_S`: 70 s for the default.

### check-verify and render-verify

Both are `Stop` hooks with the same shape: anchor on your last real message, block **once** (they honour `stop_hook_active`), fail open on any error.

- **check-verify** blocks when JS-family source files (`ts tsx js jsx mjs cjs mts cts vue svelte astro`) inside the session's repo or its worktrees were edited, the repo has an npm check script, and no passing verification command ran after the last edit. It names the exact command to run.
- **render-verify** blocks when visual files (`css scss sass less tsx jsx vue svelte astro html`) were edited but fewer than two screenshots (desktop and phone) were taken **and read** after the last edit. A repo with `.claude/no-render-verify` is skipped (video compositions, print documents).

Files outside the repo (scratchpad, `$TMPDIR`) never count. `VERIFY_HOOK_EXPLAIN=<file>` appends a JSON classification line per run, used by the replay harness.

### context-nudge

Measures the context of the transcript's last assistant message. Any prompt gets one nudge per band crossed (200k, 300k, 400k, 500k, 800k; `CONTEXT_NUDGE_LEVELS` overrides). A compaction lowers the recorded band so the next crossing nudges again. Only `/rumo build` or `/rumo wave` typed into a window above `CONTEXT_BUILD_MAX` (120k) is blocked, with the instruction to `/clear` and repeat; `#same-window` in the prompt bypasses it. It never blocks anything else and fails open.

### Referenced but not shipped

`skills/rumo/references/build.md` mentions a `build-guard` hook that denies edits and commits in the main checkout once `/rumo build` ran in the session (override `#main-ok`). It is not part of `scripts/hooks-staged/`; the build's instruction to run each main-checkout command as its own Bash call is written for it.

## Install

1. Copy the hooks and their libraries:

   ```bash
   mkdir -p ~/.claude/hooks
   cp scripts/hooks-staged/*.sh scripts/hooks-staged/*.py ~/.claude/hooks/
   chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/worktree-guard.py ~/.claude/hooks/context-nudge.py
   ```

2. Register them in `~/.claude/settings.json`. An example, using the events and matchers each hook's header declares:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         { "matcher": "mcp__github__create_pull_request|mcp__github__merge_pull_request|Bash|Write|Edit|MultiEdit",
           "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/pr-base-guard.sh" }] },
         { "matcher": "Bash",
           "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/worktree-guard.py", "timeout": 70 }] }
       ],
       "Stop": [
         { "hooks": [
           { "type": "command", "command": "$HOME/.claude/hooks/check-verify.sh" },
           { "type": "command", "command": "$HOME/.claude/hooks/render-verify.sh" } ] }
       ],
       "UserPromptSubmit": [
         { "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/context-nudge.py" }] }
       ]
     }
   }
   ```

   Merge this into your existing settings; don't replace them.

3. Re-copy after pulling a new rumo version. The staged copies in the repo are what the tests cover; the live copies are yours.

## Test

Each hook has a test under `scripts/hooks-staged/tests/`. A `<name>.test.sh` takes the hook path from `HOOK`, defaulting to the staged sibling:

```bash
bash scripts/hooks-staged/tests/worktree-guard.test.sh                                   # staged copy
HOOK=~/.claude/hooks/worktree-guard.py bash scripts/hooks-staged/tests/worktree-guard.test.sh   # live copy
python3 -I scripts/hooks-staged/tests/mandato_test.py
python3 -I scripts/hooks-staged/tests/owner_message_test.py
```

Each prints `PASS`/`FAIL` per case and exits 1 on any failure. `replay-blocks.test.sh` replays recorded hook decisions from git history and exits 77 (SKIP) outside a git checkout. `bash scripts/test-all.sh` runs everything and sets `HOOK` automatically for `<dir>/tests/<name>.test.sh`.

For what a denial means and what to do about it, see [[FAQ and Troubleshooting]].

Next: [[Discipline Skills]]
