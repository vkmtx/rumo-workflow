# Glossary

> **Source of truth:** [`CONTEXT.md`](https://github.com/vkmtx/rumo-workflow/blob/main/CONTEXT.md) in the repo. When this page and `CONTEXT.md` disagree, `CONTEXT.md` wins.

This glossary collects rumo's domain language. The entries marked **(CONTEXT.md)** are taken from the repo's `CONTEXT.md`, which is the authority: skills use those terms verbatim, and the "avoid" list names synonyms that should not appear. The remaining entries define terms the skills and references use consistently. A few protocol terms stay in Portuguese because scripts and hooks match them as data. Each of those carries its English gloss.

## Review

**Stamp** (CONTEXT.md)
The proof that the current `HEAD` was reviewed, written only by `review-stamp.sh` to `<git-dir>/rumo-review.ok`; the PR and merge gates read it. *Avoid:* selo file, review marker.

**Open finding** (CONTEXT.md)
A blocker or major that a reviewer reported and that no fix reviewer has marked `RESOLVED` or `WITHDRAWN` and the user has not waived. It holds the stamp back. *Avoid:* pending finding, unresolved issue.

**Waiver** (CONTEXT.md)
The user's explicit decision to leave one Open finding unfixed, typed by the user in the session (`#waive <axis>#<n>`); logged as a dismissed finding with reason `owner-waived`. *Avoid:* override, skip.

**Follow-up issue** (CONTEXT.md)
The one GitHub issue that a PR spawns for the minors, questions and waived findings still open when it opens; the two link each other, and nothing closes it automatically. A PR with nothing open spawns none. *Avoid:* tech-debt issue, backlog issue, follow-up ticket.

**Tier**
The review's depth, picked from size, paths and risk: `light`, `standard`, `sensitive`.

**Axis**
One independent review pass: `bugs`, `standards`, `spec`, `security`, `fix`. Axes are never merged or reranked.

**Replay**
Running a blocker's or major's `proof:` command in an archive copy of `HEAD` before any fix. A proof that doesn't reproduce demotes the finding to a question.

**Fix re-review**
A review of the fix range only, on `AXIS: fix`, that marks each earlier finding `RESOLVED`, `NOT RESOLVED` or `WITHDRAWN`.

**Base merge**
Merging `origin/<base>` into a stamped branch before merging its PR; `review-stamp.sh --base-merge` re-stamps it when the merge is mechanical.

## Sessions

**Launch prompt** (CONTEXT.md)
The first message a launcher (a `wave` lane, or a worker launcher's Worker) writes into a session it opens with `orca agent launch`; stored exactly like a typed message, it is told apart only by a line starting `LAUNCHED-BY:`, `WAVE BRIEF:` or `AUTHORIZED:`, and never counts as the owner's message. `learn.py phases` (statistics only, never a gate) also counts a wave's relayed `Orquestrador:` (orchestrator) / `PAUSA` (pause) / `CONTINUE` text as the launcher's — literal relay markers, kept in Portuguese — for transcripts older than the `LAUNCHED-BY:` relay rule; the hooks read the three markers alone. Authority comes from the lane's Mandato when one exists, else its `AUTHORIZED:` line. *Avoid:* kickoff prompt, lane prompt.

**Critical question** (CONTEXT.md)
The only kind of question that stops a build for the owner: a wrong default could not be taken back by a later commit (production, data, money, a third party, a real secret), or the answer would have to be invented (a price, a legal text, a credential). The list is `build.md` §4. *Avoid:* gate question, blocker question.

**Assumption** (CONTEXT.md)
A default the build took where the plan had a seam or an open question; one line in the plan's `## Assumptions`, copied into the PR body for the owner to read after the fact. *Avoid:* decision, open question (once taken).

**Mandato** (mandate) (CONTEXT.md)
The host-written, signed record of what an approval grants a lane: Política (policy) version, scope (`repo`, `issue`), `forca` (strength: `explicito` / `inferido`, explicit / inferred), who asked (`pediu`), who approved (`aprovou`), `fonte` (source: `github` / `zulip`) and `alcance` (reach: `pr` | `merge`), bound to one worktree and one branch. `pr-base-guard` reads it from `<git-dir>/rumo-mandato.json` via `mandato.py`. When present it replaces the `AUTHORIZED:` line, and it only restricts: it never unlocks a production deploy or DB write. *Avoid:* authorization file, token.

**Relatório** (report) (CONTEXT.md)
The one `RELATÓRIO: {json}` line (`relatorio.py emit`) every build ends with, right before `NEXT:`, so a launcher reads the outcome without parsing prose. Its `estado` (state) is one of `progress · waiting · ready · blocked · failed · dropped`; other keys are `issue`, `pr`, `merged`, `motivo` (reason), `pergunta` (question). *Avoid:* status line, summary.

**`NEXT:` line**
The literal last line of every orchestrator turn: `NEXT: clear`, `NEXT: keep-open until <condition>`, or `NEXT: rewind to <point>`.

**PAUSA / PAUSADO / CONTINUE**
Wave protocol strings (Portuguese for pause / paused). The orchestrator sends `PAUSA` under memory or load pressure; the lane finishes its command, kills servers and tests, replies `PAUSADO: <step>`, and waits for `CONTINUE`.

## Build

**Abuse case** (CONTEXT.md)
A way a step's code could be turned against the repo or its owner, written as a red test before the happy ones in the Test first of a `Risk: security` step, under one of four labels: `hook:` (the hook that must see the change), `third-party input:` (a fork, a predictable name, a path with `..` or a symlink), `check-to-use:` (state that changes between the check and the use, such as a `HEAD` that moves), `deletion:` (what is deleted and what must never be). A label that does not apply reads `n/a — <why>`; `plan-check.sh` refuses a label left empty. *Avoid:* attack case, threat case, security test.

**T0 / T1 / T2**
The work-item tiers: an idea in conversation (T0), a GitHub issue (T1), and the plan file in a feature worktree (T2). Promotion is one-way.

**Orchestrator**
The main session during `build` (or `wave`): it plans, dispatches, accepts and reviews through typed subagents, and keeps its own context thin.

**Lane** (build)
The path `build-size.sh` assigns to a build: `fast`, `visual`, `small`, `normal`. Also the **inline lane**: work only the main session may do (visual, judgment, trivial T0, the red loop of a hard bug).

**Lane** (wave)
One issue's worktree and session inside a wave, on a host (`local` or a remote host).

**Step**
One verifiable unit of a plan, with nine fields: Files, Does, Test first, Verify, Type, Risk, Category, Parallel with, Model.

**Wave** (inside a build)
A set of plan steps with disjoint Files, built in parallel and accepted together by `accept-wave.sh`.

**Rejection ladder**
revise → escalate → replan → block: one rung per failure of a step.

**Drift stop**
The two-axis check (code since `Planned at`, issue since `Ticket-synced-at`) before building from a plan written in an earlier session.

**Visual brief**
`.rumo/visual-brief.md`: purpose, content inventory, dominant element, reference image, rules that apply. The visual judge's criteria beside the issue's `[visual]` lines.

## Map

**Fog**
Decisions you can tell are coming but can't phrase sharply yet; kept under `## Not yet specified`.

**Frontier**
The open, unblocked, unclaimed tickets of a map.

**Destination**
What reaching the end of a map looks like, in one or two lines.

## Learn

**Lesson**
One imperative rule that would have prevented a real, observed mistake, stored as one line in a `lessons.md`.

**Event**
One JSON line in `~/.claude/learn/events.jsonl`, of kind `revise · escalate · replan · block · scope · finding · run`.

**Promotion**
Moving a lesson seen in two or more sessions into the file where it changes behaviour, as an approved diff.

Next: [[Architecture and Design History]]
