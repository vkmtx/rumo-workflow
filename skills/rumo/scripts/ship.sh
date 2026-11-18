#!/usr/bin/env bash
# ship.sh — the end of a build in one call (build.md §8): preflight, push, PR, follow-up, checks,
# merge, cleanup. One line per step: `SHIP <step> ok|fail|skip — <detail>`; the first fail stops
# (exit 1). Last line `SHIP DONE pr=<url> merged=yes|no`. It never merges the base itself and
# never forces a worktree removal.
# Merge only into `dev`; any other base leaves the PR open (merge skip). --merge-default-branch lets it
# merge into the remote's default branch, and only when origin has no `dev` branch.
# A reused open PR must be same-repo, on the pushed HEAD and on --base; the merge pins that HEAD.
# Cleanup keeps the worktree while it holds an ignored .env* the main checkout lacks (or differs on);
# --slot-env <file> names the slot file this build wrote (§3.1), deleted after the merge so it never blocks.
#
# Usage: ship.sh <worktree> --base <base> --issue <N> --title "<PR title>" --body-file <file>
#                [--followup-file <file>] [--slot-env <file>] [--no-merge] [--merge-default-branch] [--dry-run]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUMO="$(cd "$HERE/../../.." && pwd)"

say()  { printf 'SHIP %s %s — %s\n' "$1" "$2" "$3"; }
die()  { say "$1" fail "$2"; exit 1; }
usage() {
  echo 'usage: ship.sh <worktree> --base <base> --issue <N> --title "<PR title>" --body-file <file> [--followup-file <file>] [--slot-env <file>] [--no-merge] [--merge-default-branch] [--dry-run]' >&2
  exit 2
}

WT=""; BASE=""; ISSUE=""; TITLE=""; BODY=""; FOLLOW=""; SLOT=""; NOMERGE=0; MERGEDEF=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)          [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --issue)         [ $# -ge 2 ] || usage; ISSUE="$2"; shift 2 ;;
    --title)         [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
    --body-file)     [ $# -ge 2 ] || usage; BODY="$2"; shift 2 ;;
    --followup-file) [ $# -ge 2 ] || usage; FOLLOW="$2"; shift 2 ;;
    --slot-env)      [ $# -ge 2 ] || usage; SLOT="$2"; shift 2 ;;
    --no-merge)      NOMERGE=1; shift ;;
    --merge-default-branch) MERGEDEF=1; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       usage ;;
    -*)              echo "ship.sh: unknown option $1" >&2; usage ;;
    *)               [ -z "$WT" ] || usage; WT="$1"; shift ;;
  esac
done
[ -n "$WT" ] && [ -n "$BASE" ] && [ -n "$ISSUE" ] && [ -n "$TITLE" ] && [ -n "$BODY" ] || usage
[ -d "$WT" ] || die preflight "worktree $WT is not a directory"
WT="$(cd "$WT" && pwd -P)"
# the slot file: a path relative to the worktree, no .. part, named .env*
if [ -n "$SLOT" ]; then
  case "/$SLOT/" in /\/*|*/../*) die preflight "--slot-env $SLOT must be a path inside the worktree" ;; esac
  case "$(basename "$SLOT")" in .env*) ;; *) die preflight "--slot-env $SLOT is not an env file (.env*)" ;; esac
fi
# gh reads the repo from its cwd: every gh call runs inside the worktree, whatever the caller's cwd
gh() { (cd "$WT" && command gh "$@"); }
[ -f "$BODY" ] || die preflight "body file $BODY not found"
if [ -n "$FOLLOW" ] && [ ! -f "$FOLLOW" ]; then die preflight "follow-up file $FOLLOW not found"; fi
case "$BODY" in /*) ;; *) BODY="$(pwd -P)/$BODY" ;; esac
if [ -n "$FOLLOW" ]; then case "$FOLLOW" in /*) ;; *) FOLLOW="$(pwd -P)/$FOLLOW" ;; esac; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. preflight -------------------------------------------------------------------------
MERGE_OK=1; MERGE_WHY=""
dirty="$(git -C "$WT" status --porcelain -- . ':!.rumo' 2>&1)" || die preflight "git status failed: $dirty"
[ -z "$dirty" ] || die preflight "worktree is not clean ($(printf '%s\n' "$dirty" | head -1))"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || die preflight "no HEAD in $WT"
GITDIR="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || die preflight "not a git worktree: $WT"
STAMP="$GITDIR/rumo-review.ok"
[ -f "$STAMP" ] || die preflight "stamp does not cover HEAD — finish the review (no $STAMP)"
stamped="$(head -1 "$STAMP" 2>/dev/null | awk '{print $1}')" || stamped=""
[ "$stamped" = "$HEAD_SHA" ] || die preflight "stamp does not cover HEAD — finish the review (stamp ${stamped:-empty}, HEAD $HEAD_SHA)"

MANDATO="$RUMO/scripts/hooks-staged/mandato.py"
detail="clean, stamp covers ${HEAD_SHA:0:8}"
if [ -f "$MANDATO" ]; then
  mout="$(python3 -I "$MANDATO" check "$WT" 2>&1)"; mrc=$?
  mline="$(printf '%s\n' "$mout" | tail -1)"
  case "$mrc" in
    0)
      case "$mline" in
        *"issue=$ISSUE"|*"issue=$ISSUE "*) ;;
        *issue=*) die preflight "mandato scope: $mline names another issue than #$ISSUE" ;;
      esac
      case "$mline" in
        *alcance=pr*) MERGE_OK=0; MERGE_WHY="Mandato alcance=pr" ;;
      esac
      detail="$detail; $mline" ;;
    3) ;;
    *) die preflight "${mline:-mandato check exited $mrc}" ;;
  esac
fi
say preflight ok "$detail"

# ---- 2. push ------------------------------------------------------------------------------
BRANCH="$(git -C "$WT" symbolic-ref --short -q HEAD 2>/dev/null)" || BRANCH=""
[ -n "$BRANCH" ] || die push "detached HEAD — no branch to push"
case "$BRANCH" in
  dev|main|master) die push "refusing to push $BRANCH — ship from a feat/ or fix/ branch" ;;
esac
if [ "$DRY" -eq 1 ]; then
  say push skip "DRY-RUN git -C $WT push -u origin $BRANCH"
else
  pout="$(git -C "$WT" push -u origin "$BRANCH" 2>&1)" || die push "git push failed: $(printf '%s\n' "$pout" | tail -1)"
  say push ok "$BRANCH -> origin"
fi

# ---- 3. pr --------------------------------------------------------------------------------
PR=""; URL=""
if [ "$DRY" -eq 1 ]; then
  say pr skip "DRY-RUN gh pr create --base $BASE --head $BRANCH --title \"$TITLE\" --body-file $BODY (an open PR for the branch is reused)"
  URL="<dry-run>"; PR="<PR>"
else
  # reuse only a same-repo PR on the pushed HEAD and on $BASE; a fork's PR with the same branch name is skipped; any other open PR on the branch is a stop
  lout="$(gh pr list --head "$BRANCH" --state open --json number,url,headRefOid,baseRefName,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.url)\t\(.headRefOid)\t\(.baseRefName)\t\(.isCrossRepository)"' 2>&1)" \
    || die pr "gh pr list failed: $(printf '%s\n' "$lout" | tail -1)"
  other=""
  while IFS=$'\t' read -r n u h b x; do
    [ -n "$n" ] || continue
    [ "$x" = true ] && continue
    if [ "$x" = false ] && [ "$h" = "$HEAD_SHA" ] && [ "$b" = "$BASE" ]; then
      [ -n "$PR" ] || { PR="$n"; URL="$u"; }
    else
      [ -n "$other" ] || other="$n"
    fi
  done <<< "$lout"
  if [ -n "$PR" ]; then
    say pr ok "reused open PR #$PR $URL"
  elif [ -n "$other" ]; then
    die pr "open PR #$other on $BRANCH does not match (head/base) — resolve by hand"
  else
    cout="$(gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$BODY" 2>&1)" \
      || die pr "gh pr create failed: $(printf '%s\n' "$cout" | tail -1)"
    URL="$(printf '%s\n' "$cout" | grep -Eo 'https?://[^ ]+' | tail -1)" || URL=""
    [ -n "$URL" ] || die pr "gh pr create printed no URL: $(printf '%s\n' "$cout" | tail -1)"
    PR="${URL##*/}"
    say pr ok "created #$PR $URL"
  fi
  case "$PR" in ''|*[!0-9]*) die pr "could not read the PR number from '$URL'" ;; esac
fi

# ---- 4. followup --------------------------------------------------------------------------
if [ -n "$FOLLOW" ]; then
  if [ "$DRY" -eq 1 ]; then
    say followup skip "DRY-RUN gh issue create --title \"Follow-up #$PR: $TITLE\" --body-file $FOLLOW; then append 'Follow-up: #<issue>' to the live PR body (gh pr edit)"
  else
    live="$(gh pr view "$PR" --json body --jq .body 2>&1)" || die followup "gh pr view failed: $(printf '%s\n' "$live" | tail -1)"
    if printf '%s\n' "$live" | grep -Eq '^Follow-up: #'; then
      say followup skip "PR body already holds a Follow-up line"
    else
      iout="$(gh issue create --title "Follow-up #$PR: $TITLE" --body-file "$FOLLOW" 2>&1)" \
        || die followup "gh issue create failed: $(printf '%s\n' "$iout" | tail -1)"
      iurl="$(printf '%s\n' "$iout" | grep -Eo 'https?://[^ ]+' | tail -1)" || iurl=""
      INUM="${iurl##*/}"
      case "$INUM" in ''|*[!0-9]*) die followup "could not read the issue number from: $(printf '%s\n' "$iout" | tail -1)" ;; esac
      # re-read the live body right before editing: gh pr edit replaces the whole body
      live="$(gh pr view "$PR" --json body --jq .body 2>&1)" || die followup "gh pr view failed (issue #$INUM was created): $(printf '%s\n' "$live" | tail -1)"
      printf '%s\n\nFollow-up: #%s\n' "$live" "$INUM" > "$TMP/body.md"
      eout="$(gh pr edit "$PR" --body-file "$TMP/body.md" 2>&1)" \
        || die followup "gh pr edit failed (issue #$INUM was created): $(printf '%s\n' "$eout" | tail -1)"
      say followup ok "issue #$INUM, PR body now ends with Follow-up: #$INUM"
    fi
  fi
fi

# ---- 5. checks ----------------------------------------------------------------------------
if [ "$DRY" -eq 1 ]; then
  say checks skip "DRY-RUN gh pr checks $PR --watch --fail-fast"
else
  kout="$(gh pr checks "$PR" --watch --fail-fast 2>&1)"; krc=$?
  if [ "$krc" -eq 0 ]; then
    say checks ok "all checks passed"
  elif printf '%s\n' "$kout" | grep -qi 'no checks reported'; then
    say checks ok "no checks reported — counts as green"
  else
    names="$(printf '%s\n' "$kout" | awk -F'\t' 'tolower($2)=="fail"||tolower($2)=="failure"{print $1}' | paste -sd, - 2>/dev/null)" || names=""
    [ -n "$names" ] || names="$(printf '%s\n' "$kout" | tail -1)"
    die checks "failing: $names (hand the run id to rumo:extractor)"
  fi
fi

# ---- 6. merge -----------------------------------------------------------------------------
MERGED=no
skipwhy=""
if [ "$NOMERGE" -eq 1 ]; then
  skipwhy="--no-merge"
elif [ "$MERGE_OK" -eq 0 ]; then
  skipwhy="$MERGE_WHY — stop before the merge"
elif [ "$BASE" != dev ]; then
  skipwhy="base $BASE is not dev"
  if [ "$MERGEDEF" -eq 1 ]; then
    if [ "$DRY" -eq 1 ]; then
      skipwhy="$skipwhy; DRY-RUN --merge-default-branch merges only if $BASE is the default branch (gh repo view) and origin has no dev"
    else
      defb="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" || defb=""
      if [ -z "$defb" ]; then
        skipwhy="$skipwhy; --merge-default-branch ignored — could not read the default branch (gh repo view)"
      elif [ "$defb" != "$BASE" ]; then
        skipwhy="$skipwhy; --merge-default-branch ignored — the default branch is $defb"
      elif git -C "$WT" ls-remote --exit-code --heads origin dev >/dev/null 2>&1; then
        skipwhy="$skipwhy; --merge-default-branch ignored — origin has a dev branch"
      else
        skipwhy=""
      fi
    fi
  fi
fi
if [ -n "$skipwhy" ]; then
  say merge skip "$skipwhy"
elif [ "$DRY" -eq 1 ]; then
  say merge skip "DRY-RUN git -C $WT fetch origin $BASE; gh pr merge $PR --merge --match-head-commit $HEAD_SHA"
else
  fout="$(git -C "$WT" fetch origin "$BASE" 2>&1)" || die merge "git fetch origin $BASE failed: $(printf '%s\n' "$fout" | tail -1)"
  if ! git -C "$WT" merge-base --is-ancestor "origin/$BASE" HEAD 2>/dev/null; then
    die merge "BASE MOVED: run wave.md §Merging (merge origin/$BASE, bump, suite, review-stamp.sh --base-merge, push), then rerun ship.sh"
  fi
  mout="$(gh pr merge "$PR" --merge --match-head-commit "$HEAD_SHA" 2>&1)" || die merge "gh pr merge failed: $(printf '%s\n' "$mout" | tail -1)"
  state="$(gh pr view "$PR" --json state -q .state 2>/dev/null)" || state=""
  [ "$state" = "MERGED" ] || die merge "PR #$PR state is '${state:-unknown}', not MERGED"
  MERGED=yes
  say merge ok "PR #$PR merged"
fi

# ---- 7. cleanup ---------------------------------------------------------------------------
if [ "$MERGED" = yes ]; then
  MAIN="$(git -C "$WT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || MAIN=""
  [ -n "$MAIN" ] && [ -d "$MAIN" ] || die cleanup "cannot find the main checkout (git worktree list)"
  REPO="$(basename "$MAIN")"
  PLAN="$HOME/.claude/learn/plans/$REPO-$(basename "$WT").md"
  if [ -n "$SLOT" ] && [ "$MAIN" != "$WT" ] && [ -f "$WT/$SLOT" ]; then
    sdir="$(cd "$(dirname "$WT/$SLOT")" 2>/dev/null && pwd -P)" || sdir=""
    case "$sdir/" in
      "$WT"/*)
        if git -C "$WT" ls-files --error-unmatch -- "$SLOT" >/dev/null 2>&1; then
          say cleanup note "--slot-env $SLOT is tracked — left in place"
        else rm -f "$WT/$SLOT"; fi ;;
      *) say cleanup note "--slot-env $SLOT resolves outside the worktree — left in place" ;;
    esac
  fi
  # an ignored .env* dies with the worktree: keep it unless each is a byte copy in the main checkout (wt-gc.sh)
  lost=""
  if [ "$MAIN" != "$WT" ]; then
    while IFS= read -r -d '' rel; do
      case "/$rel" in */node_modules/*) continue ;; esac
      { [ -f "$MAIN/$rel" ] && cmp -s "$WT/$rel" "$MAIN/$rel"; } || lost="$lost${lost:+, }$rel"
    done < <(git -C "$WT" ls-files -z --others --ignored --exclude-standard -- ':(glob)**/.env*' 2>/dev/null)
  fi
  if [ "$MAIN" = "$WT" ]; then
    say cleanup skip "$WT is the main checkout — nothing to remove"
  elif [ -n "$lost" ]; then
    pout="$(git -C "$MAIN" fetch --prune 2>&1)" || die cleanup "git fetch --prune failed: $(printf '%s\n' "$pout" | tail -1)"
    say cleanup skip "env file(s) only in the worktree: $lost; run wt-gc.sh --apply --with-env"
  else
    rout="$(git -C "$MAIN" worktree remove "$WT" 2>&1)" || die cleanup "git worktree remove refused (never forced): $(printf '%s\n' "$rout" | tail -2 | paste -sd' ' -)"
    bout="$(git -C "$MAIN" branch -d "$BRANCH" 2>&1)" || die cleanup "git branch -d $BRANCH failed: $(printf '%s\n' "$bout" | tail -1)"
    pout="$(git -C "$MAIN" fetch --prune 2>&1)" || die cleanup "git fetch --prune failed: $(printf '%s\n' "$pout" | tail -1)"
    if [ -f "$PLAN" ]; then rm -f "$PLAN" && pdet="plan copy removed" || pdet="plan copy NOT removed"; else pdet="no plan copy"; fi
    say cleanup ok "worktree and branch $BRANCH removed, pruned; $pdet"
  fi
fi

printf 'SHIP DONE pr=%s merged=%s\n' "$URL" "$MERGED"
exit 0
