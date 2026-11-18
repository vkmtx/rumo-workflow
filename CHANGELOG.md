# Changelog

All notable changes to rumo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow the plugin version in
`.claude-plugin/plugin.json` (0.x: any release may change behavior).

## [Unreleased]

## [0.13.0] - 2026-11-18

### Added

- MIT license and community health files.
- A wiki and diagrams (light and dark).
- CI and tag-driven release workflows.
- `scripts/leak-scan.sh` and `scripts/export-public.sh`, to scan for personal data and publish a clean public snapshot.

### Changed

- All comments, hook and script messages and docs are in English. Protocol tokens and the Portuguese matchers for what the owner types are unchanged.
- Design records are translated and renamed.

## [0.12.4] - 2026-11-17

### Changed

- The planner agent is pinned back to the opus tier (it had moved to a different tier in 0.12.1). Help text and design notes record the reversal.

## [0.12.3] - 2026-11-15

### Removed

- Codex is no longer part of the workflow: its review path and references are gone.

## [0.12.2] - 2026-11-15

### Changed

- Help text routes usage-limit errors to the planner's quota.

### Fixed

- `ship.sh` skips a fork pull request that happens to share the branch name.
- `pr-base-guard` recognizes every shell form of a `ship.sh` call (including `dash`/`ksh`/`mksh -c` nesting) and closes several shell-option bypasses (`+c`, `-n +n`, `--emulate`, bare `source`, `noexec`); a `ship.sh` call with an unresolved worktree fails closed.
- `visual-lint` clipped-text check catches text cut inside `display: contents` and float parents.

## [0.12.1] - 2026-11-15

### Changed

- The planner agent moved to a different model tier (reverted in 0.12.4).

## [0.12.0] - 2026-11-15

### Added

- Wave lanes turn off per-lane LSP plugins and launches are gated on measured free RAM; `wave-lane-prep.sh` prepares a lane and refuses symlinked `.claude` targets.
- `wave-status` prints the machine line (load and memory) with each lane.

## [0.11.2] - 2026-11-15

### Added

- `CONTEXT.md` defines the abuse case term; `build.md` documents Rules A and B.

### Fixed

- `plan-check` Rule B refuses an empty abuse-case label; labels match at a word start and a dash before a bare `n/a` still counts as empty.

## [0.11.1] - 2026-11-15

### Fixed

- Wave orchestration reads the worktree id from the launch result, rechecks `CONTINUE` before relaunching, and attributes load before pausing a wave.

## [0.11.0] - 2026-11-13

### Fixed

- `worktree-guard` reads a Python heredoc body by AST instead of by pattern: a program that only mentions `.env` as data passes, while file touches, dynamic callables, dir enumeration and late imports fail closed.

## [0.10.2] - 2026-11-12

### Changed

- Opus is the default judgment tier again (planner, reviewer, builder-opus and visual-judge), replacing the tier introduced in 0.8.48.

## [0.10.1] - 2026-11-12

### Added

- Research note comparing review axes on sonnet versus opus (`docs/research/review-sonnet.md`): baseline from the learn log, sample comparison and a per-axis recommendation.

## [0.10.0] - 2026-11-12

### Added

- The planner writes abuse cases first: a step that pushes, merges, deletes or installs a hook is `Risk: security` and carries four labelled abuse cases before the happy path.
- `plan-check` enforces that rule as a floor and stays quiet for read-only commands, `docker --rm` and `rm` in prose.

## [0.9.0] - 2026-11-12

### Added

- `accept-wave.sh` accepts, commits and marks a whole wave in one call.
- `build-size.sh` picks the build lane; `inbox.py` lists sessions waiting on the owner.
- `ship.sh` pushes, opens the PR, files the follow-up issue, waits for checks, merges and cleans up in one call, with a model-limit fallback and API-error continue. It merges only into the integration branch unless told otherwise, reuses only a same-repo PR on the stamped head and merges with `--match-head-commit`.
- `visual-lint` gains clipped-text and contrast checks, a `--scheme` option and `--shots`.
- Decide-and-record gate in `build`: the orchestrator decides, records the decision, and asks the owner only for items on the Critical list.

### Changed

- `/learn phases` keeps wave orchestrators and launcher messages out of builds and owner waits.
- `pr-base-guard` reads a `ship.sh` call as push plus PR plus merge on its worktree.

## [0.8.49] - 2026-11-12

### Added

- Mandato (mandate): a signed (HMAC) per-lane file that states what a wave lane may do. `pr-base-guard` reads it, protects the file from writes (including `git -C`, refspecs, API merges, `rm`, `find -delete`, `chmod`, `cp`) and fails closed on unresolved paths under a Mandato.
- Relatório (report) line emitter and parser (`relatorio.py`) for build results, with validators that refuse a trailing newline.

## [0.8.48] - 2026-11-11

### Changed

- Planner, reviewer, builder-opus and visual-judge moved from the opus tier to a different tier; untyped calls follow (reverted in 0.10.2).

## [0.8.47] - 2026-11-10

### Fixed

- `wave-status` reads a structured (chat) launch as `session=chat` instead of dead; wave docs force `--surface terminal` for launches and never relaunch a stalled chat lane.

## [0.8.46] - 2026-11-10

### Added

- Shared `owner_message` rule: a launch prompt is never the owner's message, so it cannot unlock a deploy, a production write or an `#env-ok`. Launch prompts carry a `LAUNCHED-BY:` line.

### Fixed

- Agent and cross-session messages never count as the owner's; the build-mode scan in `pr-base-guard` fails closed without `owner_message`.

## [0.8.45] - 2026-11-08

### Fixed

- The Follow-up line is appended after a blank line so it does not join the last bullet of the PR body.

## [0.8.44] - 2026-11-08

### Fixed

- The Follow-up line is built from the live PR body read back from GitHub instead of from memory.

## [0.8.43] - 2026-11-08

### Fixed

- `replay-blocks` requires `--out` instead of defaulting into the user's learn directory.

## [0.8.42] - 2026-11-08

### Added

- A PR spawns one Follow-up issue for the minors, questions and waived findings still open; the two link each other.

### Fixed

- The Follow-up line re-sends the full PR body; waived blockers count.

## [0.8.41] - 2026-11-08

### Added

- An Open finding (a blocker or major that no fix reviewer resolved and the owner did not waive) holds the review stamp back; only a Waiver typed by the owner releases it.
- The reviewer's fix axis writes `RESOLVED`, `NOT RESOLVED` or `WITHDRAWN <axis>#<n>`; fix rounds close findings through `--fix` and `--inline-fix`.
- `CONTEXT.md` and the first ADR (open findings from reviewer transcripts).

## [0.8.40] - 2026-11-08

### Fixed

- `worktree-guard` heredoc scan is linear, segments are cached, and a scan that overruns its time limit denies instead of timing out.

## [0.8.39] - 2026-11-08

### Fixed

- `wave-status` prints issueless lanes as `lane:<slug>` and counts a slug file as a lane only when it holds a launch result.
- `worktree-guard` flag and URL checks read the command with comments stripped and the deny side reads the raw command.

## [0.8.38] - 2026-11-07

### Fixed

- `worktree-guard` ends a comment at its own newline; `#` inside a word, quotes or after `)` is treated as code when unsure.

## [0.8.37] - 2026-11-07

### Fixed

- `/learn phases` classifier covers wrappers, heredocs, comments, nested scripts and citations; it reads a whole `sh -c` word.

## [0.8.36] - 2026-11-07

### Changed

- Wave remote commands are built by one `remote()` helper; terminal text is read as data.

### Fixed

- `/learn phases` counts real test runs, closes queue-only background tasks and splits commands only outside quotes.

## [0.8.35] - 2026-11-06

### Fixed

- `worktree-guard` matches environment assignments on the raw token, reads assignments only where the shell does, masks backticks, and checks supabase and migration commands independently.

## [0.8.34] - 2026-11-06

### Changed

- Rules from a `/learn review` are reapplied: main-checkout commands stand alone, one command per `[cmd]` criterion, the wave brief is in reviewer scope.

## [0.8.33] - 2026-11-06

### Added

- `worktree-guard` opens a third concurrent test slot when free memory is 30% or more (otherwise 2).

## [0.8.32] - 2026-11-05

### Fixed

- `worktree-guard` narrows two loosenings to tracked files listed by `git ls-files` and plain redirect targets, and reads redirect targets case-insensitively without opening an `.example` exemption.

## [0.8.31] - 2026-11-05

### Added

- `plan-check --small` enforces 2 steps and 8000 characters for a small issue; the planner is told `SIZE: small`; a misclassified small issue leaves the lane instead of looping on a plan failure.

## [0.8.30] - 2026-11-05

### Changed

- Builders run only their step's test file; the full suite runs once after the last wave.

## [0.8.29] - 2026-11-05

### Added

- `/learn phases`: a session timeline with critical-path attribution, aggregates, and a block in `/learn review`.

## [0.8.28] - 2026-11-05

### Added

- `wave-status` prints `idle`, `stalled` and `awake` per lane (and reads workflow subagent transcripts for idleness); docs describe the stalled lane and `caffeinate`.

## [0.8.27] - 2026-11-04

### Added

- Security review axis: the sensitive tier dispatches it on `rumo:reviewer` (and `reviewer-sonnet`) instead of `/security-review`; `review-stamp` requires it on that tier even when axes are named by hand, and refuses a light or standard review when the path scan hits the diff.

## [0.8.26] - 2026-11-03

### Fixed

- `visual-lint` exits 2 with a clear message when node is missing, flags native controls only when they are a 100%-default control, ignores punctuation-only separators in links, and snapshots page style before inserting its reference.

## [0.8.25] - 2026-11-03

### Changed

- Docs: the replay environment rule is scoped to a worktree, both Orca result shapes are documented per command, and `wave.md` names `result.outcome.handle`.

## [0.8.24] - 2026-11-03

### Fixed

- `worktree-guard` denies `$(cat .env)` in unquoted heredoc bodies, `.env` names fed to interpreters or ssh, and a `.env` read piped into `tee`; xargs/rsync stdin sources count only in their own list element; unsure cases fail closed.

## [0.8.23] - 2026-11-03

### Changed

- The wave state directory sits beside the brief; the remote preflight syncs on version or hook drift before falling back to local; a reused wave name stops at `mkdir`.

## [0.8.22] - 2026-11-03

### Fixed

- `review-stamp` refuses `http.sslVerify` set to false, reading the value from the last field so a tab in a URL subsection cannot hide it.

## [0.8.21] - 2026-11-03

### Fixed

- `worktree-guard` env-copy detection ignores non-stdout redirections and inert heredoc bodies but fails closed on shell-run heredocs, continuations and fd dups; idle runners are dropped from the wait.
- `check-verify` and `render-verify` skip worktrees under temp directories.

## [0.8.20] - 2026-11-03

### Changed

- Docs: the event category is required in build section 9; both Orca result shapes are in `wave.md`; the replay environment and stamp network rules are in `review`.

## [0.8.19] - 2026-11-03

### Added

- `review-stamp` origin guard refuses rerouting transport config (URL rewrites, proxy and TLS-trust settings) in `--base-merge`; the remote tip is checked in both modes.

## [0.8.18] - 2026-11-03

### Added

- `visual-lint`: a wrapper and runner with rules for horizontal overflow, native controls, touch targets and sticky headers, run before the visual judge.

## [0.8.17] - 2026-11-02

### Changed

- The standards review axis runs on `rumo:reviewer` (opus) again; the sonnet experiment section is gone; pre-existing duplication outside the diff is not a finding.
- A dismissed finding carries a reason, and `/learn stats` groups dismissals by axis and reason.

## [0.8.16] - 2026-10-30

### Removed

- Triage labels retired with triage mode.

### Fixed

- `issue-criteria` parses up to the closing backtick, reads prose expectations, and reports MANUAL instead of FAIL when a criterion holds several commands.
- `sync-host` preflight fails on a host without a git identity; `wave-status` load probes go through the remote wrapper.
- `host-lib.sh` joins the sensitive-path scan.

## [0.8.15] - 2026-10-30

### Fixed

- `pr-base-guard` gates every merge on the PR head GitHub reports, fails closed on a URL target or an old `gh`, treats an own-owner `owner:dev` head as a release, and cites `--base-merge` when denying an ancestor stamp.

## [0.8.14] - 2026-10-30

### Added

- Visual brief before the first edit, whole-page acceptance criterion, dataviz guidance for dashboards, and a final `VERDICT` line from the visual judge.

## [0.8.13] - 2026-10-30

### Fixed

- `review-stamp`: SHA-256 sterile repo for the base-merge checker, one version check, EOF-less conflict resolutions, attribute-resolved conflicts refused on sensitive paths, and an unfetched remote tip is fetched instead of refused.

## [0.8.12] - 2026-10-30

### Fixed

- Wave follow-ups: the relaunch rewrites the slot's launch file so `wave-status` reads the new handle; remote env-file exception, `wt-gc` repo path and the wave directory repo file are documented.

## [0.8.11] - 2026-10-30

### Removed

- `/rumo audit` and `/rumo triage` (zero uses in a month); `map` stays. A router row explains the retirement.

## [0.8.10] - 2026-10-30

### Added

- Multi-host waves: `wave-host.sh` preflights a remote host, registers the repo, copies the brief and falls back to local; `wave-status` reads slots and machine load per host; per-host lane caps.

## [0.8.9] - 2026-10-30

### Added

- `context-nudge` hook: any prompt nudges once per context band from 200k tokens, and compaction re-arms it.

### Changed

- `wave-status.sh` prints every slot and the machine in one output.

## [0.8.8] - 2026-10-30

### Added

- Planner batch: plans over 24,000 characters fail `plan-check`; the planner batches reads, writes by turn ~28 with a 35-turn cap, and receives scout facts from the orchestrator.

## [0.8.7] - 2026-10-30

### Added

- `review-stamp --base-merge`: a merge of the base branch into a reviewed branch keeps the stamp when it is bump-only or merges cleanly (checked with `git merge-tree`); conflicts are accepted only as ours, theirs or both, and custom merge drivers are refused.

## [0.8.6] - 2026-10-30

### Added

- `scripts/test-all.sh` discovers and runs every test; exit 77 is SKIP; nested checkouts are skipped.

## [0.8.5] - 2026-10-30

### Changed

- Gate files (hooks, review, agents, installer, settings) hit the sensitive review scan.

## [0.8.4] - 2026-10-29

### Fixed

- `check-verify` and `render-verify` count only files inside the session's repo and honour `.claude/no-render-verify`.

## [0.8.3] - 2026-10-29

### Added

- `sync-host`: syncs the plugin, hooks and settings gate entries to a remote host (dry run by default, `--apply` backs up first, values are never printed) and reports a preflight.

## [0.8.2] - 2026-10-29

### Added

- `worktree-guard` counts logical test runs (one per jest/vitest node), reserves its slot under a lock and waits up to 50 s for one.
- `replay-blocks` harness replays recorded hook blocks against old and new hooks.

### Changed

- Builders run only the step's test file with `--maxWorkers=2`.

### Fixed

- `check-verify` no longer passes on backgrounded or hook-denied commands; wider recognition of test, lint and build commands.

## [0.8.1] - 2026-10-29

### Added

- `review-stamp.sh` is the only writer of the review stamp and needs reviewer evidence per axis; `--fix` accepts a reviewer fix axis or a verified inline fix.
- `pr-base-guard` denies hand-written stamps and gates dev-to-main release PRs by merged-PR provenance.

## [0.8.0] - 2026-10-29

### Added

- `/learn event` validates the run shape and requires finding severity; new `visual` category; `/learn normalize` writes a normalized copy and a dated backup and prints the diff; `stats` skips and reports malformed lines.
- A complete run example in build section 9.

## [0.7.0] - 2026-10-23

### Added

- `plan-check.sh`: one-call form check of a plan including the Model rule; the planner self-checks and cites the failed condition.
- `rumo:collector` agent: haiku web collection with no shell or file access, so page content never reaches a command.
- One batched, all-or-nothing `/learn event -` call per build.

### Changed

- Fix re-reviews run on `reviewer-sonnet`; the builder accepts a plan-less task brief that names its worktree.

## [0.6.0] - 2026-10-20

### Added

- `/rumo wave`: parallel Orca sessions, one worktree and `/rumo build` per issue, shared brief, RAM watch, pause and resume.
- Findings carry an outcome, axis and model; `/learn stats` compares findings by axis and model.
- `wt-gc` reports an ENV state and a `--with-env` option.

### Changed

- The standards review axis runs on `reviewer-sonnet` as a measured experiment (reverted in 0.8.17).

## [0.5.1] - 2026-10-17

### Added

- `/learn spend`: main versus subagent tokens, share above 300k, by agent type and model, heaviest runs; `/learn review` reports it.

## [0.5.0] - 2026-10-17

### Added

- `rumo:extractor` agent (haiku) for bulk extraction.

### Changed

- Calibrated delegation: sonnet builders for Risk-low steps, waves of five builders, sliced tasks.

## [0.4.0] - 2026-10-14

### Added

- Parallel clean-context review axes (bugs, standards, spec) with finding replay and a review stamp tied to HEAD.
- The issue is the spec authority; `issue-criteria.sh` runs an issue's `[cmd]` criteria at a fixed SHA, only for trusted issues (`issue-trust.sh`).
- Visual judge agent, a fast path and a ticketless build.
- `accept-step.sh` rejects load-only red and weakened tests.

## [0.3.1] - 2026-10-13

### Fixed

- Hardening: safe parallel waves, `accept-step` wired into build, an unattended gate, a mechanical review tier, learn events written by script, `wt-gc` for stale worktrees, and `smoke-agents.sh`.

## [0.3.0] - 2026-10-13

### Added

- Orchestrated `/rumo build` over typed subagents, a tiered review gate (light, standard, sensitive) and `/learn` to harvest corrections into rules.
- `accept-step.sh`: a step passes only when its verify command passes, runs more than zero tests, and goes red without the step's code.
- T0, T1, T2 work-item model with one-way stamped promotion and a two-axis drift stop.

## [0.2.0] - 2026-09-24

### Added

- `/rumo audit` (the former improve advisor folded into the flow); plans are ephemeral.
- `setup-repo` repairs a missing `origin/HEAD`; `ticket` self-heals a missing tracker document.

### Changed

- GitHub is driven through the `gh` CLI instead of a GitHub MCP server.
- A mode that leads into another names the command for the user to type instead of firing it.

## [0.1.0] - 2026-08-21

### Added

- First release: the `/rumo` flow verb, a review gate, `/learn`, `/setup-repo`, and ten discipline skills ported from mattpocock/skills 1.2.3.
