#!/usr/bin/env bash
# issue-criteria.sh - run an issue's machine-checkable criteria at a fixed commit,
# so the review's spec axis is checked against the issue, not only the plan.
#
# Usage: issue-criteria.sh [--trusted] <repo-or-worktree> <issue-body-file> [<sha>]
#   sha defaults to HEAD. Save the body first: gh issue view N --json body -q .body > file
#   Criteria lines: - [ ] [cmd] `<command>` → <expected>  ([x], "->"). Only the first code span runs.
#   Expected (one trailing "." dropped): none (exit 0) · exit N/sai [com] N · exit ≠ 0/falha · passa/ok
#   · vazio/empty/nada (no output, exit<=1) · [op]N, op in >= ≥ <= ≤ = > < (each line ends in an int
#   satisfying it, exit<=1; =0/<=0 also takes no output) · after an arrow: `literal`/word (exit 0 +
#   substring), phrase (substring, else MANUAL) · other prose: exit≠0 FAIL, else MANUAL. A further
#   span before an arrow, or `,` `;` e and ou or right before a backtick → several commands: MANUAL,
#   never run; a span after an empty/number expectation turns its pass into MANUAL. MANUAL never fails.
#   [judgment] and [visual] lines are listed, not run. Never calls gh or the network.
#   The Portuguese expectation words (sai, falha, passa/passam, vazio, nada, e, ou) match what the owner types in issues; they stay.
#   --trusted (any position) is REQUIRED to execute [cmd] lines: they run with bash -c, so
#   anyone who can edit the issue gets code execution. Pass it only after issue-trust.sh
#   exits 0 for this issue. Without it, commands are listed as NOT RUN.
#
# Exit codes:
#   0  no criterion failed (--trusted)
#   1  at least one [cmd] criterion failed (--trusted)
#   2  usage error, bad repo/sha, or zero criteria found
#   3  [cmd] criteria present but not run: body not marked --trusted
set -uo pipefail

TRUSTED=0; ARGS=()
for a in "$@"; do
  if [ "$a" = --trusted ]; then TRUSTED=1; else ARGS+=("$a"); fi
done
if [ ${#ARGS[@]} -lt 2 ] || [ ${#ARGS[@]} -gt 3 ]; then
  echo "usage: issue-criteria.sh [--trusted] <repo-or-worktree> <issue-body-file> [<sha>]" >&2
  exit 2
fi
REPO=${ARGS[0]}; BODY=${ARGS[1]}; SHA=${ARGS[2]:-HEAD}
[ -f "$BODY" ] || { echo "issue-criteria: body file not found: $BODY" >&2; exit 2; }
REPO=$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "issue-criteria: not a git repo: ${ARGS[0]}" >&2; exit 2; }
git -C "$REPO" rev-parse --verify --quiet "$SHA^{commit}" >/dev/null \
  || { echo "issue-criteria: unknown commit: $SHA" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SRC="$TMP/src"; mkdir "$SRC"
OUT="$TMP/out"

git -C "$REPO" archive "$SHA" | tar -x -C "$SRC" \
  || { echo "issue-criteria: export of $SHA failed" >&2; exit 2; }
for d in node_modules .venv; do
  if [ -e "$REPO/$d" ] && [ ! -e "$SRC/$d" ]; then ln -s "$REPO/$d" "$SRC/$d"; fi
done

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
trunc() { local s=${1//$'\n'/ }; [ ${#s} -gt 90 ] && s="${s:0:90}"; printf '%s' "$s"; }
manual() { MAN=$((MAN+1)); echo "MANUAL  $(trunc "$cmd")"; echo "    $1"; }

NCMD=0; PASS=0; FAIL=0; NJ=0; NV=0; NOTRUN=0; MAN=0
MULTI='(^|[,;]|[[:space:]](e|and|ou|or))[[:space:]]*`'
RE='^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+\[(cmd|judgment|visual)\][[:space:]]*(.*)$'

while IFS= read -r line || [ -n "$line" ]; do
  [[ $line =~ $RE ]] || continue
  kind=${BASH_REMATCH[1]}; rest=$(trim "${BASH_REMATCH[2]}")
  case $kind in
    judgment) NJ=$((NJ+1)); echo "SKIP(judgment)  $(trunc "$rest")"; continue ;;
    visual)   NV=$((NV+1)); echo "SKIP(visual)  $(trunc "$rest")"; continue ;;
  esac
  cmd=""; after=""; arrow=0
  if [[ $rest == \`* ]]; then
    r=${rest#\`}
    # cmd = text up to the FIRST closing backtick; nothing after it ever reaches bash -c.
    if [[ $r == *\`* ]]; then cmd=${r%%\`*}; after=${r#*\`}; else cmd=$r; fi
  elif [[ $rest == *' → '* ]]; then cmd=${rest%% → *}; after="→ ${rest#* → }"
  elif [[ $rest == *' -> '* ]]; then cmd=${rest%% -> *}; after="→ ${rest#* -> }"
  else cmd=$rest; fi
  cmd=$(trim "$cmd"); after=$(trim "$after")
  NCMD=$((NCMD+1))
  # Several commands: after the first span, a span later followed by an arrow, or a list connector
  # (, ; e and ou or) anywhere right before a backtick. Decided here, before the --trusted gate: a MANUAL line never runs.
  if [[ $after =~ \`[^\`]*\`.*(→|->) ]] || [[ $after =~ $MULTI ]]; then
    manual "several commands in one criterion — run by hand"; continue
  fi
  if [[ $after == '→'* ]]; then arrow=1; after=${after#'→'}
  elif [[ $after == '->'* ]]; then arrow=1; after=${after#'->'}; fi
  exp=$(trim "$after"); exp=${exp%.}
  # classify exp (first match wins) → ekind: exit | nonzero | empty | num | lit | phrase | prose
  ekind=""; en=0; eop="="; low=$(printf '%s' "$exp" | tr '[:upper:]' '[:lower:]')
  if [ -z "$exp" ]; then ekind="exit"
  elif [[ $low =~ ^(exit|exit[[:space:]]+code|sai|sai[[:space:]]+com)[[:space:]]+([0-9]+)$ ]]; then
    ekind="exit"; en=${BASH_REMATCH[2]}
  elif [[ $low =~ ^(exit|sai)[[:space:]]*(≠|!=)[[:space:]]*0$ || $low == nonzero || $low == falha ]]; then ekind=nonzero
  elif [[ $low == passa || $low == passam || $low == passes || $low == pass || $low == ok ]]; then ekind="exit"
  elif [ $arrow -eq 1 ] && [[ $exp == \`*\` && ${#exp} -ge 2 && ${exp:1:${#exp}-2} != *\`* ]]; then
    exp=${exp#\`}; exp=$(trim "${exp%\`}"); ekind=lit
  elif [[ $low == vazio* || $low == empty* || $low == nada* || $low == nothing* || $low == 'no output'* ]]; then ekind=empty
  elif [[ $exp =~ ^(≥|>=|≤|<=|==|=|>|<)?[[:space:]]*([0-9]+)([^0-9.]|$) ]] \
       && { [ -n "${BASH_REMATCH[1]}" ] || [ $arrow -eq 1 ]; }; then
    ekind=num; en=${BASH_REMATCH[2]}
    case ${BASH_REMATCH[1]} in '≥'|'>=') eop='>=' ;; '≤'|'<=') eop='<=' ;; '>') eop='>' ;; '<') eop='<' ;; *) eop='=' ;; esac
  elif [ $arrow -eq 0 ]; then ekind=prose; exp=$(trim "${exp#:}")
  elif [[ $exp != *[[:space:]]* ]]; then ekind=lit
  else ekind=phrase; fi
  if [ $TRUSTED -ne 1 ]; then
    NOTRUN=$((NOTRUN+1)); echo "NOT RUN  $(trunc "$cmd")"; continue
  fi
  (cd "$SRC" && perl -e 'alarm shift; exec @ARGV' 300 bash -c "$cmd") >"$OUT" 2>&1 </dev/null; rc=$?
  ok=0
  case $ekind in
    exit)    [ $rc -eq "$en" ] && ok=1 ;;
    nonzero) [ $rc -ne 0 ] && ok=1 ;;
    empty)   [ $rc -le 1 ] && [ ! -s "$OUT" ] && ok=1 ;;
    num)     [ $rc -le 1 ] && awk -v op="$eop" -v n="$en" '
               /^[[:space:]]*$/ { next }
               { c++; if (!match($0, /[0-9]+[[:space:]]*$/)) { bad=1; exit }
                 v = substr($0, RSTART, RLENGTH) + 0
                 if (op == ">=") g = v >= n; else if (op == "<=") g = v <= n
                 else if (op == ">") g = v > n; else if (op == "<") g = v < n; else g = v == n
                 if (!g) { bad=1; exit } }
               END { exit (bad || c == 0) }' "$OUT" && ok=1
             # → 0 with no output: exit 0 passes; exit 1 can't tell "no match" from a failed test.
             if [ $ok -eq 0 ] && [ ! -s "$OUT" ] && [ "$en" -eq 0 ] && [[ $eop == '=' || $eop == '<=' ]]; then
               [ $rc -eq 0 ] && ok=1
               [ $rc -eq 1 ] && { manual "no output, exit 1; check by hand"; continue; }
             fi ;;
    lit)     [ $rc -eq 0 ] && [[ $(cat "$OUT") == *"$exp"* ]] && ok=1 ;;
    phrase|prose)
      if [ $rc -eq 0 ]; then
        if [ "$ekind" = phrase ] && [[ $(cat "$OUT") == *"$exp"* ]]; then ok=1
        else manual "exit 0; check by hand: $(trunc "$exp")"; continue; fi
      fi ;;
  esac
  # exit/empty/num checks ignore trailing text: a span left there may be an unrun second command,
  # so a pass there is only MANUAL (a fail stays a FAIL).
  if [ $ok -eq 1 ] && [[ $ekind == empty || $ekind == num ]] && [[ $exp == *\`* ]]; then
    manual "passed, but a code span after the expectation was not checked; check by hand"; continue
  fi
  if [ $ok -eq 1 ]; then
    PASS=$((PASS+1)); echo "PASS  $(trunc "$cmd")"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $(trunc "$cmd")"
    [ $rc -ne 0 ] && echo "    (exit $rc)"
    tail -n 5 "$OUT" | sed 's/^/    /'
  fi
done < "$BODY"

if [ $((NCMD+NJ+NV)) -eq 0 ]; then
  echo "no criteria found — is this a rumo ticket?"
  exit 2
fi
if [ $NOTRUN -gt 0 ]; then
  echo "criteria: $NCMD cmd ($NOTRUN not run), $NJ judgment, $NV visual"
  echo "not run: issue body not marked trusted — check its author/editors (issue-trust.sh) and re-run with --trusted"
  exit 3
fi
MANS=""; [ $MAN -gt 0 ] && MANS=", $MAN manual"
echo "criteria: $NCMD cmd ($PASS pass, $FAIL fail$MANS), $NJ judgment, $NV visual"
[ "$FAIL" -eq 0 ]
