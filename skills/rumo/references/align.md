# align

`rumo` with no mode token, or free-form prose/a question. The default mode: sharpen a raw idea before anything gets built.

## Mechanism

1. Run a `grilling` session (`skills/discipline/grilling`) against the idea — one question at a time, wait for the answer, don't act until the user confirms. Facts about the code are looked up, not asked: send them to `rumo:scout` (batch several questions into one dispatch) and keep only its `path:line` answers in this window. The decisions are the user's.
2. The moment a domain term firms up or a hard-to-reverse decision gets made — **not at the end of the session** — invoke `domain-modeling` (`skills/discipline/domain-modeling`) to write it into `CONTEXT.md` or a new ADR. A term or decision that only lives in this chat is lost the moment the window clears; the write is what survives.
3. Repeat 1–2 until the idea is **ready** or the user stops. Ready means all five hold:
   1. behaviour described from the user's side;
   2. every acceptance criterion tagged `[cmd]` (a shell command with expected output), `[judgment]`, or `[visual]` — plus ticket's whole-page `[visual]` criterion when a block joins a shared page;
   3. out of scope named;
   4. risk answered — does it touch money, auth, data, security, or prod? (no / which);
   5. new terms already in `CONTEXT.md`.

   Then name `/rumo ticket` for the user to type. Align never publishes the issue itself — that's `ticket`'s job.

## One unbroken window

Grilling and domain capture happen in a single context window, start to finish. Don't `/clear` or `/compact` between questions, between a question and its ADR write, or at any point before a `ticket` publishes (or the user explicitly stops). The whole value of this mode is that every answer builds on the same thinking that produced the last one — breaking the window mid-align throws that away and re-derives it, badly, from a summary.

## When the question needs running code

Some questions can't be settled by talking: a state model that only reveals its shape once it runs, a UI you have to see. Don't theorize past that wall — detour:

1. **`handoff` out** — read [`handoff.md`](handoff.md) and write the continuation doc naming exactly the question at stake.
2. Open a fresh session against that file, run `prototype` (`skills/discipline/prototype`) to answer the one question with throwaway code.
3. **`handoff` back** what was learned, referenced from the original align thread, then resume grilling there.

Never let the align window itself grow a prototype inline — the throwaway code belongs in its own session per `prototype`'s contract.

## Closing line

End every align turn with the `NEXT:` line required of all `rumo` modes (see the router `SKILL.md` §5):

- Mid-interview, more rounds expected → `NEXT: keep-open until ticket publishes`
- User stopped without publishing → `NEXT: clear`
- Detouring through a prototype → `NEXT: keep-open until handoff returns`
