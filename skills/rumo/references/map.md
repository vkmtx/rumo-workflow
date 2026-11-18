# Map — decision tickets for fog too big for one session

Fires on `/rumo map`. A loose idea has arrived too big for one session, wrapped in **fog**: the way from here to the **destination** isn't visible yet. Mapping charts that way as decision tickets on the GitHub tracker, then resolves them one at a time until the route is clear. Domain-agnostic — engineering, content, whatever fits the shape.

## Plan, don't do

Each ticket resolves a **decision**, never a build slice. The map is done when nothing is left to decide before someone goes and builds. The pull to just start building is the signal you've reached the edge of the map — see Handoff below, never charge at the destination directly. Refer to the map and every ticket by its issue **title**, never a bare `#42` — a wall of numbers is illegible, names read at a glance.

## The map (GitHub issue)

The map is one issue labelled `rumo:map`. Tickets are its **sub-issues** (`gh issue create --parent <map>`, or `gh issue edit <map> --add-sub-issue <N>` for an existing one) — the map is an index, not a store: it gists each closed ticket's answer and links the ticket for detail, never restates it. Blocking uses GitHub's native issue-dependency links (`gh issue edit <N> --add-blocked-by <M>`), not a body convention — the frontier must be visible in the tracker's own UI. Read the graph back with `gh issue view <map> --json subIssues` and `gh issue view <N> --json blockedBy`. A ticket is **unblocked** when everything blocking it is closed; the **frontier** is the open, unblocked, unclaimed tickets. A session claims a ticket by assigning it to itself, first, before any work — that assignment *is* the claim.

Map body, loaded once per session (open tickets aren't listed here — query for them):

```markdown
## Destination
<what reaching the end looks like: a spec, a decision, a change. 1-2 lines.>
## Notes
<domain; skills every session should consult; standing preferences>
## Decisions so far
- [<closed ticket title>](link) — <one-line gist>
## Not yet specified
<in-scope fog you can't ticket yet>
## Out of scope
<work ruled beyond the destination — closed, never graduates>
```

Ticket body is one question, sized to one session: `## Question` + the decision to resolve. Each carries a `rumo:<type>` label. The answer isn't in the body — it's a resolution comment posted on close.

## Ticket types

| Type | Mode | Use | Skill |
|---|---|---|---|
| `research` | AFK | a fact a decision waits on, outside the working directory | `research` subagent |
| `prototype` | HITL | "how should it look/behave" needs a cheap concrete artifact to react to | `prototype` |
| `grilling` | HITL, default | conversation sharpens the decision | `grilling` + `domain-modeling` |
| `task` | HITL or AFK | manual work blocking a decision (access, provisioning) — the one type that does, not decides | — |

HITL tickets need the live human; an agent never answers both sides of a grilling ticket.

## Fog, not yet specified, out of scope

**Fog of war**: decisions you can tell are coming but can't yet phrase precisely — hangs in `## Not yet specified`. Test: can you state the question sharply *now* (ticket it), or not (leave it in fog)? Don't pre-slice fog into ticket-sized pieces — one patch may graduate into several tickets, or none. Resolving a ticket graduates the fog it clears.

**Out of scope**: work past the destination. A scoping act, not a route step — close the ticket, one line in `## Out of scope` (gist + why), never in Decisions-so-far. Never graduates; the destination would have to be redrawn first, as a fresh effort.

## Invocation

**Chart** (loose idea in): grill the destination first (it fixes scope) → grill the frontier breadth-first, surfacing open decisions → if no fog surfaces, the journey fits one session, stop and ask how to proceed → create the map + tickets you can specify now, wire blocking in a second pass (issues need ids first) → fire `research` subagents in parallel → stop. Charting hand-resolves nothing.

**Work through** (map in, ticket optional): load the map → pick the named ticket, or the first frontier ticket → claim it → resolve it (zoom into related/closed tickets on demand; the ticket's type names its skill) → post the resolution comment, close, append the gist to Decisions-so-far → graduate newly-specifiable fog into tickets, or rule out of scope if the answer reveals a ticket sits past the destination. **Never resolve more than one ticket per session** (research tickets exempted — they run in parallel).

## Handoff: when the map clears

No frontier left, `## Not yet specified` empty: the map is done, but it does not hand off to build. Load every resolved ticket's resolution comment into this window, then tell the user to type `/rumo ticket` here to **collapse the linked decisions into one spec** — synthesizing across every ticket's resolution, not just the destination line (`ticket` synthesizes only what the window holds). Jumping straight to build from a cleared map throws away the detail sitting inside each resolved ticket; `rumo ticket` is what carries it forward into the T1 that build actually reads.

End the session with a literal `NEXT: clear` / `NEXT: keep-open until <X>` / `NEXT: rewind to <Y>` line (`keep-open until ticket publishes` right after the handoff above) — mapping is plan-only, no worktree, so no merge-before-clear concern.
