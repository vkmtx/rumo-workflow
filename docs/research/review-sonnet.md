# Review axes on sonnet — what would be lost

Study for #112 (2026-11-12): can part of the review's axes run on `rumo:reviewer-sonnet` without losing a blocker or major? Severity, axes and the §2 replay are the ones in `skills/review/SKILL.md`. No agent model changes here. The security axis stays on the strong model whatever the result says, by the issue's scope.

## Sources

Repositories other than `rumo` are anonymized (`repo-a`, `crm-b`, …). Every number below comes from one of these sources, all over the window **2026-10-29T00:00Z → 2026-11-12T23:59Z**:

| Id | Source | Extracted by |
|---|---|---|
| LOG | `~/.claude/learn/events.jsonl` + `~/.claude/learn/events-202610.jsonl.gz` (read with `gzip -dc`), rows `kind=finding`. The log's last finding in window is 2026-11-12T10:30Z | python over the two files, filtered on `ts` |
| RUNS | `~/.claude/projects/*/*/subagents/agent-*.jsonl` + `.meta.json`. Reviewer runs are those with `agentType` containing `reviewer`, or a `review` description and an `AXIS:` line in the brief: 2,151 runs. Axis, `RANGE` and `TIER` come from the brief (first user message), and the report from the last assistant message. Duration is first-to-last `timestamp`. Tokens are `message.usage` (input + cache creation + cache read + output), counted once per `message.id`. A run is **complete** when its report carries `AXIS:` and `FINDINGS`; only complete runs are counted | a `rumo:extractor` script that writes one JSON line per run, aggregated in python |
| PAIRS | Within RUNS: 74 ranges reviewed on the **same axis and range, in the same session**, by an opus reviewer and a sonnet reviewer (descriptions "… (opus paired)" / "… (sonnet)", 2026-10-29 → 2026-11-02). All 74 are on the standards axis | as RUNS; findings matched by an opus judge (fable usage-limit fallback) (§Sample comparison) |
| RERUN | 10 of 15 candidate ranges from RUNS (bugs 3, spec 3, fix 3 + 1 control), re-reviewed today with `rumo:reviewer-sonnet` from the original brief | this study's sessions, 2026-11-12 |

"Blocker/major reported" means lines `N. [blocker|major]` in a complete report. "Real" means a blocker/major the build acted on, i.e. a LOG row with `outcome: fixed`. LOG has no time or token fields; those come only from RUNS.

## Baseline

From LOG (findings by axis × reviewer model; every column after the first counts blocker+major only):

| Axis | Model | Findings (all sev.) | Blocker/major | of which fixed (real) | dismissed | open | Builds with ≥1 real |
|---|---|---|---|---|---|---|---|
| bugs | opus | 485 | 148 | 141 | 4 | 3 | 101 |
| standards | opus | 640 | 61 | 53 | 6 | 2 | 45 (both models) |
| standards | sonnet | 249 | 11 | 10 | 1 | 0 | ↑ |
| spec | opus | 419 | 142 | 114 | 11 | 17 | 95 |
| fix | opus | 206 | 34 | 31 | 0 | 3 | 30 (all models) |
| fix | sonnet | 28 | 3 | 3 | 0 | 0 | ↑ |
| security | opus | 117 | 37 | 36 | 0 | 1 | 27 |

**§2 replay.** LOG records no replay outcome per finding, so the count of blocker/majors that reproduced under §2 cannot be measured from it. What it does record: in the window, no blocker/major on any review axis (the `visual` judge's 5 `wrong` dismissals are not review replays) was dismissed with reason `unreplayed` or `wrong` (the replay-demotion reasons). Blocker/majors dismissed with no reason, logged before the `reason` field existed: bugs 3, standards 6, spec 7, fix 0, security 0. Waived by the owner: bugs 1, standards 1, spec 3. This study therefore uses **fixed** as the proxy for "reproduced and acted on" on every axis. In the reruns, every sonnet-only blocker/major was replayed by hand except fix3's, which could not be (§Sample comparison).

(LOG `model: opus` is the judgment tier's key, fable runs included — `build.md` §9. `orchestrator` rows, 7 in all, are omitted.)

From RUNS (complete runs, by axis × model family):

| Axis | Model | Runs | Median min | p90 min | Median tokens (k) | Blocker/major reported | Runs with ≥1 |
|---|---|---|---|---|---|---|---|
| bugs | opus | 404 | 3.5 | 7.6 | 652 | 273 | 184 |
| bugs | fable | 9 | 6.2 | 10.1 | 900 | 5 | 3 |
| standards | opus | 338 | 2.1 | 4.0 | 514 | 143 | 107 |
| standards | fable | 9 | 3.8 | 7.7 | 708 | 2 | 2 |
| standards | sonnet | 98 | 1.0 | 2.9 | 259 | 19 | 13 |
| spec | opus | 356 | 2.5 | 6.1 | 575 | 256 | 184 |
| spec | fable | 9 | 5.4 | 6.4 | 714 | 4 | 3 |
| fix | opus | 425 | 2.3 | 7.1 | 380 | 85 | 68 |
| fix | fable | 17 | 5.6 | 11.6 | 704 | 3 | 3 |
| fix | sonnet | 111 | 1.2 | 6.0 | 181 | 13 | 13 |
| security | opus | 122 | 1.7 | 3.7 | 299 | 53 | 35 |
| security | fable | 9 | 3.7 | 9.3 | 644 | 3 | 3 |

bugs, spec and security also have 2–3 sonnet runs each (fallbacks), too few to read. Fable entered as the judgment model only on 2026-11-11/12 (first fable review run with an axis in RUNS: 2026-11-11T21:19Z), so its 9–17 runs per axis cover a different, smaller set of builds than opus's. Its higher medians are not a like-for-like comparison.

## Sample comparison

Two samples. Both use the rule from the plan:

- **Missed**: a real blocker/major from the original review that sonnet does not report, or reports only as minor or as a question (the minor case is marked *downgraded*).
- **Extra real**: a blocker/major only sonnet reported, whose proof reproduces (§2 replay) and which the build later fixed.
- **Unconfirmed**: a sonnet-only blocker/major that reproduces as a fact but that the build never acted on, or that could not be replayed.

### A. Standards — 74 natural pairs (PAIRS, 2026-10-29 → 2026-11-02)

Every pair is the same range, reviewed on the same axis in the same session by opus and by sonnet. In 47 pairs neither model reported a blocker/major. The other 27 were matched finding by finding by an independent judge: `general-purpose` on opus, because fable hit its usage limit. That is the fallback `build.md` §5 gives a visual judge; §5 names none for a matching judge, and a sonnet judge would grade its own model. The judge saw only finding lines and LOG rows. "Real" = a LOG `fixed` row on the standards axis for the same repo#issue that describes the same defect.

| | Opus | Sonnet |
|---|---|---|
| Real blocker/major found by opus | 19 | caught 7 · downgraded 5 · **missed 7** |
| …of the missed: blockers / majors | — | **1 / 6** |
| Opus blocker/major with no LOG `fixed` row (unconfirmed) | 15 | caught 1 · downgraded 3 · missed 11 |
| Sonnet-only blocker/major | — | 2 real · 4 unconfirmed |
| Median duration (all 74 pairs) | 2.2 min | 1.0 min |
| Median tokens (all 74 pairs) | 663k | 269k |

Missed real findings, one line each:

- repo-a#2, blocker: a generated root `AGENTS.md` committed outside the plan's scope (another round's sonnet run did catch it);
- crm-b#2, major: a page recomputes totals instead of calling the step 2–5 modules;
- repo-c#598, major: reminder text ignores `AppSettings.agentTone`, against invariant 10;
- manager-d#459, major: six StatCards where the DS requires MetricStrip;
- manager-d#463, major: a new external effect without the local-Supabase dry-run;
- rumo#29, major: the `check-verify` regex doesn't count `bash scripts/test-all.sh`;
- website-d#36, major: an Android ad ID written in the present tense, against the file-header rule.

### B. Bugs, spec, fix — 10 reruns (RERUN, 2026-11-12)

Picked from RUNS: complete opus/fable runs whose two SHAs are still reachable in `~/orca/projects/<repo>`, at most 2 per repo per axis, newest first. Each axis got runs with ≥1 real blocker/major (a LOG `fixed` row for the same repo#issue and axis), and fix also got one control run with none. Every rerun used `rumo:reviewer-sonnet` with the original brief, verbatim. Every original worktree and plan file had been deleted, so `REPO` pointed at the main checkout and the issue served as the only spec. That cost the spec axis its secondary spec, the plan. Seven of the ten ranges are `TIER: sensitive`, including all four fix ranges.

| Tag | Repo#issue | Axis | Range | Original (model · real b/m) | Sonnet: caught / missed (blk·maj) | Extra real | Unconf. | Min orig → sonnet |
|---|---|---|---|---|---|---|---|---|
| bugs2 | repo-e#42 | bugs | `544965a..d1367d0` | opus · 1 maj | 0 / 0·1 | 0 | 0 | 3.5 → 3.1 |
| bugs3 | rumo#98 | bugs | `4919e92..5155d6e` | fable · 1 blk + 1 maj | 0 / 1·1 (maj downgraded) | 1 | 0 | 10.1 → 9.8 |
| bugs5 | repo-f-admin#12 | bugs | `6e21266..849d992` | opus · 1 maj | 0 / 0·1 | 0 | 0 | 4.7 → 2.7 |
| spec3 | rumo#98 | spec | `4919e92..ed14207` | opus · 1 blk + 1 maj | 1 (blk as maj) / 0·1 (downgraded) | 1 | 0 | 1.8 → 7.5 |
| spec4 | repo-f-front#47 | spec | `1c4a99b..926de51` | opus · 1 blk | 0 / 1·0 | 0 | 0 | 6.8 → 1.7 |
| spec5 | repo-f-admin#12 | spec | `6e21266..849d992` | opus · 1 blk | 1 / 0·0 | 0 | 1 | 2.6 → 2.8 |
| fix1 | repo-e#38 | fix (control) | `7d4eada..6ec4b5b` | opus · 0 | — | 0 | 0 | 1.3 → 1.4 |
| fix2 | repo-e#9 | fix | `00d4096..d3b2247` | opus · 1 blk | 0 / 1·0 | 0 | 0 | 2.0 → 1.0 |
| fix3 | rumo#98 | fix | `99330b3..1ddf696` | opus · 1 blk | 0 / 1·0 | 0 | 1 | 5.8 → 14.0 |
| fix5 | repo-f-collector#8 | fix | `a20a1e9..1d824a7` | opus · 1 maj | 1 / 0·0 | 0 | 0 | 1.9 → 1.7 |

What each miss was, and what each sonnet-only finding was:

- **bugs2**: on A→B→A, the repeated question reuses an already-reserved dispatch key. Sonnet listed that exact key logic under CHECKED AND SOUND.
- **bugs3**:
  - Missed blocker: the glob-basename match makes `rm -rf dist/*` count as a write to the Mandato.
  - Downgraded major: an implied-destination `git push` is unprotected under `alcance=pr`.
  - Extra real: `/usr/bin/gh pr merge` bypasses the gate (`pr-base-guard.sh:956` at `5155d6e` tests `w[0] != 'gh'`); the build fixed it in `ac2ae32`.
- **bugs5**: a target with failed backfill windows is shown green as "complete history". Sonnet called the state transitions sound.
- **spec3**:
  - Downgraded major: the hook read the Mandato of the session's cwd, not of the target directory. Sonnet raised it only as a question.
  - Extra real: `git -C <wt> push` skips the Mandato gate (`pr-base-guard.sh:830` at `ed14207`); the build fixed it in `da9f2aa`.
- **spec4**: the List/Map tablist on the profiles page is still 32 px at 390.
- **spec5**: unconfirmed sonnet major. Shared primitives were restyled for every page; the grep proof holds, but the build never acted on it.
- **fix1** (control): neither model reported a finding. The two disagree on `spec#1` only because issue #42 was closed after the original run.
- **fix2**: the outbound module's dispatch-key pattern rejects the new `r<n>` keys the fix queues. Sonnet listed the `r<n>` key as sound.
- **fix3**:
  - Missed blocker: the `$?` dir marker reaches the review gate, which then fails open with no Mandato. The build fixed it in `5155d6e`.
  - Unconfirmed sonnet major: a prefix assignment `HOME=… git -C $HOME/…` escapes the gate. The original harness is gone and no later commit addresses it, so it is unreplayed.

## Summary

Real blocker/major per axis. "Real in sonnet" = caught + extra real. "Missed" counts downgraded findings as missed.

| Axis | Sample | Real in opus/fable | Real in sonnet | Missed (blocker · major) | Δ time (sum, orig → sonnet) |
|---|---|---|---|---|---|
| bugs | 3 reruns | 4 | 1 | 4 (1 · 3) | 18.3 → 15.6 min (−15%) |
| standards | 27 of 74 pairs | 19 | 9 | 12 (≥1 · ≥6; the 5 downgraded aren't split by severity) | 198.7 → 118.1 min over 74 pairs (−41%); median 2.2 → 1.0 |
| spec | 3 reruns | 4 | 3 | 2 (1 · 1) | 11.2 → 12.0 min (+7%) |
| fix | 3 reruns + 1 control | 3 | 1 | 2 (2 · 0) | 11.0 → 18.1 min (+65%) |
| security | not rerun (out of scope) | 37 blocker/major in LOG, 36 fixed | — | — | — |

Sonnet was not reliably faster on the reruns: quicker on bugs (−15%), slower on spec (+7%) and fix (+65%). On spec3 and fix3 it ran 4× and 2.4× longer, partly because the machine was loaded (the wave orchestrator reported load 43 on 10 cores during a PAUSA; `uptime` after the reruns, 12:50 local, read 4.35 / 13.74 / 28.94). Most of the cost difference is in tokens (standards median 663k → 269k), not in wall-clock.

## Recommendations

The rule: an axis goes to sonnet only with **0 blockers missed** (issue #112) **and 0 majors missed** (the plan's stricter reading) in the sample. No axis passes, so no build issue is opened.

### bugs

Keep on the judgment model. In 3 reruns sonnet missed 1 blocker and 3 majors and caught none of the 4 real ones. Twice it put the very code that held the bug under CHECKED AND SOUND (bugs2, bugs5). Its one extra real finding (bugs3) does not offset that.

### standards

Keep on the judgment model. Across 74 natural pairs, sonnet missed 7 of the 19 real blocker/majors (1 blocker, 6 majors) and downgraded 5 more to minor. This is the axis where sonnet is clearly cheaper (−59% median tokens, −55% median time). The misses, though, are exactly the repo-documented rules standards exists for: DS components, invariants and file-header rules.

### spec

Keep on the judgment model. In 3 reruns sonnet missed 1 blocker (spec4) and downgraded 1 major to a question (spec3). It caught 2 of the 4 real findings and found 1 extra real blocker. That makes it closer to the original than on any other axis. Still, 2 misses fail the rule, and the reruns ran without the plan file the originals had.

### fix

Keep the sensitive tier's fix re-review on the judgment model. In 3 sensitive-tier reruns sonnet missed 2 of 3 real findings, both blockers that the fix itself introduced (fix2, fix3). The original reviewer flagged them as new defects, and the build fixed them. Sonnet marked every earlier id RESOLVED and reported neither regression (on fix3 it raised only an unrelated, unconfirmed major).

Today `skills/review/SKILL.md` sends only the **non-sensitive** fix re-review to sonnet, and that route was not sampled here: all four fix ranges were sensitive. This study neither confirms nor refutes it. Sonnet's two misses were both new regressions introduced by a fix, which is what any fix re-review exists to catch. So a paired sample of non-sensitive fix re-reviews (opus and sonnet on the same range) is worth running before the route is relied on further.

### security

Stays on the strong model (out of scope by the issue, whatever the result). It was not rerun. LOG has 37 security blocker/majors in the window, 36 of them fixed.

## Limits

- Five picked candidates were never rerun: spec1 (repo-e#38, real), bugs4 and fix4 (both rumo#98, real, the same issue as bugs3/fix3), and the bugs and spec controls (bugs1, spec2). The cut came after the first four reruns, which had already put a missed blocker or major on every candidate axis. It was made by repo spread and machine load, not by how sonnet did on those ranges. Only fix kept a control.
- n is small: 3 real ranges per rerun axis, 27 informative pairs for standards. That is a screen, not proof. Every axis already failed the 0-miss rule, so more reruns could not change the recommendation; the rerun sample stopped at 10 (the issue's lower bound) for that reason.
- "Real" means a LOG `fixed` row for the same repo#issue and axis that describes the same defect, matched by text. LOG rows carry no range or finding id.
- The reruns lacked the plan file and the `$TMPDIR` harnesses the original briefs named. That handicaps spec and fix slightly. The issue body, the authority, was always available.
- The originals ran 2026-11-09 → 12. The reruns ran 2026-11-12, under machine load, so durations are noisy.
- The rumo#98 ranges account for half the rerun misses (4 of 8). It is the hook work, the hardest diff in the sample.
