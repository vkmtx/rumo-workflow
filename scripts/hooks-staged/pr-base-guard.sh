#!/bin/bash
# pr-base-guard: PreToolUse guard (matcher mcp__github__create_pull_request|mcp__github__merge_pull_request|Bash|Write|Edit|MultiEdit).
#
# Three intensities (revised 2026-09-24, audit W02/W08/W44):
#   note  -> additionalContext: the agent READS the warning and carries on (PR base, review before PR/merge).
#            Note: permissionDecision "allow" drops the reason in Claude Code — that is why note
#            does not use allow (that was bug W02: the warnings never reached the model).
#   deny  -> blocks with a reason. Used for what has no undo:
#            a production deploy not requested in this session; any deploy/merge/push in an
#            unattended automation worktree; a PR opened by a headless `/rumo build` (sdk-cli/sdk-ts)
#            with no human afterwards; a destructive write to a production database,
#            a version floor and a production seed without the word "confirmo" in the last message.
#            Launch prompts (an `AUTHORIZED:`/`WAVE BRIEF:`/`LAUNCHED-BY:` line) never count as an owner request.
#            The Mandato (mandate: <git-dir>/rumo-mandato.json, mandato.py, #98) only restricts, read from the cwd and from
#            every dir the command acts in (cd/git -C/env -C): any refused -> no PR/merge/push; any alcance=pr -> no merge
#            (gh pr merge, gh api PUT pulls/<n>/merge, MCP) and no push to dev/main/master. This hook denies writing/deleting
#            the Mandato via Bash and Write/Edit, writing mandato.key via Write/Edit, and any Bash that mentions the key
#            or ~/.config/rumo; reading via the Read tool or deliberate construction stays out (outside the matcher/scope).
#   deny works under --dangerously-skip-permissions too (Orca's mode); ask is not guaranteed.
#
# Owner-typed words this hook matches stay in Portuguese, as the owner types them: deploy words (`sobe pra prod`, …),
# `confirmo` ("I confirm") and `#sem-review` ("no review").
# Fail-open: no jq/python, empty/malformed stdin or a git error -> exit 0. Fail-closed exceptions on merge
# (only '#sem-review' in the user's message unlocks): gh too old for gh pr view --json (GH_OLD_DENY);
# a PR URL target gh cannot resolve (MERGE_URL_DENY); PR head missing from the checkout (ask for git fetch).
# Mandato present without python3/mandato.py (or a failing check) -> refused (no PR/merge/push).
# Mandato in a resolved dir + another command dir that cannot be resolved ($UNSET, $(…), glob, xargs) -> refused; with
# no Mandato in a resolved dir, nothing changes. Deleting the key or ~/.config to escape this is deliberate construction:
# out of scope.
# Wontfix #45 (deliberate construction): docs_only diffs against the LOCAL origin/dev (else origin/HEAD), which update-ref
# moves; review-stamp.sh checks the tip of its own origin, this hook does not.

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$tool" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$(pwd)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

NOTES=""
note() { NOTES="${NOTES:+$NOTES

}$1"; }

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}' \
    2>/dev/null
  exit 0
}

flush_notes() {
  [ -n "$NOTES" ] || exit 0
  jq -cn --arg ctx "$NOTES" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}' 2>/dev/null
  exit 0
}

# Scans the transcript. Mode "msgs": one line per REAL user message in this session, by the single rule
# `owner_message.user_text` (owner_message.py, beside this hook; shared with worktree-guard.py),
# most recent last. A launch prompt (`owner_message.is_launch_prompt`: some line starts
# with AUTHORIZED:/WAVE BRIEF:/LAUNCHED-BY:) becomes an EMPTY line: it counts in unattended(), but never unlocks
# deploy, `confirmo` or `#sem-review`. `python3 -I` + HOOK_DIR at the front of sys.path: nothing in the cwd shadows the
# module. Mode "build": prints 1 if the session is HEADLESS (some line with "entrypoint":"sdk-cli"|"sdk-ts"),
# a `/rumo build` happened (slash command read from the RAW text of the user entry, whatever its origin — it only
# tightens —, or a Skill tool_use rumo + args build) and ZERO real messages (om.user_text) after it. An interactive
# session ("cli", Orca automations included) never counts here: whoever typed `/rumo build` is present.
# Module missing -> fail-closed in both modes: "msgs" prints nothing (deploy/confirmo/#sem-review denied)
# and "build" treats it as zero real messages (a headless build stays unattended: PR/merge/push to dev denied).
# Unreadable transcript/no python3 -> empty (fail-open in the callers).
scan_transcript() {
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I - "$transcript" "$1" "$HOOK_DIR" <<'PY' 2>/dev/null
import json, re, sys
sys.path.insert(0, sys.argv[3])
try:
    import owner_message as om
except Exception:
    om = None  # fail-closed: no owner message is readable
BUILD_CMD = re.compile(r'<command-name>/(rumo:)?rumo</command-name>')
BUILD_ARGS = re.compile(r'<command-args>\s*build\b')
def raw_text(e):
    # Text of a user entry / queued_command, whatever its origin: only for spotting `/rumo build`.
    if not isinstance(e, dict) or e.get('isMeta') or e.get('isCompactSummary') or e.get('isVisibleInTranscriptOnly'):
        return ''
    a = e.get('attachment')
    if e.get('type') == 'attachment' and isinstance(a, dict) and a.get('type') == 'queued_command':
        return str(a.get('prompt') or '')
    if e.get('type') != 'user' or e.get('toolUseResult') is not None:
        return ''
    m = e.get('message')
    c = m.get('content') if isinstance(m, dict) and m.get('role') == 'user' else None
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return '\n'.join(str(b.get('text') or '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
    return ''
out = []
build_seen, after, headless = False, 0, False
HEADLESS = re.compile(r'"entrypoint"\s*:\s*"(sdk-cli|sdk-ts)"')
with open(sys.argv[1], errors='ignore') as fh:
    for line in fh:
        if not headless and HEADLESS.search(line):
            headless = True
        if '"user"' not in line and 'queued_command' not in line and '"Skill"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get('type') == 'assistant':
            c = (d.get('message') or {}).get('content')
            for b in (c if isinstance(c, list) else []):
                if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'Skill':
                    inp = b.get('input') or {}
                    if re.fullmatch(r'(rumo:)?rumo', str(inp.get('skill') or '')) and \
                       re.match(r'\s*build\b', str(inp.get('args') or '')):
                        build_seen, after = True, 0
            continue
        raw = raw_text(d)
        is_build = bool(BUILD_CMD.search(raw) and BUILD_ARGS.search(raw))
        if is_build:
            build_seen, after = True, 0
        if om is None:
            continue
        text = om.user_text(d)
        if not text:
            continue
        if build_seen and not is_build:
            after += 1
        out.append(re.sub(r'\s+', ' ', om.owner_text(text)).strip()[:2000])
if sys.argv[2] == 'build':
    if build_seen and after == 0 and headless:
        print(1)
elif om is not None:
    for t in out:
        print(t)
PY
}

# One line per real user message; a launch prompt = an empty line (counts, unlocks nothing).
user_msgs() { scan_transcript msgs; }

# Did any real user message in this session ask for a deploy/publish? The word list matches what the owner
# types, in English and Portuguese (sobe/subir = ship it, publica = publish, lanca = launch, no ar = live, loja = store).
# No readable transcript -> 0 (fail-open).
deploy_requested() {
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  msgs=$(user_msgs)
  printf '%s' "$msgs" | grep -qiE '\b(deploy[a-z]*|redeploy|sobe|subir|suba|publica[a-z]*|publique|release|lan[cç]a[a-z]*|no ar|pro ar|prod|produ[cç][aã]o|production|vercel|firebase|eas|submit|loja|store|testflight)\b'
}

# Does the LAST real user message contain the confirmation word (`confirmo`, owner-typed Portuguese for "I confirm")?
confirmed_now() {
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 1
  last=$(user_msgs | tail -n 1)
  printf '%s' "$last" | grep -qiE '\bconfirmo\b'
}

# Orca automation worktree running with no human: an automation path AND
# at most 1 real message (the automation's prompt). A human who resumes the
# session adds messages and leaves unattended mode. The path applies to the cwd AND to every dir the command
# acts in (mandato_dirs: cd/git -C/env -C and the <wt> of a ship.sh), not only to the cwd. The `automacoes`
# directory name is matched as data (Portuguese for "automations").
unattended() {
  local d hit=1
  while IFS= read -r d; do
    case "${d#\$\?}" in
      */orca/workspaces/*/ops|*/orca/workspaces/*/ops/*|*/orca/workspaces/*/automacoes|*/orca/workspaces/*/automacoes/*|*/orca/workspaces/*/auto-*) hit=0; break ;;
    esac
  done <<< "$(mandato_dirs)"
  [ "$hit" = 0 ] || return 1
  n=$(user_msgs | wc -l | tr -d ' ')
  [ "${n:-0}" -le 1 ]
}

# Mechanical unattended: a HEADLESS `/rumo build` with no real user message after it.
# Only this case denies `gh pr create`; an automation worktree by path still opens PRs.
build_unattended() { [ "$(scan_transcript build)" = 1 ]; }

is_unattended() { unattended || build_unattended; }

# Mandato (#98): `mandato.check` (mandato.py, beside this hook) over the cwd AND over every dir the command
# acts in (`mandato_dirs`: the dir of the create/merge/push/apimerge/apicreate lines of gh_calls). One line per dir,
# "<status> <alcance|-> <reason|->" (status absent|valid|refused); `python3 -I` + HOOK_DIR at the front of sys.path
# (nothing in the cwd shadows the module). Module missing, no python3 or an error: a <git-dir>/rumo-mandato.json file
# present -> "refused - no-module" (fail-closed); absent -> "absent - -" (previous behaviour, intact).
# Aggregated in MANDATO_STATE, computed at most once per call: any refused -> refused (reason of the
# first); else any valid -> valid, alcance=pr if any has pr; else absent. M_ST/M_AL/M_RE = the three fields.
# An unresolvable dir (gh_calls leaves it with `$` or a backtick: undefined variable, ${X:-…}, $(…), glob without a
# single match, xargs) -> "refused - unresolved-dir" ONLY when some resolved dir (the cwd included) has a Mandato file
# (valid or refused); with no Mandato in any resolved dir, the unresolvable one is ignored (absent, previous behaviour).
MANDATO_STATE=""
mandato_dirs() {
  printf '%s\n' "$cwd"
  printf '%s\n' "$calls" | awk -F'\t' '$1 ~ /^(create|merge|push|apimerge|apicreate)$/ && $2 != "-" {print $2}'
}
mandato_state() {
  [ -n "$MANDATO_STATE" ] && return 0
  local out="" gd d line i=0 st al re unres=0 seen=0
  local -a dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case $'\n'"$(printf '%s\n' "${dirs[@]}")"$'\n' in *$'\n'"$d"$'\n'*) continue ;; esac
    dirs+=("$d")
  done <<< "$(mandato_dirs)"
  if command -v python3 >/dev/null 2>&1; then
    # stdin of python is the heredoc; a dir arg is data only (an unresolved one just reads as absent there)
    out=$(python3 -I - "${HOOK_DIR:-/nonexistent}" "${dirs[@]}" <<'PY' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1])
try:
    import mandato
except Exception:
    sys.exit(0)  # module missing: the shell side decides by the file's presence
for d in sys.argv[2:]:
    try:
        st, m, reason = mandato.check(d)
        print('%s %s %s' % (st, (m or {}).get('alcance') or '-', (reason or '-').replace('\n', ' ')))
    except Exception:
        print('?')  # the shell side decides by the file's presence
PY
)
  fi
  M_ST=absent; M_AL=-; M_RE=-
  for d in "${dirs[@]}"; do
    i=$((i + 1)); line=$(printf '%s\n' "$out" | sed -n "${i}p")
    case "$d" in *'$'*|*'`'*) unres=1; continue ;; esac
    case "$line" in
      absent\ *|valid\ *|refused\ *) ;;
      *) gd=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)
         if [ -n "$gd" ] && { [ -e "$gd/rumo-mandato.json" ] || [ -L "$gd/rumo-mandato.json" ]; }; then
           line="refused - no-module"
         else
           line="absent - -"
         fi ;;
    esac
    st=${line%% *}; re=${line#* }; al=${re%% *}; re=${re#* }
    [ "$st" = absent ] || seen=1
    if [ "$st" = refused ]; then
      [ "$M_ST" = refused ] || { M_ST=refused; M_AL=-; M_RE=$re; }
    elif [ "$st" = valid ] && [ "$M_ST" != refused ]; then
      [ "$M_ST" = valid ] && [ "$M_AL" = pr ] || M_AL=$al
      M_ST=valid
    fi
  done
  if [ "$unres" = 1 ] && [ "$seen" = 1 ] && [ "$M_ST" != refused ]; then M_ST=refused; M_AL=-; M_RE=unresolved-dir; fi
  MANDATO_STATE="$M_ST $M_AL $M_RE"
}
mandato_refused() { mandato_state; [ "$M_ST" = refused ]; }
mandato_pr_only() { mandato_state; [ "$M_ST" = valid ] && [ "$M_AL" = pr ]; }
mandato_deny() {
  [ "$M_RE" = unresolved-dir ] && deny "$MANDATO_UNRESOLVED_DENY"
  deny "${MANDATO_DENY/<reason>/$M_RE}"
}

# House rule: the review skill runs before a PR and before a merge — and FINISHES. Starting is not enough: axis 1
# is a background fork whose result arrives later. Counts as done: the review's closing line
# (`TIER: light|standard|sensitive`) or the /code-review completion notification.
# 0 = found (or cannot tell).
review_ran() {
  [ -n "$transcript" ] && [ -r "$transcript" ] || return 0
  grep -qE 'TIER: \*{0,2}(light|standard|sensitive)' "$transcript" && return 0
  grep -qE '/code-review[^"]{0,80}\\?" finished' "$transcript" && return 0
  return 1
}

# Review stamp: only the review skill's review-stamp.sh writes `$(git rev-parse --git-dir)/rumo-review.ok`
# (line 1 `<full HEAD sha> <tier> <timestamp>`, + base/mode/axes/runs), and only with the transcript
# of a rumo:reviewer from this session over the exact RANGE; any other write of the stamp is denied here. PR create/merge
# require the stamp to cover the target commit (deny), except a docs-only diff or `#sem-review` in the last message.
# review_gate returns: 0 = covered/exempt; 1 = denied (message in GATE_MSG); 2 = cannot tell
# (no git) -> the caller falls back to the old nudge. Stamp that is an ancestor of the target -> the message names both paths:
# fix axis over <stamp>..<target> + --fix (new commits) or --base-merge (merge of origin/<base> before the
# PR merge); stamp from another branch/rebase -> full review.
GATE_MSG=""

# `#sem-review` is the owner-typed opt-out tag (Portuguese for "no review"); matched as data.
sem_review() { user_msgs | tail -n 1 | grep -q '#sem-review'; }

# Does the target's diff against the base (origin/dev, else origin/HEAD) touch only *.md/*.mdx or docs/?
docs_only() {
  local target=$1 dir=${2:-$cwd} base files
  base=$(git -C "$dir" rev-parse --verify -q origin/dev 2>/dev/null) ||
    base=$(git -C "$dir" rev-parse --verify -q origin/HEAD 2>/dev/null) || return 1
  files=$(git -C "$dir" diff --name-only "${base}...$target" 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  ! printf '%s\n' "$files" | grep -qvE '\.(md|mdx)$|^docs/'
}

# Does any stamp (from this worktree or another of the same repo) cover the target sha?
# $1 = target sha (empty = HEAD of $2); $2 = context directory (the command's cd/env -C; default cwd).
review_gate() {
  local target=$1 dir=${2:-$cwd} gitdir common stamp f s
  gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 2
  [ -n "$target" ] || target=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 2
  [ -n "$target" ] || return 2
  sem_review && return 0
  stamp=$(awk 'NR==1{print $1}' "$gitdir/rumo-review.ok" 2>/dev/null)
  [ "$stamp" = "$target" ] && return 0
  common=$(cd "$dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
  if [ -n "$common" ]; then
    for f in "$common/rumo-review.ok" "$common"/worktrees/*/rumo-review.ok; do
      [ -r "$f" ] || continue
      s=$(awk 'NR==1{print $1}' "$f" 2>/dev/null)
      [ "$s" = "$target" ] && return 0
    done
  fi
  docs_only "$target" "$dir" && return 0
  s=${stamp:0:7}
  if [ -z "$s" ]; then
    GATE_MSG="Review does not cover the current HEAD (no stamp vs ${target:0:7}). Run the review skill to the end (review-stamp.sh writes the stamp) — a 'merge tudo' authorizes the merge, it does not skip the review."
  elif git -C "$dir" merge-base --is-ancestor "$stamp" "$target" 2>/dev/null; then
    GATE_MSG="Review does not cover the current HEAD ($s vs ${target:0:7}). If what came after the stamp is your own commits, run the review skill's fix axis over $s..${target:0:7} (AXIS: fix) and write the stamp with review-stamp.sh --fix; if it is the merge of origin/<base> before the PR merge (wave.md §Merging), write it with review-stamp.sh --base-merge — a 'merge tudo' authorizes the merge, it does not skip the review."
  else
    GATE_MSG="Review does not cover the current HEAD ($s vs ${target:0:7}): the stamp is not an ancestor of the target (another branch or a rebase). Run the full review skill to the end (review-stamp.sh writes the stamp) — a 'merge tudo' authorizes the merge, it does not skip the review."
  fi
  return 1
}

# Cannot tell (no git/gh, gh failed): the old nudge if no review ran (fail-open).
fail_open() { review_ran || note "$REVIEW_MSG"; }

# Applies the gate: deny if denied; the old nudge if it cannot tell.
apply_gate() {
  review_gate "$1" "$2"
  case $? in
    1) deny "$GATE_MSG" ;;
    2) fail_open ;;
  esac
}

# Release PR = head `dev` and base main|master. `owner:dev` from the repo's own owner (own_owner) is normalized to dev
# first (#23) on create and on merge via Bash; from another owner it is never a release. The MCP branch does not normalize (no GitHub MCP in use).
is_release() { [ "$1" = dev ] && { [ "$2" = main ] || [ "$2" = master ]; }; }

# Owner of the context repo, lowercase; empty if it cannot tell. $1 = directory; $2 = value of -R
# (OWNER/REPO or HOST/OWNER/REPO). No literal -R -> owner from the origin URL.
own_owner() {
  local r=$2 o
  [[ "$r" =~ ^[A-Za-z]+:// ]] && r=${r#*://}   # gh accepts -R https://github.com/OWNER/REPO
  if [ -n "$r" ] && [[ "$r" != *[\$\`]* ]]; then
    case "$r" in */*/*) o=${r#*/}; o=${o%%/*} ;; *) o=${r%%/*} ;; esac
  else
    o=$(git -C "$1" remote get-url origin 2>/dev/null |
      sed -nE 's#^(https?://[^/]+/|ssh://[^/]+/|[^@/]+@[^:/]+:)([^/]+)/.*#\2#p')
  fi
  printf '%s' "$o" | tr '[:upper:]' '[:lower:]'
}

# PR via gh: prints "<headRefOid>\t<headRefName>\t<baseRefName>\t<isCrossRepository>" (1 if gh fails or the sha is invalid;
# 3 = gh too old for --json / these fields, which exist since gh 1.9.0).
# $1 = number/URL/branch (empty = PR of $3's current branch); $2 = optional owner/repo; $3 = context dir.
pr_info() {
  local out rc
  command -v gh >/dev/null 2>&1 || return 1
  out=$(cd "${3:-$cwd}" 2>/dev/null && gh pr view ${1:+"$1"} ${2:+--repo "$2"} --json headRefOid,headRefName,baseRefName,isCrossRepository \
    -q '[.headRefOid,.headRefName,.baseRefName,(.isCrossRepository|tostring)]|@tsv' 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "$out" | grep -qiE 'unknown json field|unknown flag' && return 3
    return 1
  fi
  printf '%s\n' "$out" | grep -m1 -E '^[0-9a-f]{40}'$'\t'
}

# Merge of a PR resolved by pr_info: a dev→main|master release of the SAME repo -> release_gate over the
# head gh reports; a fork PR (isCrossRepository, or an `owner:dev` target from another owner) -> the stamp covers the head.
# $1 = number/URL/branch/empty; $2 = repo; $3 = dir. Old gh (without the fields) -> deny; gh failing -> merge_fallback.
# A head the stamp does not cover and that is not in this checkout -> deny asking for git fetch (ancestry cannot be checked).
merge_gate() {
  local info sha hr br cross rc o gitdir s
  info=$(pr_info "$1" "$2" "$3"); rc=$?
  if [ "$rc" -eq 3 ]; then sem_review && return; deny "$GH_OLD_DENY"; fi
  [ "$rc" -ne 0 ] && { merge_fallback "$1" "$3" "$2"; return; }
  IFS=$'\t' read -r sha hr br cross <<< "$info"
  case "$1" in *://*|*/pull/*) ;; *:*)
    o=$(own_owner "$3" "$2")
    [ -n "$o" ] && [ "$o" = "$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')" ] || cross=true ;; esac
  if [ "$cross" != true ] && is_release "$hr" "$br"; then release_gate "$3" "$br" "$sha"; return; fi
  git -C "$3" cat-file -e "$sha^{commit}" 2>/dev/null && { apply_gate "$sha" "$3"; return; }
  review_gate "$sha" "$3"
  case $? in
    1) gitdir=$(git -C "$3" rev-parse --absolute-git-dir 2>/dev/null)
       s=$(awk 'NR==1{print substr($1,1,7)}' "$gitdir/rumo-review.ok" 2>/dev/null)
       deny "Review does not cover the PR head (${s:-no stamp} vs ${sha:0:7}): the PR head (${sha:0:7}) is not in this checkout (commit pushed after the stamp?). Run git fetch origin, update the branch and run the review on it (review-stamp.sh writes the stamp) — a 'merge tudo' authorizes the merge, it does not skip the review." ;;
    2) fail_open ;;
  esac
}

# gh could not tell the PR head (network, no PR for the branch): falls back to the local target from before #23.
# $1 empty -> checkout on dev: old nudge; another branch: stamp over the local HEAD. $1 number -> old nudge.
# $1 PR URL -> deny (gh did not resolve the URL; the merge would resolve something else or nothing). $1 dev / owner:dev from
# the own owner -> old nudge (release, like the checkout on dev); owner:dev from another owner goes on as a branch.
# $1 branch / owner:branch -> stamp over the local branch (or origin/<branch>); unresolvable -> old nudge.
# $2 = dir; $3 = repo (-R).
merge_fallback() {
  local tsha o
  if [ -z "$1" ]; then
    if [ "$(git -C "$2" branch --show-current 2>/dev/null)" = dev ]; then fail_open; else apply_gate "" "$2"; fi
  elif [[ "$1" == *://* || "$1" == */pull/* ]]; then
    sem_review || deny "$MERGE_URL_DENY"
  elif [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" = dev ]; then
    fail_open
  elif [ "${1#*:}" = dev ] && o=$(own_owner "$2" "$3") && [ -n "$o" ] \
    && [ "$o" = "$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')" ]; then
    fail_open
  else
    tsha=$(branch_sha "${1#*:}" "$2")
    if [ -n "$tsha" ]; then apply_gate "$tsha" "$2"; else fail_open; fi
  fi
}

PR_UNATTENDED_DENY="Blocked: unattended automation does not open PRs; leave the PR body in the report."

REVIEW_MSG="No review in this session. Before opening a PR or merging, run the review skill (rumo:review) and fix what it finds; if the diff touches auth, secrets, PII, money or shell execution, run /security-review too. A 'merge tudo' from the user authorizes the merge, it does not skip the review. A docs/copy-only diff may proceed."

DEPLOY_DENY="Blocked: PRODUCTION DEPLOY/PUBLISH with no deploy request from the user in this session. Ask them in one line (what will ship, and where) and run it only after they ask. To validate without publishing: vercel build / firebase deploy --dry-run."

UNATTENDED_DENY="Blocked: this is an Orca automation worktree running with no human in the session. Automation does not merge, push to dev/main or deploy — record what would be done in the final report and leave it to the user."

repo_has_dev() {
  git -C "${1:-$cwd}" show-ref --verify --quiet refs/heads/dev 2>/dev/null ||
    git -C "${1:-$cwd}" show-ref --verify --quiet refs/remotes/origin/dev 2>/dev/null
}

# Sha of a named branch (--head / merge argument), seen from $2's repo. refs/heads is
# shared between worktrees, so it resolves from any checkout of the repo.
branch_sha() {
  git -C "$2" rev-parse --verify -q "refs/heads/$1" 2>/dev/null ||
    git -C "$2" rev-parse --verify -q "refs/remotes/origin/$1" 2>/dev/null
}

# Gate for a target: PR number > named branch > HEAD of the context dir.
# Named but unresolvable target -> old nudge (cannot tell).
# Merge: always merge_gate (the PR head gh reports); create: named branch > HEAD.
gate_target() {
  local dir=$1 ref=$2 num=$3 repo=$4 kind=${5:-create} tsha
  if [ "$kind" = merge ]; then
    merge_gate "${num:-$ref}" "$repo" "$dir"
  elif [ -n "$ref" ]; then
    if tsha=$(branch_sha "${ref#*:}" "$dir") && [ -n "$tsha" ]; then apply_gate "$tsha" "$dir"
    else fail_open; fi
  else
    apply_gate "" "$dir"
  fi
}

# Release PR = head `dev`, base `main|master`. Without a stamp: passes when every first-parent commit of
# <base>..dev came from a PR merged into dev (the PR's merge/squash commit stands for its branch),
# so only a commit pushed straight to dev shows up as an orphan. A PR rebase-merged into dev shows its
# non-final commits as orphans (way out: `#sem-review`). More than 200 commits -> deny (fail-closed: the
# origin is not checked, and flooding dev must not open the gate). No refs, no gh or gh failing ->
# old nudge (fail-open, like the rest of the hook). $1 = context dir; $2 = base (main|master);
# $3 = PR head reported by gh (merge): audited instead of the local dev; missing locally -> deny
# (ask for `git fetch`), because the local dev may be behind what the merge will take.
release_gate() {
  local dir=$1 base=$2 head=$3 b d shas n merged orphans="" sha k=0
  sem_review && return 0
  b=$(git -C "$dir" rev-parse --verify -q "refs/remotes/origin/$base" 2>/dev/null) ||
    b=$(git -C "$dir" rev-parse --verify -q "refs/heads/$base" 2>/dev/null) || { fail_open; return 0; }
  if [ -n "$head" ]; then
    git -C "$dir" cat-file -e "$head^{commit}" 2>/dev/null ||
      deny "Release ${base}←dev blocked: the PR head (${head:0:7}) is not in this checkout, so the origin of the commits could not be checked. Run git fetch origin and try the merge again."
    d=$head
  else
    d=$(git -C "$dir" rev-parse --verify -q refs/remotes/origin/dev 2>/dev/null) ||
      d=$(git -C "$dir" rev-parse --verify -q refs/heads/dev 2>/dev/null) || { fail_open; return 0; }
  fi
  shas=$(git -C "$dir" rev-list --first-parent --max-count=201 "$b..$d" 2>/dev/null) || { fail_open; return 0; }
  [ -n "$shas" ] || return 0
  n=$(printf '%s\n' "$shas" | wc -l | tr -d ' ')
  if [ "$n" -gt 200 ]; then
    deny "Release ${base}←dev blocked: more than 200 commits in ${base}..dev; their PR origin could not be checked. Split the release or ask the user for '#sem-review'."
  fi
  command -v gh >/dev/null 2>&1 || { fail_open; return 0; }
  merged=$(cd "$dir" 2>/dev/null && gh pr list --state merged --base dev --limit 1000 --json mergeCommit -q '.[].mergeCommit.oid' 2>/dev/null) ||
    { fail_open; return 0; }
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    printf '%s\n' "$merged" | grep -Fxq "$sha" && continue
    k=$((k + 1))
    orphans="${orphans:+$orphans
}$(git -C "$dir" log -1 --format='%h %s' "$sha" 2>/dev/null)"
  done <<< "$shas"
  [ "$k" -gt 0 ] || return 0
  deny "Release ${base}←dev blocked: $k commit(s) of ${base}..dev did not come from a PR merged into dev:
$orphans
Bring each one to dev through a reviewed PR, or ask the user for '#sem-review' in their message."
}

# Finds `gh pr create|new|merge` in COMMAND POSITION: start, or after ; && || | ( $( ` newline,
# with optional prefixes (VAR=x, command, exec, env [-C dir], time, nohup). Quoted text and heredoc
# bodies never match (quoted content becomes a single word). Follows earlier `cd/pushd/popd <dir>`
# in the same command and `env -C dir`. `gh` matches by basename (/opt/homebrew/bin/gh), flags between
# `pr` and the subcommand are skipped (gh pr -R o/r merge 1) and `new` comes out as `create`.
# One line per invocation, TAB-separated, 6 columns, "-" = empty:
#   create|merge  dir  ref(--head | merge branch)  num  repo(-R)  base(--base)
#   push          dir  protected(0|1)  unresolvable(0|1)  -  -
#       every `git [global options] push`. protected=1: destination dev|main|master (after +, <src>: and refs/heads/),
#       --all/--mirror/--branches, or an IMPLICIT destination (no refspec, or only HEAD/@) with the dir on dev|main|master
#       (`git -C <dir> branch --show-current`). unresolvable=1: destination with `$`/backtick, xargs argv, or an implicit
#       destination after a `git checkout|switch` in the same command (the branch at push time cannot be read
#       from here) — under a Mandato with alcance=pr it counts as protected; outside it nothing changes.
#   apimerge      dir  -  -  -  -   `gh api` PUT …/pulls/<n>/merge, graphql mergePullRequest/enablePullRequestAutoMerge
#   apicreate     dir  -  -  -  -   `gh api` POST …/repos/<o>/<r>/pulls, graphql createPullRequest
#       (both only feed the Mandato gates, not the review gates)
#   ship.sh (#106, #110) `[bash|sh|zsh|dash|ksh|mksh [opts]] <…>/ship.sh <wt> --base <b> …`, `source|. <…>/ship.sh …` in command
#       position comes out as the three lines of what it runs inside, all with dir = <wt> (relative to the command's dir): push
#       (destination = current branch of <wt>), create (base <b>) and, without --no-merge/--dry-run, merge (target = the
#       branch's PR). A shell with -c/+c (clustered or not; the text becomes a nested command; with +c ksh93 appends the
#       following words to the text, so +c nests them all) or one that ends in noexec (-n, +n -n; -n +n runs; fail closed:
#       after -n, every +n, -o/+o/-O/+O with any value and every --long option clear it — `-n -o pipefail` counts as a call),
#       and cat, grep and echo of ship.sh are not calls; without <wt> or with --help, ship.sh only prints its usage: nothing
#       comes out. `source|. ship.sh` with nothing after it inherits the caller's "$@": comes out with <wt> = $@. An
#       unresolvable <wt> ($@, $1, $WT, backtick, glob, xargs): the merge comes out with target "?" (deny, fail closed)
#       even with --no-merge/--dry-run — there is no repo for the stamp and automation gates.
# dir = where the command acts (cd, git -C/--git-dir/--work-tree, GIT_DIR=, env -C, sudo -D). A dir the hook did not
# resolve comes out with `$` inside (undefined variable, ${X:-…}, $(…)) or with the prefix `$?` (backtick, glob without a
# single match, xargs/parallel argv, popd/cd - with no history): mandato_state reads it as unresolvable and the review gate
# strips the prefix. Variables exported in the hook's environment ($HOME, $PWD, …) are expanded like those assigned in the command.
# Three more signal lines (rest "-"), from the same tokenizer (quotes, comments, heredocs already removed):
#   stampwrite    -> a write-redirect target (>, >>, >|, &>, <>) mentions rumo-review.ok, or the command
#                    (after the launchers) is tee/cp/mv/install/ln/dd/truncate/rsync/ditto/sponge and an argument mentions it.
#   evidencewrite -> the same for .claude/projects/*/subagents (redirect, or tee/cp/mv/install/ln/mkdir/rsync/ditto/sponge),
#                    with targets and arguments resolved against the earlier `cd` (cd ~/.claude/projects/x && echo > subagents/y).
#   mandatowrite  -> a write-redirect target, or an argument of tee/cp/mv/install/ln/dd/truncate/rsync/ditto/sponge/
#                    rm/unlink/shred, `git rm`, `git clean` or `find … -delete/-exec`, names rumo-mandato.json (case-insensitive):
#                    literally, or by a glob on the basename — the glob counts only when it can reach a git dir (a `.git`
#                    component in the path resolved against the `cd`, or a dirname with `$`/backtick) or carries a literal
#                    `mandato`; `rm -rf dist/*`, `cp fixtures/*.json out/` pass.
# `$(…)`/backticks stay inside the word (the target `$(git rev-parse --git-dir)/rumo-review.ok` stays whole) and
# their content is parsed as a nested command. `NAME=value` seen earlier (or NAME exported in the environment) expands
# `$NAME`/`${NAME}` in dirs, write targets and arguments — never in those of gh pr; in write targets and writer arguments
# `${NAME<op>…}` (${F:-y}, ${F%x}) also becomes NAME's known value, in dirs it does not (it stays unresolvable). A gh pr target
# with `$`/backtick: on merge it comes out as "?" (deny — the merge target must be a literal number); on create it comes
# out as "-" (gate on the dir's HEAD). A quoted mention as an argument (git commit -m "… rumo-review.ok"), a read (cat, awk),
# a read redirected into another file, and rm pass.
# NOT covered: sed -i, interpreters (python -c, perl), a name split across variables, a variable coming from outside the
# command, a loop variable (for f in rumo-review.ok; do echo x > .git/$f; done). Accepted over-match: cp/rsync/
# ditto/install/ln match EVERY argument, so copies OUT of the stamp/evidence are denied too — use cat/less to read;
# likewise copying something from ~/.claude/projects/ into a local directory named subagents (fixture): rename the destination.
# Scope: blocks the habitual shortcut (a hand-written stamp, a merge without a stamp). It is not a barrier against deliberate
# construction to get around it (e.g. python/perl writing a file, GH_REPO in the environment, rsync of a directory's
# content); integrity comes from the evidence review-stamp.sh requires.
gh_calls() {
  python3 -I - "$cmd" "$cwd" <<'GHPY' 2>/dev/null   # -I: nothing from the cwd (fnmatch.py, re.py…) nor PYTHON* shadows the stdlib
import fnmatch, glob, os, re, shlex, subprocess, sys
cmd, cwd = sys.argv[1], sys.argv[2]

def strip_heredocs(s):
    out, pend, held = [], [], []
    for line in s.split('\n'):
        if pend:
            d, dash = pend[0]
            held.append(line)
            if (line.lstrip('\t') if dash else line) == d:
                pend.pop(0)
                if not pend:
                    held = []
            continue
        out.append(line)
        for m in re.finditer(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line):
            pend.append((m.group(3), m.group(1) == '-'))
    return '\n'.join(out + held)  # a heredoc that never closes was not one: keep its lines

def close_sub(s, i, closer):
    """Index just past the `closer` that ends a $( (closer ')') or ` (closer '`') opened before i."""
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2; continue
        if closer == '`':
            if c == '`':
                return i + 1
        elif c == "'":
            j = s.find("'", i + 1); i = n if j < 0 else j + 1; continue
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == '\\':
                    j += 1
                elif s[j] == '$' and s[j + 1:j + 2] == '(':
                    j = close_sub(s, j + 2, ')') - 1
                j += 1
            i = j + 1; continue
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n

def take_sub(s, i, toks):
    """s[i] starts `$(` or a backtick: returns (raw text, index after it); the inner text goes to toks
    as ('sub', inner), so segments() hands it to the command that holds it."""
    k = 1 if s[i] == '`' else 2
    j = close_sub(s, i + k, '`' if k == 1 else ')')
    toks.append(('sub', s[i + k:j - 1]))
    return s[i:j], j

def tokenize(s):
    toks, cur, i, n = [], None, 0, len(s)
    def flush():
        nonlocal cur
        if cur is not None:
            toks.append(('w', cur)); cur = None
    while i < n:
        c = s[i]
        if c == "'":
            j = s.find("'", i + 1); j = n if j < 0 else j
            cur = (cur or '') + s[i + 1:j]; i = j + 1
        elif c == '"':
            j, buf = i + 1, ''
            while j < n and s[j] != '"':
                if s[j] == '\\' and j + 1 < n:
                    j += 1
                elif (s[j] == '$' and s[j + 1:j + 2] == '(') or s[j] == '`':
                    raw, j = take_sub(s, j, toks); buf += raw; continue
                buf += s[j]; j += 1
            cur = (cur or '') + buf; i = j + 1
        elif c == '\\':
            if i + 1 < n and s[i + 1] != '\n':
                cur = (cur or '') + s[i + 1]
            i += 2
        elif c in ' \t':
            flush(); i += 1
        elif c == '\n':
            flush(); toks.append(('op', ';')); i += 1
        elif c == '#' and cur is None:
            j = s.find('\n', i); i = n if j < 0 else j
        elif (c == '$' and s[i + 1:i + 2] == '(') or c == '`':
            raw, i = take_sub(s, i, toks); cur = (cur or '') + raw
        elif c == '$' and s[i + 1:i + 2] == '{':
            j = s.find('}', i); j = n - 1 if j < 0 else j
            cur = (cur or '') + s[i:j + 1]; i = j + 1
        elif c in '<>' or (c == '&' and s[i + 1:i + 2] == '>'):
            if cur is not None and cur.isdigit():
                cur = None
            flush(); j = i + 1
            while j < n and (s[j] in '<>&' or (s[j] == '|' and s[j - 1] == '>')):   # >| (clobber) is a redirect, not a pipe
                j += 1
            if s[j - 1] == '&' and j < n and (s[j].isdigit() or s[j] == '-'):
                j += 1; toks.append(('op', 'fd'))
            else:
                toks.append(('op', 'redir>' if '>' in s[i:j] else 'redir<'))
            i = j
        elif c in ';&|()':
            flush(); j = i + 1
            if c in '&|;' and s[i + 1:i + 2] == c:
                j += 1
            toks.append(('op', s[i:j])); i = j
        else:
            cur = (cur or '') + c; i += 1
    flush()
    return toks

class Seg(list):
    """The words of one simple command; .writes = its write-redirect targets (>, >>, &>, <>);
    .subs = the inner text of its $(…) / `…`."""
    writes = subs = ()

def segments(toks):
    seg, skip = Seg(), None
    seg.writes, seg.subs = [], []
    for t, v in toks:
        if t == 'sub':
            seg.subs.append(v)
        elif t == 'op' and v.startswith('redir'):
            skip = v
        elif t == 'op' and v == 'fd':
            continue
        elif t == 'op':
            yield seg; seg, skip = Seg(), None; seg.writes, seg.subs = [], []
        elif skip:
            if skip == 'redir>':
                seg.writes.append(v)
            skip = None
        else:
            seg.append(v)
    yield seg

def resolve(base, d):
    d = os.path.expanduser(d)
    return os.path.normpath(d if os.path.isabs(d) else os.path.join(base, d))

ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
VALUED = {'-R', '--repo', '-H', '--head', '-B', '--base', '-t', '--title', '-b', '--body',
          '-F', '--body-file', '-a', '--assignee', '-l', '--label', '-m', '--milestone',
          '-p', '--project', '-r', '--reviewer', '-T', '--template', '--subject',
          '-A', '--author-email', '--match-head-commit'}
KEYWORDS = ('command', 'exec', 'time', 'nohup', 'builtin', 'do', 'then', 'else', 'elif', 'if',
            'while', 'until', '!', '{', 'sudo', 'nice', 'xargs', 'stdbuf', 'timeout')
FLAG_VALUES = {'sudo': ('-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-U'), 'xargs': ('-n', '-I', '-P', '-L', '-s', '-E', '-d'),
               'nice': ('-n',), 'timeout': ('-s', '-k', '--signal', '--kill-after'), 'stdbuf': ('-i', '-o', '-e')}

def skip_launchers(w, ctx):
    """Index of the real command word after env assignments / launcher words, and an `env -C` dir."""
    i, here = 0, None
    while i < len(w):
        if ASSIGN.match(w[i]) or w[i] in KEYWORDS:
            launcher = w[i]; i += 1
            takes = FLAG_VALUES.get(launcher, ())
            while i < len(w) and w[i].startswith('-') and w[i] != '--':  # only the launcher's own valued flags eat a word
                if launcher == 'sudo' and w[i] in ('-D', '--chdir') and i + 1 < len(w):   # sudo -D <dir> runs there
                    here = resolve(here or ctx, expand(w[i + 1]))
                elif launcher == 'sudo' and w[i].startswith('--chdir='):
                    here = resolve(here or ctx, expand(w[i][8:]))
                i += 2 if w[i] in takes else 1
            if i < len(w) and w[i] == '--':
                i += 1
            if launcher == 'timeout' and i < len(w) and re.match(r'^\d+(\.\d+)?[smhd]?$', w[i]):
                i += 1
        elif w[i] == 'env':
            i += 1
            while i < len(w):
                if ASSIGN.match(w[i]): i += 1
                elif w[i] in ('-C', '--chdir') and i + 1 < len(w): here = resolve(here or ctx, expand(w[i + 1])); i += 2
                elif w[i].startswith('--chdir='): here = resolve(here or ctx, expand(w[i][8:])); i += 1
                elif w[i] == '-u': i += 2
                elif w[i].startswith('-'): i += 1
                else: break
        else:
            break
    return i, here

SHELLS = ('bash', 'sh', 'zsh', 'dash', 'ksh', 'mksh')        # shells that run a script or a -c '…'
SHELL_VALUED = ('--rcfile', '--init-file', '--emulate')      # long shell options that eat the next word

def shell_opt_step(a):
    """How many words a shell option word a takes: 2 for --rcfile/--init-file/--emulate, 1 for any other long option
    (`--rcfile=f` is one word), and for a short cluster 1 plus one per o/O in it (`-euo pipefail`, `+o posix`)."""
    if a[:2] == '--':
        return 2 if a in SHELL_VALUED else 1
    return 1 + sum(c in 'oO' for c in a[1:])

def shell_opts(w, j):
    """Walk the option words of a shell call from w[j] -> (j_after, runs_string, noexec, plus_c). j_after is past a
    final `-`/`--`. runs_string: any short cluster, `-` or `+`, holds c (every POSIX shell runs the string for +c as
    for -c). plus_c: a `+` cluster holds c — ksh93 then runs w[j_after] with the remaining words appended as text
    (`ksh +c gh pr merge 1` merges), so the caller nests them all (in bash/zsh/dash only an over-match). noexec, fail closed: a `-` cluster with n sets it; any later word that could clear it clears it — a `+`
    cluster with n (`-n +n` runs), a `-`/`+` cluster with o/O whatever its value (`+o noexec`, `-o exec`, `-no exec`), or any
    `--long` option (`--exec`). A wrong guess (`-n -o pipefail`) only reads a ship call: over-match toward deny."""
    runs, noexec, plus_c = False, False, False
    while j < len(w) and w[j][:1] in ('-', '+') and w[j] not in ('-', '--'):
        a = w[j]
        if a[:2] == '--':
            noexec = False
        else:
            runs = runs or 'c' in a[1:]
            plus_c = plus_c or (a[0] == '+' and 'c' in a[1:])
            if any(c in 'oO' for c in a[1:]) or (a[0] == '+' and 'n' in a[1:]):
                noexec = False   # o/O wins inside its own cluster too: `zsh -no exec` runs
            elif 'n' in a[1:]:
                noexec = True
        j += shell_opt_step(a)
    if j < len(w) and w[j] in ('-', '--'):
        j += 1
    return j, runs, noexec, plus_c

def all_segments(text, depth=0):
    for w in segments(tokenize(strip_heredocs(text))):
        if depth < 3:
            for inner in w.subs:   # $(…) / `…` run before the command that holds them; a cd inside stays inside
                yield Seg(['__push__'])
                yield from all_segments(inner, depth + 1)
                yield Seg(['__pop__'])
        i, _ = skip_launchers(w, cwd)
        head = os.path.basename(w[i]) if i < len(w) else ''
        inner = None
        if head in SHELLS and depth < 3:   # bash -c '…', bash +c, bash -lc, bash --norc -c, bash -o pipefail -c
            j, has_c, _, plus_c = shell_opts(w, i + 1)
            if has_c and j < len(w):
                inner = w[j] + ' ' + ' '.join(shlex.quote(x) for x in w[j + 1:]) if plus_c else w[j]
        elif head == 'eval' and depth < 3:
            inner = ' '.join(w[i + 1:])
        if inner is not None:
            yield Seg(['__push__'])
            yield from all_segments(inner, depth + 1)
            yield Seg(['__pop__'])
        yield w

STAMP = 'rumo-review.ok'
MANDATO_FILE = 'rumo-mandato.json'
EVIDENCE = re.compile(r'\.claude/projects/[^ ]*/subagents')
STAMP_WRITERS = {'tee', 'cp', 'mv', 'install', 'ln', 'dd', 'truncate', 'rsync', 'ditto', 'sponge'}
MANDATO_WRITERS = STAMP_WRITERS | {'rm', 'unlink', 'shred'}
FIND_ACTIONS = {'-delete', '-exec', '-execdir', '-ok', '-okdir'}

def reaches_git(a, base):
    """a may sit in a git dir: a `.git` component once resolved against base, or a dirname the hook cannot read —
    `$`/backtick, or a glob in any directory part (`.g?t/r*`, `cd .g* && rm r*`: the shell may expand it to .git).
    Over-match accepted: `rm src/*/build/*` is denied too. Not covered: a symlink alias made in the same command."""
    d = os.path.dirname(a.rstrip('/'))
    full = os.path.dirname(resolve(base, a).rstrip('/'))
    return ('$' in d or '`' in d or any(c in full for c in '*?[{')
            or '.git' in resolve(base, a).lower().split('/'))

def names_mandato(a, base, reach=False):
    """a names the Mandato file: literally, or by a glob on its basename; case-insensitive (macOS FS).
    A glob counts only when it can reach a git dir (reaches_git, or reach=True: the caller's other arguments
    do) or carries a literal `mandato` — `rm -rf dist/*`, `cp fixtures/*.json out/` name nothing."""
    a = a.lower()
    if MANDATO_FILE in a:
        return True
    b = os.path.basename(a.rstrip('/'))
    if not (any(c in b for c in '*?[') and fnmatch.fnmatchcase(MANDATO_FILE, b)):
        return False
    return reach or 'mandato' in b or reaches_git(a, base)

PROTECTED = ('dev', 'main', 'master')
FIND_LAUNCHERS = {'sudo', 'doas', 'env', 'command', 'builtin', 'exec', 'nice', 'nohup', 'time', 'timeout', 'busybox',
                  'xargs', 'ionice', 'stdbuf', 'caffeinate'}
# an -exec target that can remove, empty or overwrite the file it is handed (a shell can do anything)
FIND_DESTROYERS = {'rm', 'unlink', 'shred', 'mv', 'truncate', 'chmod', 'cp', 'ln', 'tee', 'dd', 'install', 'rsync',
                   'ditto', 'sponge', 'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'python', 'python3', 'perl', 'ruby', 'node'}
GIT_VALUED = {'-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env', '--super-prefix', '--exec-path'}
PUSH_VALUED = {'--repo', '-o', '--push-option', '--receive-pack', '--exec'}

def git_call(w, here):
    """w = words of a `git …` command. Returns (dir, subcommand, args): global options (-C cumulative,
    -c k=v, --git-dir/--work-tree, flags) skipped; --work-tree, else --git-dir, names the dir acted on."""
    d, gitdir, worktree, j = here, None, None, 1
    while j < len(w) and w[j].startswith('-') and w[j] != '--':
        a = w[j]
        k, eq, val = a.partition('=')
        if eq and k in GIT_VALUED:
            pass
        elif a in GIT_VALUED:
            k, val = a, (w[j + 1] if j + 1 < len(w) else ''); j += 1
        elif a.startswith('-C') and len(a) > 2:
            k, val = '-C', a[2:]
        else:
            k, val = a, ''
        if k == '-C' and val:
            d = resolve(d, val)
        elif k == '--git-dir' and val:
            gitdir = val
        elif k == '--work-tree' and val:
            worktree = val
        j += 1
    if j < len(w) and w[j] == '--':
        j += 1
    if worktree:
        d = resolve(d, worktree)
    elif gitdir:
        # its worktree: <wt>/.git -> <wt>; a linked one's gitdir file names <wt>/.git; else the git dir itself
        # (mandato.check then finds the file but no worktree to bind -> refused: fail closed)
        g = resolve(d, gitdir)
        d = g
        if os.path.basename(g) == '.git':
            d = os.path.dirname(g)
        else:
            try:
                with open(os.path.join(g, 'gitdir')) as fh:
                    d = os.path.dirname(resolve(g, fh.read().strip()))
            except OSError:
                pass
    return d, (w[j] if j < len(w) else ''), w[j + 1:]

def push_dest(args):
    """A `git push` -> (protected, implied). protected: a destination is dev|main|master (after an optional +,
    <src>: and refs/heads/), or it pushes every branch (--all/--mirror/--branches); a lone positional counts as a
    destination. implied: the destination is the current branch's — no refspec, or a src-only HEAD/@."""
    pos, j = [], 0
    while j < len(args):
        a = args[j]
        if a == '--':
            pos += args[j + 1:]; break
        if a in ('--all', '--mirror', '--branches'):
            return True, False
        if a in PUSH_VALUED:
            j += 2; continue
        if not a.startswith('-'):
            pos.append(a)
        j += 1
    for r in (pos[1:] if len(pos) > 1 else pos):
        r = r.lstrip('+').rsplit(':', 1)[-1]
        if r.startswith('refs/heads/'):
            r = r[len('refs/heads/'):]
        if r in PROTECTED:
            return True, False
    return False, len(pos) < 2 or any(r.lstrip('+') in ('HEAD', '@') for r in pos[1:])

def current_branch(d):
    """`git -C d branch --show-current`, '' on any failure or a dir the hook did not resolve."""
    if '$' in d or '`' in d:
        return ''
    try:
        r = subprocess.run(['git', '-C', d, 'branch', '--show-current'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ''
    return r.stdout.strip() if r.returncode == 0 else ''

API_FIELDS = ('-f', '-F', '--field', '--raw-field', '--input')

def api_kind(args):
    """`gh api` args -> 'apimerge' (PUT …/pulls/<n>/merge; graphql mergePullRequest/enablePullRequestAutoMerge),
    'apicreate' (POST …/repos/<o>/<r>/pulls — explicit, or implied by -f/-F/--input with no method; graphql
    createPullRequest) or ''. Both feed only the Mandato gates."""
    method, j, merge, pulls, fields, gql = '', 0, False, False, False, False
    while j < len(args):
        a = args[j]
        if a in ('-X', '--method'):
            method = args[j + 1] if j + 1 < len(args) else ''; j += 1
        elif a.startswith('--method='):
            method = a[9:]
        elif a.startswith('-X') and len(a) > 2:
            method = a[2:]
        elif a in API_FIELDS or any(a.startswith(f + '=') for f in API_FIELDS if f.startswith('--')) or \
                (a[:2] in ('-f', '-F') and len(a) > 2):
            fields = True
        elif re.search(r'(^|/)pulls/[^/\s]+/merge/?$', a):
            merge = True
        elif re.search(r'(^|/)repos/[^/\s]+/[^/\s]+/pulls/?$', a):
            pulls = True
        elif a.strip('/') == 'graphql':
            gql = True
        j += 1
    method = method.upper()
    if gql:
        text = ' '.join(args)
        for j, a in enumerate(args):   # query=@file / --input file: read it; stdin or unreadable -> merge (fail closed)
            src = a.split('=@', 1)[1] if '=@' in a else (args[j + 1] if a == '--input' and j + 1 < len(args) else None)
            if src is None:
                continue
            try:
                if src == '-':
                    raise OSError
                with open(resolve(here_ctx[0], src), errors='replace') as fh:
                    text += ' ' + fh.read(1 << 20)
            except OSError:
                return 'apimerge'
        text = text.lower()
        if 'mergepullrequest' in text or 'enablepullrequestautomerge' in text:
            return 'apimerge'
        if 'createpullrequest' in text:
            return 'apicreate'
        return ''
    if merge and method == 'PUT':
        return 'apimerge'
    if pulls and (method == 'POST' or (not method and fields)):
        return 'apicreate'
    return ''
EVIDENCE_WRITERS = {'tee', 'cp', 'mv', 'install', 'ln', 'mkdir', 'rsync', 'ditto', 'sponge'}
# $NAME or ${NAME} only: ${NAME:-x}, $1, $$, $(…) stay unexpanded, so a dir holding them reads as unresolved.
VARREF = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))')
DECLARE = ('export', 'declare', 'local', 'readonly', 'typeset')
DYNAMIC = ('xargs', 'parallel')   # launchers that build the argv at run time
env, flags = {}, set()
ctx, oldctx, dirstack = cwd, None, []
here_ctx = [cwd]   # the dir a `gh api` runs in, for its @file arguments

def lookup(name):
    """A $NAME's value: assigned earlier in this command, else PWD/OLDPWD from the tracked cd, else the
    environment the hook (and so the agent's shell) runs with; None when unknown."""
    if name in env:
        return env[name]
    if name == 'PWD':
        return ctx
    if name == 'OLDPWD':
        return oldctx
    return os.environ.get(name)

def expand(x):
    for _ in range(3):
        y = VARREF.sub(lambda m: (lambda v: m.group(0) if v is None else v)(lookup(m.group(1) or m.group(2))), x)
        if y == x:
            break
        x = y
    return x

OPREF = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)[^A-Za-z0-9_}][^}]*\}')

def expand_loose(x):
    """expand() for write targets and writer arguments: ${NAME<op>…} (${F:-y}, ${F%x}) also becomes the known
    value of NAME — an over-match that only denies. Never used for a dir (there it must stay unresolved)."""
    x = expand(x)
    return expand(OPREF.sub(lambda m: (lambda v: m.group(0) if v is None else v)(lookup(m.group(1))), x))

def settle(d, dynamic=False):
    """The dir a command acts on, as printed for mandato_dirs. Unresolved (left a $ or backtick, has a
    newline/tab, a glob/brace with no single match, or argv built by xargs) -> prefixed '$?', which the
    shell side reads as refused (fail closed)."""
    if dynamic or '$' in d or '`' in d or '\n' in d or '\t' in d:
        return d if '$' in d else '$?' + d.replace('\n', ' ').replace('\t', ' ')
    if any(c in d for c in '*?[{') and not os.path.exists(d):
        m = [] if '{' in d else glob.glob(d)
        return os.path.normpath(m[0]) if len(m) == 1 else '$?' + d
    return d

SHIP_VALUED = ('--base', '--issue', '--title', '--body-file', '--followup-file', '--slot-env')  # ship.sh usage line

def ship_args(w):
    """w (launchers skipped) runs ship.sh — `ship.sh …` / `<path>/ship.sh …`, `source|. [--] <…>/ship.sh …`, or
    `bash|sh|zsh|dash|ksh|mksh [opts] [--] <…>/ship.sh …` — -> the words after the script, else None. The script is
    matched by basename, so any path counts (over-match only denies). Options are read by shell_opts: a cluster
    with c (runs its string, parsed as a nested command) or a final noexec (`-n`, `+n -n`) is not a ship call;
    `-n +n` is. A bare `source|. ship.sh` keeps the caller's "$@": it returns ['$@']. The caller emits an unresolved
    worktree (`$`, backtick, glob, xargs argv) as a merge with target "?" (deny), --no-merge/--dry-run included: fail closed.
    cat/grep/echo of ship.sh never reach here as the command."""
    if not w:
        return None
    h = os.path.basename(w[0])
    if h == 'ship.sh':
        return w[1:]
    if h in ('source', '.'):
        j = 2 if len(w) > 1 and w[1] == '--' else 1
        if j < len(w) and os.path.basename(w[j]) == 'ship.sh':
            return w[j + 1:] or ['$@']
        return None
    if h not in SHELLS:
        return None
    j, runs, noexec, _ = shell_opts(w, 1)
    if runs or noexec:
        return None
    if j < len(w) and os.path.basename(w[j]) == 'ship.sh':
        return w[j + 1:]
    return None

saved = []
switched = False   # a `git checkout|switch` ran earlier in this command
for w in all_segments(cmd):
    if w == ['__push__']:
        saved.append(ctx); continue
    if w == ['__pop__']:
        ctx = saved.pop() if saved else ctx; continue  # a cd inside bash -c stays inside it
    for t in map(expand_loose, w.writes):
        if STAMP in t: flags.add('stampwrite')
        if names_mandato(t, ctx): flags.add('mandatowrite')
        if EVIDENCE.search(t) or EVIDENCE.search(resolve(ctx, t)): flags.add('evidencewrite')
    for x in w:   # NAME=value (also after export/declare/…) feeds later $NAME expansion
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', x, re.S)
        if m:
            env[m.group(1)] = expand(m.group(2))
        elif x not in DECLARE:
            break
    i, here = skip_launchers(w, ctx)
    dynamic = any(x in DYNAMIC for x in w[:i])
    w = w[i:]
    if not w:
        continue
    # writer arguments: ${NAME<op>…} too becomes NAME's known value (expand_loose); dirs below keep the strict expand
    head, args = os.path.basename(w[0]), [expand_loose(x) for x in w[1:]]
    wdir = here or ctx
    if head in STAMP_WRITERS and any(STAMP in a for a in args): flags.add('stampwrite')
    if head in MANDATO_WRITERS and any(names_mandato(a, wdir) for a in args): flags.add('mandatowrite')
    # find … -delete/-exec: any arg naming the Mandato or its stem (-name/-iname/-path/-regex, glob-aware, no case);
    # a bare glob (-name '*.json') counts when a start path can reach a git dir (find .git …, cd .git && find . …)
    if head == 'find' and any(a in FIND_ACTIONS for a in args):
        starts, i = [], 0
        while i < len(args) and (args[i] in ('-H', '-L', '-P', '-E', '-X', '-d', '-s', '-x')
                                 or re.fullmatch(r'-(D|O)\S*', args[i])):   # leading find options
            i += 2 if args[i] in ('-D',) else 1
        for a in args[i:]:   # find's start paths: every argument before the first expression token
            if a.startswith('-') or a in ('(', '!', ')'):
                break
            starts.append(a)
        # a start path that is a glob (`find .g* …`) may expand to .git, like a glob dir in reaches_git
        # find recurses: a start path holding a `.git` directory (a main checkout's top, `find . …` there) reaches it
        # too — counted only for a find that removes (-delete, or -exec/-execdir/-ok of rm/unlink/shred/mv), so a
        # read such as `find . -name '*.json' -exec jq . {} +` passes
        def exec_target(k):
            # the command an -exec runs, past launchers (sudo rm, env rm, command rm, nice -n 5 rm …)
            k += 1
            while k < len(args) and (os.path.basename(args[k]) in FIND_LAUNCHERS or args[k].startswith('-')
                                     or re.fullmatch(r'[0-9.]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=.*', args[k])):
                k += 1
            return os.path.basename(args[k]) if k < len(args) else ''
        destroys = '-delete' in args or any(
            args[k] in ('-exec', '-execdir', '-ok', '-okdir') and exec_target(k) in FIND_DESTROYERS
            for k in range(len(args)))
        reach = any('$' in a or '`' in a or any(c in a for c in '*?[{') or reaches_git(a, wdir)
                    or (destroys and os.path.isdir(os.path.join(resolve(wdir, a), '.git'))) for a in starts)
        # a find that removes walks down from wherever it starts (`find . …` above a repo reaches repo/.git): any
        # glob that matches the Mandato's name counts there, as it did before the reach narrowing
        if any(names_mandato(a, wdir, reach or destroys) or 'mandato' in a.lower() for a in args): flags.add('mandatowrite')
        # A find that removes (destroys) from a start path that reaches a git dir is a Mandato write whatever its
        # filters: -name/-path globs, -regex in find's basic/emacs/extended dialects and -prune combinations can't be
        # judged reliably here, so the class is closed instead (fail closed). Accepted over-match: `find .git -name
        # '*.log' -delete` is denied too.
        if reach and destroys:
            flags.add('mandatowrite')
    if head in EVIDENCE_WRITERS and any(EVIDENCE.search(a) or EVIDENCE.search(resolve(ctx, a)) for a in args): flags.add('evidencewrite')
    # a dir NAMED subagents copied/moved/linked into a project dir: the target path never appears in an argument
    if head in EVIDENCE_WRITERS and any(os.path.basename(a.rstrip('/')) == 'subagents' for a in args) and \
            any('/.claude/projects/' in a or '/.claude/projects/' in resolve(ctx, a) for a in args): flags.add('evidencewrite')
    sa = ship_args(w)
    if sa is not None:
        # ship.sh runs `git -C <wt> push -u origin <branch>`, `gh pr create --base <b>` and, unless --no-merge or
        # --dry-run, `gh pr merge` — all inside <wt> (its first positional, relative to the dir this command runs in)
        wt, base, merges, helps, j = None, '', True, False, 0
        while j < len(sa):
            a = sa[j]
            if a in SHIP_VALUED:
                if a == '--base' and j + 1 < len(sa):
                    base = sa[j + 1]
                j += 2; continue
            if a in ('--no-merge', '--dry-run'):
                merges = False
            elif a in ('-h', '--help'):
                helps = True
            elif not a.startswith('-') and wt is None:
                wt = a
            j += 1
        if wt is not None and not helps:   # no worktree / --help: ship.sh prints usage and does nothing
            d = settle(resolve(here or ctx, expand(wt)), dynamic)
            unres = dynamic or switched or '$' in wt or '`' in wt
            print('\t'.join(('push', d, '1' if current_branch(d) in PROTECTED else '0', '1' if unres else '0', '-', '-')))
            print('\t'.join(('create', d, '-', '-', '-', base or '-')))
            if '$' in d or '`' in d:   # <wt> unresolved (var, backtick, glob, xargs argv): no repo to gate -> deny, --no-merge/--dry-run too
                print('\t'.join(('merge', d, '-', '?', '-', '-')))
            elif merges:
                print('\t'.join(('merge', d, '-', '-', '-', '-')))
        continue
    if w[0] in ('cd', 'pushd', 'popd'):
        a = [expand(x) for x in w[1:] if not (x.startswith('-') and len(x) > 1)]
        prev = ctx
        if w[0] == 'popd':
            ctx = dirstack.pop() if dirstack else '$?popd'
        elif a and a[0] == '-':
            ctx = oldctx if oldctx is not None else '$?OLDPWD'
        else:
            ctx = resolve(ctx, a[0]) if a else os.path.expanduser('~')
            if w[0] == 'pushd':
                dirstack.append(prev)
        oldctx = prev
        continue
    if head == 'git':
        gw = [expand(x) for x in w]
        # GIT_DIR / GIT_WORK_TREE assigned in this command (prefix or export) name the repo like the options do
        pre = ['--git-dir=' + env['GIT_DIR']] if env.get('GIT_DIR') else []
        pre += ['--work-tree=' + env['GIT_WORK_TREE']] if env.get('GIT_WORK_TREE') else []
        gdir, sub, gargs = git_call(gw[:1] + pre + gw[1:], here or ctx)
        if sub in ('rm', 'clean'):   # pathspecs: strict and ${NAME<op>…}-expanded, resolved against the dir git acts on
            _, _, largs = git_call([gw[0]] + pre + args, here or ctx)
            if any(names_mandato(a, gdir) for a in gargs + largs): flags.add('mandatowrite')
        if sub == 'push':
            # destination the hook cannot read ($…, backtick, xargs) -> column 4 = 1: alcance=pr treats it as protected
            unres = dynamic or any('$' in a or '`' in a for a in gargs if not a.startswith('-'))
            prot, implied = push_dest(gargs)
            if implied and not prot:
                # the destination is the checked-out branch: protected when that is dev|main|master now; a
                # checkout/switch earlier in this command moves it before the push runs -> unresolved
                prot = current_branch(gdir) in PROTECTED
                unres = unres or switched
            print('\t'.join(('push', settle(gdir, dynamic), '1' if prot else '0', '1' if unres else '0', '-', '-')))
        elif sub in ('checkout', 'switch') and '--' not in gargs:   # `git checkout -- <paths>` restores files
            switched = True
        continue
    if head != 'gh':
        continue
    if len(w) > 1 and w[1] == 'api':
        here_ctx[0] = here or ctx
        k = api_kind([expand(x) for x in w[2:]])
        if k:
            print('\t'.join((k, settle(here or ctx, dynamic), '-', '-', '-', '-')))
        continue
    if len(w) < 3 or w[1] != 'pr':
        continue
    k = 2   # flags between `pr` and the subcommand (gh pr -R o/r merge 1); -R/--repo takes the next word
    while k < len(w) and w[k].startswith('-'):
        k += 2 if w[k] in ('-R', '--repo') else 1
    if k >= len(w) or w[k] not in ('create', 'new', 'merge'):
        continue
    # `new` is gh's alias of `create`; args never expanded: which assignment reaches gh is not static
    kind, args = ('merge' if w[k] == 'merge' else 'create'), w[2:k] + w[k + 1:]
    ref = num = repo = base = ''
    j = 0
    while j < len(args):
        a = args[j]
        k, eq, val = a.partition('=')
        if a.startswith('--') and eq:
            pass
        elif a in VALUED:
            k, val = a, (args[j + 1] if j + 1 < len(args) else ''); j += 1
        elif re.match(r'^-[RHB].+', a):
            k, val = a[:2], a[2:]
        elif a.startswith('-'):
            k, val = a, ''
        else:
            k, val = '', a
        if k in ('-R', '--repo'): repo = val
        elif k in ('-H', '--head'): ref = val
        elif k in ('-B', '--base'): base = val
        elif k == '' and kind == 'merge' and not num and not ref:
            if '://' in val or '/pull/' in val: num = val   # URL (by its scheme: gh decodes %70ull etc.): reaches gh pr view verbatim (gh resolves it as gh pr merge does)
            elif val.lstrip('#').isdigit(): num = val.lstrip('#')
            else: ref = val
        j += 1
    # $(…), backtick or $VAR; a dynamic -R only matters on merge (on create the literal --head still holds)
    unres = any('$' in x or '`' in x for x in (ref, num)) or (kind == 'merge' and ('$' in repo or '`' in repo))
    if unres and kind == 'merge':
        ref, num = '', '?'    # merge: unresolvable target -> deny (the dir's HEAD may be another PR)
    elif unres:
        ref = num = ''        # create: falls back to the context dir's HEAD (the merge is blocked later)
    print('\t'.join(x or '-' for x in (kind, settle(here or ctx, dynamic), ref, num, repo, base)))
for f in sorted(flags):
    print(f + '\t-\t-\t-\t-\t-')
GHPY
}

# Command start: start of line, shell separators, subshell/backtick.
S='(^|[;&|(`[:space:]])'
# Push to dev/main/master, defined once and used by every push gate: destination after optional `+`,
# `<src>:` and `refs/heads/`. The raw text only catches a bare `git push`; `git -C/-c/--git-dir … push`
# comes tokenized from gh_calls (line `push <dir> 1`) — `push_protected`/`push_any` combine both.
PUSH_PROTECTED="${S}git[[:space:]]+push([^;&|]*)[[:space:]](origin[[:space:]]+)?[+]?([^[:space:];&|:]*:)?(refs/heads/)?(dev|main|master)([[:space:]]|$)"
push_protected() { printf '%s\n' "$calls" | grep -q $'^push\t[^\t]*\t1' || printf '%s' "$cmd" | grep -qE "$PUSH_PROTECTED"; }
push_any() { printf '%s\n' "$calls" | grep -q $'^push\t' || printf '%s' "$cmd" | grep -qE "${S}git[[:space:]]+push"; }

STAMP_WRITE_DENY="Blocked: the review stamp (rumo-review.ok) is written only by review-stamp.sh (bash <rumo>/skills/review/scripts/review-stamp.sh), which requires the transcript of this session's reviewer. Run the review — or the fix axis over <stamp>..HEAD — and then the script; never write the stamp by hand."
MANDATO_DENY="Blocked: Mandato refused (<reason>) — tampered with, from another worktree/branch or unreadable. Stop and report; only the host rewrites the Mandato."
MANDATO_PR_DENY="Blocked: this lane's Mandato has alcance=pr — merge and push to dev/main/master belong to the owner (a push destination coming from a variable/substitution counts as dev/main/master: pass it literally)."
MANDATO_UNRESOLVED_DENY="Blocked: the dir this push/PR/merge acts in comes from an undefined variable, a substitution, a glob without a single match or xargs — the hook cannot tell which Mandato applies there. Pass the literal path (cd /path && …, git -C /path …)."
MANDATO_WRITE_DENY="Blocked: the Mandato (rumo-mandato.json) and the key (mandato.key) belong to the host — this hook denies writing or deleting the Mandato, writing the key and any command that mentions the key or ~/.config/rumo. Stop and report; only the host rewrites them."

GH_OLD_DENY="Blocked: the installed gh does not accept gh pr view --json headRefOid,headRefName,baseRefName,isCrossRepository (fields that exist since gh 1.9.0), so the hook cannot read the PR head. Upgrade gh (brew upgrade gh) and run the merge again; '#sem-review' in the user's message unlocks."
MERGE_URL_DENY="Blocked: gh did not resolve the PR URL (network, or a URL the hook cannot check), so the PR head was not checked against the stamp. Run 'gh pr merge <N>' with the number in a checkout of the PR's repo; '#sem-review' in the user's message unlocks."
MERGE_UNRESOLVED_DENY="Blocked: the merge target comes from a substitution/variable and the hook cannot tell which PR it is. Resolve the number first and run 'gh pr merge <N>' with the literal number."

EVIDENCE_WRITE_DENY="Blocked: subagent transcripts (~/.claude/projects/*/subagents) are the review's evidence and only Claude Code writes them."

case "$tool" in
  mcp__github__create_pull_request)
    mandato_refused && mandato_deny
    base=$(printf '%s' "$input" | jq -r '.tool_input.base // empty' 2>/dev/null)
    head=$(printf '%s' "$input" | jq -r '.tool_input.head // empty' 2>/dev/null)
    if [ "$head" != "dev" ] && { [ "$base" = "main" ] || [ "$base" = "master" ]; } && repo_has_dev; then
      note "PRs target dev, not $base: this repo integrates on dev. If this is not a release PR requested in this session, reopen it with base dev."
    fi
    build_unattended && deny "$PR_UNATTENDED_DENY"
    if is_release "$head" "$base"; then
      release_gate "$cwd" "$base"; flush_notes
    fi
    tsha=""
    [ -n "$head" ] && tsha=$(git -C "$cwd" rev-parse --verify -q "refs/heads/$head" 2>/dev/null)
    apply_gate "$tsha"
    flush_notes
    ;;
  mcp__github__merge_pull_request)
    mandato_refused && mandato_deny
    mandato_pr_only && deny "$MANDATO_PR_DENY"
    is_unattended && deny "$UNATTENDED_DENY"
    num=$(printf '%s' "$input" | jq -r '.tool_input.pull_number // empty' 2>/dev/null)
    own=$(printf '%s' "$input" | jq -r '.tool_input.owner // empty' 2>/dev/null)
    rep=$(printf '%s' "$input" | jq -r '.tool_input.repo // empty' 2>/dev/null)
    if [ -n "$num" ]; then merge_gate "$num" "${own:+$own/$rep}" "$cwd"; else fail_open; fi
    flush_notes
    ;;
  Write|Edit|MultiEdit)
    fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ "${fp##*/}" = rumo-review.ok ] && deny "$STAMP_WRITE_DENY"
    case "$(printf '%s' "${fp##*/}" | tr '[:upper:]' '[:lower:]')" in rumo-mandato.json|mandato.key) deny "$MANDATO_WRITE_DENY" ;; esac
    [[ "$fp" =~ /\.claude/projects/.*/subagents/ ]] && deny "$EVIDENCE_WRITE_DENY"
    exit 0
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$cmd" ] || exit 0

    # gh pr create|merge in command position + stampwrite/evidencewrite signals (gh_calls).
    # No python3: the old regex, target = cwd, no detection of stamp writes (fail-open).
    if command -v python3 >/dev/null 2>&1; then
      calls=$(gh_calls)
    else
      calls=""
      printf '%s' "$cmd" | grep -qE "${S}gh[[:space:]]+pr[[:space:]]+(create|new)" && calls="create	$cwd	-	-	-	-"
      printf '%s' "$cmd" | grep -qE "${S}gh[[:space:]]+pr[[:space:]]+merge" && calls="${calls:+$calls
}merge	$cwd	-	-	-	-"
    fi
    printf '%s\n' "$calls" | grep -q '^stampwrite' && deny "$STAMP_WRITE_DENY"
    printf '%s\n' "$calls" | grep -q '^evidencewrite' && deny "$EVIDENCE_WRITE_DENY"
    printf '%s\n' "$calls" | grep -q '^mandatowrite' && deny "$MANDATO_WRITE_DENY"
    # the key: its name (also by glob: mandato.ke?, mandato.*), the RUMO_MANDATO_KEY variable or its dir; case-insensitive
    # (macOS FS). Over-match accepted.
    printf '%s' "$cmd" | grep -qiE 'mandato\.k|mandato\.[*?[]|mandato_key|config/rumo' && deny "$MANDATO_WRITE_DENY"

    # ---- Mandato (#98), before the review gates: refused -> no PR/merge/push;
    # alcance=pr -> no merge and no push to dev/main/master. absent / alcance=merge: nothing changes.
    # Read from the cwd and from every dir the command acts in (mandato_dirs); gh api PUT pulls/<n>/merge and graphql
    # mergePullRequest count as merge (apimerge), gh api POST repos/<o>/<r>/pulls and graphql createPullRequest
    # as PR (apicreate) — only here, not in the review gates. alcance=pr: an unresolvable push destination (column 4) = protected.
    if printf '%s\n' "$calls" | grep -qE '^(create|merge|apimerge|apicreate)' || push_any; then
      mandato_refused && mandato_deny
      if mandato_pr_only; then
        { printf '%s\n' "$calls" | grep -qE $'^(merge|apimerge)|^push\t[^\t]*\t[01]\t1' || push_protected; } && deny "$MANDATO_PR_DENY"
      fi
    fi

    # ---- Unattended automation: no merge, no push to dev/main, no deploy.
    if printf '%s\n' "$calls" | grep -q '^merge' || push_protected ||
       printf '%s' "$cmd" | grep -qE "${S}vercel([[:space:]]+(deploy|--prod|promote)|[[:space:]]*$)|${S}firebase[[:space:]]+deploy|${S}eas[[:space:]]+submit"; then
      is_unattended && deny "$UNATTENDED_DENY"
    fi
    # PR: only the headless `/rumo build` is blocked; an automation worktree by path still opens PRs.
    if printf '%s\n' "$calls" | grep -q '^create'; then
      build_unattended && deny "$PR_UNATTENDED_DENY"
    fi

    # ---- PR create (base dev + stamp) and merge (stamp covering the PR head), per invocation.
    while IFS=$'\t' read -r kind dir ref num repo base; do
      case "$kind" in create|merge) ;; *) continue ;; esac
      [ "$ref" = - ] && ref=""; [ "$num" = - ] && num=""; [ "$repo" = - ] && repo=""
      # '$?' marks a dir the hook did not resolve (settle): it counts for the Mandato (fail-closed above);
      # the review gate uses the dir without the mark — with it git would fail and the gate would let it through (fail-open).
      case "$dir" in '$?'*) dir=${dir:2} ;; esac
      [ "$kind" = merge ] && [ "$num" = "?" ] && deny "$MERGE_UNRESOLVED_DENY"
      if [ "$kind" = create ]; then
        cur=${ref:-$(git -C "$dir" branch --show-current 2>/dev/null)}
        case "$cur" in *:*) o=$(own_owner "$dir" "$repo")
          [ -n "$o" ] && [ "$o" = "$(printf '%s' "${cur%%:*}" | tr '[:upper:]' '[:lower:]')" ] && cur=${cur#*:} ;; esac
        [ "${cur#*:}" = dev ] && [[ "$base" == *[\$\`]* ]] && deny "Blocked: the PR base comes from a variable/substitution; pass a literal --base (main/master/dev)."
        if is_release "$cur" "$base"; then
          release_gate "$dir" "$base"; continue
        fi
        if repo_has_dev "$dir"; then
          if [ "${cur#*:}" != "dev" ]; then
            if [ "$base" = - ]; then
              note "gh pr create without --base uses the repo's default branch; this repo integrates on dev. Redo it with --base dev if that was not intended."
            elif [ "$base" = main ] || [ "$base" = master ]; then
              note "gh pr create is targeting main/master; this repo integrates on dev. Proceed only if a release PR was requested in this session."
            fi
          fi
        fi
        gate_target "$dir" "$ref" "" ""
      else
        gate_target "$dir" "$ref" "$num" "$repo" merge
      fi
    done <<< "$calls"

    # ---- Feature branch push: nudge (not deny) if no review ran in the session.
    if push_any && ! push_protected; then
      cur=$(git -C "$cwd" branch --show-current 2>/dev/null)
      case "$cur" in
        ""|dev|main|master) ;;
        *) fail_open ;;
      esac
    fi

    # ---- Production deploys: only when requested in this session.
    if printf '%s' "$cmd" | grep -qE "${S}vercel([[:space:]]+(deploy|--prod|promote)|[[:space:]]*$)" ||
       { printf '%s' "$cmd" | grep -qE "${S}firebase[[:space:]]+deploy" && ! printf '%s' "$cmd" | grep -q -- '--dry-run'; } ||
       printf '%s' "$cmd" | grep -qE "${S}eas[[:space:]]+submit|${S}eas[[:space:]]+build.*--auto-submit" ||
       printf '%s' "$cmd" | grep -qE "${S}supabase[[:space:]]+db[[:space:]]+push"; then
      deploy_requested || deny "$DEPLOY_DENY"
      note "Production deploy (requested in this session). After publishing, verify the critical path live (e.g. the repo's smoke-prod, if there is one) before calling it done."
    fi

    # ---- Destructive write to a PRODUCTION DATABASE (incident 2026-09-18, no PITR).
    prod_db=0
    if printf '%s' "$cmd" | grep -qE "${S}supabase[[:space:]]+db[[:space:]]+(query|execute|reset)" &&
       printf '%s' "$cmd" | grep -qE -- '--(linked|project-ref|db-url)'; then prod_db=1; fi
    if printf '%s' "$cmd" | grep -qE "${S}psql" &&
       printf '%s' "$cmd" | grep -qiE 'postgres(ql)?://' &&
       ! printf '%s' "$cmd" | grep -qiE 'postgres(ql)?://[^@[:space:]]*@?(localhost|127\.0\.0\.1|\[::1\])'; then prod_db=1; fi
    if printf '%s' "$cmd" | grep -qiE "${S}curl" &&
       printf '%s' "$cmd" | grep -qiE -- '-X[[:space:]]*(DELETE|PATCH)|--request[[:space:]]+(DELETE|PATCH)' &&
       printf '%s' "$cmd" | grep -qiE 'supabase\.co/rest/v1'; then prod_db=1; fi
    if [ "$prod_db" = 1 ] &&
       { printf '%s' "$cmd" | grep -qiE 'delete[[:space:]]+from|truncate|drop[[:space:]]+(table|schema|view|function|column|index)|update[[:space:]]+[[:alnum:]_."]+[[:space:]]+set|alter[[:space:]]+table|db[[:space:]]+reset|-X[[:space:]]*(DELETE|PATCH)|--request[[:space:]]+(DELETE|PATCH)'; }; then
      confirmed_now || deny "Blocked: DESTRUCTIVE WRITE TO THE PRODUCTION DATABASE (no PITR = no undo). First: (1) restate the scope in the user's words (e.g. 'only the telemetry'); (2) run the SELECT with the same condition and show the count per table; (3) save the affected rows (select json_agg) to the scratchpad; (4) ask them to reply 'confirmo'. With 'confirmo' in their last message, the command passes."
    fi

    # ---- config/appVersion node (production RTDB) and production seeds.
    if printf '%s' "$cmd" | grep -qE 'version:publish' && ! printf '%s' "$cmd" | grep -q -- '--dry-run'; then
      if printf '%s' "$cmd" | grep -qE -- '(--min|--force)([[:space:]]|=|$)'; then
        confirmed_now || deny "Blocked: this publishes a BLOCKING version FLOOR to the production RTDB (a modal that does not close; with no installable build the app becomes unusable). Show the user the measured version distribution and ask for 'confirmo'."
      fi
      deploy_requested || deny "Blocked: writes to the config/appVersion node of the production RTDB and affects installed users at once, with no request in this session. Use --dry-run to see the PUT without sending it, and ask."
    fi
    if printf '%s' "$cmd" | grep -qE 'scripts/seed/[A-Za-z0-9_.-]+\.ts'; then
      confirmed_now || deny "Blocked: this seed script writes straight to the PRODUCTION RTDB (production firebaseConfig) and has no undo. Explain what it writes and ask for 'confirmo'."
    fi

    flush_notes
    ;;
esac

exit 0
