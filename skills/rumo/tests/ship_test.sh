#!/usr/bin/env bash
# Tests for scripts/ship.sh. Each case builds a bare origin, a main checkout, a linked worktree on
# feat/x, a temp HOME and a fake `gh` first on PATH (logs its argv, answers from env vars / state files).
# SHIP_SCRIPT overrides the script under test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SHIP_SCRIPT:-$HERE/../scripts/ship.sh}"
FAILS=0
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# the real gh reads the repo from its cwd: refuse outside a git work tree, like it does
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "failed to run git: fatal: not a git repository" >&2; exit 1; }
echo "$*" >> "$GH_LOG"
args="$*"
bodyfile=""; jqx=""; prev=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && bodyfile="$a"
  { [ "$prev" = "--jq" ] || [ "$prev" = "-q" ]; } && jqx="$a"
  prev="$a"
done
out_json() { if [ -n "$jqx" ]; then printf '%s\n' "$1" | jq -r "$jqx"; else printf '%s\n' "$1"; fi; }
case "$1 $2" in
  "pr list")   out_json "${GH_PR_LIST:-[]}" ;;
  "repo view") out_json "{\"defaultBranchRef\":{\"name\":\"${GH_DEFAULT_BRANCH:-main}\"}}" ;;
  "pr create") echo "https://example.test/o/r/pull/7" ;;
  "pr edit")   cp "$bodyfile" "$GH_STATE/body" ;;
  "pr view")
    case "$args" in
      *"--json body"*)  cat "$GH_STATE/body" 2>/dev/null ;;
      *"--json state"*) echo "${GH_STATE_VAL:-MERGED}" ;;
    esac ;;
  "pr merge")  : ;;
  "pr checks")
    case "${GH_CHECKS:-pass}" in
      fail) printf 'lint\tfail\t3s\thttps://x/1\ntest\tpass\t9s\thttps://x/2\n'; exit 1 ;;
      none) echo "no checks reported on the 'feat/x' branch" >&2; exit 1 ;;
      *)    printf 'test\tpass\t9s\thttps://x/2\n' ;;
    esac ;;
  "issue create") echo "https://example.test/o/r/issues/42" ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

check() { # name condition-exit
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2"; }
hasnt() { ! printf '%s' "$1" | grep -q -- "$2"; }

# mk <branch>: sets E MAIN ORIGIN WT HOMEDIR LOG STATE; stamp covers HEAD of the worktree
mk() {
  local br="${1:-feat/x}"
  E="$(mktemp -d "$ROOT/env.XXXXXX")"
  ORIGIN="$E/origin.git"; MAIN="$E/myrepo"; WT="$E/wts/106-x"
  HOMEDIR="$E/home"; LOG="$E/gh.log"; STATE="$E/state"
  mkdir -p "$E/wts" "$HOMEDIR/.claude/learn/plans" "$STATE"; : > "$LOG"
  (
    set -e
    git init -q --bare "$ORIGIN"
    git clone -q "$ORIGIN" "$MAIN"
    cd "$MAIN"
    git config user.email t@example.com; git config user.name t
    git checkout -q -b dev
    echo base > a.txt; git add -A; git commit -q -m base
    git push -q -u origin dev
    git worktree add -q -b "$br" "$WT"
    cd "$WT"
    echo work > b.txt; git add -A; git commit -q -m work
    printf '%s review-ok\n' "$(git rev-parse HEAD)" > "$(git rev-parse --absolute-git-dir)/rumo-review.ok"
  ) >/dev/null 2>&1
  printf 'summary\n\nCloses #5\n' > "$E/body.md"
  printf 'Follow-up de #7\n\n- [ ] x\n' > "$E/followup.md"
  echo plan > "$HOMEDIR/.claude/learn/plans/myrepo-106-x.md"
}

# ship [extra args...] — runs the script, sets OUT RC
ship() {
  OUT="$(cd / && PATH="$BIN:$PATH" HOME="$HOMEDIR" GH_LOG="$LOG" GH_STATE="$STATE" \
    "$SCRIPT" "$WT" --base dev --issue 5 --title "My PR" --body-file "$E/body.md" "$@" 2>&1)"; RC=$?
}
pushed() { git -C "$ORIGIN" rev-parse --verify -q "refs/heads/${1:-feat/x}" >/dev/null 2>&1; }
logged() { grep -q -- "$1" "$LOG"; }
last() { printf '%s\n' "$OUT" | tail -1; }

# 1 no stamp
mk; rm -f "$(git -C "$WT" rev-parse --absolute-git-dir)/rumo-review.ok"; ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP preflight fail" && ! pushed && [ ! -s "$LOG" ] || ok=1
check "1 no stamp -> preflight fail, nothing pushed" $ok

# 2 stamp != HEAD
mk; printf '%s\n' "0000000000000000000000000000000000000000 x" > "$(git -C "$WT" rev-parse --absolute-git-dir)/rumo-review.ok"; ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP preflight fail.*stamp does not cover HEAD" && ! pushed || ok=1
check "2 stamp not on HEAD -> preflight fail" $ok

# 2b stamp covers the old HEAD after a new commit
mk; (cd "$WT" && echo more > c.txt && git add -A && git commit -q -m more) >/dev/null 2>&1; ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "stamp does not cover HEAD" && ! pushed || ok=1
check "2b commit after the stamp -> preflight fail" $ok

# 3 dirty tree
mk; echo dirty > "$WT/b.txt"; ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP preflight fail.*not clean" && ! pushed || ok=1
check "3 dirty tree -> preflight fail" $ok

# 3b untracked .rumo is not dirt
mk; mkdir "$WT/.rumo"; echo x > "$WT/.rumo/plan.md"; ship --dry-run
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP preflight ok" || ok=1
check "3b .rumo untracked ignored by preflight" $ok

# 4 happy path
mk; HEAD4="$(git -C "$WT" rev-parse HEAD)"; ship
ok=0
[ $RC -eq 0 ] || ok=1
pushed || ok=1
logged "pr create --base dev --head feat/x --title My PR --body-file $E/body.md" || ok=1
logged "pr merge 7 --merge --match-head-commit $HEAD4" || ok=1
[ ! -e "$WT" ] || ok=1
git -C "$MAIN" rev-parse --verify -q refs/heads/feat/x >/dev/null 2>&1 && ok=1
[ ! -e "$HOMEDIR/.claude/learn/plans/myrepo-106-x.md" ] || ok=1
[ "$(last)" = "SHIP DONE pr=https://example.test/o/r/pull/7 merged=yes" ] || ok=1
for s in preflight push pr checks merge cleanup; do has "$OUT" "SHIP $s ok" || ok=1; done
check "4 happy path: push, PR, merge, worktree+branch+plan gone, DONE merged=yes" $ok
[ $ok -ne 0 ] && printf '%s\n' "$OUT" | sed 's/^/    /'

# 5 --no-merge
mk; ship --no-merge
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP merge skip" && ! logged "pr merge" && [ -d "$WT" ] \
  && [ -e "$HOMEDIR/.claude/learn/plans/myrepo-106-x.md" ] && [ "$(last)" = "SHIP DONE pr=https://example.test/o/r/pull/7 merged=no" ] || ok=1
check "5 --no-merge -> merge skip, worktree kept, merged=no" $ok

# 6 base moved
mk
(
  set -e
  git clone -q "$ORIGIN" "$E/other"; cd "$E/other"
  git config user.email t@example.com; git config user.name t
  git checkout -q dev; echo moved > m.txt; git add -A; git commit -q -m moved; git push -q origin dev
) >/dev/null 2>&1
ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP merge fail.*BASE MOVED" && ! logged "pr merge" && [ -d "$WT" ] || ok=1
check "6 base moved -> BASE MOVED fail, no merge" $ok

# prjson <number> <head sha> <base> <isCrossRepository> — one open-PR object for GH_PR_LIST
prjson() { printf '{"number":%s,"url":"https://example.test/o/r/pull/%s","headRefOid":"%s","baseRefName":"%s","isCrossRepository":%s}' "$1" "$1" "$2" "$3" "$4"; }

# 7 existing open PR reused
mk; H="$(git -C "$WT" rev-parse HEAD)"; GH_PR_LIST="[$(prjson 9 "$H" dev false)]" ship --no-merge
ok=0; [ $RC -eq 0 ] && ! logged "pr create" && has "$OUT" "reused open PR #9" && [ "$(last)" = "SHIP DONE pr=https://example.test/o/r/pull/9 merged=no" ] || ok=1
check "7 open PR reused, no create call" $ok

# 7-head/base: an open PR that does not match is never reused
for v in "head:dev:false" "base:main:false"; do
  mk; H="$(git -C "$WT" rev-parse HEAD)"; kind="${v%%:*}"; rest="${v#*:}"; b="${rest%%:*}"; x="${rest#*:}"
  [ "$kind" = head ] && H="1111111111111111111111111111111111111111"
  GH_PR_LIST="[$(prjson 9 "$H" "$b" "$x")]" ship
  ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP pr fail.*open PR #9 on feat/x does not match" && ! logged "pr create" && ! logged "pr merge" && [ -d "$WT" ] || ok=1
  check "7-$kind non-matching open PR ($kind) -> pr fail, not reused" $ok
done

# 7-fork a fork's open PR with the same branch name (anyone can open one) is skipped: own PR created and merged by number
mk; H="$(git -C "$WT" rev-parse HEAD)"; GH_PR_LIST="[$(prjson 9 "$H" dev true)]" ship
ok=0; [ $RC -eq 0 ] && logged "pr create --base dev --head feat/x" && logged "pr merge 7 --merge --match-head-commit $H" \
  && ! logged "pr merge 9" && hasnt "$OUT" "does not match" && has "$(last)" "merged=yes" || ok=1
check "7-fork same-branch fork PR skipped -> own PR created and merged, fork PR untouched" $ok

# 7-fork+other a same-repo PR that does not match still stops, and it is the one named (not the fork)
mk; H="$(git -C "$WT" rev-parse HEAD)"
GH_PR_LIST="[$(prjson 8 "$H" dev true),$(prjson 9 1111111111111111111111111111111111111111 dev false)]" ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "open PR #9 on feat/x does not match" || ok=1
check "7-fork+other fork skipped, non-matching same-repo PR -> pr fail naming it" $ok

# 7e a matching PR is picked even after a non-matching one
mk; H="$(git -C "$WT" rev-parse HEAD)"; GH_PR_LIST="[$(prjson 8 "$H" dev true),$(prjson 9 "$H" dev false)]" ship --no-merge
ok=0; [ $RC -eq 0 ] && has "$OUT" "reused open PR #9" || ok=1
check "7e matching PR chosen among several" $ok

# 8 follow-up, then idempotent rerun
mk; printf 'summary\n\n- bullet\n' > "$STATE/body"
ship --no-merge --followup-file "$E/followup.md"
ok=0
[ $RC -eq 0 ] || ok=1
logged "issue create --title Follow-up #7: My PR --body-file $E/followup.md" || ok=1
logged "pr edit 7 --body-file" || ok=1
[ "$(tail -1 "$STATE/body")" = "Follow-up: #42" ] || ok=1
[ "$(tail -2 "$STATE/body" | head -1 | wc -c | tr -d ' ')" = "1" ] || ok=1   # blank line before it
grep -q '^- bullet$' "$STATE/body" || ok=1
check "8 follow-up: issue created, live body read back and appended" $ok
: > "$LOG"
ship --no-merge --followup-file "$E/followup.md"
ok=0
[ $RC -eq 0 ] && has "$OUT" "SHIP followup skip" && ! logged "issue create" && ! logged "pr edit" \
  && [ "$(grep -c '^Follow-up: #' "$STATE/body")" = "1" ] || ok=1
check "8b rerun does not append twice" $ok

# 9 checks failing
mk; GH_CHECKS=fail ship
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP checks fail.*lint" && hasnt "$OUT" "failing:.*test" && ! logged "pr merge" && [ -d "$WT" ] || ok=1
check "9 checks failing -> fail naming the check, no merge" $ok

# 9b no checks reported
mk; GH_CHECKS=none ship --no-merge
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP checks ok.*no checks reported" || ok=1
check "9b no checks reported counts as green" $ok

# 10 dry-run
mk; ship --dry-run
ok=0; [ $RC -eq 0 ] && ! pushed && [ ! -s "$LOG" ] && [ -d "$WT" ] && has "$OUT" "SHIP preflight ok" && has "$OUT" "DRY-RUN" \
  && has "$OUT" "SHIP push skip" && [ -e "$HOMEDIR/.claude/learn/plans/myrepo-106-x.md" ] && has "$(last)" "SHIP DONE.*merged=no" || ok=1
check "10 --dry-run: nothing pushed, no gh call, worktree kept" $ok

# 10b dry-run still runs the real preflight
mk; echo dirty > "$WT/b.txt"; ship --dry-run
ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP preflight fail" || ok=1
check "10b --dry-run still fails a dirty preflight" $ok

# 11 branch dev refused
mk
# the main checkout owns `dev`: detach it, then fast-forward dev to the work commit inside the worktree
(git -C "$MAIN" checkout -q --detach && git -C "$WT" checkout -q dev && git -C "$WT" merge -q --ff-only feat/x) >/dev/null 2>&1
printf '%s review-ok\n' "$(git -C "$WT" rev-parse HEAD)" > "$(git -C "$WT" rev-parse --absolute-git-dir)/rumo-review.ok"
before="$(git -C "$ORIGIN" rev-parse dev)"
ship
ok=0; [ "$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)" = "dev" ] || ok=1
[ $RC -eq 1 ] && has "$OUT" "SHIP push fail.*refusing" && [ "$(git -C "$ORIGIN" rev-parse dev)" = "$before" ] && [ ! -s "$LOG" ] || ok=1
check "11 branch dev -> push refused" $ok

# 12 Mandato: alcance=pr stops before the merge; a refused one fails preflight
MANDATO_PY="$HERE/../../../scripts/hooks-staged/mandato.py"
if [ -f "$MANDATO_PY" ] && command -v python3 >/dev/null 2>&1; then
  mk
  KEY="$E/key"; printf 'throwaway-key\n' > "$KEY"
  cat > "$E/m.json" <<EOF
{"v":1,"politica":"abc1234","repo":"o/r","issue":5,"forca":"explicito","pediu":"a","aprovou":"b","fonte":"github","alcance":"pr","worktree":"$WT","branch":"feat/x","emitido":"2026-01-01T00:00:00Z"}
EOF
  GD="$(git -C "$WT" rev-parse --absolute-git-dir)"
  RUMO_MANDATO_KEY="$KEY" python3 -I "$MANDATO_PY" sign --key "$KEY" "$E/m.json" > "$GD/rumo-mandato.json" 2>/dev/null
  export RUMO_MANDATO_KEY="$KEY"
  ship
  ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP merge skip.*Mandato" && ! logged "pr merge" && pushed && [ -d "$WT" ] && has "$(last)" "merged=no" || ok=1
  check "12 Mandato alcance=pr -> push + PR, merge skipped" $ok

  sed 's/"alcance": "pr"/"alcance": "merge"/' "$GD/rumo-mandato.json" > "$E/tampered" && cp "$E/tampered" "$GD/rumo-mandato.json"
  ship
  ok=0; [ $RC -eq 1 ] && has "$OUT" "SHIP preflight fail.*MANDATO refused" || ok=1
  check "12b tampered Mandato -> preflight fail" $ok
  unset RUMO_MANDATO_KEY
else
  echo "SKIP: 12 mandato.py not found"
fi

# 13 merge only into dev: any other base leaves the PR open
for b in main master production release/x; do
  mk; git -C "$MAIN" push -q origin "dev:$b" >/dev/null 2>&1; ship --base "$b"
  ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP merge skip — base $b is not dev" && ! logged "pr merge" && [ -d "$WT" ] \
    && [ "$(last)" = "SHIP DONE pr=https://example.test/o/r/pull/7 merged=no" ] || ok=1
  check "13-$b base $b -> merge skip, PR open" $ok
done

# 13b --merge-default-branch merges into the default branch when origin has no dev
mk; git -C "$MAIN" push -q origin dev:main >/dev/null 2>&1; git -C "$ORIGIN" branch -q -D dev >/dev/null 2>&1
H="$(git -C "$WT" rev-parse HEAD)"; GH_DEFAULT_BRANCH=main ship --base main --merge-default-branch
ok=0; [ $RC -eq 0 ] && logged "pr merge 7 --merge --match-head-commit $H" && has "$(last)" "merged=yes" || ok=1
check "13b --merge-default-branch, base=default, no origin/dev -> merged" $ok
[ $ok -ne 0 ] && printf '%s\n' "$OUT" | sed 's/^/    /'

# 13c the flag is ignored while origin has dev
mk; git -C "$MAIN" push -q origin dev:main >/dev/null 2>&1; GH_DEFAULT_BRANCH=main ship --base main --merge-default-branch
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP merge skip — base main is not dev.*--merge-default-branch ignored.*dev" && ! logged "pr merge" && has "$(last)" "merged=no" || ok=1
check "13c --merge-default-branch with origin/dev -> skip naming why" $ok

# 13d the flag is ignored when the base is not the default branch
mk; git -C "$MAIN" push -q origin dev:main >/dev/null 2>&1; git -C "$ORIGIN" branch -q -D dev >/dev/null 2>&1
GH_DEFAULT_BRANCH=master ship --base main --merge-default-branch
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP merge skip — base main is not dev.*--merge-default-branch ignored.*master" && ! logged "pr merge" || ok=1
check "13d --merge-default-branch, base != default -> skip naming why" $ok

# 14 an ignored .env* only in the worktree keeps the worktree and branch
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; mkdir -p "$WT/.vercel"
echo SECRET=1 > "$WT/.env.local"; echo X=1 > "$WT/.vercel/.env.production.local"
ship
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP cleanup skip — env file(s) only in the worktree:.*\.env\.local" \
  && has "$OUT" "\.vercel/\.env\.production\.local" && has "$OUT" "wt-gc.sh --apply --with-env" \
  && [ -f "$WT/.env.local" ] && git -C "$MAIN" rev-parse --verify -q refs/heads/feat/x >/dev/null 2>&1 \
  && has "$(last)" "merged=yes" || ok=1
check "14 env only in the worktree -> cleanup skip, worktree+branch kept" $ok
[ $ok -ne 0 ] && printf '%s\n' "$OUT" | sed 's/^/    /'

# 14b a different copy in the main checkout also blocks; 14c a byte-identical one does not
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; echo A=1 > "$WT/.env.local"; echo A=2 > "$MAIN/.env.local"; ship
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP cleanup skip.*\.env\.local" && [ -d "$WT" ] || ok=1
check "14b env differing from main -> cleanup skip" $ok
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; echo A=1 > "$WT/.env.local"; echo A=1 > "$MAIN/.env.local"; ship
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP cleanup ok" && [ ! -e "$WT" ] || ok=1
check "14c env identical to main -> cleanup ok" $ok

# 14d --slot-env: the build's own slot file is deleted after the merge, so it never blocks the cleanup;
# a second env file still does; 14e a slot path outside the worktree or not an env file is refused
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; echo PORT=3101 > "$WT/.env.local"; ship --slot-env .env.local
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP cleanup ok" && [ ! -e "$WT" ] || ok=1
check "14d --slot-env .env.local -> deleted after merge, cleanup ok" $ok
[ $ok -ne 0 ] && printf '%s\n' "$OUT" | sed 's/^/    /'
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; echo PORT=3101 > "$WT/.env.local"; echo S=1 > "$WT/.env"; ship --slot-env .env.local
ok=0; [ $RC -eq 0 ] && has "$OUT" "SHIP cleanup skip.*\.env" && [ -f "$WT/.env" ] && [ ! -e "$WT/.env.local" ] || ok=1
check "14d2 --slot-env with a second env file -> slot deleted, cleanup skip" $ok
# 14f a slot behind a symlinked dir that leaves the worktree is not deleted; 14g a tracked slot file is not deleted
mk; echo '.env*' >> "$MAIN/.git/info/exclude"; OUTSIDE="$(mktemp -d)"; echo K=1 > "$OUTSIDE/.env"; ln -s "$OUTSIDE" "$WT/cfg"; echo cfg >> "$MAIN/.git/info/exclude"
ship --slot-env cfg/.env
ok=0; [ -f "$OUTSIDE/.env" ] && has "$OUT" "slot-env.*outside the worktree" || ok=1
check "14f --slot-env through a symlink out of the worktree -> kept, named" $ok
mk; printf 'A=\n' > "$WT/.env.example"; git -C "$WT" add -f .env.example; git -C "$WT" -c user.email=a@b -c user.name=a commit -qm ex
printf '%s review-ok\n' "$(git -C "$WT" rev-parse HEAD)" > "$(git -C "$WT" rev-parse --absolute-git-dir)/rumo-review.ok"
ship --slot-env .env.example
ok=0; has "$OUT" "slot-env.*tracked" && ! has "$OUT" "worktree remove refused" || ok=1
check "14g --slot-env naming a tracked file -> kept, named" $ok
[ $ok -ne 0 ] && printf '%s\n' "$OUT" | sed 's/^/    /'
for bad in ../x/.env.local README.md /tmp/.env.local; do
  mk; ship --slot-env "$bad"
  ok=0; [ $RC -ne 0 ] && has "$OUT" "SHIP preflight fail.*slot-env" && ! logged "pr create" || ok=1
  check "14e --slot-env $bad -> preflight fail" $ok
done

echo
if [ $FAILS -eq 0 ]; then echo "all passed"; exit 0; else echo "$FAILS failed"; exit 1; fi
