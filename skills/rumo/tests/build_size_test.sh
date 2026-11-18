#!/usr/bin/env bash
# Tests for scripts/build-size.sh: the lane of a build, decided from the saved issue JSON alone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/build-size.sh"
FAILS=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1 -- got: $out (rc=$rc)"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

# mk <labels-json> <body> [comment-body...] -> $ROOT/issue.json
mk() {
  local labels=$1 body=$2; shift 2
  python3 -I - "$labels" "$body" "$@" > "$ROOT/issue.json" <<'PY'
import json, sys
labels, body, comments = sys.argv[1], sys.argv[2], sys.argv[3:]
print(json.dumps({'title': 't', 'body': body,
                  'labels': [{'name': n} for n in json.loads(labels)],
                  'comments': [{'body': c} for c in comments]}))
PY
}
run() { out=$("$SCRIPT" "$ROOT/issue.json" 2>"$ROOT/err"); rc=$?; }

C1='- [ ] [cmd] `make test` exits 0'
C2='- [x] [cmd] `make lint` exits 0'
V1='- [ ] [visual] the header renders on mobile'
J1='- [ ] [judgment] the copy reads well'

# 1 normal: more than 3 criteria
mk '[]' "$(printf '%s\n%s\n%s\n%s' "$C1" "$C2" "$V1" "$J1")"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE normal — " || ok=1
check "1 four criteria -> normal" $ok

# 2 normal: zero criteria
mk '[]' "just prose, no checklist"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE normal — " || ok=1
check "2 zero criteria -> normal" $ok

# 3 normal: risk: label
mk '["risk:sensitive"]' "$C1"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE normal — " || ok=1
check "3 risk:sensitive label -> normal" $ok

# 4 normal: Risk section with content
mk '[]' "$(printf '%s\n\n## Risk\nTouches the auth middleware.\n\n## Done\n%s' "$C1" "$C2")"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE normal — " || ok=1
check "4 ## Risk with content -> normal" $ok

# 5 ## Risk none -> not normal
mk '[]' "$(printf '## Risk\nnone\n\n## Done\n%s' "$C1")"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE fast — 1 criteria, all cmd" || ok=1
check "5 ## Risk none -> not normal (fast)" $ok

# 6 ## Risco, blank line first, 'Nenhum.' -> not normal
mk '[]' "$(printf '## Risco\n\nNenhum.\n\n%s' "$C1")"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE fast — " || ok=1
check "6 ## Risco / Nenhum. -> not normal" $ok

# 7 ## Risco 'Nada a declarar' -> not normal; ## Risco in other case with content -> normal
mk '[]' "$(printf '## risco\nNada a declarar\n%s' "$C1")"; run
ok=0; [ $rc -eq 0 ] && has "$out" "SIZE fast — " || ok=1
check "7 ## risco / Nada a declarar -> not normal" $ok

# 8 visual: no [cmd]
mk '[]' "$(printf '%s\n%s' "$V1" "$J1")"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE visual — 2 criteria, all visual/judgment" ] || ok=1
check "8 visual + judgment only -> visual" $ok

# 9 fast: 2 cmd
mk '[]' "$(printf '%s\n%s' "$C1" "$C2")"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE fast — 2 criteria, all cmd" ] || ok=1
check "9 two cmd -> fast" $ok

# 10 small: 3 cmd
mk '[]' "$(printf '%s\n%s\n%s' "$C1" "$C2" "$C1")"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE small — 3 criteria" ] || ok=1
check "10 three cmd -> small" $ok

# 11 small: mixed cmd + visual
mk '[]' "$(printf '%s\n%s' "$C1" "$V1")"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE small — 2 criteria" ] || ok=1
check "11 mixed cmd + visual -> small" $ok

# 12 criteria inside comments are counted (body 1 + comments 2 = 3 -> small; cmd only in comment)
mk '[]' "$C1" "$C2" "no criteria here" "  - [X] [cmd] indented"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE small — 3 criteria" ] || ok=1
check "12 criteria in comments counted" $ok

# 13 comments-only criteria still count (body has none)
mk '[]' "prose" "$V1"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE visual — 1 criteria, all visual/judgment" ] || ok=1
check "13 criteria only in a comment" $ok

# 14 non-risk label does not force normal
mk '["bug","ready"]' "$C1"; run
ok=0; [ $rc -eq 0 ] && [ "$out" = "SIZE fast — 1 criteria, all cmd" ] || ok=1
check "14 other labels ignored" $ok

# 15 exactly one line
mk '[]' "$C1"; run
ok=0; [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || ok=1
check "15 exactly one line" $ok

# 16 bad JSON -> exit 2, message on stderr
printf 'not json{' > "$ROOT/issue.json"; run
ok=0; [ $rc -eq 2 ] && [ -s "$ROOT/err" ] && [ -z "$out" ] || ok=1
check "16 invalid JSON -> exit 2 + stderr" $ok

# 17 missing file -> exit 2
out=$("$SCRIPT" "$ROOT/nope.json" 2>"$ROOT/err"); rc=$?
ok=0; [ $rc -eq 2 ] && [ -s "$ROOT/err" ] || ok=1
check "17 missing file -> exit 2" $ok

# 18 no argument -> exit 2
out=$("$SCRIPT" 2>"$ROOT/err"); rc=$?
ok=0; [ $rc -eq 2 ] || ok=1
check "18 no argument -> exit 2" $ok

# 19 JSON that is not an object -> exit 2
printf '[1,2]' > "$ROOT/issue.json"; run
ok=0; [ $rc -eq 2 ] || ok=1
check "19 non-object JSON -> exit 2" $ok

[ "$FAILS" -eq 0 ] || { echo "$FAILS FAILED"; exit 1; }
echo "all passed"
