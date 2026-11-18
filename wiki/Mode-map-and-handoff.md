# Modes: map and handoff

Two modes handle work that does not fit one window. **map** (`/rumo map`) is for fog: an idea too big for one session, where the way from here to the destination isn't visible yet. It charts that way as decision tickets on the GitHub tracker and resolves them one per session until the route is clear, then hands off to `ticket`. **handoff** (`/rumo handoff`) writes one portable Markdown file that lets a different session, harness, directory or person pick up mid-work. Both are plan-only: neither writes source.

## map

### Plan, don't do

Each ticket resolves a **decision**, never a build slice. The map is done when nothing is left to decide before someone builds. The pull to start building is the signal you have reached the edge of the map. Maps and tickets are referred to by issue **title**, never a bare `#42`.

### The map on GitHub

| Element | Representation |
|---|---|
| Map | one issue labelled `rumo:map` |
| Tickets | its **sub-issues** (`gh issue create --parent <map>` or `gh issue edit <map> --add-sub-issue <N>`) |
| Blocking | native dependency links (`gh issue edit <N> --add-blocked-by <M>`) |
| Claim | assigning the ticket to yourself, before any work |
| Answer | a resolution comment posted on close, not the body |

Read the graph back with `gh issue view <map> --json subIssues` and `gh issue view <N> --json blockedBy`. A ticket is **unblocked** when everything blocking it is closed; the **frontier** is the open, unblocked, unclaimed tickets.

Map body:

```markdown
## Destination
<what reaching the end looks like. 1-2 lines.>
## Notes
<domain; skills every session should consult; standing preferences>
## Decisions so far
- [<closed ticket title>](link) — <one-line gist>
## Not yet specified
<in-scope fog you can't ticket yet>
## Out of scope
<work ruled beyond the destination>
```

A ticket body is one question sized to one session (`## Question`), with a `rumo:<type>` label:

| Type | Mode | Use | Skill |
|---|---|---|---|
| `research` | AFK | a fact a decision waits on, outside the working directory | `research` subagent |
| `prototype` | HITL | a cheap concrete artifact to react to | `prototype` |
| `grilling` | HITL, default | conversation sharpens the decision | `grilling` + `domain-modeling` |
| `task` | HITL or AFK | manual work blocking a decision (access, provisioning) | — |

HITL tickets need the live human; an agent never answers both sides of a grilling ticket.

### Fog and scope

- **Fog of war:** decisions you can tell are coming but can't phrase sharply yet. They stay in `## Not yet specified`; they are not pre-sliced into tickets. Resolving a ticket graduates the fog it clears.
- **Out of scope:** work past the destination. The ticket is closed and one line goes into `## Out of scope`; it never graduates.

### Two invocations

**Chart** (a loose idea in): grill the destination first → grill the frontier breadth-first → if no fog surfaces, the journey fits one session: stop and ask → create the map and the tickets you can specify now, then wire blocking in a second pass → fire `research` subagents in parallel → stop. Charting resolves nothing by hand.

**Work through** (a map in): load the map → pick the named ticket or the first frontier ticket → claim it → resolve it with its type's skill → post the resolution comment, close, append the gist to Decisions so far → graduate newly specifiable fog. **One ticket per session** (research tickets excepted).

### When the map clears

No frontier and nothing left under Not yet specified: every resolution comment is loaded into the window, and you are told to type `/rumo ticket` there, so `ticket` collapses the linked decisions into one spec. A cleared map never goes straight to `build`; the detail inside each resolved ticket would be lost. The session ends with `NEXT: keep-open until ticket publishes`.

## handoff

### Triggers, and only these

| Trigger | Example |
|---|---|
| New harness | the continuation happens in a different model or CLI |
| New directory | work continues in another repo or working directory |
| A colleague | a human picks up next |
| Forking a side task mid-phase | the **prototype detour**: mid-align or mid-build on A, a separate question B ("does this state model feel right") is answered in a fresh session with `prototype`, then handed back into the original window by path |

Not a trigger: a task changing (`/clear`) or abandoning a path (`/rewind`).

### Contents

- what has been decided and why (the residue, not a transcript);
- current state: branch, worktree, uncommitted changes, last command and its result;
- pointers to durable artifacts (`CONTEXT.md`, ADRs, issue URL, plan file, prototype findings) by path or URL, never re-pasted;
- skills the next session should invoke, and for what;
- for a fork: which question it answers and where the answer goes back;
- secrets stripped before writing (API keys, tokens, passwords, connection strings, PII); when unsure, redacted with a note of what kind.

### Where it goes

The OS temp directory: not the repo, never committed. For a colleague, hand them the path directly. The turn ends with `NEXT: clear` once the path is given, unless the same window continues on the non-forked part (`NEXT: keep-open until <X>`).

Next: [[Review Gate]]
