# rumo — maintenance rules for this repo

- Every skill is either user-invoked (`disable-model-invocation: true` — rumo, learn,
  setup-repo) or model-invoked (review + everything under `skills/discipline/`). A
  user-invoked skill may call model-invoked skills, never another user-invoked one — to
  lead into one, it names the command for the user to type. One exception: `/rumo wave` starts
  `/rumo build` in the sessions it creates, for the issues the typed command names.
- The live hooks in `~/.claude/hooks/` are installed by the owner, never by a build.
- GitHub work goes through the `gh` CLI (`gh issue view/create/edit`, `--parent`,
  `--blocked-by`). No skill here may assume a GitHub MCP.
- Plans are ephemeral (`build` deletes each on merge), so nothing here treats `plans/` as a
  durable backlog.
- `skills/discipline/*` are ported from mattpocock-skills 1.2.3 with mechanism intact —
  edit them only to fix references to killed names (ask-matt, grill-with-docs, grill-me,
  to-spec, to-tickets, implement, wayfinder, triage, audit, handoff, improve-codebase-architecture,
  setup-matt-pocock-skills, improve). Their replacements live under `skills/rumo/references/`, except audit, triage, improve
  and improve-codebase-architecture: retired, no replacement.
- Every orchestrator turn ends with a literal `NEXT:` line (clear | keep-open until X |
  rewind to Y). If you add a mode, it inherits this contract.
- After touching either manifest run `claude plugin validate .` (see the `--strict` note below).
- Every behavior change bumps `version` in `.claude-plugin/plugin.json` — bump only inside the
  pre-merge base-merge commit (`skills/rumo/references/wave.md` §Merging), so no ticket lists
  `plugin.json` in its files — then `claude plugin update rumo@rumo`: Claude Code runs a cached copy
  (`~/.claude/plugins/cache/rumo/`), so an unbumped edit never reaches a session.
- When a skill's behavior changes, update the case map in `skills/rumo/references/help.md` —
  a router that lies is worse than no router. Load `writing-for-agents` before editing
  any SKILL.md here.
- Origin: designed and stress-tested 2026-08-21.
- `agents/*.md` are the typed subagents `/rumo build` and `review` dispatch (`rumo:<name>`).
  Model and effort live only in their frontmatter — skills dispatch them without a `model`
  param (a param overrides the pin). `builder.md` and `builder-opus.md` share one body, and so do `reviewer.md` and
  `reviewer-sonnet.md`: edit each pair in the same commit. The sonnet-vs-opus Model rule's single source is `agents/planner.md`.
- Byte budgets: `python3 -I skills/learn/scripts/learn.py budget agents/*.md skills/*/SKILL.md` —
  `skills/discipline/*` is left out on purpose (ported text, frozen by the rule above).
  Tests: `bash scripts/test-all.sh` — discovers every `*_test.sh`, `*.test.sh` and `*_test.py`, so a new
  test needs no line here; a `<dir>/tests/<name>.test.sh` gets `HOOK=<dir>/<name>.{sh,py}` when that file
  exists (the staged hooks; the live copies in `~/.claude/hooks/` are installed after merge); `--root <dir>`
  runs a tree without `.git`, where a test that needs git history exits 77 and shows as `SKIP`. Its own test: `bash tests/test_all_test.sh`. After editing `agents/` or updating `claude`: `bash scripts/smoke-agents.sh
  --plugin-dir .` (live run, ~1 min; asserts each agent's real model). The installed plugin's agents shadow
  `--plugin-dir`, so a NEW agent verifies only after the bump + `claude plugin update rumo@rumo`, with a bare run.
- `claude plugin validate . --strict` fails on the default branch since validator 2.1.27x with one warning
  (root `CLAUDE.md` is not loaded as plugin context) — that file is for maintainers, keep it.
  Run without `--strict`; accepted are that warning and the directory check `ICON_MISSING`
  (rumo is not listed in the plugin directory; the icon is the owner's call when listing it). No other
  warning; the `ℹ Advice` block doesn't change the verdict and doesn't count.
