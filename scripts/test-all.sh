#!/usr/bin/env bash
# Run: bash scripts/test-all.sh [--root <dir>] — runs every *_test.sh, *.test.sh, *_test.py under root; exit 1 on any FAIL; a test exiting 77 is SKIP (not a failure).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { echo "usage: test-all.sh [--root <dir>]" >&2; exit 2; }
case "${1-}" in
  "") ;;
  --root) [ $# -eq 2 ] && [ -d "$2" ] && ROOT="$(cd "$2" && pwd)" || usage ;;
  *) usage ;;
esac
[ $# -le 2 ] || usage
L=$(mktemp -d); trap 'rm -rf "$L"' EXIT
found=$(find "$ROOT" \( -name .git -o -name node_modules -o -name .rumo \) -prune -o -type f \( -name '*_test.sh' -o -name '*.test.sh' -o -name '*_test.py' \) -print | LC_ALL=C sort)
tests=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  d=$(dirname "$t"); nested=0
  while [ "$d" != "$ROOT" ] && [ "$d" != / ]; do [ -e "$d/.git" ] && { nested=1; break; }; d=$(dirname "$d"); done
  [ $nested -eq 0 ] && tests="$tests$t"$'\n'
done <<<"$found"
[ -n "$tests" ] || { echo "FAIL no tests found under $ROOT"; exit 1; }
fail=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  rel=${t#"$ROOT"/}; d=$(dirname "$t"); b=$(basename "$t"); unset HOOK
  if [[ "$b" == *.test.sh && "$(basename "$d")" == tests ]]; then
    n=${b%.test.sh}; p=$(dirname "$d")
    if [ -e "$p/$n.sh" ]; then export HOOK="$p/$n.sh"; elif [ -e "$p/$n.py" ]; then export HOOK="$p/$n.py"; fi
  fi
  if [[ "$t" == *.py ]]; then cmd=(python3 -I "$t"); else cmd=(bash "$t"); fi
  (cd "$ROOT" && "${cmd[@]}") >"$L/log" 2>&1 </dev/null; rc=$?
  if [ $rc -eq 0 ]; then echo "PASS $rel"
  elif [ $rc -eq 77 ]; then echo "SKIP $rel"
  else echo "FAIL $rel"; tail -20 "$L/log" | sed 's/^/    /' >&2; fail=1; fi
done <<<"$tests"
unset HOOK
exit $fail
