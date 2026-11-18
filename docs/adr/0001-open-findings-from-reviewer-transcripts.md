# Open findings come from reviewer transcripts, closed only by a reviewer or the user

`review-stamp.sh` refuses the stamp while a blocker or major finding is open (#15). It takes the list from the final assistant message of each `rumo:reviewer*` transcript it already accepts (findings get ids `<axis>#<n>` from the numbered FINDINGS list), and a finding closes only through a finished `fix` reviewer run that writes `RESOLVED <axis>#<n>` or `WITHDRAWN <axis>#<n>`, or through an explicit waiver by the user. So the orchestrator can no longer close a major itself: an inline fix (< 30 lines) closes only minors, and a replay that fails to reproduce a major demotes it in the report but needs a fix reviewer's `WITHDRAWN` before the stamp.

## Considered Options

- **Orchestrator passes the open list as a flag** — rejected: the orchestrator vouching for itself, the gap #9 closed.
- **The script re-runs each `proof:` command** — rejected: executes commands a reviewer wrote from a possibly untrusted diff.
- **Replay demotion closes a major without a reviewer** — rejected: cheaper by one reviewer run, but the demotion is the orchestrator's own judgment.

## Waiver

The user waives a finding by typing `#waive <axis>#<n>` in a real user message of the session (type user, role user, not isMeta) — the same proof `#env-ok` uses; the script reads it from the session transcript. A waiver, or a fix reviewer's `RESOLVED`/`WITHDRAWN`, closes an id only in reports that finished before it, and machine-written user entries (`!` command output, slash-command output, hook feedback) never count as the user typing. No skill ever writes the token and `wave` never sends it to a lane, because a launch prompt reaches the script as a user message too. An unattended lane with an open finding gets no stamp, so no PR: it ends `BLOCKED: open finding <ids>` with the PR body as text, and the user unblocks it from the lane's pane. Same trust level #9 accepted: a session able to forge its own transcript could forge the subagent ones too.
