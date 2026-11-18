#!/usr/bin/env bash
# accept-step.sh - accept one plan step only if its Verify command passes,
# actually runs tests, and goes RED when the step's code changes are removed.
#
# Usage: accept-step.sh <worktree> '<verify command>'
#          [--expect '<ERE>'] [--red '<command>'] [--code <file> ...] [--tests <file> ...]
#   --code files are relative to the worktree; test files are NOT passed here.
#   --tests files (worktree-relative) are the test files the step touched; each
#   list (--code / --tests) runs until the next -- option.
#
# Checks, in order:
#   tests not weakened  each --tests file: fewer assertion-bearing lines than HEAD
#                       (expect(/it(/test(/describe( word-bounded, assert, assertXxx(,
#                       should; counts compared, so an edited assertion passes), or an
#                       added .skip( .only( xit( xdescribe( @pytest.mark.skip
#                       @unittest.skip .todo( -> reject (untracked files: whole file
#                       counts as added). Runs before the green run.
#   verify              the Verify command must exit 0
#   zero-test           and must not report zero tests
#   --expect            green output must match the ERE (grep -E)
#   red without code    with --code files stashed, the --red command (default: the
#                       Verify command) must FAIL. A load failure (Cannot find module,
#                       ImportError, SyntaxError, TS2307 ...) with no assertion signal
#                       is rejected: red must be a behaviour failure. Exception: when
#                       every --code file is untracked (new in this step) a load
#                       failure is the only possible red and is accepted as load-only.
#
# Exit codes:
#   0  accepted
#   1  rejected (reason on stdout, first line starts "ACCEPT FAIL:")
#   2  usage/internal error (including a failed restore)
set -uo pipefail

USAGE="usage: accept-step.sh <worktree> '<verify command>' [--expect '<ERE>'] [--red '<command>'] [--code <file> ...] [--tests <file> ...]"
if [ $# -lt 2 ]; then
  echo "$USAGE" >&2
  exit 2
fi
WT=$1; VERIFY=$2; shift 2
CODE=(); TESTS=(); EXPECT=""; REDCMD=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --code) mode=code ;;
    --tests) mode=tests ;;
    --expect|--red)
      if [ $# -lt 2 ]; then echo "usage: $1 needs a value" >&2; exit 2; fi
      if [ "$1" = "--expect" ]; then EXPECT=$2; else REDCMD=$2; fi
      mode=""; shift ;;
    --*) echo "usage: unknown option: $1" >&2; exit 2 ;;
    *)
      case "$mode" in
        code) CODE+=("$1") ;;
        tests) TESTS+=("$1") ;;
        *) echo "usage: unexpected argument: $1" >&2; exit 2 ;;
      esac ;;
  esac
  shift
done

cd "$WT" 2>/dev/null || { echo "ACCEPT ERROR: cannot cd to $WT" >&2; exit 2; }
WT=$(pwd)

OUT=$(mktemp) || exit 2
STASHED=0
cleanup() { rm -f "$OUT"; }
restore() {
  if [ "$STASHED" -eq 1 ]; then
    STASHED=0
    if ! git stash pop --index --quiet >/dev/null 2>&1 && ! git stash pop --quiet >/dev/null 2>&1; then
      echo "ACCEPT ERROR: restore failed — run git stash pop in $WT"
      cleanup
      exit 2
    fi
  fi
}
on_exit() { restore; cleanup; }
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ZERO='Ran 0 tests|No tests found|no test files found|Tests:[[:space:]]+0 total|collected 0 items|(^|[^0-9])0 passed|# tests 0'

LOADFAIL='Cannot find module|Failed to resolve import|ERR_MODULE_NOT_FOUND|ModuleNotFoundError|ImportError|No module named|SyntaxError|TS2307|is not defined|Unable to resolve'
# Always a load failure, whatever else the output says (jest prints "● Test suite failed to run").
STRONGLOAD='Test suite failed to run|Failed to load|Cannot find module'
# Assertion markers, case-sensitive: "Expected" only at line start (jest/vitest "Expected: 3");
# no bare '● ' (jest uses it for load errors too) and no bare 'assert'.
ASSERTSIG='AssertionError|expect\(received\)|expect\(.*\)\.(not\.)?(toBe|toEqual|toMatch)|^[[:space:]]*(Expected|Received)|FAILED \(failures=|✗|×'

run_cmd() { bash -c "$1" >"$OUT" 2>&1; }
run_verify() { run_cmd "$VERIFY"; }

# Assertion-bearing line: it(/test(/describe(/expect( not preceded by an identifier char or '.'
# (so split( / wait( / submit( don't match), assert / assertion as a word, or assertXxx( calls, should.
WEAK_CNT='(^|[^A-Za-z0-9_.])(it|test|describe|expect)\(|\bassert(ion)?\b|assert[A-Z][a-zA-Z]*\(|\.should\b'
WEAK_ADD='\.(skip|only)\(|\bxit\(|\bxdescribe\(|@pytest\.mark\.skip|@unittest\.skip|\.todo\('
TESTSCK=""
if [ ${#TESTS[@]} -gt 0 ]; then
  for f in "${TESTS[@]}"; do
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      diff=$(git diff HEAD -- "$f")
      rm_n=$(printf '%s\n' "$diff" | grep -E '^-' | grep -v '^--- ' | grep -Ec "$WEAK_CNT")
      add_n=$(printf '%s\n' "$diff" | grep -E '^\+' | grep -v '^+++ ' | grep -Ec "$WEAK_CNT")
      # count comparison: an edited assertion (one out, one in) is not a weakening
      if [ "$((rm_n - add_n))" -gt 0 ]; then
        echo "ACCEPT FAIL: step removed assertions from $f ($((rm_n - add_n)) fewer)"
        exit 1
      fi
      if printf '%s\n' "$diff" | grep -E '^\+' | grep -v '^+++ ' | grep -Eq "$WEAK_ADD"; then
        echo "ACCEPT FAIL: step skipped/focused tests in $f"
        exit 1
      fi
    elif [ -f "$f" ]; then
      # untracked (new) test file: the whole content counts as added
      if grep -Eq "$WEAK_ADD" "$f"; then
        echo "ACCEPT FAIL: step skipped/focused tests in $f"
        exit 1
      fi
    fi
  done
  TESTSCK=" · tests not weakened"
fi

run_verify; rc=$?
if [ $rc -ne 0 ]; then
  if grep -Eiq "$ZERO" "$OUT"; then
    echo "ACCEPT FAIL: verify ran zero tests (exit $rc)"
  else
    echo "ACCEPT FAIL: verify failed (exit $rc)"
  fi
  tail -n 20 "$OUT"
  exit 1
fi
if grep -Eiq "$ZERO" "$OUT"; then
  echo "ACCEPT FAIL: verify ran zero tests"
  tail -n 20 "$OUT"
  exit 1
fi

EXPECTCK=""
if [ -n "$EXPECT" ]; then
  if ! grep -Eq -- "$EXPECT" "$OUT"; then
    echo "ACCEPT FAIL: verify output does not match --expect"
    tail -n 20 "$OUT"
    exit 1
  fi
  EXPECTCK=" · expect ok"
fi

RED="red check skipped (no --code)"
if [ ${#CODE[@]} -gt 0 ]; then
  for f in "${CODE[@]}"; do
    if [ ! -e "$f" ] && ! git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      echo "ACCEPT FAIL: --code path does not exist: $f"
      exit 1
    fi
  done
  allnew=1
  for f in "${CODE[@]}"; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && allnew=0
  done
  before=$(git stash list | wc -l)
  if ! git stash push --include-untracked --quiet -- "${CODE[@]}" >/dev/null 2>&1; then
    [ "$(git stash list | wc -l)" -gt "$before" ] && git stash pop --index --quiet >/dev/null 2>&1
    echo "ACCEPT ERROR: git stash push failed — tree left as it was"
    exit 2
  fi
  after=$(git stash list | wc -l)
  if [ "$after" -le "$before" ]; then
    echo "ACCEPT FAIL: code files have no changes to test against"
    exit 1
  fi
  STASHED=1
  run_cmd "${REDCMD:-$VERIFY}"; rc2=$?
  restore
  if [ $rc2 -eq 0 ]; then
    echo "ACCEPT FAIL: tests stay green without the step's code — Verify proves nothing"
    exit 1
  fi
  RED="red without code: yes (assertion)"
  if grep -Eiq "$STRONGLOAD" "$OUT" || { grep -Eiq "$LOADFAIL" "$OUT" && ! grep -Eq "$ASSERTSIG" "$OUT"; }; then
    if [ "$allnew" -eq 1 ]; then
      RED="red: load-only (new files)"
    else
      echo "ACCEPT FAIL: red run failed to load, not on an assertion — the test must import something that exists before the step and fail on behaviour"
      tail -n 20 "$OUT"
      exit 1
    fi
  fi
fi

echo "ACCEPT OK: verify passed · zero-test ok${EXPECTCK} · $RED${TESTSCK}"
exit 0
