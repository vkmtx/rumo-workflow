#!/usr/bin/env bash
# Tests for scripts/issue-criteria.sh. Each case uses a temp git repo and a body fixture.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/issue-criteria.sh"
FAILS=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

REPO="$ROOT/repo"; mkdir "$REPO"
(
  cd "$REPO" || exit 1
  git init -q; git config user.email t@example.com; git config user.name t
  printf '#!/bin/sh\necho hello world\n' > hi.sh
  printf 'old data\n' > old.txt
  git add -A && git commit -q -m one
  git rm -q old.txt && git commit -q -m two
) >/dev/null 2>&1
OLD=$(git -C "$REPO" rev-parse HEAD~1)

body() { printf '%s\n' "$@" > "$ROOT/body.md"; echo "$ROOT/body.md"; }

# 1 passing cmd with expected
b=$(body '## Acceptance' '- [ ] [cmd] `sh hi.sh` → hello')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  sh hi.sh" && has "$out" "criteria: 1 cmd (1 pass, 0 fail), 0 judgment, 0 visual" || ok=1
check "1 passing cmd with expected" $ok

# 2 exit 0 but wrong output
b=$(body '- [ ] [cmd] `sh hi.sh` → goodbye')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  sh hi.sh" && has "$out" "    hello world" || ok=1
check "2 wrong output fails with tail" $ok

# 3 failing cmd
b=$(body '- [x] [cmd] `exit 3`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  exit 3" || ok=1
check "3 failing cmd" $ok

# 4 judgment / visual skipped and counted
b=$(body '- [ ] [judgment] reads well' '- [ ] [visual] looks right' '- [ ] [cmd] `true`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "SKIP(judgment)  reads well" && has "$out" "SKIP(visual)  looks right" && has "$out" "criteria: 1 cmd (1 pass, 0 fail), 1 judgment, 1 visual" || ok=1
check "4 judgment/visual are SKIP" $ok

# 5 -> arrow and backticked expected
b=$(body '- [ ] [cmd] `sh hi.sh` -> `hello world`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  sh hi.sh" || ok=1
check "5 -> arrow, backticked expected" $ok

# 6 no expected part
b=$(body '- [ ] [cmd] `test -f hi.sh`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  test -f hi.sh" || ok=1
check "6 no expected part" $ok

# 7 sha export
b=$(body '- [ ] [cmd] `cat old.txt` → old data')
out=$("$SCRIPT" "$REPO" "$b" "$OLD" --trusted 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] || ok=1
check "7a old sha passes" $ok
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] || ok=1
check "7b HEAD fails" $ok

# 8 no criteria
b=$(body 'just prose' '- [ ] plain item')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 2 ] && has "$out" "no criteria found — is this a rumo ticket?" || ok=1
check "8 no criteria -> 2" $ok

# 9 bad args
"$SCRIPT" >/dev/null 2>&1; r1=$?
"$SCRIPT" --trusted "$REPO" "$ROOT/missing.md" >/dev/null 2>&1; r2=$?
"$SCRIPT" --trusted "$ROOT/nope" "$b" >/dev/null 2>&1; r3=$?
"$SCRIPT" --trusted "$REPO" "$b" deadbeefnot >/dev/null 2>&1; r4=$?
"$SCRIPT" --trusted >/dev/null 2>&1; r5=$?
"$SCRIPT" --trusted "$REPO" "$b" HEAD extra >/dev/null 2>&1; r6=$?
ok=0; [ $r1 -eq 2 ] && [ $r2 -eq 2 ] && [ $r3 -eq 2 ] && [ $r4 -eq 2 ] && [ $r5 -eq 2 ] && [ $r6 -eq 2 ] || ok=1
check "9 bad args -> 2" $ok

# 10 node_modules symlinked
mkdir "$REPO/node_modules"; echo found > "$REPO/node_modules/marker"
b=$(body '- [ ] [cmd] `cat node_modules/marker` → found')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] || ok=1
check "10 node_modules symlinked" $ok

# 11 untrusted (no --trusted): nothing runs, NOT RUN rows, exit 3
MARK="$ROOT/pwned-marker"
b=$(body '- [ ] [cmd] `echo pwned > '"$MARK"'`' '- [ ] [cmd] `sh hi.sh` → hello' '- [ ] [judgment] reads well' '- [ ] [visual] looks right')
out=$("$SCRIPT" "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 3 ] && [ ! -e "$MARK" ] \
  && has "$out" "NOT RUN  echo pwned > $MARK" && has "$out" "NOT RUN  sh hi.sh" \
  && has "$out" "SKIP(judgment)  reads well" && has "$out" "SKIP(visual)  looks right" \
  && has "$out" "not run: issue body not marked trusted — check its author/editors (issue-trust.sh) and re-run with --trusted" \
  && ! has "$out" "PASS" || ok=1
check "11 untrusted -> exit 3, NOT RUN, marker not created" $ok

# 12 --trusted in middle position runs it
b=$(body '- [ ] [cmd] `sh hi.sh` → hello')
out=$("$SCRIPT" "$REPO" --trusted "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  sh hi.sh" || ok=1
check "12 --trusted in any position" $ok

# 13 empty expected after arrow -> treated as no expected part
b=$(body '- [ ] [cmd] `test -f hi.sh` →' '- [ ] [cmd] `true` ->   ' '- [ ] [cmd] `true` → ')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  test -f hi.sh" && has "$out" "criteria: 3 cmd (3 pass, 0 fail)" || ok=1
check "13 empty expected after arrow" $ok

# 14 #42 "→ vazio" / "→ empty": no output and grep's no-match exit 1 pass; output present fails
b=$(body '- [ ] [cmd] `grep -n nomatch-xyz hi.sh` → vazio' '- [ ] [cmd] `grep -n nomatch-xyz hi.sh` → empty')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "criteria: 2 cmd (2 pass, 0 fail)" || ok=1
check "14a #42 → vazio / → empty pass on no output (exit 1)" $ok
b=$(body '- [ ] [cmd] `grep -n hello hi.sh` → vazio')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  grep -n hello hi.sh" || ok=1
check "14b #42 → vazio fails when output present" $ok

# 15 #42 prose after the code span: cmd is the code span only; exit phrase -> PASS, other prose -> MANUAL
b=$(body '- [ ] [cmd] `sh hi.sh` sai com 0')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  sh hi.sh" || ok=1
check "15a #42 prose exit phrase after code span -> PASS  sh hi.sh" $ok
b=$(body '- [ ] [cmd] `sh hi.sh`: prints a greeting')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "MANUAL  sh hi.sh" && has "$out" "exit 0; check by hand: prints a greeting" && ! has "$out" "PASS  sh" || ok=1
check "15c #42 fix prose (not an exit phrase), exit 0 -> MANUAL" $ok
b=$(body '- [ ] [cmd] `exit 4`: prose')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  exit 4" || ok=1
check "15b #42 prose after code span, nonzero exit fails" $ok

# 16 #42 "→ exit N"
b=$(body '- [ ] [cmd] `sh hi.sh` → exit 0' '- [ ] [cmd] `exit 2` → exit 2')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "criteria: 2 cmd (2 pass, 0 fail)" || ok=1
check "16a #42 → exit N passes on rc == N" $ok
b=$(body '- [ ] [cmd] `true` → exit 1')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  true" || ok=1
check "16b #42 → exit 1 fails on rc 0" $ok

# 17 #42 numeric: every line ends with an integer satisfying op N
b=$(body '- [ ] [cmd] `printf "a:2\nb:1\n"` → ≥1 em cada' '- [ ] [cmd] `grep -c hello hi.sh` ≥ 1' '- [ ] [cmd] `grep -c nomatch-xyz hi.sh` → 0')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "criteria: 3 cmd (3 pass, 0 fail)" || ok=1
check "17a #42 ≥N per line (arrow and no arrow), → 0 with grep exit 1" $ok
b=$(body '- [ ] [cmd] `printf "a:2\nb:0\n"` → ≥1 em cada')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" 'FAIL  printf "a:2\nb:0\n"' || ok=1
check "17b #42 ≥1 em cada fails when one line is 0" $ok

# 18 #42 several commands in one criterion: MANUAL, never executed (even --trusted)
b=$(body '- [ ] [cmd] `touch '"$ROOT"'/m1`, `true` e `true` passam, sem warning novo')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ ! -e "$ROOT/m1" ] && has "$out" "MANUAL  touch $ROOT/m1" \
  && has "$out" "several commands in one criterion — run by hand" && has "$out" "1 manual" || ok=1
check "18 #42 several commands -> MANUAL, not run, exit 0" $ok

# 19 #42 unmatched phrase after exit 0 -> MANUAL
b=$(body '- [ ] [cmd] `sh hi.sh` → prints the greeting twice')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "MANUAL  sh hi.sh" && has "$out" "exit 0; check by hand: prints the greeting twice" || ok=1
check "19 #42 unmatched phrase -> MANUAL" $ok

# 20 #42 fix: "`x` → 1, e `y` → 0." holds two commands -> MANUAL, nothing run
b=$(body '- [ ] [cmd] `touch '"$ROOT"'/m2; echo 1` → 1, e `echo 5` → 0.')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ ! -e "$ROOT/m2" ] && has "$out" "MANUAL  touch $ROOT/m2; echo 1" \
  && has "$out" "several commands in one criterion — run by hand" && ! has "$out" "PASS" || ok=1
check "20 #42 fix span-then-arrow second command -> MANUAL, not run" $ok

# 21 #42 fix: one trailing sentence period is stripped, so "→ 4." is numeric
b=$(body '- [ ] [cmd] `echo 4` → 4.')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  echo 4" || ok=1
check "21a #42 fix → 4. passes on 4" $ok
b=$(body '- [ ] [cmd] `echo 4` → 0.')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  echo 4" || ok=1
check "21b #42 fix → 0. fails on 4" $ok

# 22 #42 fix: exit phrases
b=$(body '- [ ] [cmd] `exit 3` → exit ≠ 0' '- [ ] [cmd] `true` → passa' '- [ ] [cmd] `true` → sai 0.')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "criteria: 3 cmd (3 pass, 0 fail)" || ok=1
check "22 #42 fix exit ≠ 0 / passa / sai 0. pass" $ok

# 23 #42 fix: → 0 with no output — exit 0 passes; exit 1 (no match or a failed test) -> MANUAL
b=$(body '- [ ] [cmd] `grep -c nomatch-xyz hi.sh | grep -v 0` → 0')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "MANUAL  grep -c nomatch-xyz hi.sh | grep -v 0" && has "$out" "no output, exit 1" || ok=1
check "23a #42 fix → 0 on empty output, exit 1 -> MANUAL" $ok
b=$(body '- [ ] [cmd] `true` → 0' '- [ ] [cmd] `false` → 0')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "PASS  true" && has "$out" "MANUAL  false" && ! has "$out" "PASS  false" || ok=1
check "23b #42 fix → 0: true passes, false is not a PASS" $ok

# 24 #42 fix: an inline code span inside prose is not a second command
b=$(body '- [ ] [cmd] `sh hi.sh`: o comando imprime `hello` (assert)')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "MANUAL  sh hi.sh" && has "$out" "exit 0; check by hand" && ! has "$out" "several commands" || ok=1
check "24a #42 fix inline span in prose runs, exit 0 -> MANUAL check by hand" $ok
b=$(body '- [ ] [cmd] `false`: imprime `x`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  false" || ok=1
check "24b #42 fix inline span in prose, nonzero exit -> FAIL" $ok

# 25 #42 fix: prose claim without arrow is not a PASS
b=$(body '- [ ] [cmd] `grep -c hello hi.sh`: appears only once')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "MANUAL  grep -c hello hi.sh" && ! has "$out" "PASS  grep" || ok=1
check "25 #42 fix prose claim -> MANUAL, not PASS" $ok

# 26 #42 fix: "`a`, `b` e `c` passam" -> MANUAL, none run
b=$(body '- [ ] [cmd] `touch '"$ROOT"'/m3`, `touch '"$ROOT"'/m4` e `touch '"$ROOT"'/m5` passam')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ ! -e "$ROOT/m3" ] && [ ! -e "$ROOT/m4" ] && [ ! -e "$ROOT/m5" ] \
  && has "$out" "MANUAL  touch $ROOT/m3" && has "$out" "several commands" || ok=1
check "26 #42 fix list of commands -> MANUAL, none run" $ok

# 27 #42 fix: a second command after the arrow, no arrow of its own -> MANUAL, none run
b=$(body '- [ ] [cmd] `grep -n nomatch-xyz hi.sh` → vazio, e `touch '"$ROOT"'/m6` também')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ ! -e "$ROOT/m6" ] && has "$out" "several commands" || ok=1
check "27 #42 fix connector + span after the arrow -> MANUAL, not run" $ok

# 28 #42 fix: a span after an exit/empty/num expectation, connector or not -> MANUAL, none run
b=$(body '- [ ] [cmd] `grep -n nomatch-xyz hi.sh` → vazio, e também `touch '"$ROOT"'/m7`' \
  '- [ ] [cmd] `grep -n nomatch-xyz hi.sh` → vazio; depois `touch '"$ROOT"'/m8`' \
  '- [ ] [cmd] `grep -c nomatch-xyz hi.sh` → 0, and then `touch '"$ROOT"'/m9`')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ ! -e "$ROOT/m7" ] && [ ! -e "$ROOT/m8" ] && [ ! -e "$ROOT/m9" ] \
  && ! has "$out" "PASS" && has "$out" "3 manual" || ok=1
check "28 #42 fix span after exit/empty/num expectation -> MANUAL, not run" $ok

# 29 #42 fix: an inline span after a num expectation does not hide a real FAIL
b=$(body '- [ ] [cmd] `grep -c hello hi.sh` → 0 (no `hello` left)')
out=$("$SCRIPT" --trusted "$REPO" "$b" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "FAIL  grep -c hello hi.sh" || ok=1
check "29 #42 fix span after expectation, check fails -> FAIL" $ok

echo
if [ $FAILS -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
