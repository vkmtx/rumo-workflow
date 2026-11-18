# Discipline Skills

rumo bundles ten model-invoked discipline skills under `skills/discipline/`. They are ported from [mattpocock/skills](https://github.com/mattpocock/skills) (version 1.2.3, MIT license) with their mechanism intact, and rumo's modes call them at specific points: `grilling` and `domain-modeling` drive align, `tdd` and `diagnosing-bugs` run in the build's inline lane, `prototype` answers detour questions, and `writing-for-agents` governs every edit to an instruction file. Because they are ported text, they are frozen in this repo: edits are limited to fixing references to command names rumo replaced.

## The ten skills

| Skill | What it does (from its description) | Where rumo uses it |
|---|---|---|
| `grilling` | Grills the user relentlessly about a plan, decision or idea, one question at a time | align's interview; `grilling` tickets in `map` |
| `domain-modeling` | Builds and sharpens a project's domain model: ubiquitous language in `CONTEXT.md`, decisions as ADRs | align writes terms and decisions the moment they resolve; `map` grilling tickets |
| `tdd` | Test-driven development, red-green-refactor in vertical slices | the build's inline lane, at agreed seams |
| `diagnosing-bugs` | A diagnosis loop for hard bugs and performance regressions: a reproduction that goes red before any theory | inline in `build` for a bug that resists a first glance; once the loop is red and the fix specified, the fix may go to a builder |
| `prototype` | A throwaway prototype that answers one design question, logic or UI, never both | the prototype detour from align or build via `handoff`; `prototype` tickets in `map` |
| `research` | Investigates a question against high-trust primary sources and writes the findings to a Markdown file | `research` tickets in `map`, run in parallel |
| `codebase-design` | Shared vocabulary for deep modules: interfaces, seams, deepening opportunities | design discussions and other skills that need the vocabulary |
| `resolving-merge-conflicts` | Resolves an in-progress merge or rebase by reading each side's primary sources and preserving both intents | merge conflicts during a build or a base merge |
| `wizard` | Generates an interactive bash wizard that walks a human through steps only they can do (dashboards, credentials, CI secrets, cutovers) | manual procedures the agent cannot perform |
| `writing-for-agents` | How to write documents for agents: skills, `CLAUDE.md`, `AGENTS.md` | loaded before every `/learn review` promotion and before editing any `SKILL.md` in rumo |

## Supporting files

Several skills ship reference files beside their `SKILL.md`:

| Skill | Files |
|---|---|
| `codebase-design` | `DEEPENING.md`, `DESIGN-IT-TWICE.md` |
| `domain-modeling` | `ADR-FORMAT.md`, `CONTEXT-FORMAT.md` |
| `prototype` | `LOGIC.md`, `UI.md` |
| `tdd` | `mocking.md`, `tests.md` |
| `diagnosing-bugs` | `scripts/hitl-loop.template.sh` |
| `wizard` | `template.sh` (the wizard library: stage progress, confirmation gates, hidden secret entry, `.env` upserts, `gh secret`/`gh variable` writes) |
| `writing-for-agents` | `SKILL-MECHANICS.md` |

Each skill also carries an upstream `agents/openai.yaml` metadata file.

## Upstream skills that became rumo modes

Some upstream skills were not ported as standalone skills; their role moved into `/rumo` or was retired:

| Upstream | In rumo |
|---|---|
| `to-spec`, `to-tickets` | merged into `/rumo ticket` |
| `handoff` | `/rumo handoff` |
| `audit`, `triage`, `improve`, `improve-codebase-architecture` | retired, no replacement |

The other replaced names (`ask-matt`, `grill-with-docs`, `grill-me`, `implement`, `wayfinder`, `setup-matt-pocock-skills`) have their replacements under `skills/rumo/references/`, per the maintenance rules in the repo's `CLAUDE.md`.

## Credit

The discipline skills are the work of Matt Pocock and contributors, published at [github.com/mattpocock/skills](https://github.com/mattpocock/skills) under the MIT license. rumo's command surface was also built from that collection (25 skills at the time) and from shadcn's `improve` advisor, which was retired together with `/rumo audit` in 0.8.x.

Next: [[Configuration]]
