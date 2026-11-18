# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting:
<https://github.com/vkmtx/rumo-workflow/security/advisories/new>

Do not open a public issue or pull request for a vulnerability, and do not post credentials or
reproduction details in Discussions. You will get an acknowledgement through the advisory thread;
fixes are developed in the private advisory and published together with the release.

## Scope

rumo is a Claude Code plugin made of skills, typed subagents and shell/Python scripts. The parts
that matter for security are the **hooks and gates**, because they are the mechanical safety net
around an autonomous agent:

- `scripts/hooks-staged/` — `worktree-guard`, `pr-base-guard`, `check-verify`, `render-verify`,
  `context-nudge`, and the shared `owner_message` and `mandato` modules. A bypass of any of them
  (a command shape that slips past a deny rule, a launch prompt that is treated as the owner's
  approval, a way to write a review stamp or a Mandato by hand) is in scope.
- `skills/review/` — the review stamp and its only writer, `review-stamp.sh`, including the
  base-merge checker.
- `skills/rumo/scripts/ship.sh` and the wave launcher scripts (`scripts/wave-*.sh`,
  `scripts/sync-host.sh`), where a wrong branch, repository or host could push, merge or delete
  something unintended.
- Secret handling: anything that makes the tooling print, copy or log credentials or `.env` files.

Out of scope: vulnerabilities in Claude Code itself, in `gh`, `git` or other third-party tools
(report those upstream), and findings that need an attacker who already controls the machine and
the Claude Code settings.

## What a good report contains

The hook or script involved, the exact command or input that gets through, what you expected to be
denied, and the version from `.claude-plugin/plugin.json`.

## Supported versions

Only the latest release receives fixes.
