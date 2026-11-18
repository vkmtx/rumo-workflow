#!/usr/bin/env bash
# review-stamp.sh — the only writer of the review stamp (<git-dir>/rumo-review.ok).
#
# Usage (run inside the reviewed repo/worktree):
#   review-stamp.sh --tier light|standard|sensitive --base <sha> [--axes a,b] [--session <id>]
#   review-stamp.sh --fix [--inline-fix] [--session <id>]
#   review-stamp.sh --base-merge [--session <id>]
#
# Full-review mode writes the stamp only with evidence: for every required axis, a finished
# rumo:reviewer* subagent of this Claude Code session whose brief (line 1 of its transcript)
# carries a line `RANGE: <base>..<HEAD>` (trailing text allowed) and `AXIS: <axis>`. Required axes:
# light → bugs; standard → bugs,standards,spec; sensitive → bugs,standards,spec,security; --axes
# overrides the set (values in bugs,standards,spec,security), but the sensitive tier always adds
# security. The built-in /security-review is not evidence: the sensitive tier's security axis is a
# rumo:reviewer run like the others.
# Open findings: the script reads the final report (the last assistant message with text) of every
# accepted reviewer run and refuses while an Open finding remains (exit 1). Each top-level `<n>.` / `<n>)`
# line (number in any bold/code decoration; a numbered line indented deeper than the first item continues
# that item, unless it starts with a severity — then it opens `unreadable:<agentId>`) of the numbered
# FINDINGS list (up to QUESTIONS / CHECKED AND SOUND / NOT CHECKED) whose severity, in any bracket/bold
# decoration, is blocker or major opens `<axis>#<n>` (`fix#<n>` for a fix run); a report without a FINDINGS
# line, or a numbered line whose severity can't be read, opens `unreadable:<agentId>` (fail closed). A finding closes three ways: a fix reviewer's line `RESOLVED <id>` or `WITHDRAWN <id>`
# (anchored, case-sensitive; never closes fix#<n>), or a Waiver — `#waive <id>…` (`unreadable:<agentId>`
# too) in a real user message of this session's own transcript ($HOME/.claude/projects/*/<session>.jsonl:
# type/role user, not isMeta, no toolUseResult, typed by the owner, not machine-written — `!` output,
# slash-command text, hook feedback —, text before any `AUTHORIZED:`), the proof #env-ok uses. Ids stay
# keyed per report: a closer or waiver closes an id only in reports whose final entry's `timestamp` is
# earlier than its own (a missing or unreadable timestamp closes nothing; when every open id has such an
# entry, the refusal says to rerun the full review instead of naming #waive).
# Fix chain: when some axis has no run on BASE..HEAD, the script looks for R = the HEAD the axes reviewed —
# the nearest strict ancestor of HEAD (strict descendant of BASE) where every axis has a run on BASE..R and
# a finished `AXIS: fix` run has `RANGE: <R>..<HEAD>`; reviewed=HEAD. Sources: every axis run on BASE..HEAD
# and on BASE..R plus every fix run on R..HEAD (findings `fix#<n>`); closers: those fix runs. With R = HEAD,
# fix runs on `RANGE: HEAD..HEAD` count (a replay-demoted major withdrawn with no code change). Either way
# runs= = the first run per axis plus fix:<id> for every closer, so the fix modes re-read each one.
# Full-review mode refuses light/standard when the review §0 path scan ($SCAN) hits a path changed in
# BASE..HEAD (exit 1): such a diff stamps only with --tier sensitive.
# --base must cover the whole PR: it must be an ancestor-or-equal of the fork point
# FORK = merge-base(HEAD, T), T = origin's own tip read with `git ls-remote origin` (refs/heads/dev when
# origin/dev exists locally, else HEAD), never the local ref; neither local ref → exit 2; no answer from
# origin → exit 2 (a review stamp needs network); the base-merge transport check applies here too.
# Not covered (wontfix #23): a hotfix cut from main in a repo with origin/dev — FORK is measured against
# origin/dev, so its --base is refused. Hotfixes go through dev like every PR (PRs target dev).
#
# Session: --session, else $CLAUDE_CODE_SESSION_ID. Transcripts: only this session's own project dirs,
# $HOME/.claude/projects/*/<session>/subagents, searched recursively (workflows/wf_*/ included).
# There is no env override for the evidence location.
#
# Fix mode (--fix) moves an existing stamp OLD forward to HEAD after review fixes. OLD must be a
# strict ancestor of HEAD. Evidence: a finished rumo:reviewer* run with `RANGE: <OLD>..<HEAD>` and
# `AXIS: fix`. With --inline-fix no reviewer is needed, but REVIEWED..HEAD must change < 30 lines (no
# binary file) and no path changed in REVIEWED..HEAD may match the review §0 scan. OLD's tier alone does
# not refuse: a sensitive stamp is inline-fixed under the same conditions (and stays sensitive), and when
# its fix touches a scanned path the refusal names the path and the fix re-review to run (`AXIS: fix`,
# `RANGE: <OLD>..<HEAD>`). REVIEWED = the old stamp's reviewed= (a legacy stamp without it → OLD), so chained
# inline-fixes share one budget until a reviewer runs again. A base-merge between them would put the
# base's lines into REVIEWED..HEAD, so a non-reviewer-backed base-merge stamp records budget_from=<M>
# and budget_used=<lines already spent in REVIEWED..S>: the next inline-fix counts budget_used plus
# budget_from..HEAD (and scans only those paths), and carries both fields forward. budget_from must lie
# in REVIEWED..OLD; a broken budget refuses, and an unreadable one is recorded as budget_used=30.
# The fix stamp keeps OLD's tier and base (a legacy one-line stamp → base=OLD) and adds fix_of=OLD.
# Open findings in fix mode: sources = the old stamp's runs= entries plus every fix run on OLD..HEAD;
# closers = those fix runs plus the old stamp's own fix: entries (what they closed stays closed). --fix
# refuses an open one like the review does; --inline-fix adds no closer (an inline fix closes only minors),
# so a blocker/major still open in the old stamp's runs refuses it; it also re-reads every fix run with
# `RANGE: <OLD>..<X>`, X ancestor-or-equal of HEAD (a fix reviewer's later major holds it too). The session's
# #waive counts in both. runs= reports are looked up in this session and in the old stamp's session=.
#
# Base-merge mode (--base-merge) moves an existing stamp S to HEAD = M after the pre-merge
# `git merge origin/<base>` (and the version bump), with no reviewer, only when M is mechanical:
# M^1 == S exactly. With two parents (no third), M^2 must be an ancestor of the remote's own tip:
# `git ls-remote origin` (refs/heads/dev when UP is origin/dev, else HEAD), because the local UP is a
# ref anyone can move. A tip not fetched yet is fetched here (objects + FETCH_HEAD, no ref moves);
# still missing → refused with a fetch hint; no answer
# from origin → exit 2. Any git config that could reroute origin refuses first (exit 1), in any config
# scope: url.*.insteadOf, core.sshCommand, remote.origin.{uploadpack,vcs,proxy}, http[.<url>].{proxy,
# sslCAInfo,sslCAPath,curloptResolve}, any http[.<url>].sslVerify entry read as false or not a valid
# boolean (in any scope, even when a later entry makes git's effective value true — deliberately
# stricter), or a remote.origin.url that is not one github.com URL.
# Not covered (wontfix #45): a remote.origin.url naming another GitHub repo, and routes set in the
# caller's environment (GIT_SSH_COMMAND, GIT_SSH, GIT_SSL_NO_VERIFY, GIT_SSL_CAINFO, an ssh on PATH or
# ~/.ssh/config) — deliberate construction, same class as the hook's "GH_REPO in the environment" (NOT covered);
# the test suite reaches its fake origins this way. Then
# every path where M differs from `git merge-tree --write-tree S M^2` must be either the "version"
# line of .claude-plugin/plugin.json (greater than both parents') or a conflict resolved as ours,
# theirs, ours+theirs or theirs+ours with every line untouched (a missing final newline counts as
# untouched only when a side's own last line lacks one); a conflict on a §0 scan path (also one a
# committed merge attribute such as `merge=union` would auto-resolve: §0 paths are checked against a
# merge-tree with no attributes at all), a binary or marker-less conflict, a conflict-marker-size
# attribute and `merge -s ours` are refused. The checker's
# git calls run in a temporary bare repo borrowing the objects (no local/global/system config, no
# info/attributes, no replace refs; attributes only from S's tree), so a merge driver, filter or
# renormalize setting that shaped the real merge makes M differ from AUTO. With one
# parent the only change allowed is that "version" line, greater than before. The new stamp keeps
# S's tier, base=<new fork point with the remote tip>, reviewed=M when S was reviewer-backed (its
# reviewed= is S, or a legacy stamp has none) else S's reviewed= carried forward plus budget_from=M and
# budget_used= (see fix mode), and adds base_merge_of=S.
# Not covered: how the two sides interact semantically — the full suite and the typecheck after the merge stay mandatory.
#
# Stamp: line 1 `<HEAD40> <tier> <UTC timestamp>` (the PR/merge hook reads only field 1), then
# base=, reviewed=<last HEAD backed by a reviewer: HEAD for review/fix, carried forward for
# inline-fix and for a base-merge of a non-reviewer-backed stamp>, mode=review|fix|inline-fix|base-merge, axes=, runs=<axis>:<agentId>,…[,fix:<agentId>…], [fix_of=|base_merge_of=,] [budget_from=, budget_used=,] session=.
# GIT_NO_REPLACE_OBJECTS=1 is exported for every git call: a replace ref must not shape the inline-fix
# diff, an ancestry check or the fork point.
# Exit: 0 stamped · 1 no evidence / refused · 2 usage/repo error.
set -uo pipefail
export GIT_NO_REPLACE_OBJECTS=1  # replace refs must not shape any read (inline-fix diff, ancestry)

die() { echo "review-stamp: $1" >&2; exit "${2:-2}"; }

TIER="" BASE_ARG="" AXES_ARG="" SESSION="" FIX=0 INLINE=0 HAVE_AXES=0 BM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)       [ $# -ge 2 ] || die "--tier requires a value"; TIER="$2"; shift 2 ;;
    --base)       [ $# -ge 2 ] || die "--base requires a value"; BASE_ARG="$2"; shift 2 ;;
    --axes)       [ $# -ge 2 ] || die "--axes requires a value"; AXES_ARG="$2"; HAVE_AXES=1; shift 2 ;;
    --session)    [ $# -ge 2 ] || die "--session requires a value"; SESSION="$2"; shift 2 ;;
    --fix)        FIX=1; shift ;;
    --inline-fix) INLINE=1; shift ;;
    --base-merge) BM=1; shift ;;
    *)            die "unknown flag: $1" ;;
  esac
done

if [ $BM -eq 1 ]; then
  { [ $FIX -eq 1 ] || [ $INLINE -eq 1 ] || [ -n "$TIER" ] || [ -n "$BASE_ARG" ] || [ $HAVE_AXES -eq 1 ]; } && die "--base-merge cannot be combined with --fix/--inline-fix/--tier/--base/--axes"
elif [ $FIX -eq 1 ]; then
  { [ -n "$TIER" ] || [ -n "$BASE_ARG" ] || [ $HAVE_AXES -eq 1 ]; } && die "--fix cannot be combined with --tier/--base/--axes"
elif [ $INLINE -eq 1 ]; then
  die "--inline-fix only works with --fix"
fi

[ -n "$SESSION" ] || SESSION="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SESSION" ] || die "CLAUDE_CODE_SESSION_ID missing — run inside a Claude Code session (or pass --session)"
# The id becomes a path component: keep it to a plain name.
[[ "$SESSION" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$SESSION" != . ] && [ "$SESSION" != .. ] \
  || die "invalid session id: $SESSION"

HEAD=$(git rev-parse --verify -q HEAD 2>/dev/null) || die "not a git repository with a HEAD"
GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || die "git dir not found"
# The review §0 path scan, copied exactly from skills/review/SKILL.md.
SCAN='((^|/)(auth|migrations?)/|\.env|schema\.(prisma|sql)$|secret|passw|crypt|payment|billing|stripe|checkout|\.github/workflows/|dockerfile|docker-compose|(^|/)rls|polic(y|ies)\.sql$)|^scripts/hooks-staged/|^hooks/|^skills/review/|^agents/[^/]+\.md$|(^|/)\.claude/settings[^/]*\.json$|^\.claude-plugin/marketplace\.json$|^scripts/(install|install-hooks|sync-host|host-lib)\.sh$'

DIRS=()
for d in "$HOME"/.claude/projects/*/"$SESSION"/subagents; do [ -d "$d" ] && DIRS+=("$d"); done
ODIRS=()  # fix modes: subagent dirs of the old stamp's own session, where its runs= reports live (read_stamp)
SESS=()  # the session's own transcript: the only place a Waiver (#waive) is read from
for f in "$HOME"/.claude/projects/*/"$SESSION".jsonl; do [ -f "$f" ] && SESS+=("$f"); done

# find_runs <left40> <right40|*> <axes,csv> <dirs…> → `axis:agentId` lines, every matching run in sorted-path
# order (callers take the first per axis for runs=; the Open-finding check reads them all). A right of `*`
# accepts any RANGE right side and appends `:<right as written, lowercased>` to each line.
find_runs() {
  python3 -I - "$@" <<'PY'
import glob, json, os, re, sys

def find_runs(left, right, axes, dirs):
    rng = re.compile(r"^\s*RANGE:\s*([0-9a-fA-F]{7,40})\.\.([0-9a-fA-F]{7,40})(?![0-9a-fA-F])")
    axl = re.compile(r"^\s*AXIS:\s*(\S+)")
    for d in dirs:
        for meta_path in sorted(glob.glob(os.path.join(d, "**", "agent-*.meta.json"), recursive=True)):
            aid = os.path.basename(meta_path)[len("agent-"):-len(".meta.json")]
            try:
                with open(meta_path, encoding="utf-8") as f:
                    meta = json.load(f)
                if not isinstance(meta, dict):
                    continue
                if not re.match(r"^rumo:reviewer", str(meta.get("agentType", ""))):
                    continue
                if meta.get("finished") is not True:
                    continue
                with open(os.path.join(os.path.dirname(meta_path), f"agent-{aid}.jsonl"), encoding="utf-8") as f:
                    first = json.loads(f.readline())
            except (OSError, ValueError):
                continue
            if not isinstance(first, dict) or first.get("type") != "user":
                continue
            msg = first.get("message")
            if not isinstance(msg, dict) or msg.get("role", "user") != "user":
                continue
            content = msg.get("content")
            if isinstance(content, list):
                content = "\n".join(b.get("text", "") for b in content
                                    if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
            if not isinstance(content, str):
                continue
            lines = content.splitlines()
            hit = None
            for ln in lines:
                m = rng.match(ln)
                if m and left.startswith(m.group(1).lower()) and (right == "*" or right.startswith(m.group(2).lower())):
                    hit = m.group(2).lower()
                    break
            if hit is None:
                continue
            words = {m.group(1) for m in (axl.match(ln) for ln in lines) if m}
            for ax in axes:
                if ax in words:
                    print(f"{ax}:{aid}:{hit}" if right == "*" else f"{ax}:{aid}")

left, right, axes = sys.argv[1], sys.argv[2], [a for a in sys.argv[3].split(",") if a]
find_runs(left.lower(), right.lower(), axes, sys.argv[4:])
PY
}

# open_findings <sources_csv> <closers_csv> <dirs…> -- <session_jsonl…> → the Open findings, sorted and
# comma-joined on one line (empty when none), then a line `notime` when every open id has an entry with no
# readable time (no transcript, or no timestamp), which no closer or waiver can close. sources = `label:agentId,…` (every accepted reviewer run);
# closers = `agentId,…` (fix runs; may be empty). Exit 2 only on an internal error.
open_findings() {
  python3 -I - "$@" <<'PY'
import glob, json, os, re, sys
from datetime import datetime

FIND = re.compile(r"^\s*FINDINGS\b")
END = re.compile(r"^\s*(QUESTIONS|CHECKED AND SOUND|NOT CHECKED)\b")
# A numbered item: `1.`, `2)`, `**1.**`, `**1**.` — the id is the number; group 1 is its indent.
NUM = re.compile(r"^([ \t]*)[*_`]*(\d+)[*_`]*[.)][*_`]*\s*(.*)")
# The severity may sit in any bracket/bold/code decoration: `[major]`, `**[blocker]**`, `[**Major**]`.
SEV = re.compile(r"^[\s\[\]()*_`]*(blocker|major|minor)(?![A-Za-z])", re.I)
# Case-sensitive and anchored: `NOT RESOLVED …` never matches, and fix#<n> is never closed by a closer.
CLOSE = re.compile(r"^\s*(?:[-*]\s*)?(RESOLVED|WITHDRAWN)\s+((?:bugs|standards|spec|security)#\d+)\b")
IDS = r"(?:bugs|standards|spec|security|fix)#\d+|unreadable:[A-Za-z0-9_.-]+"
WAIVE = re.compile(r"#waive((?:[ \t,]+(?:" + IDS + r"))+)")
ID = re.compile(IDS)
# Machine-written user entries (pr-base-guard's SKIP, plus slash-command text) are never the user typing.
SKIP = ("<local-command", "<task-notification", "<system-reminder", "Caveat:", "[Request interrupted",
        "Stop hook feedback", "<bash-", "<user-prompt-submit-hook", "<command-")

def when(e):
    """The entry's timestamp as an aware datetime; None when absent or unreadable (it then closes nothing)."""
    t = e.get("timestamp")
    if not isinstance(t, str):
        return None
    try:
        d = datetime.fromisoformat(t[:-1] + "+00:00" if t.endswith("Z") else t)
    except ValueError:
        return None
    return d if d.tzinfo is not None else None

def text_of(content, skip=False):
    if isinstance(content, str):
        return "" if skip and content.lstrip().startswith(SKIP) else content
    if isinstance(content, list):
        return "\n".join(b["text"] for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)
                         and not (skip and b["text"].lstrip().startswith(SKIP)))
    return ""

def transcripts(aid, dirs):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", aid):
        return []  # not a plain agent id (e.g. a mangled runs= entry): no report → unreadable, fail closed
    out = []
    for d in dirs:
        out += glob.glob(os.path.join(glob.escape(d), "**", f"agent-{glob.escape(aid)}.jsonl"), recursive=True)
    return sorted(set(out))

def final_report(path):
    """(text, time) of the last assistant entry whose content yields non-empty text; with none,
    (None, time of the last timestamped entry)."""
    last, at, seen = None, None, None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(e, dict):
                    continue
                seen = when(e) or seen
                if e.get("type") != "assistant":
                    continue
                m = e.get("message")
                t = text_of(m.get("content")) if isinstance(m, dict) else ""
                if t.strip():
                    last, at = t, when(e)
    except OSError:
        return None, None
    return (last, at) if last is not None else (None, seen)

def reports(aid, dirs):
    return [final_report(p) for p in transcripts(aid, dirs)]

# Same reading as worktree-guard.py `_owner_typed`/`last_user_text` (hooks and scripts don't import each
# other), plus pr-base-guard's skip of entries carrying toolUseResult and of its SKIP prefixes.
def _owner_typed(e):
    o = e.get("origin")
    if isinstance(o, dict) and o.get("kind") != "human":
        return False
    if e.get("isCompactSummary") or e.get("isVisibleInTranscriptOnly"):
        return False
    c = (e.get("message") or {}).get("content")
    return not (isinstance(c, str) and c.lstrip().startswith("<task-notification>"))

def _unquoted(text):
    return text.split("AUTHORIZED:", 1)[0]

def user_texts(path):
    """(text, time) of each message the user typed, from the session's own transcript."""
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            m = e.get("message")
            if not isinstance(m, dict):
                continue
            if (e.get("type") == "user" and m.get("role") == "user" and not e.get("isMeta")
                    and e.get("toolUseResult") is None and _owner_typed(e)):
                yield _unquoted(text_of(m.get("content"), skip=True)), when(e)

args = sys.argv[1:]
sources = [x for x in args[0].split(",") if x]
closers = [x for x in args[1].split(",") if x]
rest = args[2:]
cut = rest.index("--") if "--" in rest else len(rest)
dirs, sessions = rest[:cut], rest[cut + 1:]

# Findings stay keyed per source report: (id, time that report finished).
found = []
for src in sources:
    label, _, aid = src.partition(":")
    reps = reports(aid, dirs)
    if not reps:
        found.append((f"unreadable:{aid}", None))
    for rep, at in reps:
        lines = (rep or "").splitlines()
        start = next((i for i, ln in enumerate(lines) if FIND.match(ln)), None)
        if start is None:
            found.append((f"unreadable:{aid}", at))
            continue
        top = None  # indent of the first numbered item; a deeper numbered line continues the previous item,
        # unless it starts with a severity: then it is a finding out of place, read as unreadable (fail closed)
        for ln in lines[start + 1:]:
            if END.match(ln):
                break
            m = NUM.match(ln)
            if not m:
                continue
            ind = len(m.group(1).expandtabs(4))
            if top is None:
                top = ind
            elif ind > top:
                if SEV.match(m.group(3)):
                    found.append((f"unreadable:{aid}", at))
                continue
            sev = SEV.match(m.group(3))
            if sev is None:
                found.append((f"unreadable:{aid}", at))  # a numbered finding whose severity can't be read
            elif sev.group(1).lower() in ("blocker", "major"):
                found.append((f"{label}#{int(m.group(2))}", at))

# Closures: (id, time). One closes a finding only when both times are readable and the finding's report
# finished before it, so a waiver or a RESOLVED line never reaches a later report's same id.
closures = []
for aid in closers:
    for rep, at in reports(aid, dirs):
        for ln in (rep or "").splitlines():
            m = CLOSE.match(ln)
            if m:
                closures.append((m.group(2), at))
for s in sessions:
    for t, at in user_texts(s):
        for m in WAIVE.finditer(t):
            closures += [(i.rstrip(".") if i.startswith("unreadable:") else i, at) for i in ID.findall(m.group(1))]

def closed(fid, fat):
    return fat is not None and any(cid == fid and cat is not None and fat < cat for cid, cat in closures)

left = [(fid, fat) for fid, fat in found if not closed(fid, fat)]
print(",".join(sorted({fid for fid, _ in left})))
# Line 2: `notime` when every open id has an entry with no time — nothing can ever close it (no waiver either).
untimed = {fid for fid, fat in left if fat is None}
if left and all(fid in untimed for fid, _ in left):
    print("notime")
PY
}

# check_open <refusal prefix> <sources_csv> <closers_csv> — dies (exit 1) while an Open finding remains; reports
# are looked up in DIRS and ODIRS (the old stamp's session); the session's waivers always count.
check_open() {
  local out open
  out=$(open_findings "$2" "$3" ${DIRS[@]+"${DIRS[@]}"} ${ODIRS[@]+"${ODIRS[@]}"} -- ${SESS[@]+"${SESS[@]}"}) \
    || die "failed to read the reviewers' reports" 2
  open=$(printf '%s\n' "$out" | sed -n 1p)
  [ -n "$open" ] || return 0
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = notime ] && die "${1}open finding $open — run the full review" 1
  die "${1}open finding $open — run a fix round with RESOLVED/WITHDRAWN <id>, or the user types #waive <id>" 1
}
csv() { awk 'NF' | paste -sd, -; }               # stdin lines → one comma-joined line
ids() { awk -F: 'NF>=2{print $2}' | csv; }        # `label:agentId` lines → `agentId,…`

# write_stamp <tier> <base> <reviewed> <mode> <axes> <runs> [<extra key=value>] — atomic write into the git dir.
write_stamp() {
  local extra=""
  [ $# -ge 7 ] && extra="$7"$'\n'
  TMP=$(mktemp "$GITDIR/rumo-review.ok.XXXXXX") || die "could not create the temp file in $GITDIR"
  trap 'rm -f "$TMP"' EXIT
  if ! printf '%s %s %s\nbase=%s\nreviewed=%s\nmode=%s\naxes=%s\nruns=%s\n%ssession=%s\n' \
         "$HEAD" "$1" "$(date -u +%FT%TZ)" "$2" "$3" "$4" "$5" "$6" "$extra" "$SESSION" > "$TMP" \
     || ! mv -f "$TMP" "$GITDIR/rumo-review.ok"; then
    die "failed to write the stamp in $GITDIR"
  fi
  trap - EXIT
  echo "STAMPED ${HEAD:0:7} $1 $4"
}

# read_stamp — the existing stamp: SF, OLD (full sha), OLDTIER (validated), OLDBASE, OLDREV, OLDBF
# (budget_from=), OLDBU (budget_used=), OLDRUNS (runs=), ODIRS (subagent dirs of its session=); dies exit 1.
read_stamp() {
  SF="$GITDIR/rumo-review.ok"
  OLD="" OLDTIER="" OLDBASE="" OLDREV="" OLDBF="" OLDBU="" OLDRUNS="" OLDSESS=""
  if [ -f "$SF" ]; then
    OLD=$(awk 'NR==1{print $1}' "$SF")
    OLDTIER=$(awk 'NR==1{print $2}' "$SF")
    OLDBASE=$(awk 'NR>1 && /^base=/{print substr($0,6); exit}' "$SF")
    OLDREV=$(awk 'NR>1 && /^reviewed=/{print substr($0,10); exit}' "$SF")
    OLDBF=$(awk 'NR>1 && /^budget_from=/{print substr($0,13); exit}' "$SF")
    OLDBU=$(awk 'NR>1 && /^budget_used=/{print substr($0,13); exit}' "$SF")
    OLDRUNS=$(awk 'NR>1 && /^runs=/{print substr($0,6); exit}' "$SF")
    OLDSESS=$(awk 'NR>1 && /^session=/{print substr($0,9); exit}' "$SF")
    # A later session re-reads runs= where they were written (a plain name only: it becomes a path).
    if [[ "$OLDSESS" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$OLDSESS" != . ] && [ "$OLDSESS" != .. ] && [ "$OLDSESS" != "$SESSION" ]; then
      for d in "$HOME"/.claude/projects/*/"$OLDSESS"/subagents; do [ -d "$d" ] && ODIRS+=("$d"); done
    fi
  fi
  [ -n "$OLD" ] || die "no stamp — run the full review" 1
  OLD=$(git rev-parse --verify -q "${OLD}^{commit}" 2>/dev/null) || die "stamp does not resolve to a commit — run the full review" 1
  case "$OLDTIER" in light|standard|sensitive) ;; *) die "invalid stamp tier: '$OLDTIER' — run the full review" 1 ;; esac
}

# inline_count <from> <to> — BIN (first binary path, or empty) and N (lines added+removed) of from..to.
inline_count() {
  local num
  # --no-renames: a move out of a sensitive dir lists both paths and counts both sides.
  num=$(git -c core.quotePath=false diff --no-renames --numstat "$1" "$2") || die "git diff failed"
  BIN=$(printf '%s\n' "$num" | awk -F'\t' '$1=="-"||$2=="-"{print $3; exit}')
  N=$(printf '%s\n' "$num" | awk -F'\t' 'NF>=3{s+=$1+$2} END{print s+0}')
}

# budget_start — from REVIEWED OLD OLDBF OLDBU: BF (where the inline-fix count starts) and BU (lines
# already spent before BF); a stamp without budget_from= → BF=REVIEWED, BU=0. Broken → BERR, return 1.
budget_start() {
  BF="$REVIEWED" BU=0 BERR=""
  [ -n "$OLDBF" ] || return 0
  BF=$(git rev-parse --verify -q "${OLDBF}^{commit}" 2>/dev/null) \
    || { BERR="budget_from= of the stamp does not resolve to a commit"; return 1; }
  # no leading zero: bash arithmetic would read it as octal
  [[ "$OLDBU" =~ ^(0|[1-9][0-9]*)$ ]] || { BERR="invalid budget_used= in the stamp"; return 1; }
  BU=$OLDBU
  git merge-base --is-ancestor "$REVIEWED" "$BF" && git merge-base --is-ancestor "$BF" "$OLD" \
    || { BERR="budget_from= of the stamp is outside reviewed=..stamp"; return 1; }
}

# resolve_up — the fork reference UP: origin/dev, else origin/HEAD; neither → exit 2 — origin/dev wins even for a branch cut from main (wontfix #23, see header).
resolve_up() {
  if git rev-parse --verify -q refs/remotes/origin/dev >/dev/null 2>&1; then
    UP=refs/remotes/origin/dev
  elif UP=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); then
    :
  elif git rev-parse --verify -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
    UP=refs/remotes/origin/HEAD
  else
    die "neither origin/dev nor origin/HEAD exists — cannot determine the fork point"
  fi
}

# refuse_transport <mode> <any> <hits> — <hits> = `git config --show-scope --get-regexp` lines; exits 1 naming
# "<scope> <key>" of the first line (any=1) or of the first whose value is not "true" (any=0). A bool value
# is one word, so it is the LAST whitespace field and the key is all before it (a URL subsection may hold
# spaces and tabs, never a newline); any other value may hold spaces, so that key ends at its first blank.
refuse_transport() {
  local hit
  hit=$(printf '%s\n' "$3" | awk -v any="$2" 'NF && (any || $NF != "true") {
    k = $0; sub(/^[^\t]*\t/, "", k)
    if (any) sub(/[ \t].*/, "", k); else sub(/[ \t]+[^ \t]*$/, "", k)
    print $1" "k; exit }')
  [ -z "$hit" ] || die "$1 refused: local transport config reroutes origin ($hit)" 1
}

# origin_guard <mode> — refuses (exit 1) git config that could reroute origin (list and wontfix #45: see header).
origin_guard() {
  local hits rc url
  hits=$(git config --show-scope --get-regexp '^(url\..+\.insteadof|core\.sshcommand|remote\.origin\.(uploadpack|vcs|proxy)|http\.(.+\.)?(proxy|sslcainfo|sslcapath|curloptresolve))$' 2>/dev/null); rc=$?
  [ $rc -le 1 ] || die "git config unreadable — cannot verify the origin"
  refuse_transport "$1" 1 "$hits"
  # sslVerify only disables TLS checks when git reads it as false (false/no/off/0/empty); true is git's default.
  # Every entry in every scope is checked, so one false refuses even if a later entry makes the effective value true.
  # Not a valid boolean → git exits 128 → refused (fail closed: the read above proved the config readable).
  hits=$(git config --show-scope --type=bool --get-regexp '^http\.(.+\.)?sslverify$' 2>/dev/null); rc=$?
  [ $rc -le 1 ] || die "$1 refused: http[.<url>].sslverify is not a valid boolean" 1
  refuse_transport "$1" 0 "$hits"
  url=$(git config --get-all remote.origin.url 2>/dev/null)
  [[ "$url" =~ ^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$ ]] \
    || die "$1 refused: remote.origin.url is not a github.com URL: ${url//$'\n'/ }" 1
}

# remote_tip <mode> — after origin_guard, RREF and RSHA = origin's own tip for UP (refs/heads/dev when UP is
# origin/dev, else HEAD) via git ls-remote; an unfetched tip is fetched (objects + FETCH_HEAD, no ref moves).
# No answer → exit 2 (offline); still missing → exit 1.
remote_tip() {
  local hint=""
  origin_guard "$1"
  [ "$1" = base-merge ] && hint=" and redo the merge"
  case "$UP" in refs/remotes/origin/dev) RREF=refs/heads/dev ;; *) RREF=HEAD ;; esac
  RSHA=$(GIT_TERMINAL_PROMPT=0 git ls-remote origin "$RREF" 2>/dev/null | awk -F'\t' -v r="$RREF" '$2==r{print $1; exit}')
  [ -n "$RSHA" ] || die "git ls-remote origin $RREF failed or returned empty — cannot verify the base"
  # A tip not fetched yet is fetched here: objects + FETCH_HEAD only (--refmap= moves no refs/remotes/*).
  git cat-file -e "${RSHA}^{commit}" 2>/dev/null \
    || { GIT_TERMINAL_PROMPT=0 git fetch -q --no-tags --refmap= origin "$RREF" >/dev/null 2>&1 \
         && git cat-file -e "${RSHA}^{commit}" 2>/dev/null; } \
    || die "$1 refused: origin has ${RSHA:0:7} at $RREF, missing here — run git fetch origin$hint" 1
}

# base_merge_check <S> <M> <UP> <SCAN> <RSHA> — exit 0 mechanical · 1 refused (one line) · 2 git error.
base_merge_check() {
  python3 -I - "$@" <<'BMPY'
import difflib, os, re, shutil, subprocess, sys, tempfile
S, M, UP, SCAN, RSHA = sys.argv[1:6]
PJ = ".claude-plugin/plugin.json"
VER = re.compile(rb'^(\s*"version"\s*:\s*")([^"]*)(")')
class Refuse(Exception): pass
def fail(what, r): print(f"git {what} falhou: {r.stderr.decode(errors='replace').strip()}"); sys.exit(2)
# Sterile repo: local, unreviewed state (config, info/attributes, global/system attributes, replace refs,
# grafts, GIT_* env) must not shape what the checker reads. Every git call below runs in a temporary bare
# repo that borrows the real objects through alternates; attributes come only from S's committed tree.
# Only the real objects dir and the remote tip's SHA are read from the real repo (a ref, not content).
def real(*a):
    r = subprocess.run(["git", *a], capture_output=True, env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
    if r.returncode != 0: fail(a[0], r)
    return r.stdout.decode().strip()
OBJ = real("rev-parse", "--path-format=absolute", "--git-path", "objects")
UPSHA = real("rev-parse", "--verify", "-q", f"{RSHA}^{{commit}}")  # the remote's own tip, not the local UP
FMT = real("rev-parse", "--show-object-format")
TMP = tempfile.mkdtemp(prefix="rumo-bm-")
ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
ENV.update(HOME=TMP, XDG_CONFIG_HOME=TMP, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_ATTR_NOSYSTEM="1", GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0")
GDIR = os.path.join(TMP, "r.git")
def git(*a, ok=(0,), inp=None, attr=None):  # attr: the tree-ish the command reads attributes from (S, or none)
    pre = ["-c", "core.attributesFile=" + os.devnull] + ([f"--attr-source={attr}"] if attr else [])
    r = subprocess.run(["git", *pre, *a], capture_output=True, input=inp, env=ENV)
    if r.returncode not in ok: fail(a[0], r)
    return r
def sterile():
    r = subprocess.run(["git", "init", "-q", "--bare", "--template=", f"--object-format={FMT}", GDIR], capture_output=True, env=ENV)
    if r.returncode != 0: fail("init", r)
    os.makedirs(os.path.join(GDIR, "objects", "info"), exist_ok=True)
    with open(os.path.join(GDIR, "objects", "info", "alternates"), "w") as f: f.write(OBJ + "\n")
    ENV["GIT_DIR"] = GDIR
def blob(rev, path):  # bytes, or None when the path is absent
    r = git("cat-file", "blob", f"{rev}:{path}", ok=(0, 128))
    return r.stdout if r.returncode == 0 else None
def lines(b): return (b or b"").splitlines(keepends=True)
def eof(ls): return ls[:-1] + [ls[-1] + b"\n"] if ls and not ls[-1].endswith(b"\n") else ls
def norm(ls): return [VER.sub(rb"\1<V>\3", l, count=1) for l in ls]
def version(b):  # the single "version" value as an int triple, else refuse 'without exactly one "version" line'
    vs = [m.group(2) for m in (VER.match(l) for l in lines(b)) if m]
    if len(vs) != 1 or not re.fullmatch(rb"\d+\.\d+\.\d+", vs[0]):
        raise Refuse(f'{PJ} without exactly one "version" line X.Y.Z')
    return tuple(int(x) for x in vs[0].split(b"."))
def changed(a, b):  # [(srcmode, dstmode, status, path)] of `git diff --raw` between two tree-ishes
    tok = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", a, b).stdout.split(b"\0")
    out = []
    for i in range(0, len(tok) - 1, 2):
        sm, dm, _, _, st = tok[i].decode()[1:].split(" ")
        out.append((sm, dm, st, tok[i + 1].decode("utf-8", "surrogateescape")))
    return out
def short(ref): return ref[len("refs/remotes/"):] if ref.startswith("refs/remotes/") else ref
def bump_ok(*ps):  # M's "version" is greater than S's and each parent in ps
    v = version(blob(M, PJ))
    if not all(v > version(blob(p, PJ)) for p in (S, *ps)):
        raise Refuse(f"the version in {PJ} is not greater than the parents'")
def version_only(c, a, b):  # entry c of changed(a, b) is PJ changing only its "version" value
    return c[3] == PJ and c[0] == c[1] and norm(lines(blob(a, PJ))) == norm(lines(blob(b, PJ)))
def only_version(a, b): return all(version_only(c, a, b) for c in changed(a, b))
def one_parent():
    ch = changed(S, M)
    if [c[3] for c in ch] != [PJ] or not version_only(ch[0], S, M):
        raise Refuse(f'the commit of a parent changes more than the "version" line of {PJ}')
    bump_ok()
def two_parents(P2):
    if git("merge-base", "--is-ancestor", P2, UPSHA, ok=(0, 1)).returncode != 0:
        raise Refuse(f"the second parent is not in {short(UP)}")
    # No user merge driver can run here (no config): a driver-made M differs from AUTO and is refused.
    tok = git("-c", "merge.conflictStyle=diff3", "merge-tree", "--write-tree", "-z", S, P2, ok=(0, 1), attr=S).stdout.split(b"\0")
    auto = tok[0].decode()
    stages = {}  # path → {stage: (mode, oid)}
    for t in tok[1:]:
        if not t: break
        meta, path = t.split(b"\t", 1)
        mode, oid, st = meta.decode().split(" ")
        stages.setdefault(path.decode("utf-8", "surrogateescape"), {})[st] = (mode, oid)
    # A merge attribute committed in S (e.g. `merge=union`) can auto-resolve a conflict, so a §0 path
    # refuses any conflict git raises with no attributes at all (attributes from the empty tree).
    EMPTY = git("mktree", inp=b"").stdout.decode().strip()
    for t in git("merge-tree", "--write-tree", "--name-only", "-z", S, P2, ok=(0, 1), attr=EMPTY).stdout.split(b"\0")[1:]:
        if not t: break
        path = t.decode("utf-8", "surrogateescape")
        if re.search(SCAN, path, re.I): raise Refuse(f"conflict in sensitive path {path}")
    # -s ours: the base brought clean (non-conflicted) changes and M kept none of them
    brought = [c for c in changed(S, auto) if c[3] not in stages and not version_only(c, S, auto)]
    if brought and only_version(S, M):
        raise Refuse("merge -s ours (discards what the base brought)")
    diff = {c[3]: c for c in changed(auto, M)}
    for p in sorted(set(diff) | set(stages)):
        if p in stages:
            conflict(p, stages[p], auto, diff.get(p), P2); continue
        sm, dm, _, _ = diff[p]
        if p != PJ or sm != dm or norm(lines(blob(auto, p))) != norm(lines(blob(M, p))):
            raise Refuse(f"{p} differs from the automatic merge")
        bump_ok(P2)
OPEN, BASE, SEP, CLOSE = (re.compile(x) for x in (rb"^<{7}( |\r?\n|$)", rb"^\|{7}( |\r?\n|$)", rb"^={7}(\r?\n|$)", rb"^>{7}( |\r?\n|$)"))
MARK = re.compile(b"|".join(r.pattern for r in (OPEN, BASE, SEP, CLOSE)))
def parse(a):  # diff3-style AUTO lines → [("c", line) | ("h", base, ours, theirs)]; malformed → None (caller refuses)
    segs, st, cur = [], 0, None
    want = {1: BASE, 2: SEP, 3: CLOSE}
    for l in a:
        if st == 0:
            if OPEN.match(l): st, cur = 1, ([], [], [])
            elif BASE.match(l) or SEP.match(l) or CLOSE.match(l): return None
            else: segs.append(("c", l))
        elif want[st].match(l):
            if st == 3: segs.append(("h",) + cur); st = 0
            else: st += 1
        elif OPEN.match(l) or BASE.match(l) or SEP.match(l) or CLOSE.match(l): return None
        else: cur[{1: 1, 2: 0, 3: 2}[st]].append(l)   # ours, base, theirs
    return segs if st == 0 else None
def units(B, O, T):  # split one conflict into stable base lines and change units (ours text, theirs text, who changed it)
    ch = []
    for who, X in (("o", O), ("t", T)):
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, B, X, autojunk=False).get_opcodes():
            if tag != "equal": ch.append((i1, i2, j1, j2, who))
    groups = []
    for c in sorted(ch, key=lambda c: (c[0], c[1])):
        if groups:
            g = groups[-1]
            if (c[0] < g[1] and g[0] < c[1]) or c[0] == c[1] == g[0] == g[1]:
                g[1] = max(g[1], c[1]); g[2].append(c); continue
        groups.append([c[0], c[1], [c]])
    def side(g, who, X):
        out, pos = [], g[0]
        for i1, i2, j1, j2, w in g[2]:
            if w == who: out += B[pos:i1] + X[j1:j2]; pos = i2
        return out + B[pos:g[1]]
    pieces, pos = [], 0
    for g in groups:
        pieces += [("s", l) for l in B[pos:g[0]]]
        pieces.append(("u", side(g, "o", O), side(g, "t", T), {c[4] for c in g[2]}))
        pos = g[1]
    return pieces + [("s", l) for l in B[pos:]]
def step(reach, m, opts):  # positions in m reachable by appending one of opts at a position in reach
    return {q + len(o) for q in reach for o in opts if m[q:q + len(o)] == o}
def unit_opts(pc):  # a unit only one side changed keeps exactly that side's text (any base text would revert
    o, t, who = pc[1], pc[2], pc[3]  # or re-add what it changed); a unit both sides changed takes any of the 4 forms
    if who == {"o"}: return [o]
    if who == {"t"}: return [t]
    return [o, t, o + t, t + o]
def resolved(a, m):  # m reproduces AUTO a, each git hunk taken whole (ours/theirs/ours+theirs/theirs+ours) or
    segs = parse(a)  # split into units, each kept as its changing side (both changed: any form); lines byte-identical
    if segs is None: return False
    reach = {0}
    for s in segs:
        if s[0] == "c": reach = step(reach, m, [[s[1]]])
        else:
            B, O, T = s[1], s[2], s[3]
            sub = reach
            for pc in units(B, O, T):
                sub = step(sub, m, [[pc[1]]] if pc[0] == "s" else unit_opts(pc))
                if not sub: break
            reach = step(reach, m, [O, T, O + T, T + O]) | sub
        if not reach: return False
    return len(m) in reach
def conflict(p, st, auto, d, P2):
    if re.search(SCAN, p, re.I): raise Refuse(f"conflict in sensitive path {p}")
    if "2" not in st or "3" not in st or any(st[k][0] not in ("100644", "100755") for k in ("2", "3")):
        raise Refuse(f"conflict without markers in {p}")
    if any(b"\0" in git("cat-file", "blob", st[k][1]).stdout for k in ("2", "3")):
        raise Refuse(f"binary conflict in {p}")
    attr = git("check-attr", "-z", "conflict-marker-size", "--", p, attr=S).stdout.split(b"\0")
    if len(attr) < 3 or attr[2] != b"unspecified": raise Refuse(f"conflict-marker-size in {p}")
    if not any(l.startswith(b"<<<<<<<") for l in lines(blob(auto, p))):
        raise Refuse(f"conflict without markers in {p}")
    if any(MARK.match(l) for k in ("2", "3") for l in lines(git("cat-file", "blob", st[k][1]).stdout)):
        raise Refuse(f"conflict in {p} with marker lines in the content")
    m = blob(M, p)
    if m is None or (d is not None and d[0] != d[1]): raise Refuse(f"{p} differs from the automatic merge")
    a, ml = lines(blob(auto, p)), lines(m)
    # `\ No newline at end of file`: git adds "\n" inside the markers, so when a side itself ends without
    # one, M may end without it too (a side that ends with "\n" licenses nothing).
    if any(b and not b.endswith(b"\n") for b in (git("cat-file", "blob", st[k][1]).stdout for k in ("2", "3"))):
        a, ml = eof(a), eof(ml)
    if resolved(a, ml): return
    if p == PJ and resolved(norm(a), norm(ml)): return bump_ok(P2)
    raise Refuse(f"conflict resolution in {p} outside ours/theirs/ours+theirs/theirs+ours")
def main():
    parents = [p.decode() for p in git("rev-list", "--parents", "-n", "1", M).stdout.split()[1:]]
    if not parents: raise Refuse("commit without a parent")
    if len(parents) >= 3: raise Refuse("octopus merge (3+ parents)")
    if parents[0] != S: raise Refuse("the first parent is not the sealed commit")
    if len(parents) == 1: return one_parent()
    return two_parents(parents[1])
try:
    sterile()
    main()
except Refuse as e:
    print(e); sys.exit(1)
finally:
    shutil.rmtree(TMP, ignore_errors=True)
BMPY
}

if [ $BM -eq 1 ]; then
  read_stamp
  [ "$OLD" != "$HEAD" ] || die "the stamp already covers HEAD (${HEAD:0:7})" 1
  resolve_up
  # UP is a local ref anyone can move (update-ref), so P2 is checked against the remote's own tip.
  remote_tip base-merge
  OUT=$(base_merge_check "$OLD" "$HEAD" "$UP" "$SCAN" "$RSHA" 2>&1); rc=$?
  [ $rc -eq 0 ] || { [ $rc -eq 1 ] && die "base-merge refused: $OUT" 1; die "$OUT" 2; }
  FORK=$(git merge-base HEAD "$RSHA" 2>/dev/null) || die "HEAD has no fork point with ${UP#refs/remotes/}"
  # reviewed=M only when S itself was reviewer-backed (reviewed= == S, or a legacy stamp without it);
  # otherwise carry S's reviewed= forward, so the inline-fix budget keeps counting from that review,
  # and record the budget already spent: the next inline-fix counts from M, so the base's lines are not
  # charged. Anything unreadable records budget_used=30 (exhausted: the next fix goes to a reviewer).
  NEWREV="$HEAD" EXTRA="base_merge_of=$OLD"
  if [ -n "$OLDREV" ]; then
    REVSHA=$(git rev-parse --verify -q "${OLDREV}^{commit}" 2>/dev/null) || REVSHA=""
    if [ "$REVSHA" != "$OLD" ]; then
      NEWREV="$OLDREV" USED=30
      if [ -n "$REVSHA" ]; then
        REVIEWED="$REVSHA"
        if budget_start; then
          inline_count "$BF" "$OLD"
          [ -n "$BIN" ] || USED=$((BU + N))
        fi
      fi
      EXTRA+=$'\n'"budget_from=$HEAD"$'\n'"budget_used=$USED"
    fi
  fi
  write_stamp "$OLDTIER" "$FORK" "$NEWREV" base-merge base-merge "" "$EXTRA"
  exit 0
fi

if [ $FIX -eq 1 ]; then
  read_stamp
  [ "$OLD" != "$HEAD" ] || die "the stamp already covers HEAD (${HEAD:0:7})" 1
  git merge-base --is-ancestor "$OLD" "$HEAD" || die "stamp is not an ancestor of HEAD (rebase?) — run the full review" 1
  if [ -n "$OLDBASE" ]; then
    OLDBASE=$(git rev-parse --verify -q "${OLDBASE}^{commit}" 2>/dev/null) || OLDBASE="$OLD"
  else
    OLDBASE="$OLD"
  fi

  # The old stamp's runs= are re-read as sources; its own fix runs keep closing what they closed.
  OLDFIX=$(printf '%s\n' "${OLDRUNS//,/$'\n'}" | awk -F: '$1=="fix"' | ids)

  if [ $INLINE -eq 1 ]; then
    # The budget runs from the last reviewer-backed HEAD, so chained inline-fixes accumulate.
    if [ -n "$OLDREV" ]; then
      REVIEWED=$(git rev-parse --verify -q "${OLDREV}^{commit}" 2>/dev/null) \
        || die "inline-fix refused: reviewed= of the stamp does not resolve to a commit — dispatch the fix axis" 1
      git merge-base --is-ancestor "$REVIEWED" "$OLD" \
        || die "inline-fix refused: reviewed= of the stamp is not an ancestor of the stamp — dispatch the fix axis" 1
    else
      REVIEWED="$OLD"
    fi
    # A base-merge stamp moved the count's start to its M (budget_from=) with what was spent before it.
    budget_start || die "inline-fix refused: $BERR — dispatch the fix axis" 1
    inline_count "$BF" "$HEAD"
    [ -z "$BIN" ] || die "inline-fix refused: binary file $BIN" 1
    N=$((BU + N))
    [ "$N" -lt 30 ] || die "inline-fix refused: $N lines since the last review (${REVIEWED:0:7}) (>= 30)" 1
    # Paths before BF were scanned by the inline-fixes that stamped them.
    NAMES=$(git -c core.quotePath=false diff --no-renames --name-only "$BF" "$HEAD") || die "git diff failed"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '%s\n' "$p" | grep -Eiq "$SCAN" || continue
      # A sensitive stamp is inline-fixed only while the fix itself stays off the scan: say what to run.
      [ "$OLDTIER" != sensitive ] || die "inline-fix refused: sensitive path $p — sensitive stamp: run the fix re-review (AXIS: fix, RANGE: $OLD..$HEAD)" 1
      die "inline-fix refused: sensitive path $p" 1
    done <<<"$NAMES"
    # An inline fix closes only minors: it adds no closer, so a blocker/major still open refuses. Fix runs
    # written after the stamp (RANGE OLD..X, X ancestor-or-equal of HEAD) are re-read too, in either session.
    LATE=$(find_runs "$OLD" '*' fix ${DIRS[@]+"${DIRS[@]}"} ${ODIRS[@]+"${ODIRS[@]}"}) || die "failed to read the transcripts" 2
    LATE=$(printf '%s\n' "$LATE" | while IFS=: read -r _ aid r; do
      [ -n "$aid" ] || continue
      c=$(git rev-parse --verify -q "${r}^{commit}" 2>/dev/null) || continue
      git merge-base --is-ancestor "$c" "$HEAD" && printf 'fix:%s\n' "$aid"
    done)
    check_open "inline-fix refused: " "$(printf '%s\n%s\n' "${OLDRUNS//,/$'\n'}" "$LATE" | csv)" \
      "$(printf '%s\n%s\n' "${OLDFIX//,/$'\n'}" "${LATE//fix:/}" | csv)"
    EXTRA="fix_of=$OLD"
    [ -z "$OLDBF" ] || EXTRA+=$'\n'"budget_from=$BF"$'\n'"budget_used=$BU"
    write_stamp "$OLDTIER" "$OLDBASE" "$REVIEWED" inline-fix inline-fix "" "$EXTRA"
    exit 0
  fi

  RUNS_OUT=$(find_runs "$OLD" "$HEAD" fix ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
  id=$(printf '%s\n' "$RUNS_OUT" | awk -F: '$1=="fix"{print $2; exit}')
  [ -n "$id" ] || die "no reviewer evidence for fix in RANGE ${OLD:0:7}..${HEAD:0:7} in this session" 1
  FIXIDS=$(printf '%s\n' "$RUNS_OUT" | ids)
  check_open "" "$(printf '%s\n%s\n' "${OLDRUNS//,/$'\n'}" "$RUNS_OUT" | csv)" "$(printf '%s\n%s\n' "${OLDFIX//,/$'\n'}" "${FIXIDS//,/$'\n'}" | csv)"
  write_stamp "$OLDTIER" "$OLDBASE" "$HEAD" fix fix "fix:$id" "fix_of=$OLD"
  exit 0
fi

case "$TIER" in
  light)              AXES="bugs" ;;
  standard)           AXES="bugs,standards,spec" ;;
  sensitive)          AXES="bugs,standards,spec,security" ;;
  "")                 die "--tier missing (light|standard|sensitive)" ;;
  *)                  die "invalid tier: $TIER (light|standard|sensitive)" ;;
esac
if [ $HAVE_AXES -eq 1 ]; then
  [ -n "$AXES_ARG" ] || die "--axes empty"
  IFS=',' read -r -a _ax <<<"$AXES_ARG"
  AXES=""
  for a in "${_ax[@]}"; do
    case "$a" in bugs|standards|spec|security) ;; *) die "invalid axis in --axes: '$a' (bugs,standards,spec,security)" ;; esac
    case ",$AXES," in *",$a,"*) ;; *) AXES="${AXES:+$AXES,}$a" ;; esac
  done
  if [ "$TIER" = sensitive ]; then
    case ",$AXES," in *",security,"*) ;; *) AXES="$AXES,security" ;; esac
  fi
fi

[ -n "$BASE_ARG" ] || die "--base missing"
BASE=$(git rev-parse --verify -q "${BASE_ARG}^{commit}" 2>/dev/null) || die "base does not resolve to a commit: $BASE_ARG"
[ "$BASE" != "$HEAD" ] || die "base == HEAD (${HEAD:0:7}): nothing to review"
git merge-base --is-ancestor "$BASE" "$HEAD" || die "base ${BASE:0:7} is not an ancestor of HEAD ${HEAD:0:7}"

# --base must cover the whole PR: ancestor-or-equal of the fork point with origin's own tip (dev, else HEAD).
resolve_up
remote_tip review
FORK=$(git merge-base HEAD "$RSHA" 2>/dev/null) || die "HEAD has no fork point with ${UP#refs/remotes/}"
hint=""
[ "$UP" = refs/remotes/origin/dev ] && hint=". Branch cut from main (hotfix)? Not supported (wontfix #23): a hotfix goes through dev like any PR — cut the branch from origin/dev and open the PR against dev."
git merge-base --is-ancestor "$BASE" "$FORK" \
  || die "--base ${BASE:0:7} does not cover the whole PR (fork point with ${UP#refs/remotes/} = ${FORK:0:7})$hint"

# The §0 path scan decides the floor: a sensitive path in BASE..HEAD admits only the sensitive tier.
if [ "$TIER" != sensitive ]; then
  NAMES=$(git -c core.quotePath=false diff --no-renames --name-only "$BASE" "$HEAD") || die "git diff failed"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$p" | grep -Eiq "$SCAN" && die "tier $TIER refused: sensitive path $p — use --tier sensitive" 1
  done <<<"$NAMES"
fi

IFS=',' read -r -a _req <<<"$AXES"
# first_runs <find_runs output> → RUNS (first run per required axis, `axis:id,…`) and MISSING (axes without one).
first_runs() {
  local a id
  RUNS="" MISSING=""
  for a in "${_req[@]}"; do
    id=$(printf '%s\n' "$1" | awk -F: -v a="$a" '$1==a{print $2; exit}')
    if [ -n "$id" ]; then RUNS="${RUNS:+$RUNS,}$a:$id"; else MISSING="${MISSING:+$MISSING,}$a"; fi
  done
}

# R = the HEAD the axes reviewed. R = HEAD, or the fix chain: the nearest R (strict ancestor of HEAD, strict
# descendant of BASE) where every axis has a run on BASE..R and a fix reviewer ran on R..HEAD.
R="$HEAD"
RUNS_OUT=$(find_runs "$BASE" "$HEAD" "$AXES" ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
RUNS_HEAD="$RUNS_OUT"  # axis runs on BASE..HEAD stay sources even when the fix chain picks R < HEAD
first_runs "$RUNS_OUT"
if [ -n "$MISSING" ]; then
  MISS0="$MISSING"
  CANDS=$(find_runs "$BASE" '*' "$AXES" ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
  ORDER=$(printf '%s\n' "$CANDS" | awk -F: 'NF>=3{print $3}' | sort -u | while IFS= read -r r; do
    c=$(git rev-parse --verify -q "${r}^{commit}" 2>/dev/null) || continue
    [ "$c" != "$HEAD" ] && [ "$c" != "$BASE" ] || continue
    git merge-base --is-ancestor "$c" "$HEAD" && git merge-base --is-ancestor "$BASE" "$c" || continue
    printf '%s %s\n' "$(git rev-list --count "$c..$HEAD")" "$c"
  done | sort -u | sort -n -k1,1 -k2,2 | awk '{print $2}')
  for c in $ORDER; do
    out=$(find_runs "$BASE" "$c" "$AXES" ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
    first_runs "$out"
    [ -z "$MISSING" ] || continue
    fx=$(find_runs "$c" "$HEAD" fix ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
    [ -n "$fx" ] || continue
    R="$c" RUNS_OUT="$out" FIXOUT="$fx"
    break
  done
  [ "$R" != "$HEAD" ] || die "no reviewer evidence for $MISS0 in RANGE ${BASE:0:7}..${HEAD:0:7} in this session" 1
  first_runs "$RUNS_OUT"
else
  # R = HEAD: a fix run on HEAD..HEAD (a replay-demoted major withdrawn with no code change) closes too.
  FIXOUT=$(find_runs "$HEAD" "$HEAD" fix ${DIRS[@]+"${DIRS[@]}"}) || die "failed to read the transcripts" 2
fi
# runs= names every closer, so --fix/--inline-fix re-read what closed each finding.
FIXIDS=$(printf '%s\n' "$FIXOUT" | awk -F: '$1=="fix" && !seen[$2]++ {print "fix:" $2}' | csv)
RUNS="$RUNS${FIXIDS:+,$FIXIDS}"

# Open findings: every axis run on BASE..HEAD and on BASE..R, and every fix run on R..HEAD, is a source; the
# fix runs close by RESOLVED/WITHDRAWN <id>, the user's #waive closes any.
check_open "" "$(printf '%s\n%s\n%s\n' "$RUNS_HEAD" "$RUNS_OUT" "$FIXOUT" | csv)" "$(printf '%s\n' "$FIXOUT" | ids)"

write_stamp "$TIER" "$BASE" "$HEAD" review "$AXES" "$RUNS"
