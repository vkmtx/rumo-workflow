---
name: learn
description: 'Turn mistakes into rules — harvest a session, record a lesson, or review: promote repeats as approved diffs.'
disable-model-invocation: true
---

`/learn` keeps the setup improving: **record cheap, promote on repetition, retire the rest** — the `design-taste` taste-log loop, generalized. A **lesson** is one imperative rule that would have prevented a real, observed mistake. It never rewrites an instruction file without the user approving the diff.

`learn.py` below = `python3 -I <this skill's base directory>/scripts/learn.py`.

## Where lessons live

| Scope | File | Read by |
|---|---|---|
| Repo — about this codebase | `<repo>/docs/agents/lessons.md` (committed) | `rumo:planner` (quotes into steps), the standards reviewer |
| Global — about how we work | `~/.claude/learn/lessons.md` | `/learn review` (promotion source) |
| Raw events | `~/.claude/learn/events.jsonl` (+ monthly `events-YYYYMM.jsonl.gz`), written only through `learn.py event` (`/rumo build` §9) | `learn.py stats` |
| Retired | `lessons-archive.md` beside each `lessons.md` | nobody, by default |

Entry format, one line:

```
- L<n> · <YYYY-MM-DD> · ×<count> · <imperative rule> — why: <the mistake, one line> · seen: <issue/PR/session/event>
```

Every write to a `lessons.md` is followed by `learn.py scan <file>` (exit 1 = a line looks like a secret: redact it). Missing file → create it with a `# Lessons` heading (repo file: the `setup-repo` §5 header). Missing `~/.claude/learn/` → `mkdir -p` it.

## Mode by first token

### bare — harvest this session

1. `learn.py harvest --current --cwd "$PWD"` (from the repo root; add `--days 1` instead of `--current` when the user says "hoje"/"today").
2. Read the report against what you remember of this session. Keep only signals that point at a **mistake with a cause**: a correction of something you did, a hook that stopped you, a step that failed and why, a rejected tool call. Drop questions, mid-conversation steering, and preferences already written somewhere.
3. Each survivor → one candidate lesson: rule (positive, imperative, testable), why, seen, and **scope** (repo if it is about this codebase's code/commands/data; global if it is about workflow, tools, or communication). A candidate that matches an existing lesson → bump its `×count` instead of adding.
4. Show the candidates as a numbered table (rule · why · scope · new/bump). Write only what the user approves (or edits), then print the file paths touched.

### `<text>` — record one

Rewrite the user's text as one entry (keep their meaning; make it imperative), pick the scope by the rule in step 3, show the line, write it on a yes.

### `review` — promote, calibrate, retire

1. **Gather**: `learn.py stats --days 30`, `learn.py spend --days 7` (where the tokens went), `learn.py phases --days 14` (where the clock time went), both `lessons.md` files (global, and the repo's when inside a repo), and `learn.py harvest --days 14` for signals outside builds. When `stats` prints `skipped N malformed`, the log holds lines the validator rejects: `learn.py normalize` writes `events.normalized.jsonl` plus a dated backup and prints counts and samples — show ``diff <backup> events.normalized.jsonl`` to the user, and replace `events.jsonl` only on the user's yes, carrying over lines appended since the backup.
2. **Promote** every lesson seen in **two or more distinct sessions** (`×count` counts sessions, never lines; harvest prints `×n sessions`), and every repeated cause in `stats`, to the place where it changes behaviour — the most specific one that would have prevented it:

   | The rule is about… | Promote into |
   |---|---|
   | how a builder/planner/reviewer works | that agent's body (`agents/*.md` in the rumo checkout) |
   | a rumo step (plan, ticket, review gate) | the matching `skills/rumo/references/*.md` or `plan-template.md` |
   | this repo's code or commands | stays in the repo `lessons.md` (the planner already quotes it) — promotion = sharpen its wording |
   | visual taste | `design-taste`'s "Lições consolidadas" (consolidated lessons) |
   | always-true working preference | `~/.claude/CLAUDE.md` (keep it ≤ ~120 lines) |
   | something mechanical a script can check | a hook spec: event, matcher, what it blocks, test cases — built after approval like any code |

   Load `writing-for-agents` before drafting any promotion. Each promotion is a diff — show all of them together, numbered; apply only the approved ones. Promoted lessons leave `lessons.md` with a pointer line in the archive (`→ promoted to <file>`).
3. **Calibrate the Model rule** from `stats`' "Calibration candidates" section only — it already requires n ≥ 5 per category and leaves out `env` (infrastructure) failures. Each candidate → propose sharpening the planner's brief for that category, or routing it to `opus` (an edit to the planner's Model rule); an opus candidate ≥ 90% → propose moving it to sonnet. "none (need n ≥ 5)" means no calibration this round.
3b. **Reviewer habits**: findings with `"outcome":"dismissed"` grouped by category, and stats' "Dismissed by axis × reason" (`legacy` = logged before `reason` existed) — a pattern dismissed ≥ 3 times becomes a proposed line in `agents/reviewer.md` telling it to stop raising that class; a pattern fixed ≥ 3 times becomes a repo lesson so the planner prevents it upfront.
4. **Retire**: `×1` lessons older than 60 days → `lessons-archive.md`.
5. **Budget and secrets**: `learn.py budget ~/.claude/CLAUDE.md <memory dir>/MEMORY.md ~/.claude/learn/lessons.md <repo>/docs/agents/lessons.md` plus every agent/SKILL file a promotion touched → anything OVER (bytes, lines, or line length) gets a trim proposal in the same diff set. Then `learn.py scan` on both `lessons.md` files → any hit is redacted before anything is written or committed.
6. Rumo source changed → remind the rumo repo rule: bump `version` in `.claude-plugin/plugin.json`, then `claude plugin update rumo@rumo`.

Close `review` with a 5-line report: promoted (n, where) · calibrated (what) · retired (n) · budget status · the one pattern the stats say costs the most, and the top line of `spend` (main vs subagents, share above 300k). Print the `phases` block below it, verbatim.

## Close

End every `/learn` turn with the literal `NEXT:` line (`clear` · `keep-open until <X>` · `rewind to <Y>`).
