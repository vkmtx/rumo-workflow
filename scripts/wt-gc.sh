#!/usr/bin/env bash
# wt-gc — list (and with --apply, remove) git worktrees left behind by /rumo build.
# Usage: wt-gc.sh [--apply [--with-env]] [--days N] [repo-path ...]   (default: every repo in ~/orca/projects)
#   MERGED  branch merged into origin/<base> (dev, else origin/HEAD) or its PR is MERGED (gh)
#   GONE    upstream branch deleted on the remote
#   STALE   no commit in N days (default 14) and no open PR — listed only, never removed
#   DIRTY   uncommitted changes — listed only, never removed
#   ENV     would be MERGED/GONE but holds an ignored .env* not byte-identical to the main checkout's
#           — listed only; removed with --apply --with-env (prints "env lost: <paths>")
#   AUTO    an Orca automation worktree (…/ops, …/automacoes, …/auto-*) — never removed
# --apply removes only clean MERGED/GONE worktrees: `git worktree remove` (no --force) + `git branch -d`,
#   plus, for MERGED only, the plan copy ${RUMO_PLANS_DIR:-~/.claude/learn/plans}/<repo>-<worktree-dir>.md
#   when its "Branch / worktree" line names that worktree. A branch with no commit yet (reflog: only
#   created/renamed) is ACTIVE, never MERGED.
#   PLAN    a plan copy whose "Branch / worktree" path no longer exists — removed by --apply only
#           when its "Issue" URL is CLOSED (gh); no gh / no Issue / open → kept
# Exit 0 · 2 usage. Prints one row per worktree with its size.
set -uo pipefail
apply=0; with_env=0; days=14; repos=()
plans=${RUMO_PLANS_DIR:-$HOME/.claude/learn/plans}
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --with-env) with_env=1 ;;
    --days) [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--days needs a whole number"; exit 2; }; days="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) repos+=("$1") ;;
  esac; shift
done
[ ${#repos[@]} -eq 0 ] && for d in "$HOME"/orca/projects/*/; do [ -d "$d/.git" ] && repos+=("${d%/}"); done
have_gh=0; command -v gh >/dev/null && have_gh=1
now=$(date +%s)
printf '%-8s %-7s %-40s %s\n' STATE SIZE BRANCH PATH
for repo in "${repos[@]}"; do
  base=origin/dev; git -C "$repo" rev-parse -q --verify "$base" >/dev/null || base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD || echo "")
  main=$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n "1s/^worktree //p"); [ -n "$main" ] || continue   # the main checkout, even when a linked worktree was passed
  git -C "$repo" worktree prune
  git -C "$repo" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8)} /^detached/{b="(detached)"} /^$/{if(p!="")print p"\t"b; p="";b=""} END{if(p!="")print p"\t"b}' |
  while IFS=$'\t' read -r path ref; do
    [ "$path" = "$main" ] && continue
    branch=${ref#refs/heads/}; state=STALE
    case "$path" in */ops|*/automacoes|*/auto-*) state=AUTO ;; esac
    # Just created (no commit yet) and merged look the same in the graph. The reflog tells them apart:
    # entries but none that made a commit on it (creation, rename, fast-forward, reset don't count)
    # = fresh. With no reflog (disabled/expired), fall back to the worktree's age.
    moves=9; work=1
    if [ "$branch" != "(detached)" ]; then
      subjects=$(git -C "$repo" reflog show --format=%gs "refs/heads/$branch" 2>/dev/null)
      moves=$(printf '%s' "$subjects" | grep -c '^' | tr -d ' ')
      work=$(printf '%s\n' "$subjects" | grep -ciE '^(commit|cherry-pick)' | tr -d ' ')
    fi
    age_days=$(( (now - $(stat -f %m "$path/.git" 2>/dev/null || echo "$now")) / 86400 ))
    fresh=0; { { [ "$moves" != 0 ] && [ "$work" = 0 ]; } || { [ "$moves" = 0 ] && [ "$age_days" -lt "$days" ]; }; } && fresh=1
    if [ "$state" = AUTO ]; then :
    elif [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then state=DIRTY
    elif [ $fresh = 1 ]; then state=ACTIVE
    elif [ "$branch" = "(detached)" ]; then state=DETACHED
    elif [ -n "$base" ] && git -C "$repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then state=MERGED
    elif git -C "$repo" for-each-ref --format='%(upstream:track)' "refs/heads/$branch" | grep -q gone; then state=GONE
    elif [ $have_gh = 1 ] && [ -n "$(cd "$repo" && gh pr list --head "$branch" --state merged --json headRefOid --jq ".[] | select(.headRefOid == \"$(git -C "$repo" rev-parse "$branch")\") | .headRefOid" 2>/dev/null)" ]; then state=MERGED   # the merged PR's head is this exact commit (a reused branch name isn't)
    else
      last=$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo "$now")
      open=0; [ $have_gh = 1 ] && open=$(cd "$repo" && gh pr list --head "$branch" --state open --json number --jq length 2>/dev/null || echo 0)
      if [ "${open:-0}" != "0" ] || [ $(( (now - last) / 86400 )) -lt "$days" ]; then state=ACTIVE; fi
    fi
    # an ignored .env* dies with the worktree: one that isn't a byte copy of the main checkout's keeps it (ENV)
    base_state=$state; lost=""
    if [ "$state" = MERGED ] || [ "$state" = GONE ]; then
      # every ignored .env* file, also inside ignored dirs (.vercel/.env.production.local)
      while IFS= read -r -d '' rel; do
        case "/$rel" in */node_modules/*) continue ;; esac
        { [ -f "$main/$rel" ] && cmp -s "$path/$rel" "$main/$rel"; } || lost="$lost $rel"
      done < <(git -C "$path" ls-files -z --others --ignored --exclude-standard -- ':(glob)**/.env*' 2>/dev/null)
      [ -n "$lost" ] && state=ENV
    fi
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    printf '%-8s %-7s %-40s %s\n' "$state" "$size" "$branch" "$path"
    if [ $apply = 1 ] && { [ "$state" = MERGED ] || [ "$state" = GONE ] || { [ "$state" = ENV ] && [ $with_env = 1 ]; }; }; then
      [ "$state" = ENV ] && echo "  env lost:$lost"
      # the plan copy goes only with a MERGED worktree (a GONE one may hold unmerged work) and only when
      # it names this worktree's path; anything else is left to the orphan-plan pass below
      plan="$plans/$(basename "$main")-$(basename "$path").md"; drop_plan=0
      if [ "$base_state" = MERGED ] && [ -f "$plan" ]; then
        named=$(grep -m1 -E '^- \*\*Branch / worktree\*\*:.* at `[^`]+`' "$plan" | sed -E 's/.* at `([^`]+)`.*/\1/')
        [ -n "$named" ] && [ "$(cd "$named" 2>/dev/null && pwd -P)" = "$(cd "$path" && pwd -P)" ] && drop_plan=1
      fi
      if git -C "$repo" worktree remove "$path"; then
        # -d keeps a branch with unmerged commits; -D only when the merge is proven (ancestor or merged PR — squash merges aren't ancestors)
        git -C "$repo" branch -d "$branch" >/dev/null 2>&1 || { [ "$base_state" = MERGED ] && git -C "$repo" branch -D "$branch" >/dev/null 2>&1; } || echo "  kept branch $branch (unmerged commits)"
        echo "  removed $path"
        [ $drop_plan = 1 ] && rm -f "$plan" && echo "  removed plan $plan"
      fi
    fi
  done
done
# orphan plan copies: their worktree is gone; removed only once their issue is closed
for f in "$plans"/*.md; do
  [ -f "$f" ] || continue
  line=$(grep -m1 -E '^- \*\*Branch / worktree\*\*:.* at `[^`]+`' "$f") || continue
  wt=$(printf '%s\n' "$line" | sed -E 's/.* at `([^`]+)`.*/\1/')
  [ -e "$wt" ] && continue
  printf '%-8s %-7s %-40s %s\n' PLAN - "$(basename "$f")" "$wt"
  [ $apply = 1 ] && [ $have_gh = 1 ] || continue
  url=$(grep -m1 -E '^- \*\*Issue\*\*:' "$f" | grep -oE 'https://[^ )>`]+' | head -1)
  [ -n "$url" ] && [ "$(gh issue view "$url" --json state -q .state 2>/dev/null)" = CLOSED ] && rm -f "$f" && echo "  removed plan $f"
done
if [ $apply = 0 ]; then echo "dry run — re-run with --apply to remove the clean MERGED/GONE rows (ENV too with --with-env)"; fi
exit 0
