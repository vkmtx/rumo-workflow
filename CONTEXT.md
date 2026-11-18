# rumo

A Claude Code plugin that routes work from idea to merged PR: align, ticket, build, review, wave.

## Language

### Review

**Stamp**:
The proof that the current HEAD was reviewed, written only by `review-stamp.sh`; the PR and merge gates read it.
_Avoid_: selo file, review marker

**Open finding**:
A blocker or major that a reviewer reported and that no fix reviewer has marked RESOLVED or WITHDRAWN and the user has not waived. It holds the stamp back.
_Avoid_: pending finding, unresolved issue

**Waiver**:
The user's explicit decision to leave one open finding unfixed, typed by the user in the session; logged as a dismissed finding with reason `owner-waived`.
_Avoid_: override, skip, dispensa (Portuguese for waiver)

**Follow-up issue**:
The one GitHub issue that a PR spawns for the minors, questions and waived findings still open when it opens; the two link each other, and nothing closes it automatically. A PR with nothing open spawns none.
_Avoid_: tech-debt issue, backlog issue, follow-up ticket

### Sessions

**Launch prompt**:
The first message a launcher (a `wave` lane, or a worker launcher's Worker) writes into a session it opens with `orca agent launch`; stored exactly like a typed message, it is told apart only by a line starting `LAUNCHED-BY:`, `WAVE BRIEF:` or `AUTHORIZED:`, and never counts as the owner's message. `learn.py phases` (statistics only, never a gate) also counts a wave's relayed `Orquestrador:` (orchestrator) / `PAUSA` (pause) / `CONTINUE` text as the launcher's — literal relay markers, kept in Portuguese — for transcripts older than the `LAUNCHED-BY:` relay rule; the hooks read the three markers alone. Authority comes from the lane's Mandato when one exists, else its `AUTHORIZED:` line.
_Avoid_: kickoff prompt, lane prompt

**Critical question**:
The only kind of question that stops a build for the owner: a wrong default could not be taken back by a later commit (production, data, money, a third party, a real secret), or the answer would have to be invented (a price, a legal text, a credential). The list is `build.md` §4.
_Avoid_: gate question, blocker question

**Assumption**:
A default the build took where the plan had a seam or an open question; one line in the plan's `## Assumptions`, copied into the PR body for the owner to read after the fact.
_Avoid_: decision, open question (once taken)

**Mandato**:
Mandato (mandate): the host-written, signed record of what an approval grants a lane — the Política (policy) version (`politica`), scope (`repo`, `issue`), strength (`forca`: `explicito` explicit / `inferido` inferred), who asked (`pediu`), who approved (`aprovou`), source (`fonte`: `github` / `zulip`) and reach (`alcance`: `pr|merge`) — bound to one worktree and one branch. `pr-base-guard` reads it from `<git-dir>/rumo-mandato.json` (via `mandato.py`); when present it replaces the `AUTHORIZED:` line, and only restricts — it never unlocks a production deploy or DB write.
_Avoid_: authorization file, token

**Relatório**:
Relatório (report): the one `RELATÓRIO: {json}` line (`relatorio.py emit`) every build ends with, right before `NEXT:`, so a launcher reads the outcome without parsing prose; its `estado` (state) is one of progress · waiting · ready · blocked · failed · dropped.
_Avoid_: status line, summary

### Build

**Abuse case**:
A way a step's code could be turned against the repo or its owner, written as a red test before the happy ones in the Test first of a `Risk: security` step, under one of four labels: `hook:` (the hook that must see the change), `third-party input:` (a fork, a predictable name, a path with `..` or a symlink), `check-to-use:` (state that changes between the check and the use, such as a HEAD that moves), `deletion:` (what is deleted and what must never be). A label that does not apply reads `n/a — <why>`; `plan-check.sh` refuses a label left empty.
_Avoid_: attack case, threat case, security test
