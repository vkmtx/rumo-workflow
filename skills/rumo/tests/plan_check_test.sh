#!/usr/bin/env bash
# Tests for scripts/plan-check.sh. Each case writes a fixture plan to a temp dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/plan-check.sh"
FAILS=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

BASE='# Plan: fixture

## Steps

### Step 1: first
- Files: a.sh, b.sh (create)
- Does: one
- Test first: t1
- Verify: `bash a.sh` → ok
- Type: cmd
- Risk: none
- Category: docs
- Parallel with: 2
- Model: sonnet — all four conditions hold

### Step 2: second
- Files: c.py
- Does: two
- Test first: t2
- Verify: `python3 c.py` -> fine
- Type: cmd
- Risk: auth
- Category: auth
- Parallel with: 1
- Model: opus — (4) auth

### Step 3: third
- Files: `ui.tsx`
- Does: three
- Test first: t3
- Verify: `screenshot` → looks right
- Type: visual
- Risk: none
- Category: ui-logic
- Parallel with: —
- Model: orchestrator

## Waves
`[1,2],[3]`
'

# expect <name> <plan-text> <exit> <substring>
expect() {
  local name="$1" text="$2" want="$3" sub="$4"
  printf '%s\n' "$text" > "$ROOT/p.md"
  local out rc
  out=$("$SCRIPT" "$ROOT/p.md" 2>&1); rc=$?
  local ok=0
  [ $rc -eq "$want" ] && has "$out" "$sub" || ok=1
  [ $ok -ne 0 ] && echo "  rc=$rc out=$out"
  check "$name" $ok
}
# expect_small: same as expect, with the --small flag
expect_small() {
  local name="$1" text="$2" want="$3" sub="$4"
  printf '%s\n' "$text" > "$ROOT/p.md"
  local out rc
  out=$("$SCRIPT" --small "$ROOT/p.md" 2>&1); rc=$?
  local ok=0
  [ $rc -eq "$want" ] && has "$out" "$sub" || ok=1
  [ $ok -ne 0 ] && echo "  rc=$rc out=$out"
  check "$name" $ok
}
# variant <old> <new>: replace first occurrence in BASE
variant() { local o="$1" n="$2"; printf '%s' "${BASE/"$o"/$n}"; }

expect "valid 3-step plan" "$BASE" 0 "PLAN OK: 3 steps — sonnet 1 · opus 1 · orchestrator 1"
printf '%s\n' "$BASE" > "$ROOT/p.md"; out=$("$SCRIPT" "$ROOT/p.md" 2>&1)
ok=0; [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && has "$out" "PLAN OK" || ok=1
check "valid plan prints exactly one line" $ok

expect "missing field" "$(variant '- Does: one
' '')" 1 "PLAN FAIL: Step 1: Does: missing"
expect "files glob *" "$(variant 'Files: a.sh, b.sh' 'Files: a.sh, src/*.sh')" 1 "PLAN FAIL: Step 1: Files:"
expect "files glob ?" "$(variant 'Files: a.sh, b.sh' 'Files: a.sh, sr?.sh')" 1 "PLAN FAIL: Step 1: Files:"
expect "files .." "$(variant 'Files: a.sh, b.sh' 'Files: a.sh, ../x.sh')" 1 "PLAN FAIL: Step 1: Files:"
expect "files trailing /" "$(variant 'Files: a.sh, b.sh' 'Files: a.sh, src/')" 1 "PLAN FAIL: Step 1: Files:"
expect "verify without command" "$(variant '`bash a.sh` → ok' 'bash a.sh → ok')" 1 "PLAN FAIL: Step 1: Verify:"
expect "verify without arrow" "$(variant '`bash a.sh` → ok' '`bash a.sh`')" 1 "PLAN FAIL: Step 1: Verify:"
expect "type invalid" "$(variant 'Type: cmd' 'Type: shell')" 1 "PLAN FAIL: Step 1: Type:"
expect "risk invalid token" "$(variant 'Risk: auth' 'Risk: auth, bogus')" 1 "PLAN FAIL: Step 2: Risk:"
expect "category invalid" "$(variant 'Category: docs' 'Category: stuff')" 1 "PLAN FAIL: Step 1: Category:"
expect "model invalid" "$(variant 'Model: sonnet' 'Model: haiku')" 1 "PLAN FAIL: Step 1: Model:"
expect "visual needs orchestrator" "$(variant 'Model: orchestrator' 'Model: sonnet — all four conditions hold')" 1 "PLAN FAIL: Step 3: Model:"
expect "sonnet with risk" "$(variant 'Risk: none' 'Risk: money')" 1 "PLAN FAIL: Step 1: Model:"
expect "opus cites nothing" "$(variant 'Model: opus — (4) auth' 'Model: opus — because')" 1 "PLAN FAIL: Step 2: Model:"
expect "opus risk without (4)" "$(variant 'Model: opus — (4) auth' 'Model: opus — (2) auth')" 1 "PLAN FAIL: Step 2: Model:"
expect "opus risk none cites (4)" "$(variant 'Risk: auth' 'Risk: none')" 1 "PLAN FAIL: Step 2: Model:"
expect "opus risk none cites (2) ok" "$(variant 'Risk: auth' 'Risk: none' | sed 's/(4) auth/(2) vague/')" 0 "PLAN OK"
expect "parallel names missing step" "$(variant 'Parallel with: 2' 'Parallel with: 9')" 1 "PLAN FAIL: Step 1: Parallel with:"
expect "parallel shares file" "$(variant 'Files: c.py' 'Files: c.py, b.sh')" 1 "PLAN FAIL: Step 1: Parallel with: shares b.sh with Step 2"

# --- calibration against real-world plan formats ---
# 1 header separators
expect "header: em dash" "$(variant '### Step 3: third' '### Step 3 — third')" 0 "PLAN OK: 3 steps"
expect "header: en dash" "$(variant '### Step 3: third' '### Step 3 – third')" 0 "PLAN OK: 3 steps"
expect "header: hyphen" "$(variant '### Step 3: third' '### Step 3 - third')" 0 "PLAN OK: 3 steps"
# 2 field name followed by a parenthetical
expect "field with parenthetical" "$(variant '- Test first: t1' '- Test first (`auth.test.ts`, red on missing module): t1')" 0 "PLAN OK: 3 steps"
expect "missing field still caught with parenthetical siblings" "$(variant '- Does: one
' '' | sed 's/^- Test first: t2/- Test first (x): t2/')" 1 "PLAN FAIL: Step 1: Does: missing"
# 3 continuation lines
expect "verify on nested bullets" "$(variant '- Verify: `bash a.sh` → ok' '- Verify:
  - `bash a.sh` → ok')" 0 "PLAN OK: 3 steps"
expect "verify nested bullets without expected" "$(variant '- Verify: `bash a.sh` → ok' '- Verify:
  - `bash a.sh`')" 1 "PLAN FAIL: Step 1: Verify:"
expect "indented line does not become a field" "$(variant '- Does: one' '- Does: one
  - Risk: money')" 0 "PLAN OK: 3 steps"
# 4 Risk and Category with trailing explanation
expect "risk: data — explanation" "$(variant 'Risk: auth' 'Risk: data — edits the Prisma model')" 0 "PLAN OK"
expect "risk: security (paren)" "$(variant 'Risk: auth' 'Risk: security (public endpoint)' | sed 's/^- Test first: t2$/- Test first: t2 hook: n\/a — no hook; third-party input: fork; check-to-use: HEAD moves; deletion: none/')" 0 "PLAN OK"
expect "risk: none (paren)" "$(variant 'Risk: none' 'Risk: none (local files only)')" 0 "PLAN OK"
expect "risk: semicolon" "$(variant 'Risk: auth' 'Risk: auth, data; see notes')" 0 "PLAN OK"
expect "risk: bad token with explanation" "$(variant 'Risk: auth' 'Risk: auth, bogus (why)')" 1 "PLAN FAIL: Step 2: Risk:"
expect "category: other (paren)" "$(variant 'Category: docs' 'Category: other (prompt)')" 0 "PLAN OK"
# 5 Parallel with prose
expect "parallel: dash plus parenthetical with a number" "$(variant 'Parallel with: —' 'Parallel with: —  (Verify needs the DB and fixed port 4380)')" 0 "PLAN OK"
expect "parallel: id then explanation" "$(variant 'Parallel with: 2' 'Parallel with: 2 (no overlap) — port 4380 is free')" 0 "PLAN OK"
# 6 Verify rule only for sonnet|opus; word-based expected result
expect "orchestrator verify by prose" "$(variant 'Verify: `screenshot` → looks right' 'Verify: screenshot of desktop and mobile, read both')" 0 "PLAN OK"
expect "sonnet verify with word expected" "$(variant 'Verify: `bash a.sh` → ok' 'Verify: `bash a.sh` exits 0')" 0 "PLAN OK"
expect "opus verify with PASS word" "$(variant 'Verify: `python3 c.py` -> fine' 'Verify: `python3 c.py` → every line PASS' | sed 's/→ every line PASS/prints PASS/')" 0 "PLAN OK"
expect "verify word only inside backticks" "$(variant 'Verify: `bash a.sh` → ok' 'Verify: `echo pass`')" 1 "PLAN FAIL: Step 1: Verify:"

# --- review fixes ---
# files annotations: parentheticals never glue onto or split a path
expect "files: annotation does not hide a shared path" "$(variant 'Files: a.sh, b.sh (create)' 'Files: `src/a.ts` (only the `<style>` block), `src/b.ts`' | sed 's/^- Files: c.py/- Files: `src\/a.ts`/')" 1 "PLAN FAIL: Step 1: Parallel with: shares src/a.ts with Step 2"
expect "files: annotations (delete)(generated)(git mv)" "$(variant 'Files: a.sh, b.sh (create)' 'Files: a.sh (delete), b.sh (generated), c1.sh (`git mv`)')" 0 "PLAN OK"
# fenced blocks
expect "fence: # comment and field-lookalike inside fence" "$(variant '- Does: one' '- Does: one
```bash
# usage: x.sh
- Risk: money
### Step 9: not a step
```')" 0 "PLAN OK: 3 steps"
# ranges
for r in '1–3' '1-3' '1..3'; do
  expect "parallel range $r includes the middle step" "$(variant 'Files: `ui.tsx`' 'Files: `ui.tsx`, c.py' | sed "s/^- Parallel with: —\$/- Parallel with: $r/")" 1 "shares c.py with Step 2"
done
expect "parallel range expands (missing member)" "$(variant 'Parallel with: 2' 'Parallel with: 2..9')" 1 "PLAN FAIL: Step 1: Parallel with: step 9 does not exist"

# route-group paths keep their parentheses; only annotations are stripped
expect "files: route groups are distinct paths" "$(variant 'Files: a.sh, b.sh (create)' 'Files: src/app/(auth)/page.tsx (create)' | sed 's/^- Files: c.py/- Files: `src\/app\/(shop)\/page.tsx`/')" 0 "PLAN OK"
expect "files: shared route-group path names the full path" "$(variant 'Files: a.sh, b.sh (create)' 'Files: src/app/(auth)/page.tsx' | sed 's/^- Files: c.py/- Files: `src\/app\/(auth)\/page.tsx` (only the head)/')" 1 "shares src/app/(auth)/page.tsx with Step 2"
# 7 numeric steps
P="# Plan"$'\n'
for i in 1 2 3 4 5 6 7; do
  P+="
### Step $i: s$i
- Files: f$i.sh
- Does: d
- Test first: t
- Verify: \`true\` → ok
- Type: cmd
- Risk: none
- Category: docs
- Parallel with: —
- Model: sonnet — all four conditions hold
"
done
expect "7 steps" "$P" 1 "PLAN FAIL: plan: 7 steps (max 6 — split the issue)"
# 6 numeric + F1 is fine
P6="${P%%### Step 7:*}"
P6+="
### Step F1: fix
- Files: g.sh
- Does: d
- Test first: t
- Verify: \`true\` → ok
- Type: cmd
- Risk: none
- Category: docs
- Parallel with: none
- Model: sonnet — all four conditions hold
"
expect "6 steps + F1 ok" "$P6" 0 "PLAN OK: 7 steps — sonnet 7 · opus 0 · orchestrator 0"
expect "no steps" "# Plan

nothing here" 1 "PLAN FAIL: plan: no steps"

# 8 size cap
PAD30=$(head -c 30000 /dev/zero | tr '\0' 'x')
expect "plan of 30k characters fails citing the cap" "$BASE
## Notes
$PAD30" 1 "characters (max 24000"
PAD23=$(head -c 23000 /dev/zero | tr '\0' 'x')
expect "plan under 24000 characters passes" "$BASE
## Notes
$PAD23" 0 "PLAN OK: 3 steps"

# 9 --small limits (2 steps, 8000 characters)
TWO="${BASE%%### Step 3*}"
PAD7=$(head -c 6573 /dev/zero | tr '\0' 'x')
PAD9=$(head -c 8573 /dev/zero | tr '\0' 'x')
expect_small "small: 2 steps, 7000 characters passes" "$TWO
## Notes
$PAD7" 0 "PLAN OK: 2 steps"
expect_small "small: 3 steps fails citing max 2" "$BASE" 1 "steps (max 2"
expect_small "small: step failure names the way out" "$BASE" 1 "NOT SMALL"
expect_small "small: 9000 characters fails citing max 8000" "$TWO
## Notes
$PAD9" 1 "characters (max 8000"
expect "without --small a 9000-character plan passes" "$TWO
## Notes
$PAD9" 0 "PLAN OK: 2 steps"

# --- abuse cases (#113) ---
# s1 <does> <files> <risk> <test-first> <model>: BASE with Step 1's fields replaced
s1() {
  local t="$BASE"
  t="${t/"- Does: one"/- Does: $1}"
  t="${t/"- Files: a.sh, b.sh (create)"/- Files: $2}"
  t="${t/"- Risk: none"/- Risk: $3}"
  t="${t/"- Test first: t1"/- Test first: $4}"
  t="${t/"- Model: sonnet — all four conditions hold"/- Model: $5}"
  printf '%s' "$t"
}
SON='sonnet — all four conditions hold'
OPUS='opus — (4) security'
LABELS='hook: n/a — none; third-party input: fork; check-to-use: HEAD moves; deletion: only the temp dir'
# abuse: a triggered step without security fails Rule A
expect "abuse: git push with Risk none" "$(s1 'runs git push origin HEAD' 'a.sh' 'none' 't1' "$SON")" 1 "PLAN FAIL: Step 1: Risk: push/merge/deploy/delete/shell/hook step ('git push') needs security"
expect "abuse: gh pr merge with Risk none" "$(s1 'calls gh pr merge --squash' 'a.sh' 'none' 't1' "$SON")" 1 "PLAN FAIL: Step 1: Risk: push/merge/deploy/delete/shell/hook step ('gh pr merge') needs security"
expect "abuse: rm -rf with Risk none" "$(s1 'cleans up with rm -rf "$dir"' 'a.sh' 'none' 't1' "$SON")" 1 "PLAN FAIL: Step 1: Risk: push/merge/deploy/delete/shell/hook step ('rm -rf') needs security"
expect "abuse: shell=True with Risk none" "$(s1 'runs subprocess.run(cmd, shell=True)' 'a.sh' 'none' 't1' "$SON")" 1 "PLAN FAIL: Step 1: Risk: push/merge/deploy/delete/shell/hook step ('shell=True') needs security"
expect "abuse: hook path with Risk none" "$(s1 'one' 'scripts/hooks-staged/guard.py' 'none' 't1' "$SON")" 1 "PLAN FAIL: Step 1: Risk: push/merge/deploy/delete/shell/hook step ('scripts/hooks-staged/guard.py') needs security"
expect "abuse: auth risk is not security" "$(s1 'runs git push' 'a.sh' 'auth' "t1 $LABELS" 'opus — (4) auth')" 1 "needs security"
# abuse (fix round 1): hook config files trigger
expect "abuse: hooks/hooks.json with Risk none" "$(s1 'one' 'hooks/hooks.json' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: .claude/settings.json with Risk none" "$(s1 'one' '.claude/settings.json' 'none' 't1' "$SON")" 1 "needs security"
# abuse (fix round 1): git global options and common deletes trigger
expect "abuse: git -C dir push" "$(s1 'pushes with git -C "$wt" push -u origin HEAD' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: git --no-pager push" "$(s1 'runs git --no-pager push' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: git worktree remove" "$(s1 'runs git worktree remove "$wt"' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: git branch -D" "$(s1 'runs git branch -D feat/x' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: find -delete" "$(s1 'runs find "$d" -name x -delete' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: plain rm" "$(s1 'runs rm "$plan"' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: shred" "$(s1 'runs shred -u f' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "abuse: git rm" "$(s1 'runs git rm f' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
# fix round 1: read-only false positives stay quiet
expect "quiet: git merge-base" "$(s1 'checks ancestry with git merge-base --is-ancestor' 'a.sh' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "quiet: planner eval case" "$(s1 'adds a planner eval case' 'a.sh' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "abuse: eval( from input" "$(s1 'calls eval(user_input) on the payload' 'a.sh' 'none' 't1' "$SON")" 1 "needs security"
expect "quiet: docker --rm" "$(s1 'runs docker run --rm image' 'a.sh' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "quiet: rm in prose" "$(s1 'documents that rm is never used' 'a.sh' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "quiet: deployment URL" "$(s1 'notes the deployment URL' 'a.sh' 'none' 't1' "$SON")" 0 "PLAN OK"
# abuse: a security step without abuse cases first fails Rule B
expect "abuse: labels after happy:" "$(s1 'runs git push' 'a.sh' 'security' "happy: pushes; $LABELS" "$OPUS")" 1 "PLAN FAIL: Step 1: Test first: abuse cases must come before happy:"
expect "abuse: lacks check-to-use:" "$(s1 'runs git push' 'a.sh' 'security' 'hook: n/a — x; third-party input: fork; deletion: none' "$OPUS")" 1 "PLAN FAIL: Step 1: Test first: security step lacks abuse cases check-to-use:"
expect "abuse: lacks all four" "$(s1 'runs git push' 'a.sh' 'security' 't1' "$OPUS")" 1 "lacks abuse cases hook:, third-party input:, check-to-use:, deletion:"
expect "abuse: untriggered security step still needs labels" "$(s1 'one' 'a.sh' 'security' 't1' "$OPUS")" 1 "PLAN FAIL: Step 1: Test first: security step lacks abuse cases"
expect "abuse: uppercase labels count" "$(s1 'runs git push' 'a.sh' 'security' 'HOOK: n/a — x; THIRD-PARTY INPUT: fork; CHECK-TO-USE: HEAD; DELETION: none' "$OPUS")" 0 "PLAN OK"
# abuse (#115): every label needs a case or n/a — <why>
expect "abuse: all four labels empty" "$(s1 'runs git push' 'a.sh' 'security' 'hook: third-party input: check-to-use: deletion: happy: pushes' "$OPUS")" 1 "PLAN FAIL: Step 1: Test first: empty abuse case hook:, third-party input:, check-to-use:, deletion:"
expect "abuse: template placeholder" "$(s1 'runs git push' 'a.sh' 'security' 'abuse cases first — `hook:` `third-party input:` `check-to-use:` `deletion:` (`n/a — <why>` when one does not apply), then `happy:`' "$OPUS")" 1 "empty abuse case hook:, third-party input:, check-to-use:"
expect "abuse: bare n/a" "$(s1 'runs git push' 'a.sh' 'security' 'hook: n/a; third-party input: fork; check-to-use: HEAD moves; deletion: none' "$OPUS")" 1 "Test first: empty abuse case hook: ("
expect "abuse: one empty label in the middle" "$(s1 'runs git push' 'a.sh' 'security' 'hook: n/a — x; third-party input: ; check-to-use: HEAD; deletion: none' "$OPUS")" 1 "Test first: empty abuse case third-party input: ("
expect "abuse: webhook: is not the hook: label" "$(s1 'runs git push' 'a.sh' 'security' 'third-party input: a webhook: payload; hook: ; check-to-use: HEAD; deletion: none; happy: x' "$OPUS")" 1 "Test first: empty abuse case hook: ("
expect "abuse: dash before a bare n/a" "$(s1 'runs git push' 'a.sh' 'security' 'hook: — n/a; third-party input: fork; check-to-use: HEAD; deletion: none; happy: x' "$OPUS")" 1 "Test first: empty abuse case hook: ("
expect "happy: n/a with a reason passes" "$(s1 'runs git push' 'a.sh' 'security' 'hook: n/a — no hook reads a.sh; third-party input: n/a — local only; check-to-use: HEAD moves; deletion: n/a — nothing is deleted; happy: pushes' "$OPUS")" 0 "PLAN OK"
# happy
expect "happy: security step, labels on continuation lines, then happy:" "$(s1 'runs git push origin HEAD' 'a.sh' 'security' 'in a_test.sh —
  hook: n/a — not a hook
  third-party input: a fork PR
  check-to-use: HEAD moves
  deletion: never the user config
  happy: pushes' "$OPUS")" 0 "PLAN OK"
expect "happy: .md-only Files exempt" "$(s1 'documents git push' 'docs/a.md, README.md' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "happy: React hooks dir is not a hook dir" "$(s1 'one' 'src/hooks/useX.ts' 'none' 't1' "$SON")" 0 "PLAN OK"
expect "happy: prod, security with labels" "$(s1 'runs gh pr create' 'a.sh' 'prod, security' "$LABELS; happy: ok" "$OPUS")" 0 "PLAN OK"
expect "happy: deploy word in Does with security" "$(s1 'deploys to vercel' 'a.sh' 'security' "$LABELS" "$OPUS")" 0 "PLAN OK"

"$SCRIPT" "$ROOT/nope.md" >/dev/null 2>&1; rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "missing file exits 2" $ok
"$SCRIPT" >/dev/null 2>&1; rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "no args exits 2" $ok
"$SCRIPT" --small >/dev/null 2>&1; rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "--small with no plan exits 2" $ok

echo
if [ $FAILS -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
