#!/usr/bin/env bash
# Run: bash tests/wt_gc_test.sh — builds throwaway repos, exit 1 on any FAIL.
G="$(cd "$(dirname "$0")/.." && pwd)/scripts/wt-gc.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
row() { printf '%s\n' "$out" | grep -qE "^$1 +[^ ]+ +$2 "; }   # row STATE BRANCH: that state on that branch's own line
T=$(mktemp -d); export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare "$T/origin.git"; git init -q -b dev "$T/repo"; cd "$T/repo"
git commit -q --allow-empty -m base; git remote add origin "$T/origin.git"; git push -q origin dev
for b in merged dirty active automacoes fresh envonly envsame vercel gone r0; do git worktree add -q --no-track -b "feat/$b" "$T/wt/$b" origin/dev; done
git -C "$T/wt/merged" commit -q --allow-empty -m m; git merge -q --ff-only feat/merged; git push -q origin dev; git fetch -q
echo x > "$T/wt/dirty/new.txt"
git -C "$T/wt/active" commit -q --allow-empty -m a
printf '.env\n.vercel/\n' > "$T/repo/.git/info/exclude"; git -C "$T/wt/envonly" commit -q --allow-empty -m e; git merge -q --no-ff -m m2 feat/envonly; git push -q origin dev; git fetch -q; echo S=1 > "$T/wt/envonly/.env"
# main holds its own .env; envsame's has the same bytes (collectable), envonly's differs (ENV)
echo S=main > "$T/repo/.env"; echo S=main > "$T/wt/envsame/.env"
git -C "$T/wt/envsame" commit -q --allow-empty -m s; git merge -q --no-ff -m m3 feat/envsame; git push -q origin dev; git fetch -q
# a .env inside an ignored dir, merged, absent from main → ENV
git -C "$T/wt/vercel" commit -q --allow-empty -m v; git merge -q --no-ff -m m4 feat/vercel; git push -q origin dev; git fetch -q
mkdir -p "$T/wt/vercel/.vercel"; echo SECRET=only-here > "$T/wt/vercel/.vercel/.env.production.local"
# GONE: unmerged commit, upstream deleted on the remote
git -C "$T/wt/gone" commit -q --allow-empty -m 'unmerged work'; git -C "$T/wt/gone" push -q -u origin feat/gone; git push -q origin --delete feat/gone; git fetch -q --prune
# a wave session renamed its branch but has not committed yet (reflog: created + renamed)
git -C "$T/wt/r0" branch -m feat/renamed
export RUMO_PLANS_DIR="$T/plans"; mkdir -p "$RUMO_PLANS_DIR"
planfor() { printf -- '- **Branch / worktree**: `feat/x` at `%s`\n- **Issue**: none\n' "$1" > "$RUMO_PLANS_DIR/$2"; }
planfor "$T/wt/merged" repo-merged.md; planfor "$T/wt/gone" repo-gone.md; planfor "$T/wt/elsewhere" repo-envsame.md
printf -- '- **Branch / worktree**: `feat/x` at `%s`\n- **Issue**: none\n' "$T/wt/gone-long-ago" > "$RUMO_PLANS_DIR/orphan.md"
printf 'handoff, no branch line\n' > "$RUMO_PLANS_DIR/handoff.md"
out=$(PATH="/usr/bin:/bin" bash "$G" "$T/repo")
ok "env equal to main's → MERGED" '[[ "$out" == *"MERGED"*"feat/envsame"* ]]'
ok "env differing from main's → ENV" '[[ "$out" == *"ENV "*"feat/envonly"* ]]'
ok "orphan plan listed as PLAN" '[[ "$out" == *"PLAN"*"orphan.md"*"$T/wt/gone-long-ago"* ]]'
ok "plan without branch line ignored" '[[ "$out" != *"handoff.md"* ]]'
ok "merged row"  '[[ "$out" == *"MERGED"*"feat/merged"* ]]'
ok "dirty row"   '[[ "$out" == *"DIRTY"*"feat/dirty"* ]]'
ok "active row"  '[[ "$out" == *"ACTIVE"*"feat/active"* ]]'
ok "renamed branch with no commits → ACTIVE" 'row ACTIVE feat/renamed'
ok ".env inside an ignored dir differing from main → ENV" 'row ENV feat/vercel'
ok "gone row" 'row GONE feat/gone'
ok "dry run keeps all" '[ -d "$T/wt/merged" ] && [[ "$out" == *"dry run"* ]]'
out=$(PATH="/usr/bin:/bin" bash "$G" --apply "$T/repo"); rc=$?
ok "--apply exits 0" '[ "$rc" = 0 ]'
ok "apply keeps a renamed branch with no commits" '[ -d "$T/wt/r0" ] && git -C "$T/repo" rev-parse -q --verify feat/renamed >/dev/null'
ok "apply keeps ENV from an ignored-dir .env" '[ -f "$T/wt/vercel/.vercel/.env.production.local" ]'
ok "apply removes GONE worktree but keeps its plan" '[ ! -d "$T/wt/gone" ] && [ -f "$RUMO_PLANS_DIR/repo-gone.md" ]'
ok "apply keeps a plan whose Branch line names another path" '[ ! -d "$T/wt/envsame" ] && [ -f "$RUMO_PLANS_DIR/repo-envsame.md" ]'
ok "apply removes merged" '[ ! -d "$T/wt/merged" ] && ! git -C "$T/repo" rev-parse -q --verify feat/merged >/dev/null'
ok "apply keeps dirty"  '[ -f "$T/wt/dirty/new.txt" ]'
ok "automation worktree kept" '[ -d "$T/wt/automacoes" ] && [[ "$out" == *"AUTO"*"feat/automacoes"* ]]'
ok "fresh branch (no commits) kept" '[ -d "$T/wt/fresh" ]'
ok "merged but holding an ignored .env kept" '[ -f "$T/wt/envonly/.env" ]'
ok "apply removes worktree whose .env equals main's" '[ ! -d "$T/wt/envsame" ]'
ok "apply removes the merged worktree's plan copy" '[ ! -f "$RUMO_PLANS_DIR/repo-merged.md" ] && [[ "$out" == *"removed plan"*"repo-merged.md"* ]]'
ok "orphan plan without Issue kept by apply" '[ -f "$RUMO_PLANS_DIR/orphan.md" ]'
out=$(PATH="/usr/bin:/bin" bash "$G" --apply --with-env "$T/repo")
ok "--with-env removes ENV worktree" '[ ! -d "$T/wt/envonly" ] && [[ "$out" == *"env lost: .env"* ]]'
ok "apply keeps active" '[ -d "$T/wt/active" ] && git -C "$T/repo" rev-parse -q --verify feat/active >/dev/null'
# no reflog (disabled/expired): an old merged worktree is still collected, a new one is kept
git init -q -b dev "$T/r2"; cd "$T/r2"; git commit -q --allow-empty -m base; git remote add origin "$T/origin2.git"; git init -q --bare "$T/origin2.git"; git push -q origin dev
git -c core.logAllRefUpdates=false worktree add -q --no-track -b feat/old "$T/wt2/old" origin/dev
git -c core.logAllRefUpdates=false worktree add -q --no-track -b feat/new "$T/wt2/new" origin/dev
rm -f .git/logs/refs/heads/feat/old .git/logs/refs/heads/feat/new
touch -t 202001010000 "$T/wt2/old/.git"
out=$(PATH="/usr/bin:/bin" bash "$G" "$T/r2")
ok "no reflog + old worktree → MERGED" '[[ "$out" == *"MERGED"*"feat/old"* ]]'
ok "no reflog + new worktree → ACTIVE" '[[ "$out" == *"ACTIVE"*"feat/new"* ]]'
out=$(PATH="/usr/bin:/bin" bash "$G" "$T/wt2/new")
ok "a linked worktree as the repo arg never lists the main checkout" '[[ "$out" != *" dev "* ]] && [[ "$out" != *"$T/r2"$'\n'* ]] && [[ "$out" == *"feat/old"* ]]'
ok "--days rejects a non-number" '! PATH="/usr/bin:/bin" bash "$G" --days abc "$T/r2" >/dev/null'
# a fresh worktree fast-forwarded to an advanced base before its first commit is still fresh
git init -q -b dev "$T/r3"; cd "$T/r3"; git commit -q --allow-empty -m base; git init -q --bare "$T/origin3.git"; git remote add origin "$T/origin3.git"; git push -q origin dev; git fetch -q
git worktree add -q --no-track -b feat/ff "$T/wt3/ff" origin/dev
git commit -q --allow-empty -m sibling; git push -q origin dev; git -C "$T/wt3/ff" fetch -q; git -C "$T/wt3/ff" merge -q origin/dev
out=$(PATH="/usr/bin:/bin" bash "$G" --apply "$T/r3")
ok "fast-forwarded fresh worktree kept by --apply" '[ -d "$T/wt3/ff" ] && [[ "$out" != *"MERGED"*"feat/ff"* ]]'
rm -rf "$T"; exit $fail
