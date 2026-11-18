# Ticket — synthesize the conversation into GitHub issue(s)

Mechanism ported from mattpocock's `to-spec` + `to-tickets`, merged into one flow that
produces **T1** work items (see the work-item model in `rumo`'s main `SKILL.md`). Invoked as
`/rumo ticket`.

## No interview

Synthesize ONLY what's already in this conversation window — the codebase exploration
already done, the decisions already made. Do NOT ask the user new questions to fill gaps; a
gap in the conversation is a gap in the ticket, not a cue to interview. If the window was
cleared or compacted since the ask was discussed, there is nothing to synthesize: say so
plainly and stop — don't reconstruct the ask from memory or guess at it.

## Preconditions

- `docs/agents/issue-tracker.md` exists — repo-specific tracker conventions (which repo,
  mono-repo routing). Missing → **self-heal, don't dead-end**: you're already inside a
  user-typed flow, so scaffold just this file from the template in
  [`setup-repo`'s §1](../../setup-repo/SKILL.md) (adopt-mode, uncommitted, never overwrite),
  report `created`, and continue. `/setup-repo` stays available for the full bootstrap later.
- `docs/agents/triage-labels.md` exists — the label vocabulary for this repo. Missing → same
  self-heal from `setup-repo`'s §2.
- `CONTEXT.md` at repo root — use its terms verbatim in every ticket title and body; don't
  paraphrase them.
- Search for an existing open issue covering this ask — never duplicate. If this ask already
  promoted to an in-flight T2 plan, this flow doesn't apply — `/rumo build` owns that plan until its PR merges.

## Classify the ask

**Single coherent ask** → one T1 issue, published directly.

**Larger work** → break into **tracer-bullet** vertical slices: each slice cuts a narrow but
COMPLETE path through every layer it touches (schema, API, UI, tests), is demoable/verifiable
on its own, and is sized to fit one fresh context window. Never a horizontal slice of one layer.

**Wide mechanical refactor** (blast radius fans across the whole codebase — rename a column,
retype a shared symbol) → offer **expand–contract** instead of forcing tracer bullets: expand
(new form beside the old, nothing breaks) → migrate call sites in batches sized by blast
radius, each batch its own issue blocked by the expand → contract (delete the old form,
blocked by every batch). Offer this; don't impose it silently.

## Blocking edges

Every multi-issue breakdown gets its dependency graph as **native GitHub blocking links** (set
with `gh issue create --blocked-by <N>` or `gh issue edit <N> --add-blocked-by <M>`), not prose
alone. A "Blocked by: #N" line in the body is a fallback only when the native relation
genuinely can't be set. Work the frontier: publish and
work blockers first — an issue with no unresolved blocker can start immediately.

## Tagged criteria and risk

Tag every acceptance criterion `[cmd]`, `[judgment]`, or `[visual]` — never force a judgment
call into a fake command. A `[cmd]` criterion holds exactly one runnable command in one pair of
backticks, the expected result in prose after it: `issue-criteria.sh` runs the backticked text
as shell. The tags route the build: the planner sends `[cmd]` work to builders
and keeps `[judgment]`/`[visual]` steps in the main session, so a mixed issue is normal. A
block that lands on a shared page (one other blocks already live on) also gets a whole-page
`[visual]` criterion naming the page's purpose and a reference image (approved prototype or
competitor screen) — a block can pass alone while the page it joins stops reading as itself. Fill
`## Risk` from align's risk answer; any risk → add the `risk:sensitive` label (create it with
`gh label create risk:sensitive` if the repo lacks it) — it lifts the review to the sensitive tier.

**Slice size**: one issue = one plan of ≤ 6 steps (≈ ≤ 900 changed lines). Bigger → split into
tracer bullets before publishing.

## Issue body template

Self-contained — whoever (or whatever) picks it up has not seen this conversation. No file
paths or code snippets, they go stale fast (exception: a prototype snippet that encodes a
decision more precisely than prose — inline it, note where it came from).

```
## What to build
End-to-end behaviour this issue makes work, from the user's perspective — not a
layer-by-layer implementation list. Use CONTEXT.md vocabulary throughout.

## Acceptance criteria
- [ ] [cmd] `<command>` → <expected>
- [ ] [judgment] <what the reviewer/user decides>
- [ ] [visual] <what the screenshot must show>
- [ ] [visual] whole page reads as <purpose>, against <reference image>   (block on a shared page)

## Risk
None — or which of money · auth · data · security · prod, and how.

## Blocked by
Human-readable cross-reference to the native link set below ("blocked by #41"),
or "None — can start immediately".
```

## Labels & publish

Apply labels from `docs/agents/triage-labels.md`'s vocabulary — that file is the source of
truth for which label marks an issue agent-workable; don't assume a hardcoded name still
applies. Publish one issue per ticket, dependency order (blockers first), with
`gh issue create --title "..." --body-file <file> --label <label>`, and set blocking links at
creation (`--blocked-by`) or immediately after (`gh issue edit --add-blocked-by`) — a blocker
created after its dependent leaves a dangling reference.

## Cut point

Cut what goes IN the body at the point the ask stabilized — the decision, not the
deliberation. Rejected alternatives, dead ends, and "what if" tangents stay in this
conversation's history; they don't belong in the ticket. The ticket is what gets built, not a
transcript of how the group got there.

Publishing closes the align phase for this ask. End this turn with:

- `NEXT: clear` — the common case, once every issue is published and confirmed.
- `NEXT: keep-open until <X>` — only if more of THIS ask still needs alignment (e.g. slices
  remain to quiz the user on).
