# Mode: ticket

`/rumo ticket` turns an aligned idea into T1 work items: self-contained GitHub issues with tagged acceptance criteria, a risk section, labels from the repo's vocabulary and native blocking links. It synthesizes only what the current window already holds and never interviews. A single coherent ask becomes one issue; larger work becomes several tracer-bullet issues published in dependency order. The mechanism is ported from mattpocock's `to-spec` and `to-tickets`, merged into one flow.

## No interview

`ticket` uses only the codebase exploration and decisions already present in the window. A gap in the conversation is a gap in the ticket, not a cue for new questions. If the window was cleared or compacted since the ask was discussed, there is nothing to synthesize: it says so and stops, instead of reconstructing the ask from memory.

## Preconditions

| Precondition | Missing → |
|---|---|
| `docs/agents/issue-tracker.md` (which repo, monorepo routing) | self-heal: scaffold just this file from `/setup-repo`'s template, uncommitted, report `created`, continue |
| `docs/agents/triage-labels.md` (label vocabulary) | same self-heal |
| `CONTEXT.md` at the repo root | its terms are used verbatim in every title and body |
| no existing open issue for this ask | never duplicate; an ask already promoted to an in-flight T2 plan belongs to `/rumo build` until its PR merges |

## Classify the ask

| Shape | Output |
|---|---|
| Single coherent ask | one T1, published directly |
| Larger work | **tracer-bullet** vertical slices: each cuts a narrow but complete path through every layer it touches (schema, API, UI, tests), is verifiable on its own, and fits one fresh context window. Never a horizontal slice of one layer. |
| Wide mechanical refactor (rename a column, retype a shared symbol) | **expand–contract** is offered, not imposed: expand (new beside old) → migrate call sites in batches, each its own issue blocked by the expand → contract (delete the old form), blocked by every batch |

**Slice size:** one issue is one plan of at most 6 steps (about 900 changed lines or fewer). Bigger is split before publishing.

## Criteria, risk and labels

- Every criterion is tagged `[cmd]`, `[judgment]` or `[visual]`. A judgment call is never forced into a fake command.
- A `[cmd]` criterion holds exactly one runnable command in one pair of backticks, with the expected result in prose after it. `issue-criteria.sh` runs the backticked text as shell during review.
- The tags route the build: `[cmd]` work goes to builders, `[judgment]` and `[visual]` steps stay in the main session. A mixed issue is normal.
- A block that lands on a shared page also gets a whole-page `[visual]` criterion naming the page's purpose and a reference image (an approved prototype or competitor screen).
- `## Risk` comes from align's risk answer. Any risk adds the label `risk:sensitive` (created with `gh label create risk:sensitive` if missing), which lifts the review to the sensitive tier.
- Labels come from `docs/agents/triage-labels.md`; that file decides which label marks an issue agent-workable.

## Issue body template

The body is self-contained: whoever picks it up has not seen the conversation. No file paths or code snippets (they go stale), except a prototype snippet that encodes a decision more precisely than prose.

```markdown
## What to build
End-to-end behaviour this issue makes work, from the user's perspective.
Use CONTEXT.md vocabulary throughout.

## Acceptance criteria
- [ ] [cmd] `<command>` → <expected>
- [ ] [judgment] <what the reviewer/user decides>
- [ ] [visual] <what the screenshot must show>
- [ ] [visual] whole page reads as <purpose>, against <reference image>   (block on a shared page)

## Risk
None — or which of money · auth · data · security · prod, and how.

## Blocked by
Human-readable cross-reference to the native link ("blocked by #41"),
or "None — can start immediately".
```

## Blocking edges and publish order

Multi-issue breakdowns get their dependency graph as **native GitHub blocking links**, not prose:

```bash
gh issue create --title "..." --body-file body.md --label ready-for-agent --blocked-by 41
gh issue edit 43 --add-blocked-by 42
```

A `Blocked by: #N` line in the body is only a fallback when the native relation can't be set. Blockers are published first, so no link points at an issue that does not exist yet. An issue with no unresolved blocker can start immediately: work the frontier.

## Cut point

The body records the decision at the point the ask stabilized, not the deliberation. Rejected alternatives and dead ends stay in the conversation history.

Publishing closes the align phase for this ask:

- `NEXT: clear` once every issue is published and confirmed (the common case);
- `NEXT: keep-open until <X>` only if more of this ask still needs alignment.

Next: [[Mode build]]
