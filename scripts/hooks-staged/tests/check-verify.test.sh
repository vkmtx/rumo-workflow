#!/bin/bash
# Usage: [HOOK=<hook path>] [CV_TIME_BUDGET=<seconds>] [CV_LOAD=<1-min load>] bash <hooks dir>/tests/check-verify.test.sh  → PASS/FAIL/SKIP per case, exit 1 on any FAIL
H="${HOOK:-$(dirname "$0")/../check-verify.sh}"; FX="$(dirname "$0")/_fixture.py"; fail=0
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
R="$D/repo"; git init -q "$R"; git -C "$R" commit -q --allow-empty -m init; git -C "$R" worktree add -q "$D/wt" 2>/dev/null; mkdir -p "$D/out" "$D/norepo"
echo '{"scripts":{"test":"x","check":"y"}}' > "$R/package.json"
# t NAME STEPS_JSON EXPECT(allow|block) [extra-json-fields]   (CWD=<dir> t … overrides the hook cwd)
t() { python3 "$FX" "$D/t.jsonl" "$2"
  out=$(printf '{"transcript_path":"%s/t.jsonl","cwd":"%s"%s}' "$D" "${CWD:-$R}" "$4" | bash "$H" 2>/dev/null); rc=$?
  case "$out" in *'"block"'*) got=block;; *) got=allow;; esac
  [ "$rc" = 0 ] && [ "$got" = "$3" ] && echo "PASS $1" || { echo "FAIL $1 (rc=$rc got $got want $3) $out"; fail=1; }; }
U='{"u":"do it"}'
E="{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/a.ts\"}}"
V='{"use":"Bash","in":{"command":"npm test"},"res":"all passed"}'
t "verify passed after edit"       "[$U,$E,$V]" allow
t "verify failed (is_error)"       "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"boom\",\"err\":true}]" block
t "verify failed (Exit code 1)"    "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"Exit code 1\\nFAIL x\"}]" block
t "Exit code 0 is fine"            "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"Exit code 0\\nok\"}]" allow
t "verify before last edit"        "[$U,$V,$E]" block
t "sed -i edit counted"            "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"sed -i '' s/a/b/ src/a.ts\"}}]" block
t "sed -i then verify"             "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"sed -i '' s/a/b/ src/a.ts\"}},$V]" allow
t "heredoc into .py: no npm gate"   "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > x.py <<EOF\\nprint(1)\\nEOF\"}}]" allow
t "heredoc into .ts counted"         "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > x.ts <<EOF\\nx\\nEOF\"}}]" block
t "no edit"                        "[$U,{\"use\":\"Read\",\"in\":{\"file_path\":\"$R/src/a.ts\"}}]" allow
t "bash non-source write ignored"  "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"echo hi > notes.txt\"}}]" allow
t "edit only no verify"            "[$U,$E]" block
t "stop_hook_active"               "[$U,$E]" allow ',"stop_hook_active":true'
CM='"git commit -m \"$(cat <<EOF\nfix src/a.ts\nEOF\n)\""'
t "heredoc msg mentioning src/a.ts"  "[$U,$E,$V,{\"use\":\"Bash\",\"in\":{\"command\":$CM}}]" allow
t "cat <<EOF > src/b.ts after tests" "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cat <<EOF > src/b.ts\\nx\\nEOF\"}}]" block
t ">> src/c.ts counted"              "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"echo y >> src/c.ts\"}}]" block
t "tee src/d.ts counted"             "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"echo y | tee src/d.ts\"}}]" block
t "quoted > mention not an edit"     "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"echo 'a > b.ts'\"}}]" allow
# repo scope: only files inside the session's repo (or its worktrees) count
t "\$TMPDIR write is scratch"        "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > \$TMPDIR/x.py <<EOF\\nprint(1)\\nEOF\"}}]" allow
t "../../x.py outside repo"          "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cat > ../../x.py <<EOF\\nx\\nEOF\"}}]" allow
t "../../x.ts outside repo"          "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > ../../x.ts\"}}]" allow
t "\$(…) target unresolved"          "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"echo x > \$(mktemp -d)/a.ts\"}}]" allow
t "assigned var expanded into repo"  "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"P=$R/src; echo x > \$P/b.ts\"}}]" block
t "export var outside repo"          "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"export O=$D/out; echo x > \$O/b.ts\"}}]" allow
t "cd into repo subdir"              "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cd src && echo x > a.ts\"}}]" block
t "cd out of repo"                   "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cd $D/out && echo x > a.ts\"}}]" allow
t "unresolvable cd skips relative write" "[$U,$V,{\"use\":\"Bash\",\"in\":{\"command\":\"cd \\\"\$(git rev-parse --show-toplevel)\\\" && echo x > a.ts\"}}]" allow
t "tool_use cwd is the base"         "[$U,$V,{\"use\":\"Bash\",\"cwd\":\"$D/out\",\"in\":{\"command\":\"echo x > a.ts\"}}]" allow
t "edit outside repo"                "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/out/a.ts\"}}]" allow
t "worktree of the repo counts"      "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/wt/src/a.ts\"}}]" block
mkdir -p "$D/scratch"; git -C "$R" worktree add -q --detach "$D/scratch/wt2" 2>/dev/null
TMPDIR="$D/scratch" t "worktree under \$TMPDIR is scratch" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/scratch/wt2/src/a.ts\"}}]" allow
t "temp worktree of a temp repo still counts" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/scratch/wt2/src/a.ts\"}}]" block
CWD="$D/norepo" t "cwd not a repo"  "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/norepo/a.ts\"}}]" allow
# wider verification commands: edit, then the command -> allow
vc() { t "verify cmd: $1" "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"$1\"},\"res\":\"ok\"}]" "${2:-allow}"; }
vc "pnpm --filter web test"
vc "pnpm -C apps/x typecheck"
vc "npm --prefix x test"
vc "yarn workspace x test"
vc "pnpm exec biome check ."
vc "npx playwright test"
vc "pnpm e2e"
vc "node --test tests/"
vc "bash skills/rumo/scripts/accept-step.sh .rumo/plan.md 1"
vc "python3 -m pytest -q"
vc "python3 -I skills/learn/tests/learn_test.py"
vc "bash scripts/x/tests/a.test.sh"
vc "bash scripts/test-all.sh"
vc "bash scripts/test-all.sh --root /tmp/x"
vc "cat scripts/test-all.sh" block
vc "pnpm test:unit"
vc "npm install check-types" block
# language gate: only JS-family files get the npm gate
t ".sql edit: no npm gate"           "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/db/a.sql\"}}]" allow
t ".py edit: no npm gate"            "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/a.py\"}}]" allow
t "sed -i on .css: render-verify's job" "[$U,{\"use\":\"Bash\",\"in\":{\"command\":\"sed -i '' s/a/b/ src/a.css\"}}]" allow
t ".mts counted"                     "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/a.mts\"}}]" block
# fixes from the label cross-check: background / denied commands, interpreter writes, ignored files, edit-then-verify in one command
# bj CMD [extra-json-fields-for-the-step] -> one Bash step with CMD JSON-escaped
bj() { python3 -c 'import json,sys; d={"use":"Bash","in":{"command":sys.argv[1]}}; d.update(json.loads(sys.argv[2]) if len(sys.argv)>2 and sys.argv[2] else {}); print(json.dumps(d))' "$1" "$2"; }
t "background npm test is no verification" "[$U,$E,$(bj 'npm test' '{"in":{"command":"npm test","run_in_background":true},"res":"Command running in background"}')]" block
t "hook-error result is no verification"  "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"PreToolUse:Bash hook error: denied\"}]" block
PYW=$'cd '"$R"$' && python3 - <<\'EOF\'\np=\'src/a.ts\'\ns=open(p).read()\nopen(p,\'w\').write(s)\nEOF'
t "python heredoc rewrites src/a.ts"      "[$U,$V,$(bj "$PYW")]" block
PYD=$'cd '"$R"$' && python3 - <<\'EOF\'\ndef edit(p, pairs):\n    s = open(p).read()\n    open(p, \'w\').write(s)\n\nedit(\'src/a.ts\', [])\nEOF'
t "python heredoc def edit(p) helper"     "[$U,$V,$(bj "$PYD")]" block
PYR=$'cd '"$R"$' && python3 - <<\'EOF\'\ns=open(\'src/a.ts\').read()\nopen(\'out.json\',\'w\').write(s)\nEOF'
t "python heredoc only reads src/a.ts"    "[$U,$V,$(bj "$PYR")]" allow
PYC="cd $R && python3 -c \"open('src/a.ts','w').write('x')\""
t "python -c writes src/a.ts"             "[$U,$V,$(bj "$PYC")]" block
NODE=$'cd '"$R"$' && node <<\'EOF\'\nrequire(\'fs\').writeFileSync(\'src/a.ts\', \'x\')\nEOF'
t "node heredoc writeFileSync src/a.ts"   "[$U,$V,$(bj "$NODE")]" block
printf '.rumo/\n' >> "$R/.git/info/exclude"
t "gitignored .rumo/x.ts is not repo code" "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/.rumo/x.ts\"}}]" allow
t "ignored bash write .rumo/x.ts"          "[$U,$(bj "echo x > $R/.rumo/y.ts")]" allow
t "src/a.ts still counts beside ignore"    "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/.rumo/x.ts\"}},$E]" block
t "sed -i then vitest in one command"     "[$U,$(bj "sed -i '' s/a/b/ src/a.ts && npx vitest run")]" allow
t "vitest then sed -i in one command"     "[$U,$(bj "npx vitest run && sed -i '' s/a/b/ src/a.ts")]" block
vc "npm run verify"
vc "vercel build"
vc "vercel deploy --prod"
# same-command order by shell segment; removed / restored files stop counting
t "sed -i; vitest naming the target"      "[$U,$(bj "sed -i '' s/a/b/ src/a.ts; npx vitest run src/a.ts")]" allow
PYV=$'cd '"$R"$' && python3 - <<\'EOF\'\np=\'src/a.ts\'\nopen(p,\'w\').write(\'x\')\nEOF\nnpx vitest run'
t "python heredoc then vitest on a later line" "[$U,$(bj "$PYV")]" allow
PYB=$'npx vitest run; python3 - <<\'EOF\'\nopen(\'src/a.ts\',\'w\').write(\'x\')\nEOF'
t "vitest then python heredoc write"      "[$U,$(bj "$PYB")]" block
t "created then rm'd .tmp-x.mjs"          "[$U,$(bj $'cat > .tmp-x.mjs <<\'EOF\'\nx\nEOF'),$(bj 'rm .tmp-x.mjs')]" allow
t "created, run and rm'd in one command"  "[$U,$(bj $'cat > .tmp-x.mjs <<\'EOF\'\nx\nEOF\nnode .tmp-x.mjs; rm -f .tmp-x.mjs')]" allow
t "rm then recreate in one command"       "[$U,$(bj 'rm -f src/a.ts && echo x > src/a.ts')]" block
t "edit then git checkout -- file"        "[$U,$E,$(bj 'git checkout -- src/a.ts')]" allow
t "edit then git restore file"            "[$U,$E,$(bj 'git restore src/a.ts')]" allow
t "edit then git restore --staged only"   "[$U,$E,$(bj 'git restore --staged src/a.ts')]" block
t "two edits, one rm'd"                   "[$U,$E,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/b.ts\"}},$(bj 'rm src/a.ts')]" block
t "two edits, both rm'd"                  "[$U,$E,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/b.ts\"}},$(bj 'rm src/a.ts src/b.ts')]" allow
t "sed target named again by biome"       "[$U,$(bj "sed -i '' s/a/b/ src/a.ts; pnpm check:policies; pnpm exec biome check src/a.ts")]" allow
# v2 criterion fixes: auto-backgrounded results, cp/mv destinations, temp-named files, npx <tool> lint, wider checkout/restore
t "auto-backgrounded npm test is no pass"  "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"Command was moved to the background with ID: x\"}]" block
t "running in the background is no pass"   "[$U,$E,{\"use\":\"Bash\",\"in\":{\"command\":\"npm test\"},\"res\":\"Command running in the background with ID: y\"}]" block
t "cp restore after the check"             "[$U,$E,$V,$(bj 'cp /tmp/x.bak src/a.ts')]" block
t "cp into a dir adds <dir>/<basename>"    "[$U,$V,$(bj 'cp /tmp/new.ts src/')]" block
t "cp into an extensionless dir"           "[$U,$V,$(bj 'cp /tmp/new.ts src')]" block
t "mv onto a file"                         "[$U,$V,$(bj 'mv /tmp/new.ts src/a.ts')]" block
t "cp out of the repo"                     "[$U,$V,$(bj "cp $R/src/a.ts /tmp/bak.ts")]" allow
t "cp -t form is left alone"               "[$U,$V,$(bj 'cp -t src /tmp/new.ts')]" allow
t "cp to a non-JS file"                    "[$U,$V,$(bj 'cp /tmp/x src/a.json')]" allow
t "backup, edit, check, restore stays blocked" "[$U,$E,$(bj "cp $R/src/a.ts /tmp/bak && sed -i '' s/a/b/ src/a.ts && npx vitest run; cp /tmp/bak src/a.ts")]" block
t "backup, edit, check, no restore"        "[$U,$(bj "cp $R/src/a.ts /tmp/bak && sed -i '' s/a/b/ src/a.ts && npx vitest run")]" allow
t "temp-named config is not repo code"     "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/playwright.tmp.config.ts\"}}]" allow
t "foo.temp.ts is not repo code"           "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/foo.temp.ts\"}}]" allow
t "temp-named bash write"                  "[$U,$(bj 'echo x > .tmp-x.mjs')]" allow
t "attempt.ts is repo code"                "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/src/attempt.ts\"}}]" block
vc "npx -y hyperframes@1.2.0 lint"
vc "npx hyperframes check"
vc "npx install-foo" block
t "edit then git checkout HEAD -- file"    "[$U,$E,$(bj 'git checkout HEAD -- src/a.ts')]" allow
t "edit then git checkout file"            "[$U,$E,$(bj 'git checkout src/a.ts')]" allow
t "edit then git checkout HEAD file"       "[$U,$E,$(bj 'git checkout HEAD src/a.ts')]" allow
t "edit then git checkout main"            "[$U,$E,$(bj 'git checkout main')]" block
t "edit then git restore -s HEAD -W file"  "[$U,$E,$(bj 'git restore -s HEAD -W src/a.ts')]" allow
t "edit then git restore --worktree file"  "[$U,$E,$(bj 'git restore --source=HEAD~1 --worktree src/a.ts')]" block
t "edit then git restore -S file"          "[$U,$E,$(bj 'git restore -S src/a.ts')]" block
# a file restored from its own backup carries no net edit (mutation red checks)
MUT='cp src/a.ts /tmp/x/a.ts.bak; git show HEAD:src/a.ts > src/a.ts; npx vitest run; cp /tmp/x/a.ts.bak src/a.ts'
t "verified edit, then mutation red check"    "[$U,$E,$V,$(bj "$MUT")]" allow
t "unverified edit, then mutation red check"  "[$U,$E,$(bj "$MUT")]" block
t "mutation check alone carries no net edit"  "[$U,$(bj 'cp src/a.ts $TMPDIR/a.bak; git show HEAD:src/a.ts > src/a.ts; npx vitest run; cp $TMPDIR/a.bak src/a.ts')]" allow
t "check inside the window is no pass"        "[$U,$E,$(bj 'cp src/a.ts /tmp/x/a.ts.bak'),$(bj 'git show HEAD:src/a.ts > src/a.ts'),$V,$(bj 'cp /tmp/x/a.ts.bak src/a.ts')]" block
EB="{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/b.ts\"}}"
t "dir backup of two files, restored"        "[$U,$E,$EB,$V,$(bj 'H=/tmp/x/hold; cp src/a.ts src/b.ts $H/; echo x > src/a.ts; echo y > src/b.ts; npx vitest run; cp $H/a.ts $H/b.ts src/')]" allow
t "dir restore of one file, other unverified" "[$U,$E,$V,$EB,$(bj 'H=/tmp/x/hold; cp src/a.ts src/b.ts $H/; echo x > src/a.ts; cp $H/a.ts src/')]" block
t "cp of another file is no restore"          "[$U,$E,$V,$(bj 'cp /tmp/other.ts src/a.ts')]" block
t "restore of a different backup is a write"  "[$U,$E,$V,$(bj 'cp src/b.ts /tmp/x/b.bak; cp /tmp/x/b.bak src/a.ts')]" block
# review fixes: in-place edits that look like checks, rev checkouts, heredoc-only mentions, tracked temp names, timing, shared block
t "sed jest->vitest in-place after the check" "[$U,$V,$(bj "sed -i '' 's/jest/vitest/g' src/a.test.ts")]" block
t "edit then sed -i on src/jest.setup.ts"     "[$U,$E,$(bj "sed -i '' 's/x/y/' src/jest.setup.ts")]" block
t "perl -pi on a vitest file after the check" "[$U,$V,$(bj "perl -pi -e 's/a/b/' src/vitest.setup.ts")]" block
t "edit then git checkout origin/dev -- file" "[$U,$E,$(bj 'git checkout origin/dev -- src/a.ts')]" block
t "git checkout origin/dev -- file after check" "[$U,$V,$(bj 'git checkout origin/dev -- src/a.ts')]" block
t "edit then git checkout origin/dev file"    "[$U,$E,$(bj 'git checkout origin/dev src/a.ts')]" block
t "edit then git restore -s main file"        "[$U,$E,$(bj 'git restore -s main src/a.ts')]" block
t "edit then commit msg heredoc mentions npm test" "[$U,$E,$(bj $'git commit -m "$(cat <<EOF\nfix: a (npm test next)\nEOF\n)"')]" block
mkdir -p "$R/src"; echo x > "$R/src/temp-gauge.tsx"; git -C "$R" add src/temp-gauge.tsx; git -C "$R" commit -q -m gauge
t "tracked temp-named file is repo code"      "[$U,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/temp-gauge.tsx\"}}]" block
t "untracked temp-named beside a tracked one" "[$U,{\"use\":\"Write\",\"in\":{\"file_path\":\"$R/playwright.tmp.config.ts\"}},{\"use\":\"Edit\",\"in\":{\"file_path\":\"$R/src/temp-gauge.tsx\"}},$V]" allow
t "\$TMPDIR/x.ts is scratch"                  "[$U,$V,$(bj $'cat > $TMPDIR/x.ts <<EOF\nx\nEOF')]" allow
# round 2: a segment that writes a counted file is never a check; heredoc-run checks
t "check, then sed -e … -i on a jest file"  "[$U,$V,$(bj "sed -e 's/a/b/' -i src/jest.setup.ts")]" block
t "check, then sed -E … -i on a.test.ts"    "[$U,$V,$(bj "sed -E 's/jest/vitest/' -i src/a.test.ts")]" block
t "check, then echo > src/jest.setup.ts"    "[$U,$V,$(bj "echo 'export {}' > src/jest.setup.ts")]" block
t "check, then python -c writes vitest cfg" "[$U,$V,$(bj "python3 -c \"open('src/vitest.config.ts','w').write('x')\"")]" block
t "check, then cp over src/jest.setup.ts"   "[$U,$V,$(bj "cp /tmp/x.ts src/jest.setup.ts")]" block
t "check, then git restore -s main jest"    "[$U,$V,$(bj "git restore -s main src/jest.setup.ts")]" block
t "edit then bash heredoc runs npm test"    "[$U,$E,$(bj $'bash <<EOF\nnpm test\nEOF')]" allow
t "edit then sh heredoc runs vitest"        "[$U,$E,$(bj $'sh <<\'EOF\'\nnpx vitest run\nEOF')]" allow
t "edit then bash heredoc, failed result"   "[$U,$E,$(bj $'bash <<EOF\nnpm test\nEOF' '{"res":"Exit code 1\nFAIL"}')]" block
t "edit then cat heredoc mentions npm test" "[$U,$E,$(bj $'cat <<EOF\nnpm test\nEOF')]" block
# round 3: an unparsable command keeps the gate; a shell-run body's writes count; ssh runs remotely; the budget runs from the end
t "edit then unparsable command"            "[$U,$E,$(bj 'echo "oops')]" block
t "unparsable command, then edit"           "[$U,$(bj 'echo "oops'),$E]" block
t "edit then bash heredoc tests then writes" "[$U,$E,$(bj $'bash <<EOF\nnpm test\necho x > src/a.ts\nEOF')]" block
t "check, then bash heredoc writes jest file" "[$U,$V,$(bj $'bash <<EOF\necho x > src/jest.setup.ts\nEOF')]" block
t "edit then sh heredoc sed then test"      "[$U,$E,$(bj $'sh <<EOF\nsed -i s/a/b/ src/b.ts\nnpm test\nEOF')]" allow
t "edit then ssh heredoc npm test"          "[$U,$E,$(bj $'ssh host <<EOF\nnpm test\nEOF')]" block
t "edit then 21 KB echo; npm test"          "[$U,$E,$(bj "echo $(printf 'a%.0s' $(seq 1 21000)); npm test")]" allow
# timing: big commands finish within TB seconds (SECONDS granularity). CV_TIME_BUDGET=<s> sets TB outright and never SKIPs.
# Else the 1-min load is read AFTER the run (load lags; CV_LOAD=<n> overrides the read): above 3×cores → SKIP, so load alone
# never reddens the suite; otherwise TB = 3 s × ceil(load / cores), never under 3 s.
cv_budget() { python3 -I -c '
import math, os
n = os.cpu_count() or 1
l = float(os.environ.get("CV_LOAD") or os.getloadavg()[0])
print("SKIP" if l > 3 * n else 3 * max(1, math.ceil(l / n)), l, n)' 2>/dev/null || echo "3 ? ?"; }
tm() { local TB l n; python3 "$FX" "$D/t.jsonl" "$2"; s=$SECONDS
  out=$(printf '{"transcript_path":"%s/t.jsonl","cwd":"%s"}' "$D" "$R" | bash "$H" 2>/dev/null); el=$((SECONDS - s))
  if [ -n "${CV_TIME_BUDGET:-}" ]; then TB=$CV_TIME_BUDGET
  else read -r TB l n <<<"$(cv_budget)"
    [ "$TB" = SKIP ] && { echo "SKIP $1 (load $l > 3x $n cores; took ${el}s)"; return 0; }
  fi
  [ "$el" -lt "$TB" ] && echo "PASS $1 (${el}s, budget ${TB}s)" || { echo "FAIL $1 (${el}s >= budget ${TB}s)"; fail=1; }; }
BIG=$(python3 -c '
import json
q = chr(39) * 3
rows = "\n".join("<tr class=\"row\" data-id=\"r%d\"><td title=\"cell\">%d</td></tr>" % (i, i) for i in range(2500))
cmd = "python3 - <<" + chr(39) + "PY" + chr(39) + "\nhtml = " + q + "<table>\n" + rows + "\n</table>" + q + "\nopen(\"/x/report.html\",\"w\").write(html)\nPY"
print(json.dumps({"use": "Bash", "in": {"command": cmd}}))')
tm "150 KB python heredoc html within budget" "[$U,$E,$BIG]"
NPMX=$(python3 -c 'import json; print(json.dumps({"use":"Bash","in":{"command":"echo \"" + "npm x " * 12000 + "\""}}))')
tm "72 KB one-line echo npm x within budget" "[$U,$E,$NPMX]"
DEFS=$(python3 -c '
import json
body = "".join("def f%d(a):\n  open(a, \"w\")\n" % i for i in range(6000))
cmd = "python3 - <<" + chr(39) + "PY" + chr(39) + "\n" + body + "f0(\"/x/o.txt\")\nPY"
print(json.dumps({"use": "Bash", "in": {"command": cmd}}))')
tm "6000 python defs in a heredoc within budget" "[$U,$E,$DEFS]"
SEGS=$(python3 -c 'import json; print(json.dumps({"use":"Bash","in":{"command":" ; ".join(["echo \"" + "npm x " * 3300 + "\""] * 10)}}))')
tm "193 KB of echo segments within budget" "[$U,$E,$SEGS]"
# the repo-scope block is byte-identical in both hooks
RV="$(dirname "$H")/render-verify.sh"
if [ ! -f "$RV" ]; then echo "PASS shared block identical (skipped: no render-verify.sh next to \$H)"
elif [ -n "$(sed -n '/^# --- repo scope/p' "$H")" ] && diff <(sed -n '/^# --- repo scope/,/^# --- end repo scope/p' "$H") \
     <(sed -n '/^# --- repo scope/,/^# --- end repo scope/p' "$RV") >/dev/null; then echo "PASS shared block identical"
else echo "FAIL shared block identical"; fail=1; fi
# explain seam
python3 "$FX" "$D/t.jsonl" "[$U,$E,{\"use\":\"Edit\",\"in\":{\"file_path\":\"$D/out/b.ts\"}}]"
rm -f "$D/ex.jsonl"
printf '{"transcript_path":"%s/t.jsonl","cwd":"%s"}' "$D" "$R" | VERIFY_HOOK_EXPLAIN="$D/ex.jsonl" bash "$H" >/dev/null 2>&1
if python3 -I -c '
import json, sys
d = json.loads(open(sys.argv[1]).read().splitlines()[-1])
w = {f["why"] for f in d["files"]}
sys.exit(0 if d["hook"] == "check-verify" and d["decision"] == "block" and {"in-repo", "out-of-repo"} <= w else 1)
' "$D/ex.jsonl" 2>/dev/null; then echo "PASS explain"; else echo "FAIL explain"; fail=1; fi
echo '{"scripts":{}}' > "$R/package.json"
t "no check script"                "[$U,$E]" allow
rm "$R/package.json"
t "no package.json"                "[$U,$E]" allow
out=$(printf 'not json' | bash "$H" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && echo "PASS garbage fails open" || { echo "FAIL garbage fails open"; fail=1; }
exit $fail
