---
name: rumo
description: 'Flow verb for all engineering work: bare = align an idea by interview (grilling + domain capture); keywords ticket | build | wave | map | handoff | help route to publishing GitHub issues, building through an orchestrator with typed planner/builder/reviewer subagents, running several issues at once in parallel Orca sessions, charting decision maps, or writing continuation docs.'
disable-model-invocation: true
---

`rumo` is one router over six modes. It never does the work itself — every mode's real mechanism lives in a reference file you must read before acting.

## 1. Parse the mode

Take the first whitespace-separated token of the invocation arguments and match it against the table below. No token, or the text doesn't match any keyword (free-form prose, a question, "help me think about X") → **align**.

| First token | Mode | Reference |
|---|---|---|
| *(none)* / anything else | `align` | [`references/align.md`](references/align.md) |
| `ticket` | `ticket` | [`references/ticket.md`](references/ticket.md) |
| `build` | `build` | [`references/build.md`](references/build.md) |
| `wave` | `wave` | [`references/wave.md`](references/wave.md) |
| `map` | `map` | [`references/map.md`](references/map.md) |
| `handoff` | `handoff` | [`references/handoff.md`](references/handoff.md) |
| `help` | the case map | [`references/help.md`](references/help.md) |
| `audit` / `triage` | aposentados 2026-10 (#12) — fire no mode | answer one line: a finding becomes an issue via `/rumo ticket`; a standalone review runs the `review` skill. Then `NEXT: clear` |

**Read the matched reference file before acting on that mode** — this file carries only what every mode shares.

## 2. The six contracts, one line each

- **align** — sharpen a raw idea by interview (`grilling` discipline skill) and capture domain terms/decisions into `CONTEXT.md`/ADRs the moment they resolve (`domain-modeling`), in one unbroken window, until a T1 publishes or the user stops.
- **ticket** — turn an aligned idea into a T1: a tracer-bullet GitHub issue with native blocking links and labels from the repo's label vocabulary; for a multi-session build, decompose into several linked T1s first.
- **build** — do the work a T1/T2 names as **orchestrator**, start to merge without asking: planner writes typed steps, builders execute them in waves, each wave accepted by command, tiered `review`, events logged for `/learn` (§3), PR, merge on `dev` when everything is green, worktree cleaned. Only a Critical question stops it (`build.md` §4).
- **wave** — several T1s at once: one Orca worktree + `/rumo build` session per issue, 3 local + 2 on a remote host, shared brief, RAM watched, dead sessions relaunched.
- **map** — for fog too big for one session (greenfield, huge feature): chart a shared map of decision tickets on the tracker, resolve one at a time, hand off to `ticket` once the way is clear — never build straight off the map.
- **handoff** — a portable continuation doc for a new harness, directory, colleague, or a `prototype` detour (both directions).

## 3. Who does the work (build's core, needed everywhere work is routed)

The main session **orchestrates**; typed subagents from this plugin do the hands-on work, each pinned to its model in its own frontmatter:

| Agent | Model | Does |
|---|---|---|
| `rumo:scout` | haiku | codebase facts with `path:line` |
| `rumo:extractor` | haiku | **extraction** from bulk — logs, transcripts, JSON, CI output — into the shape the brief names; no judgment |
| `rumo:collector` | haiku | the same from the **web** (search, pages), no shell |
| `rumo:planner` | opus high | the plan: typed steps with Files · Does · Test first · Verify · Type · Risk · Parallel with · Model |
| `rumo:builder` | sonnet high | a `Model: sonnet` plan step, or a precise `WORKTREE · TASK · FILES · VERIFY` brief |
| `rumo:builder-opus` | opus medium | risky or under-specified steps, and any step a sonnet builder failed |
| `rumo:reviewer` | opus high | bugs / standards / spec / security axes (fix on the sensitive tier), fixed SHAs, clean context |
| `rumo:reviewer-sonnet` | sonnet high | fix re-reviews outside the sensitive tier |
| `rumo:visual-judge` | opus high | visual steps, judged from screenshots, `design-taste` and the visual brief only |

Inline in the main session, never delegated: **visual** steps (render-verify and `design-taste` only see the main session), **judgment** steps, a trivial T0, and the red loop of `diagnosing-bugs`.

Dispatch typed agents with `subagent_type` and **no `model` param** — a param overrides the frontmatter pin (the hook blocks it). Work outside a build routes the same way: a precise build brief → `rumo:builder`, bulk → `rumo:extractor`, web → `rumo:collector`, a lookup → `rumo:scout`. An untyped call is for research, diagnosis or judgment, with an explicit `model`, or a usage-limit fallback (build §5).

**Workflow scripts** route the same way: `agent(prompt, {agentType: 'rumo:<name>'})` takes the frontmatter pin, with neither `model` nor `effort`. Tier by phase: collect/extract on haiku, build from a precise spec on sonnet, opus only where judgment decides (judge, verify, diagnose); an untyped mechanical call takes `effort: 'low'`.

**Slice every delegated task to one unit** (one file group, lot or question) sized for ~100 turns: a subagent pays its whole context every turn, so five clean 80-turn runs beat one 400-turn run at 500k. Unsliceable → ask for a partial report (done · remaining · state on disk) at the midpoint; the next agent continues from it.

## 4. T0 → T1 → T2

- **T0** — an idea that lives only in conversation. Its only durable residue is `CONTEXT.md`/an ADR, written the moment a term or decision resolves — never the chat transcript.
- **T1** — a GitHub issue: tracer-bullet scope, native blocking links, labels from the label vocabulary ([`references/ticket.md`](references/ticket.md) names its file). The issue *is* the truth. A T1 whose done-criteria are all judgment calls (no shell-checkable bar) closes directly via `Closes #N` — it never gets promoted to T2.
- **T2** — `<feature worktree>/.rumo/plan.md`, written by `rumo:planner` at the start of `build`, never committed, gone with the worktree after merge (the PR + closed issue are the record). Promotion T1→T2 is one-way and stamps both sides (`build.md` §3.3) — never open a new issue from a ticket-born plan.

**Drift stop** before building from a plan written in an earlier session: code (`git diff --stat <Planned at>..origin/<base> -- <Files>`) and issue (`updatedAt` vs `Ticket-synced-at`). Either moved → re-plan first (`build.md` §3.3).

## 5. Context doctrine

The align phase (grill → ticket publish) is **one unbroken window** — no `/clear` or `/compact` mid-align. Every build starts in a **fresh** window. Abandoning a path uses `/rewind` (keeps the cached prefix), never `/compact` (throws the cache away).

**Every orchestrator turn — `rumo`, `setup-repo`, `review`, `learn` — must end its final message with one literal line:**

```
NEXT: clear
NEXT: keep-open until <condition>
NEXT: rewind to <point>
```

If a worktree path was in play, the merge happens **before** `clear` — never leave committed-but-unmerged work behind an emptied window.

## 6. No task in mind?

`/rumo help` (or bare `/rumo` with nothing to route) → read [`references/help.md`](references/help.md) and print its case map; don't guess a mode.

## 7. Hard boundaries

- A build pushes, opens its PR and merges into `dev` by itself once stamped and green (`build.md` §8). A release into `main`/`master`, a production deploy and a production DB write happen only when the user asked **this session**.
- `/rumo`, `/setup-repo` and `/learn` are user-invoked: only a typed command fires them (except `wave` starting `/rumo build` for the issues it names). When one mode leads into another, name the exact command for the user to type ("type `/rumo ticket` here") and end the turn there.
- Visual work stays in the main session (§3).
