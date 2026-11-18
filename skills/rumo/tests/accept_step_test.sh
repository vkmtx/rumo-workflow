#!/usr/bin/env bash
# Tests for scripts/accept-step.sh. Each case builds a fresh temp git repo.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/accept-step.sh"
VERIFY='python3 -m unittest discover -s tests -q'
FAILS=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkrepo() {
  local d; d="$(mktemp -d "$ROOT/repo.XXXXXX")"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email t@example.com
    git config user.name t
    mkdir tests emptydir
    printf 'def sub(a, b):\n    return a - b\n' > calc.py
    printf 'import unittest\nclass T(unittest.TestCase):\n    def test_x(self):\n        self.assertEqual(1, 1)\n' > tests/test_base.py
    git add -A && git commit -q -m base
  ) >/dev/null 2>&1
  echo "$d"
}

check() { # name condition-exit
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2"; }

addtest() { # dir module
  printf 'import unittest, sys\nsys.path.insert(0, ".")\nimport %s\nclass T(unittest.TestCase):\n    def test_y(self):\n        self.assertEqual(%s.add(1, 2), 3)\n' "$2" "$2" > "$1/tests/test_$2.py"
}

# 1
d=$(mkrepo); printf 'def sub(a, b):\n    return a - b\ndef add(a, b):\n    return a + b\n' > "$d/calc.py"
addtest "$d" calc; before=$(cksum < "$d/calc.py")
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "ACCEPT OK" && [ "$(cksum < "$d/calc.py")" = "$before" ] && [ -f "$d/tests/test_calc.py" ] && [ -z "$(git -C "$d" stash list)" ] || ok=1
check "1 modified tracked file accepted and restored" $ok

# 2
d=$(mkrepo); printf 'def add(a, b):\n    return a + b\n' > "$d/newmod.py"; addtest "$d" newmod
out=$("$SCRIPT" "$d" "$VERIFY" --code newmod.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ -f "$d/newmod.py" ] && [ -z "$(git -C "$d" stash list)" ] || ok=1
check "2 untracked code file accepted and restored" $ok

# 3
d=$(mkrepo); printf 'def sub(a, b):\n    return a - b\ndef add(a, b):\n    return a + b\n' > "$d/calc.py"
before=$(cksum < "$d/calc.py")
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "stay green" && [ "$(cksum < "$d/calc.py")" = "$before" ] || ok=1
check "3 test independent of code rejected" $ok

# 4
d=$(mkrepo)
out=$("$SCRIPT" "$d" "false" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "verify failed" || ok=1
check "4 failing verify rejected" $ok

# 5
d=$(mkrepo)
out=$("$SCRIPT" "$d" "python3 -m unittest discover -s emptydir" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "zero tests" || ok=1
check "5 zero tests rejected" $ok

# 6
d=$(mkrepo)
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "no changes" || ok=1
check "6 unchanged code file rejected" $ok

# 7
d=$(mkrepo)
out=$("$SCRIPT" "$d" "$VERIFY" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "red check skipped" || ok=1
check "7 no --code skips red check" $ok

# 8
"$SCRIPT" "$ROOT/does-not-exist" "true" >/dev/null 2>&1; rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "8 bad worktree exits 2" $ok

# 9 — a --code path that doesn't exist: rejected, no stash left behind, real code untouched
d=$(mkrepo)
printf 'def sub(a, b):\n    return a - b\ndef add(a, b):\n    return a + b\n' > "$d/calc.py"
before=$(cksum < "$d/calc.py")
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py ghost.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "does not exist" && [ -z "$(git -C "$d" stash list)" ] && [ "$(cksum < "$d/calc.py")" = "$before" ] || ok=1
check "9 missing --code path rejected cleanly" $ok

ADDCALC='def sub(a, b):\n    return a - b\ndef add(a, b):\n    return a + b\n'

# 10 — new untracked module: load failure is the only possible red, accepted as load-only
d=$(mkrepo); printf 'def add(a, b):\n    return a + b\n' > "$d/newmod.py"; addtest "$d" newmod
out=$("$SCRIPT" "$d" "$VERIFY" --code newmod.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "load-only (new files)" || ok=1
check "10 new untracked module accepted as load-only" $ok

# 11 — tracked module, red is AttributeError/assertion, not a load failure
d=$(mkrepo); printf "$ADDCALC" > "$d/calc.py"; addtest "$d" calc
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "(assertion)" && has "$out" "zero-test ok" || ok=1
check "11 tracked module red on behaviour reports (assertion)" $ok

# 12 — tracked module: stashing leaves an import of a symbol that vanished -> load failure rejected
d=$(mkrepo); printf "$ADDCALC" > "$d/calc.py"
printf 'import unittest, sys\nsys.path.insert(0, ".")\nfrom calc import add\nclass T(unittest.TestCase):\n    def test_y(self):\n        self.assertEqual(add(1, 2), 3)\n' > "$d/tests/test_calc.py"
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "failed to load, not on an assertion" && [ -z "$(git -C "$d" stash list)" ] || ok=1
check "12 red from ImportError on tracked module rejected" $ok

# 13 — --expect match / miss
d=$(mkrepo)
out=$("$SCRIPT" "$d" "$VERIFY" --expect 'Ran [1-9][0-9]* test' 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "expect ok" || ok=1
check "13 --expect match accepted" $ok
out=$("$SCRIPT" "$d" "$VERIFY" --expect 'NEVER_PRINTED_XYZ' 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "does not match --expect" || ok=1
check "14 --expect miss rejected" $ok

# 15 — --red command replaces verify for the red run (case 3 shape would be rejected without it)
d=$(mkrepo); printf "$ADDCALC" > "$d/calc.py"
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "stay green" || ok=1
check "15a without --red the independent test is rejected" $ok
out=$("$SCRIPT" "$d" "$VERIFY" --red 'false' --code calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "red without code: yes" || ok=1
check "15b --red command is the one used for the red run" $ok

# 16 — --tests: removed assertion rejected
d=$(mkrepo)
printf 'import unittest\nclass T(unittest.TestCase):\n    def test_x(self):\n        pass\n' > "$d/tests/test_base.py"
out=$("$SCRIPT" "$d" "$VERIFY" --tests tests/test_base.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "removed assertions from tests/test_base.py" || ok=1
check "16 --tests removed assertion rejected" $ok

# 17 — --tests: added skip rejected
d=$(mkrepo)
printf 'import unittest\nclass T(unittest.TestCase):\n    @unittest.skip("later")\n    def test_x(self):\n        self.assertEqual(1, 1)\n' > "$d/tests/test_base.py"
out=$("$SCRIPT" "$d" "$VERIFY" --tests tests/test_base.py 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "skipped/focused tests in tests/test_base.py" || ok=1
check "17 --tests added skip rejected" $ok

# 18 — --tests untouched / strengthened accepted, combined with --code
d=$(mkrepo); printf "$ADDCALC" > "$d/calc.py"; addtest "$d" calc
out=$("$SCRIPT" "$d" "$VERIFY" --code calc.py --tests tests/test_base.py tests/test_calc.py 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "tests not weakened" || ok=1
check "18 --tests untouched/new files accepted alongside --code" $ok

# jest-style helper: tracked lib.js + t.test.js, step edits lib.js; t.sh prints $1 text when lib lacks NEW
mkjest() { # red-output-text
  local d; d="$(mkrepo)"
  (
    cd "$d" || exit 1
    echo 'module.exports=1' > lib.js
    printf 'const parts = s.split(",")\nexpect(parts.length).toBe(2)\nexpect(a).toBe(1)\n' > t.test.js
    printf 'if grep -q NEW lib.js; then echo "Tests: 1 passed, 1 total"; exit 0; fi\ncat red.txt; exit 1\n' > t.sh
    printf '%s\n' "$1" > red.txt
    git add -A && git commit -q -m jest
    echo 'module.exports=1 // NEW' > lib.js
  ) >/dev/null 2>&1
  echo "$d"
}

# 19 — jest "Test suite failed to run" + Cannot find module on tracked code: load failure, rejected
d=$(mkjest "$(printf 'FAIL t.test.js\n  ● Test suite failed to run\n\n    Cannot find module ./helper from t.test.js')")
out=$("$SCRIPT" "$d" 'bash t.sh' --code lib.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "failed to load, not on an assertion" || ok=1
check "19 jest load failure rejected" $ok

# 20 — SyntaxError: Unexpected token (case-insensitive 'Expected' must not count as assertion)
d=$(mkjest "$(printf 'FAIL t.test.js\n  ● Test suite failed to run\n\n    SyntaxError: Unexpected token <')")
out=$("$SCRIPT" "$d" 'bash t.sh' --code lib.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "failed to load, not on an assertion" || ok=1
check "20 SyntaxError Unexpected token rejected" $ok
d=$(mkjest "$(printf 'SyntaxError: Unexpected token <')")
out=$("$SCRIPT" "$d" 'bash t.sh' --code lib.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "failed to load, not on an assertion" || ok=1
check "20b SyntaxError Unexpected token alone rejected" $ok

# 21 — real jest assertion output accepted
d=$(mkjest "$(printf 'FAIL t.test.js\n  ● adds\n\n    expect(received).toBe(expected) // Object.is equality\n\n    Expected: 3\n    Received: 2')")
out=$("$SCRIPT" "$d" 'bash t.sh' --code lib.js 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "(assertion)" || ok=1
check "21 jest assertion failure accepted" $ok

# 22 — editing s.split(",") -> s.split(";") is not a weakening
d=$(mkjest "x")
git -C "$d" checkout -q lib.js
sed -i.bak 's/split(",")/split(";")/' "$d/t.test.js"; rm -f "$d/t.test.js.bak"
out=$("$SCRIPT" "$d" true --tests t.test.js 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && has "$out" "tests not weakened" || ok=1
check "22 split() edit not flagged" $ok

# 23 — editing an expect line (one removed, one added) is not flagged
sed -i.bak 's/toBe(2)/toBe(3)/' "$d/t.test.js"; rm -f "$d/t.test.js.bak"
out=$("$SCRIPT" "$d" true --tests t.test.js 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] || ok=1
check "23 edited expect line not flagged" $ok

# 24 — deleting one expect is flagged with the count
printf 'const parts = s.split(",")\nexpect(a).toBe(1)\n' > "$d/t.test.js"
out=$("$SCRIPT" "$d" true --tests t.test.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "removed assertions from t.test.js (1 fewer)" || ok=1
check "24 deleted expect flagged with count" $ok

# 24b — replacing an expect with a "// should …" comment is still a removed assertion
printf 'const parts = s.split(",")\nexpect(parts.length).toBe(2)\n// should be 1 later\n' > "$d/t.test.js"
out=$("$SCRIPT" "$d" true --tests t.test.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "removed assertions from t.test.js" || ok=1
check "24b expect swapped for a should-comment flagged" $ok

# 25 — new untracked test file with .only( is rejected
d=$(mkrepo)
printf 'it.only("x", () => { expect(1).toBe(1) })\n' > "$d/new.test.js"
out=$("$SCRIPT" "$d" true --tests new.test.js 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "skipped/focused tests in new.test.js" || ok=1
check "25 untracked test with .only rejected" $ok

[ $FAILS -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
[ $FAILS -eq 0 ]
