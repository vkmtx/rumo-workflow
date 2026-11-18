#!/usr/bin/env bash
# Run: bash tests/test_all_test.sh — builds throwaway trees (no .git), exit 1 on any FAIL.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/test-all.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a/tests" "$T/h/tests"
printf 'exit 0\n' > "$T/a/tests/pass_test.sh"; printf 'echo boom\nexit 1\n' > "$T/a/tests/fail_test.sh"; printf 'import sys\nsys.exit(0)\n' > "$T/a/tests/ok_test.py"
for n in guard py lone; do printf 'echo "${HOOK-unset}" > "%s/h/%s.out"\n' "$T" "$n" > "$T/h/tests/$n.test.sh"; done
: > "$T/h/guard.sh"; : > "$T/h/py.py"
out=$(HOOK=/inherited bash "$S" --root "$T" 2>/dev/null); rc=$?
ok "mixed tree exits 1" '[ $rc -eq 1 ]'
ok "failing test reported" 'grep -qx "FAIL a/tests/fail_test.sh" <<<"$out"'
ok "passing .sh reported" 'grep -qx "PASS a/tests/pass_test.sh" <<<"$out"'
ok "passing .py reported" 'grep -qx "PASS a/tests/ok_test.py" <<<"$out"'
ok "sibling .sh → HOOK" '[ "$(cat "$T/h/guard.out")" = "$T/h/guard.sh" ]'
ok "sibling .py → HOOK" '[ "$(cat "$T/h/py.out")" = "$T/h/py.py" ]'
ok "no sibling → HOOK unset (inherited cleared)" '[ "$(cat "$T/h/lone.out")" = unset ]'
ok "no .git created" '[ ! -e "$T/.git" ]'
err=$(bash "$S" --root "$T" 2>&1 >/dev/null)
ok "FAIL prints indented log tail to stderr" 'grep -qx "    boom" <<<"$err"'
T2=$(mktemp -d); mkdir -p "$T2/x/tests"; printf 'exit 0\n' > "$T2/x/tests/p_test.sh"
bash "$S" --root "$T2" >/dev/null 2>&1; ok "all-pass tree exits 0" '[ $? -eq 0 ]'
T3=$(mktemp -d); bash "$S" --root "$T3" >/dev/null 2>&1; rc3=$?
ok "empty tree exits 1" '[ $rc3 -eq 1 ]'
bash "$S" --bogus >/dev/null 2>&1; ok "unknown arg exits 2" '[ $? -eq 2 ]'
rm -rf "$T2" "$T3"
T4=$(mktemp -d); mkdir -p "$T4/s/tests"; printf 'exit 77\n' > "$T4/s/tests/skip_test.sh"; printf 'exit 0\n' > "$T4/s/tests/p_test.sh"
out4=$(bash "$S" --root "$T4" 2>/dev/null); rc4=$?
ok "exit 77 prints SKIP" 'grep -qx "SKIP s/tests/skip_test.sh" <<<"$out4"'
ok "SKIP does not fail the run" '[ $rc4 -eq 0 ]'
T5=$(mktemp -d); mkdir -p "$T5/n/tests" "$T5/n/sub/tests"; printf 'exit 0\n' > "$T5/n/tests/pass_test.sh"; printf 'gitdir: x\n' > "$T5/n/sub/.git"; printf 'exit 1\n' > "$T5/n/sub/tests/other_test.sh"
out5=$(bash "$S" --root "$T5" 2>&1); rc5=$?
ok "nested checkout tests dropped, run passes" '[ $rc5 -eq 0 ]'
ok "nested checkout not mentioned" '! grep -q "n/sub/" <<<"$out5"'
T6=$(mktemp -d); mkdir -p "$T6/g/sub/.git" "$T6/g/sub/tests"; printf 'exit 0\n' > "$T6/g/sub/tests/x_test.sh"
out6=$(bash "$S" --root "$T6" 2>&1); rc6=$?
ok "only-nested-checkout tree exits 1" '[ $rc6 -eq 1 ]'
ok "only-nested-checkout reports no tests" 'grep -q "^FAIL no tests found" <<<"$out6"'
rm -rf "$T4" "$T5" "$T6"
exit $fail
