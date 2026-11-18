# Configuration

rumo has no configuration file of its own. Its behaviour comes from conventions (branch names, worktree locations), from files it reads in your repository, from a small state tree under `~/.claude/learn/`, and from a few environment variables that the scripts and hooks honour. This page lists every path rumo reads or writes and every environment variable a user may set, with defaults taken from the scripts.

## Conventions

| Convention | Value | Where it matters |
|---|---|---|
| Integration branch | `dev`; else the documented base; else the default branch | build base, review fixed point, `ship.sh` merge target |
| Feature branch | `feat/<slug>`, `fix/<slug>`; `feat/<N>-<slug>` in a wave lane | build |
| Feature worktrees | `~/orca/workspaces/<repo>/<slug>` | build, `worktree-guard` scope |
| Repositories | `~/orca/projects/<repo>` | `wt-gc.sh` default scan, remote host clones (`wave-host.sh`) |
| Tracker | GitHub issues via `gh` only | every mode |
| Instruction file | `CLAUDE.md` (`AGENTS.md` only when it exists alone) | `/setup-repo` |

## Files in your repository

| Path | Written by | Read by |
|---|---|---|
| `CONTEXT.md` | align (`domain-modeling`), `/setup-repo` | every mode; terms used verbatim |
| `docs/adr/*.md` | `domain-modeling` | planner, standards reviewer |
| `docs/agents/issue-tracker.md` | `/setup-repo`, `ticket` self-heal | `ticket` |
| `docs/agents/triage-labels.md` | `/setup-repo`, `ticket` self-heal | `ticket` |
| `docs/agents/domain.md` | `/setup-repo` | sessions exploring the repo |
| `docs/agents/lessons.md` | `/setup-repo`, `/learn` | planner, standards reviewer |
| `CLAUDE.md` `## Agent skills` block | `/setup-repo` | Claude Code |
| `.gitignore` entry `.rumo/` | `/setup-repo` | git |
| `.claude/no-render-verify` | you | `render-verify` (skip the repo) |

## Files in a feature worktree

All under `.rumo/`, which is excluded from git (`.git/info/exclude`) and removed with the worktree.

| Path | Content |
|---|---|
| `.rumo/plan.md` | the T2 plan |
| `.rumo/spec.md` | a ticketless build's spec |
| `.rumo/visual-brief.md`, `.rumo/visual-check.md`, `.rumo/shots/` | the visual pipeline |
| `.rumo/pr-body.md`, `.rumo/followup.md` | inputs to `ship.sh` |
| `.env.local` | only what differs: local DB, slot port |
| `.claude/settings.local.json` | wave lanes: LSP plugins turned off by `wave-lane-prep.sh` |

## Files in the git directory

| Path | Written by | Read by |
|---|---|---|
| `<git-dir>/rumo-review.ok` | `review-stamp.sh` only (line 1: `<full HEAD sha> <tier> <timestamp>`, then base, mode, axes, runs) | `pr-base-guard`, `review-stamp.sh --fix/--base-merge`, `ship.sh` |
| `<git-dir>/rumo-mandato.json` | an external host, via `mandato.py sign` | `mandato.py check`, `pr-base-guard`, build §8 |

## Files under your home directory

| Path | Content |
|---|---|
| `~/.claude/learn/events.jsonl` | build events; rotated monthly to `events-YYYYMM.jsonl.gz` |
| `~/.claude/learn/lessons.md`, `lessons-archive.md` | global lessons and their archive |
| `~/.claude/learn/plans/<repo>-<slug>.md` | plan copies, deleted after merge |
| `~/.claude/learn/waves/<repo>-<wave>.md` | a wave's shared brief |
| `~/.claude/learn/waves/<name>.state/` | `repo` (owner/name), and per lane `<N>.json`, `<N>@<host>.json` or `<slug>.json` (launch results) |
| `~/.claude/projects/*/<session>.jsonl` | Claude Code transcripts, read by `learn.py`, `inbox.py`, `review-stamp.sh`, hooks, `wave-status.sh` |
| `~/.claude/plugins/cache/rumo/` | the cached plugin Claude Code actually runs |
| `~/.claude/hooks/` | live hooks, installed by you |
| `~/.claude/state/worktree-guard-slots.json` | test-slot reservations (under a lock) |
| `~/.config/rumo/mandato.key` | Mandato HMAC key (default location) |
| `$TMPDIR/context-nudge-<session_id>` | the highest context band already nudged |

## Environment variables

### Test concurrency (`worktree-guard.py`)

| Variable | Default | Effect |
|---|---|---|
| `RUMO_MAX_TEST_RUNS` | unset | exact limit of logical test runs machine-wide (no memory bonus) |
| — | 3 / 2 | without the variable: 3 when free memory ≥ 30%, else 2 (unknown memory = 2) |
| `RUMO_TEST_WAIT_S` | 50 | seconds to wait for a slot before denying; the hook's settings timeout must exceed it |
| `RUMO_TEST_POLL_S` | 3 | poll interval while waiting |
| `RUMO_TEST_RESERVE_S` | 15 | lifetime of a slot reservation (0 = off) |
| `RUMO_STALE_TEST_MIN` | 20 | a run older than this many minutes doesn't count |
| `RUMO_IDLE_CPU_PCT`, `RUMO_IDLE_MIN_S` | 1, 30 | a runner under this CPU share for this long during the wait counts as hung |
| `WORKTREE_GUARD_HOME`, `_PS`, `_MEM`, `_CPU`, `_CWD` | — | test seams |
| `WORKTREE_GUARD_SCAN_BUDGET_S` | 15 | seconds of analysis per call; overrun → deny |

### Other hooks

| Variable | Default | Used by |
|---|---|---|
| `RUMO_MANDATO_KEY` | `~/.config/rumo/mandato.key` | `mandato.py` |
| `CONTEXT_NUDGE_LEVELS` | `200000,300000,400000,500000,800000` | `context-nudge.py` |
| `CONTEXT_BUILD_MAX` | `120000` | `context-nudge.py` build/wave gate |
| `VERIFY_HOOK_EXPLAIN` | unset | `check-verify.sh`, `render-verify.sh`: append a JSON classification line to this file |

### Scripts

| Variable | Default | Used by |
|---|---|---|
| `CLAUDE_CODE_SESSION_ID` | set by Claude Code | `review-stamp.sh` (unless `--session` is given) |
| `RUMO_PLANS_DIR` | `~/.claude/learn/plans` | `wt-gc.sh` |
| `WAVE_REMOTE_SH` | `ssh -o BatchMode=yes -o ConnectTimeout=10` | `wave-host.sh`, `wave-status.sh`, `wave-lane-prep.sh` |
| `WAVE_HOST_PROJECTS` | `orca/projects` (relative to the host's home) | `wave-host.sh` |
| `SYNC_LOCAL_ROOT` | `$HOME/.claude` | `sync-host.sh` |
| `SYNC_HOST_ROOT` | `.claude` (host home) | `sync-host.sh` |
| `SYNC_LOCAL_RUMO` | `$HOME/orca/projects/rumo` | `sync-host.sh` |
| `SYNC_HOST_RUMO` | `orca/projects/rumo` | `sync-host.sh` |
| `SYNC_BACKUP_DIR` | `.claude-sync-backups` (outside `~/.claude` on purpose) | `sync-host.sh` |
| `SYNC_REMOTE_SH`, `SYNC_REMOTE_WRAP` | unset (`ssh`) | `sync-host.sh` |
| `SYNC_ORCA_ENV` | the host name | `sync-host.sh` Orca `--environment` |
| `SYNC_GH_USER` | local `gh api user --jq .login` | `sync-host.sh` preflight |

## Owner tokens

Some behaviour changes only when **you** type a token in a real message of the session (never in a launch prompt or a machine-written entry):

| Token | Effect | Checked by |
|---|---|---|
| `#env-ok` | allows copying a real env file into a worktree | `worktree-guard`, review replay |
| `#waive <axis>#<n>` | leaves one Open finding unfixed | `review-stamp.sh` |
| `#sem-review` ("no review") | allows a PR or merge without a stamp covering the target | `pr-base-guard` |
| `confirmo` ("I confirm") | allows a destructive production DB write or production seed | `pr-base-guard` |
| `#same-window` | allows `/rumo build`/`wave` in a large window | `context-nudge` |

The Portuguese tokens are matched as typed input and are not translated.

Next: [[Glossary]]
