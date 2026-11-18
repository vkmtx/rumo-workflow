#!/usr/bin/env bash
# Tests for scripts/accept-wave.sh. Each case builds a fresh temp git repo with a plan in .rumo/plan.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/accept-wave.sh"
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
    mkdir tests docs .rumo
    printf '.env*\n*.log\n__pycache__/\n' > .gitignore
    printf 'def sub(a, b):\n    return a - b\n' > calc.py
    printf 'notes\n' > docs/notes.md
    printf 'import unittest\nclass T(unittest.TestCase):\n    def test_x(self):\n        self.assertEqual(1, 1)\n' > tests/test_base.py
    git add -A && git commit -q -m base
  ) >/dev/null 2>&1
  echo "$d"
}

check() { # name condition-exit
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2"; }
last() { printf '%s\n' "$1" | tail -n 1; }
ncommits() { git -C "$1" rev-list --count HEAD; }
names() { git -C "$1" show --name-only --format= "$2" | LC_ALL=C sort | tr '\n' ' '; }

addtest() { # dir module
  printf 'import unittest, sys\nsys.path.insert(0, ".")\nimport %s\nclass T(unittest.TestCase):\n    def test_y(self):\n        self.assertEqual(%s.add(1, 2), 3)\n' "$2" "$2" > "$1/tests/test_$2.py"
}
# the two builders' work: step 1 edits calc.py + its test, step 2 creates newmod.py + its test
build1() { printf 'def sub(a, b):\n    return a - b\ndef add(a, b):\n    return a + b\n' > "$1/calc.py"; addtest "$1" calc; }
build2() { printf 'def add(a, b):\n    return a + b\n' > "$1/newmod.py"; addtest "$1" newmod; }

mkplan() { # dir [step1 Files value]
  local f1=${2:-'`calc.py`, `tests/test_calc.py` (create)'}
  cat > "$1/.rumo/plan.md" <<EOF
# Plan: add things

## Steps

### Step 1: add to calc
- Files: $f1
- Does: adds add()
- Test first: tests/test_calc.py
- Verify: \`python3 -m unittest tests/test_calc.py\` → OK
- Type: cmd
- Risk: none
- Category: api
- Parallel with: 2
- Model: sonnet — step one

### Step 2: new module
- Files:
  - \`newmod.py\` (create)
  - tests/test_newmod.py (create)
- Does: adds newmod.add()
- Test first: tests/test_newmod.py
- Verify: \`python3 -m unittest tests/test_newmod.py\` → OK
- Type: cmd
- Risk: none
- Category: api
- Parallel with: 1
- Model: sonnet — step two

### Step 3: notes
- Files: docs/notes.md
- Does: documents it
- Test first: none
- Verify: \`grep -q add docs/notes.md\` → exit 0
- Type: judgment
- Risk: none
- Category: docs
- Parallel with: —
- Model: orchestrator — judgment

### Step 4: done already
- Files: docs/old.md
- Does: nothing
- Test first: none
- Verify: \`true\` → exit 0
- Type: judgment
- Risk: none
- Category: docs
- Parallel with: —
- Model: orchestrator — judgment
- Done: abc1234

## Waves

\`[1,2] → [3]\`
EOF
}

# a
d=$(mkrepo); mkplan "$d"; build1 "$d"; build2 "$d"; echo x > "$d/stray.txt"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" "2=feat: two" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "^WAVE FAIL scope stray.txt — " && [ "$(ncommits "$d")" = "$n" ] \
  && ! grep -q -- '- Done: [0-9a-f]\{7\}$' <(sed -n '1,/### Step 4/p' "$d/.rumo/plan.md") && ! has "$out" "ACCEPT" || ok=1
check "a path outside every step's Files: scope fail, exit 1, no commit" $ok

# b
d=$(mkrepo); mkplan "$d" '`calc.py`, `tests/test_calc.py` (create), newmod.py'; build1 "$d"; build2 "$d"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" "2=feat: two" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "^WAVE FAIL scope newmod.py — " && [ "$(ncommits "$d")" = "$n" ] || ok=1
check "b path listed by two named steps: scope fail" $ok

# c — an ignored .env* fails scope only when born after the plan file
d=$(mkrepo); echo 'K=v' > "$d/.env.local"; sleep 1; mkplan "$d"; build1 "$d"; build2 "$d"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" "2=feat: two" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ "$(last "$out")" = "WAVE OK 2/2" ] && ! has "$out" "WAVE FAIL scope" \
  && [ "$(ncommits "$d")" = "$((n+2))" ] && [ -f "$d/.env.local" ] || ok=1
check "c ignored .env.local created before the plan: wave accepted" $ok
if python3 -I -c 'import os, sys; sys.exit(0 if hasattr(os.stat("."), "st_birthtime") else 1)'; then
  d=$(mkrepo); mkplan "$d"; sleep 1; build1 "$d"; build2 "$d"; echo 'K=v' > "$d/.env.local"; n=$(ncommits "$d")
  out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" "2=feat: two" 2>&1); rc=$?
  ok=0; [ $rc -eq 1 ] && has "$out" "^WAVE FAIL scope .env.local — .*after the plan" && [ "$(ncommits "$d")" = "$n" ] \
    && ! has "$out" "ACCEPT" || ok=1
  check "c ignored .env.local created after the plan: scope fail" $ok
else
  echo "SKIP: c ignored .env.local created after the plan: scope fail (no birth time on this platform)"
fi

# d
d=$(mkrepo); mkplan "$d"; cp "$d/.rumo/plan.md" "$ROOT/copy-d.md"; build1 "$d"; build2 "$d"; echo noise > "$d/debug.log"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" --copy "$ROOT/copy-d.md" "1=feat: one" "2=feat: two" 2>&1); rc=$?
s1=$(git -C "$d" rev-parse --short HEAD~1 2>/dev/null); s2=$(git -C "$d" rev-parse --short HEAD 2>/dev/null)
ok=0; [ $rc -eq 0 ] && [ "$(last "$out")" = "WAVE OK 2/2" ] && [ "$(ncommits "$d")" = "$((n+2))" ] || ok=1
check "d two steps accepted: WAVE OK 2/2, exit 0, two commits" $ok
ok=0; [ "$(names "$d" HEAD~1)" = "calc.py tests/test_calc.py " ] && [ "$(names "$d" HEAD)" = "newmod.py tests/test_newmod.py " ] \
  && [ "$(git -C "$d" log -1 --format=%s HEAD~1)" = "feat: one" ] && [ "$(git -C "$d" log -1 --format=%s HEAD)" = "feat: two" ] \
  && [ -z "$(git -C "$d" status --porcelain -- . ':!.rumo')" ] && [ -f "$d/debug.log" ] || ok=1
check "d each commit holds only its own Files, with its message" $ok
ok=0; has "$out" "^STEP 1 ACCEPT OK $s1\$" && has "$out" "^STEP 2 ACCEPT OK $s2\$" || ok=1
check "d STEP lines carry the short shas" $ok
for f in "$d/.rumo/plan.md" "$ROOT/copy-d.md"; do
  ok=0; [ "$(grep -A1 -- '- Model: sonnet — step one' "$f" | tail -n 1)" = "- Done: $s1" ] \
    && [ "$(grep -A1 -- '- Model: sonnet — step two' "$f" | tail -n 1)" = "- Done: $s2" ] \
    && [ "$(grep -c -- '^- Done: ' "$f")" = 3 ] || ok=1
  check "d Done lines right after each step's last field in $(basename "$f")" $ok
done

# e
d=$(mkrepo); mkplan "$d"; build1 "$d"; build2 "$d"; n=$(ncommits "$d")
printf 'import unittest\nclass T(unittest.TestCase):\n    def test_y(self):\n        self.assertEqual(1, 1)\n' > "$d/tests/test_newmod.py"
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "2=feat: two" "1=feat: one" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "^STEP 2 ACCEPT FAIL: .*stay green" && has "$out" "^STEP 1 ACCEPT OK " \
  && [ "$(last "$out")" = "WAVE FAIL 1/2 — rejected: 2" ] || ok=1
check "e green-without-code step rejected, sibling accepted: WAVE FAIL 1/2, exit 1" $ok
ok=0; [ "$(ncommits "$d")" = "$((n+1))" ] && [ "$(names "$d" HEAD)" = "calc.py tests/test_calc.py " ] \
  && [ "$(git -C "$d" status --porcelain --untracked-files=all -- . ':!.rumo' | LC_ALL=C sort | tr '\n' ' ')" = "?? newmod.py ?? tests/test_newmod.py " ] \
  && [ "$(grep -c -- '^- Done: ' "$d/.rumo/plan.md")" = 2 ] && [ -z "$(git -C "$d" stash list)" ] || ok=1
check "e rejected step's files left uncommitted, no Done line for it" $ok

# f
d=$(mkrepo); mkplan "$d"; echo x > "$d/docs/old.md"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "4=docs: old" 2>&1); rc=$?
ok=0; [ $rc -eq 2 ] && [ "$(ncommits "$d")" = "$n" ] || ok=1
check "f step already Done: exit 2" $ok
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "9=docs: nine" 2>&1); rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "f unknown step: exit 2" $ok
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" 2>&1); rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "f no step given: exit 2" $ok

# g — `(create)` + backticks + sub-bullets parsed: only step 2 named, step 1's files untouched
d=$(mkrepo); mkplan "$d"; build2 "$d"
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "2=feat: two" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ "$(last "$out")" = "WAVE OK 1/1" ] && [ "$(names "$d" HEAD)" = "newmod.py tests/test_newmod.py " ] || ok=1
check "g (create) and backticked sub-bullet Files parse" $ok
d=$(mkrepo); mkplan "$d"; build1 "$d"
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ "$(names "$d" HEAD)" = "calc.py tests/test_calc.py " ] || ok=1
check "g (create) and backticked comma Files parse" $ok

# h — Expect line becomes --expect
d=$(mkrepo); mkplan "$d"; build1 "$d"; n=$(ncommits "$d")
sed -i.bak 's/^- Model: sonnet — step one$/&\
- Expect: NEVER_PRINTED_[0-9]+/' "$d/.rumo/plan.md"; rm -f "$d/.rumo/plan.md.bak"
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "1=feat: one" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "^STEP 1 ACCEPT FAIL: .*--expect" && [ "$(ncommits "$d")" = "$n" ] \
  && [ "$(last "$out")" = "WAVE FAIL 0/1 — rejected: 1" ] || ok=1
check "h Expect line is passed as --expect" $ok

# i — judgment step with no test file: Verify alone
d=$(mkrepo); mkplan "$d"; echo 'add documented' >> "$d/docs/notes.md"
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "3=docs: notes" 2>&1); rc=$?
ok=0; [ $rc -eq 0 ] && [ "$(last "$out")" = "WAVE OK 1/1" ] && [ "$(names "$d" HEAD)" = "docs/notes.md " ] || ok=1
check "i judgment step accepted on Verify exit 0" $ok
d=$(mkrepo); mkplan "$d"; echo 'nothing relevant' >> "$d/docs/notes.md"; n=$(ncommits "$d")
out=$(bash "$SCRIPT" "$d" "$d/.rumo/plan.md" "3=docs: notes" 2>&1); rc=$?
ok=0; [ $rc -eq 1 ] && has "$out" "^STEP 3 ACCEPT FAIL: " && [ "$(ncommits "$d")" = "$n" ] || ok=1
check "i judgment step rejected on Verify exit 1" $ok

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILED"; exit 1; fi
echo "ALL PASS"
