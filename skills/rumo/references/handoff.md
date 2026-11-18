# Handoff — portable continuation for a narrow set of triggers

Ported from mattpocock's `handoff`. Produces one Markdown file that lets a **different**
session pick up mid-work. Narrow by design — most work stays in one continuous window (see
`rumo`'s context doctrine); reach for this only on one of the triggers below, never as a
substitute for `/clear` or `/rewind`.

## Triggers — and ONLY these

- **New harness**: the continuation happens outside this tool entirely (a different model/CLI).
- **New directory**: work continues in a different repo/working directory than this session has open.
- **A colleague**: a human, not an agent, picks up the work next.
- **Forking a side task mid-phase**: this window is mid-align or mid-build on ask A, and a
  genuinely separate question B needs answering without losing A's state. Canonical case —
  the **prototype detour**: A is mid-build; B is "does this state model feel right." Write the
  handoff, open a fresh session, run `prototype` there (answers ONE question, logic or UI,
  never both), then hand back into the ORIGINAL A window and reference the findings by
  path — don't re-paste them.

Not a trigger: a task simply changing (`/clear`), or abandoning a path (`/rewind`) — neither
needs a portable document; both stay inside this same window and history.

## Contents

- What's been decided and why — the residue, not a transcript of what was said.
- Current state: branch, worktree, uncommitted changes, last command run and its result.
- Pointers to durable artifacts already produced — CONTEXT.md/ADR, issue URL, plan file, a
  prototype's findings file — by path or URL. Never re-paste content another artifact holds.
- Suggested skills the next session should invoke, and for what.
- If forking a side task: which question the fork answers, and where to reference the answer
  back into (the original thread's identifier).
- Secrets: strip API keys, tokens, passwords, connection strings, PII before writing, not
  after. Unsure whether something is one → redact it, note "redacted: <what kind>".

## Where to save

The OS temp directory — not the repo, not `plans/`, never committed; it's a continuation
artifact, not project history. If the trigger is "a colleague," hand them the path directly
rather than committing it anywhere they'd need repo access to read.

## Closing

Writing a handoff ends this window's usefulness for the forked-off piece. End the turn with
`NEXT: clear` once the file is written and its path given to the user — unless this SAME
window continues on the non-forked part of the work, in which case `NEXT: keep-open until <X>`.
