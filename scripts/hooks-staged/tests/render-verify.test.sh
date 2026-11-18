#!/bin/bash
# Usage: [HOOK=<hook path>] bash <hooks dir>/tests/render-verify.test.sh  → PASS/FAIL per case, exit 1 on any FAIL
H="${HOOK:-$(dirname "$0")/../render-verify.sh}"; FX="$(dirname "$0")/_fixture.py"; fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
R="$D/repo"; git init -q "$R"
M="$D/marked"; git init -q "$M"; mkdir -p "$M/.claude"; : > "$M/.claude/no-render-verify"; mkdir -p "$D/norepo"
# t NAME STEPS_JSON EXPECT(allow|block) [message-substring] [extra-json-fields]
t() { python3 "$FX" "$D/t.jsonl" "$2"
  out=$(printf '{"transcript_path":"%s/t.jsonl","cwd":"%s"%s}' "$D" "${CWD:-$R}" "$5" | bash "$H" 2>/dev/null); rc=$?
  case "$out" in *'"block"'*) got=block;; *) got=allow;; esac
  ok=1; [ "$rc" = 0 ] && [ "$got" = "$3" ] || ok=0
  [ -n "$4" ] && case "$out" in *"$4"*) ;; *) ok=0;; esac
  [ $ok = 1 ] && echo "PASS $1" || { echo "FAIL $1 (rc=$rc got $got want $3) $out"; fail=1; }; }
U='{"u":"do it"}'
E="{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/a.css\"}}"
S1='{"use":"Bash","in":{"command":"orca exec --command \"screenshot /s/d.png\""}}'
S2='{"use":"Bash","in":{"command":"orca exec --command \"screenshot /s/m.png\""}}'
R1='{"use":"Read","in":{"file_path":"/s/d.png"}}'
R2='{"use":"Read","in":{"file_path":"/s/m.png"}}'
t "two images read after edit"     "[$U,$E,$S1,$R1,$S2,$R2]" allow
t "one image after edit"           "[$U,$E,$S1,$R1]" block "1 image"
t "zero images after edit"         "[$U,$E]" block "0 image"
t "block message names sizes"      "[$U,$E,$S1,$R1]" block "390"
t "same image read twice = 1"      "[$U,$E,$S1,$R1,$R1]" block "1 image"
t "images read before edit"        "[$U,$S1,$R1,$S2,$R2,$E]" block
t "one before, one after"          "[$U,$S1,$R1,$E,$S2,$R2]" block
t "stale file re-read, shot old"   "[$U,$S1,$S2,$E,$R1,$R2]" block
t "heredoc into .css counted"      "[$U,$S1,$R1,$S2,$R2,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > a.css <<EOF\\nbody{}\\nEOF\"}}]" block
t "sed -i on .tsx counted"         "[$U,$S1,$R1,$S2,$R2,{\"use\":\"Bash\",\"in\":{\"command\":\"sed -i '' s/a/b/ src/A.tsx\"}}]" block
t "non-visual edit"                "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"/proj/a.ts\"}}]" allow
t "bash non-visual write"          "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > a.txt\"}}]" allow
t "test file tsx ignored"          "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"/proj/a.test.tsx\"}}]" allow
t "heredoc PR body mentioning app.css" "[$U,$E,$S1,$R1,$S2,$R2,{\"use\":\"Bash\",\"in\":{\"command\":\"cat <<EOF | gh pr create --body-file -\\nchanged app.css\\nEOF\"}}]" allow
t "cat > app.css <<EOF after shots"   "[$U,$E,$S1,$R1,$S2,$R2,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > app.css <<EOF\\nbody{}\\nEOF\"}}]" block
t "stop_hook_active"               "[$U,$E]" allow "" ',"stop_hook_active":true'
t "visual edit outside repo"       "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/norepo/print.html\"}}]" allow
t "~/Documents html"               "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$HOME/Documents/x.html\"}}]" allow
t "\$TMPDIR write is scratch"       "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > \$TMPDIR/a.html\"}}]" allow
t "../../a.css outside repo"       "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > ../../a.css\"}}]" allow
t "\$(...) target unresolved"       "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > \$(mktemp -d)/a.css\"}}]" allow
CWD="$M" t "marker repo skipped"   "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$M/src/a.css\"}}]" allow
bj() { python3 -c 'import json,sys; print(json.dumps({"use":"Bash","in":{"command":sys.argv[1]}}))' "$1"; }
PYW=$'cd '"$R"$' && python3 - <<\'EOF\'\nopen(\'src/a.css\',\'w\').write(\'x\')\nEOF'
t "python heredoc writes src/a.css"  "[$U,$(bj "$PYW")]" block
printf '.rumo/\n' >> "$R/.git/info/exclude"
t "gitignored .rumo/shot.html"       "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/.rumo/shot.html\"}}]" allow
t "ignored bash write .rumo/s.html"  "[$U,$(bj "echo x > $R/.rumo/s.html")]" allow
t "written then rm'd preview.tsx"    "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/preview.tsx\"}},$(bj "rm \"$R/src/preview.tsx\"")]" allow
t "preview.tsx rm'd but a.css remains" "[$U,$E,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/preview.tsx\"}},$(bj "rm \"$R/src/preview.tsx\"")]" block
t "cp into a dir counts dest/basename"  "[$U,$(bj "cp /tmp/new.css \"$R/src/\"")]" block
t "cp onto a css file counts"           "[$U,$(bj "cp /tmp/new.css $R/src/b.css")]" block
t "cp out of the repo"                  "[$U,$(bj 'cp src/a.css /tmp/bak.css')]" allow
t "temp-named html is not repo code"    "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/a.tmp.html\"}}]" allow
t "edit then git checkout HEAD -- css"  "[$U,$E,$(bj 'git checkout HEAD -- src/a.css')]" allow
t "css restored from its own backup"     "[$U,$E,$S1,$R1,$S2,$R2,$(bj 'cp src/a.css /tmp/x/a.bak; echo x > src/a.css; cp /tmp/x/a.bak src/a.css')]" allow
t "css mutated, backup not restored"     "[$U,$E,$S1,$R1,$S2,$R2,$(bj 'cp src/a.css /tmp/x/a.bak; echo x > src/a.css')]" block
# review fixes: mutation window, removal recomputes the last edit, rev checkouts, tracked temp names, timing
t "edit, backup, variant shots, revert"  "[$U,$E,$(bj 'cp src/a.css /tmp/a.css.bak'),$E,$S1,$R1,$S2,$R2,$(bj 'cp /tmp/a.css.bak src/a.css')]" block
t "shots before the backup still count"  "[$U,$E,$S1,$R1,$S2,$R2,$(bj 'cp src/a.css /tmp/a.css.bak'),$E,$(bj 'cp /tmp/a.css.bak src/a.css')]" allow
t "variant shot read after the revert"   "[$U,$E,$(bj 'cp src/a.css /tmp/a.css.bak'),$E,$S1,$S2,$(bj 'cp /tmp/a.css.bak src/a.css'),$R1,$R2]" block
EF="{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/b.css\"}}"
t "G shot, F edited then git-restored"   "[$U,$EF,$S1,$R1,$S2,$R2,$E,$(bj 'git checkout -- src/a.css')]" allow
t "git checkout origin/dev -- css"       "[$U,$E,$S1,$R1,$S2,$R2,$(bj 'git checkout origin/dev -- src/a.css')]" block
mkdir -p "$R/src"; echo x > "$R/src/temp-gauge.tsx"; git -C "$R" add src/temp-gauge.tsx; git -C "$R" commit -q -m gauge
t "tracked temp-named tsx is repo code"  "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/temp-gauge.tsx\"}}]" block
t "untracked temp-named html still skipped" "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/b.tmp.html\"}}]" allow
# timing: big commands finish in < 3 s (SECONDS granularity)
tm() { python3 "$FX" "$D/t.jsonl" "$2"; s=$SECONDS
  out=$(printf '{"transcript_path":"%s/t.jsonl","cwd":"%s"}' "$D" "$R" | bash "$H" 2>/dev/null); el=$((SECONDS - s))
  [ "$el" -lt 3 ] && echo "PASS $1 (${el}s)" || { echo "FAIL $1 (${el}s >= 3s)"; fail=1; }; }
BIG=$(python3 -c '
import json
q = chr(39) * 3
rows = "\n".join("<tr class=\"row\" data-id=\"r%d\"><td title=\"cell\">%d</td></tr>" % (i, i) for i in range(2500))
cmd = "python3 - <<" + chr(39) + "PY" + chr(39) + "\nhtml = " + q + "<table>\n" + rows + "\n</table>" + q + "\nopen(\"/x/report.html\",\"w\").write(html)\nPY"
print(json.dumps({"use": "Bash", "in": {"command": cmd}}))')
tm "150 KB python heredoc html in < 3 s" "[$U,$E,$BIG]"
NPMX=$(python3 -c 'import json; print(json.dumps({"use":"Bash","in":{"command":"echo \"" + "npm x " * 12000 + "\""}}))')
tm "72 KB one-line echo npm x in < 3 s" "[$U,$E,$NPMX]"
DEFS=$(python3 -c '
import json
body = "".join("def f%d(a):\n  open(a, \"w\")\n" % i for i in range(6000))
cmd = "python3 - <<" + chr(39) + "PY" + chr(39) + "\n" + body + "f0(\"/x/o.txt\")\nPY"
print(json.dumps({"use": "Bash", "in": {"command": cmd}}))')
tm "6000 python defs in a heredoc in < 3 s" "[$U,$E,$DEFS]"
SEGS=$(python3 -c 'import json; print(json.dumps({"use":"Bash","in":{"command":" ; ".join(["echo \"" + "npm x " * 3300 + "\""] * 10)}}))')
tm "193 KB of echo segments in < 3 s" "[$U,$E,$SEGS]"
CWD="$D/norepo" t "cwd not a repo" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/norepo/a.css\"}}]" allow
t "tool_use cwd is the base"       "[$U,{\"use\":\"Bash\",\"cwd\":\"$D/norepo\",\"in\":{\"command\":\"echo x > a.css\"}}]" allow
t "in-repo edit names design-taste" "[$U,$E]" block "design-taste"
mkdir -p "$D/scratch"; git -C "$R" worktree add -q --detach "$D/scratch/wt2" 2>/dev/null
TMPDIR="$D/scratch" t "worktree under \$TMPDIR is scratch" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/scratch/wt2/src/a.css\"}}]" allow
t "temp worktree of a temp repo still counts" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/scratch/wt2/src/a.css\"}}]" block
# explain: one in-repo and one out-of-repo visual edit, hook asked to log its classification
python3 "$FX" "$D/ex.t.jsonl" "[$U,$E,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/norepo/b.css\"}}]"
rm -f "$D/ex.jsonl"
printf '{"transcript_path":"%s/ex.t.jsonl","cwd":"%s"}' "$D" "$R" | VERIFY_HOOK_EXPLAIN="$D/ex.jsonl" bash "$H" >/dev/null 2>&1
if tail -n 1 "$D/ex.jsonl" 2>/dev/null | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
w = {f["why"] for f in d["files"]}
sys.exit(0 if d["hook"] == "render-verify" and d["decision"] == "block" and {"in-repo", "out-of-repo"} <= w else 1)' 2>/dev/null; then
  echo "PASS explain"; else echo "FAIL explain"; fail=1; fi
out=$(printf 'not json' | bash "$H" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && echo "PASS garbage fails open" || { echo "FAIL garbage fails open"; fail=1; }
exit $fail
