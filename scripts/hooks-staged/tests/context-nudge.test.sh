#!/bin/bash
# Usage: [HOOK=<hook path>] bash <hooks dir>/tests/context-nudge.test.sh → PASS/FAIL per case, exit 1 on any FAIL.
# Default hook = ../context-nudge.py next to this tests/ dir (same layout staged in the repo and installed).
H="${HOOK:-$(dirname "$0")/../context-nudge.py}"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); export TMPDIR="$T"
tr() { echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":$1,\"cache_creation_input_tokens\":0,\"output_tokens\":5}}}" > "$T/t.jsonl"; }
run() { echo "{\"session_id\":\"s1\",\"transcript_path\":\"$T/t.jsonl\"}" | python3 "$H"; }
# runp PROMPT [SESSION] — a hook payload with prompt text (session s2 by default)
runp() { python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[3],"transcript_path":sys.argv[1],"prompt":sys.argv[2]}))' "$T/t.jsonl" "$1" "${2:-s2}" | python3 "$H"; }
# nudged OUT K — OUT is the nudge at ~K k tokens, naming /rumo handoff and /clear, with no block
nudged() { [[ "$1" == *"[context] Context at ~$2k"* && "$1" == *UserPromptSubmit* && "$1" == *"/rumo handoff"* && "$1" == *"/clear"* && "$1" != *'"decision"'* ]]; }
# any prompt: one nudge per band from 200k, never a block
tr 150000; ok "150k silent" '[ -z "$(run)" ]'
tr 210000; out=$(runp "fix the login test" s3); ok "ordinary prompt at 210k nudges, no block" 'nudged "$out" 210'
tr 230000; out=$(runp "now the lint" s3); ok "second prompt same band silent" '[ -z "$out" ]'
tr 320000; out=$(runp "go on" s3); ok "320k next band nudges" 'nudged "$out" 320'
tr 520000; out=$(run); ok "520k, no prompt field, nudges" 'nudged "$out" 520'
tr 60000; out=$(runp "after the compact" s3); ok "below 200k after a compaction silent" '[ -z "$out" ]'
tr 205000; out=$(runp "again" s3); ok "re-crossing 200k after a compaction nudges" 'nudged "$out" 205'
tr 110000; out=$(CONTEXT_NUDGE_LEVELS=100000 runp "x" s4); ok "CONTEXT_NUDGE_LEVELS overrides the bands" 'nudged "$out" 110'
rm -f "$T/t.jsonl"; ok "missing transcript silent" '[ -z "$(run)" ]'
ok "garbage stdin exit 0" '[ "$(echo nope | python3 "$H" >/dev/null; echo $?)" = 0 ]'
# build/wave gate: a build starts in a fresh window — still blocks from 120k
tr 130000; out=$(runp "/rumo build #42"); ok "build at 130k still blocks" '[[ "$out" == *'"'"'"decision": "block"'"'"'* && "$out" == *"/clear"* && "$out" == *"/rumo build #42"* ]]'
tr 150000; out=$(runp "/rumo wave epic #9"); ok "wave at 150k blocks" '[[ "$out" == *'"'"'"decision": "block"'"'"'* ]]'
tr 150000; out=$(runp "/rumo:rumo build #42"); ok "plugin-qualified build blocks" '[[ "$out" == *'"'"'"decision": "block"'"'"'* ]]'
tr 150000; out=$(runp "/rumo build #42 #same-window"); ok "#same-window passes" '[[ "$out" != *block* ]]'
tr 210000; out=$(runp "/rumo build #42 #same-window" s5); ok "#same-window at 210k nudges, no block" 'nudged "$out" 210'
tr 60000; out=$(runp "/rumo build #42"); ok "fresh window build passes" '[ -z "$out" ]'
tr 150000; out=$(runp "/rumo ticket"); ok "other rumo modes pass" '[[ "$out" != *block* ]]'
tr 150000; out=$(runp "rode o /rumo build depois"); ok "mention mid-text passes" '[[ "$out" != *block* ]]'
rm -f "$T/t.jsonl"; out=$(runp "/rumo build #42"); ok "no transcript yet passes" '[ -z "$out" ]'
rm -rf "$T"; exit $fail
