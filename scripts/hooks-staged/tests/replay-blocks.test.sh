#!/bin/bash
# Usage: bash <hooks dir>/tests/replay-blocks.test.sh  → PASS/FAIL per case, exit 1 on any FAIL
HERE="$(cd "$(dirname "$0")" && pwd)"; fail=0
top=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null); [ "$top" = "$(cd "$HERE/../../.." && pwd -P)" ] || { echo "SKIP replay-blocks: $HERE is not in its own git checkout (export tree; replay reads hooks from git history)"; exit 77; }
# the old hooks come from a private-history commit (replay-blocks.py's --old-ref default): a public
# mirror or a fresh copy has a checkout but not that commit
for sha in $(sed -n 's/.*"--old-ref", default="\([0-9a-f]*\)".*/\1/p' "$HERE/replay-blocks.py"); do
  git -C "$top" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "SKIP replay-blocks: history commit $sha is not in this checkout"; exit 77; }
done
# not under /var/folders or /tmp: the harness refuses scratch --out dirs (the old hook ignores them)
mkdir -p "$HOME/.cache"; T=$(mktemp -d "$HOME/.cache/rumo-replay-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
RB="$HERE/replay-blocks.py"
R="$T/orca/projects/demo"; git init -q "$R"; mkdir -p "$R/src" "$T/outside" "$T/projects/s" "$T/orca/workspaces/ghost"
# the old hook walks up from cwd to find package.json: give f's missing cwd an ancestor that has one,
# so the old hook still blocks f (otherwise the 95% sanity rate could never hold in this fixture)
echo '{"scripts":{"test":"x"}}' > "$T/orca/workspaces/ghost/package.json"
echo '{"scripts":{"test":"x"}}' > "$R/package.json"
git -C "$R" add -A; git -C "$R" commit -q -m init

# ok NAME CONDITION(0|1)   — PASS when the condition command succeeded
ok() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

# --- fixture transcripts ---
python3 -I - "$T" <<'PY'
import json, sys
T = sys.argv[1]
def cmd(hook):
    return '/bin/bash "$HOME/.claude/hooks/%s.sh"' % hook
def write(name, cwd, edit, hook, ts):
    reason = "blocked by %s" % hook
    L = [
        {"type": "user", "message": {"role": "user", "content": "do it"}},
        {"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "t1", "name": "Edit", "input": {"file_path": edit}}]}},
        {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "done"}]}},
        {"type": "attachment", "cwd": cwd, "timestamp": ts,
         "attachment": {"type": "hook_success", "hookName": "Stop", "hookEvent": "Stop"}},
        {"type": "user", "isMeta": True, "message": {"role": "user",
         "content": "Stop hook feedback:\n" + reason}},
        {"type": "attachment", "cwd": cwd, "timestamp": ts,
         "attachment": {"type": "hook_blocking_error", "hookName": "Stop", "hookEvent": "Stop",
                        "blockingError": {"blockingError": reason, "command": cmd(hook)}}},
        {"type": "user", "message": {"role": "user", "content": "ok"}},
    ]
    open("%s/projects/s/%s.jsonl" % (T, name), "w").write("\n".join(json.dumps(x) for x in L) + "\n")
R = T + "/orca/projects/demo"
write("a", R, R + "/src/a.ts", "check-verify", "2026-10-22T10:00:00Z")
write("b", R, T + "/outside/x.ts", "check-verify", "2026-10-23T10:00:00Z")
write("c", R, R + "/src/a.css", "render-verify", "2026-10-24T10:00:00Z")
write("d", R, R + "/src/a.ts", "check-verify", "2026-10-01T10:00:00Z")
# e: worktree of demo that no longer exists; f: worktree of a repo with no main checkout
write("e", T + "/orca/workspaces/demo/gone", T + "/orca/workspaces/demo/gone/src/a.ts", "check-verify", "2026-10-25T10:00:00Z")
write("f", T + "/orca/workspaces/ghost/w", T + "/orca/workspaces/ghost/w/a.ts", "check-verify", "2026-10-25T11:00:00Z")
PY

OUT="$T/out"
SUM=$(python3 -I "$RB" --since 2026-10-21 --out "$OUT" --projects "$T/projects" --orca "$T/orca" 2>"$T/err"); rc=$?
ok "harness exits 0" $([ "$rc" = 0 ] && echo 0 || echo 1)
[ "$rc" = 0 ] || { echo "$SUM"; cat "$T/err"; }

# rf BASENAME FIELD → prints the record's field (strings raw; "files" → its why values)
rf() { python3 -I - "$OUT/records.jsonl" "$1" "$2" <<'PY'
import json, os, sys
path, base, field = sys.argv[1:4]
for l in open(path):
    r = json.loads(l)
    if os.path.basename(r["source"]) == base + ".jsonl":
        v = r["files"] if field == "files_why" else r[field]
        if field == "files_why":
            v = " ".join(f["why"] for f in v)
        print(v)
PY
}
n=$(wc -l < "$OUT/records.jsonl" 2>/dev/null | tr -d ' ')
ok "5 records (d excluded)" $([ "$n" = 5 ] && echo 0 || echo 1)
ok "a old block new block" $([ "$(rf a old_verdict) $(rf a new_verdict)" = "block block" ] && echo 0 || echo 1)
ok "b old block new allow" $([ "$(rf b old_verdict) $(rf b new_verdict)" = "block allow" ] && echo 0 || echo 1)
ok "c old block new block" $([ "$(rf c old_verdict) $(rf c new_verdict)" = "block block" ] && echo 0 || echo 1)
if ls "$OUT"/cut/*.jsonl >/dev/null 2>&1 && ! grep -lF -e 'Stop hook feedback' -e '"ok"' "$OUT"/cut/*.jsonl >/dev/null 2>&1; then c=0; else c=1; fi
ok "cut drops the block and later lines" $c
echo "$SUM" | grep -q 'old-hook reproduce: 5/5'; ok "summary reproduce 5/5" $?
case "$(rf b files_why)" in *out-of-repo*) c=0;; *) c=1;; esac
ok "b files why out-of-repo" $c

# labels: ids come from records.jsonl
mklabels() { python3 -I - "$OUT/records.jsonl" "$T/labels.jsonl" "$1" "$2" "$3" <<'PY'
import json, os, sys
rec, out, la, lb, lc = sys.argv[1:6]
m = {"a": la == "true", "b": lb == "true", "c": lc == "true"}  # e/f stay unlabelled
with open(out, "w") as o:
    for l in open(rec):
        r = json.loads(l)
        k = os.path.basename(r["source"])[:-6]
        if k not in m:
            continue
        o.write(json.dumps({"id": r["id"], "label": m[k], "why": "test"}) + "\n")
PY
}
mklabels true false true
LS=$(python3 -I "$RB" --since 2026-10-21 --out "$OUT" --projects "$T/projects" --orca "$T/orca" --labels "$T/labels.jsonl" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && echo "$LS" | grep -q 'CRITERION PASS'; then c=0; else c=1; echo "$LS"; fi
ok "labels pass" $c
mklabels true true true
LS=$(python3 -I "$RB" --since 2026-10-21 --out "$OUT" --projects "$T/projects" --orca "$T/orca" --labels "$T/labels.jsonl" 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && echo "$LS" | grep -q 'CRITERION FAIL' && echo "$LS" | grep -q 'REGRESSION'; then c=0; else c=1; echo "rc=$rc"; echo "$LS"; fi
ok "labels fail" $c
# --- step 5: stand-in worlds, --assume-marker, judge pack ---
case "$(rf e cwd_status)" in standin) c=0;; *) c=1;; esac
ok "e standin" $c
ok "e standin old block new block" $([ "$(rf e old_verdict) $(rf e new_verdict)" = "block block" ] && echo 0 || echo 1)
ok "f unresolved" $([ "$(rf f cwd_status)" = unresolved ] && echo 0 || echo 1)
ok "a stays live" $([ "$(rf a cwd_status)" = live ] && echo 0 || echo 1)
echo "$SUM" | grep -q 'standin: 1 · old reproduce 1/1'; ok "summary per status standin" $?
echo "$SUM" | grep -q 'unresolved: 1 · old reproduce'; ok "summary per status unresolved" $?
[ ! -e "$T/orca/workspaces/demo/gone" ] && [ ! -e "$T/orca/workspaces/ghost/w" ]; ok "world never touches the orca tree" $?

OUT2="$T/out2"
SUM2=$(python3 -I "$RB" --since 2026-10-21 --out "$OUT2" --projects "$T/projects" --orca "$T/orca" --assume-marker demo --judge-pack "$T/pack.jsonl" 2>"$T/err2"); rc=$?
ok "assume-marker run exits 0" $([ "$rc" = 0 ] && echo 0 || echo 1)
[ "$rc" = 0 ] || { echo "$SUM2"; cat "$T/err2"; }
rf2() { OUT="$OUT2" rf "$@"; }
ok "c allowed with assumed marker" $([ "$(rf2 c new_verdict) $(rf2 c cwd_status)" = "allow standin" ] && echo 0 || echo 1)
ok "a still blocks with marker" $([ "$(rf2 a new_verdict)" = block ] && echo 0 || echo 1)
n=$(wc -l < "$T/pack.jsonl" 2>/dev/null | tr -d ' ')
ok "pack has one line per record" $([ "$n" = 5 ] && echo 0 || echo 1)
if [ -s "$T/pack.jsonl" ] && ! grep -qiE 'verdict|"explain"' "$T/pack.jsonl"; then c=0; else c=1; fi
ok "pack hides verdicts" $c
a_id=$(rf a id)
if python3 -I - "$T/pack.jsonl" "$a_id" "$R" <<'PY'
import json, sys
path, rid, R = sys.argv[1:4]
for l in open(path):
    e = json.loads(l)
    if e["id"] == rid:
        sys.exit(0 if ("Edit %s/src/a.ts" % R) in e["timeline"] and e["last_user"] == "do it" else 1)
sys.exit(1)
PY
then c=0; else c=1; fi
ok "pack timeline names the edit" $c

# --- step 7: $HOME/~ spellings, clean worktree names, --assume-marker on a live non-orca repo ---
M="$T/docs/Motions"; git init -q "$M"; mkdir -p "$M/src"; echo '{"scripts":{"test":"x"}}' > "$M/package.json"
git -C "$M" add -A; git -C "$M" commit -q -m init
ORELH="${T#$HOME/}/orca"   # the fixture's orca dir relative to $HOME
python3 -I - "$T" "$ORELH" <<'PY'
import json, os, sys
T, REL = sys.argv[1:3]
os.makedirs(T + "/projects3/s", exist_ok=True)
def write(name, cwd, tool_input, tool, hook, ts):
    reason = "blocked by %s" % hook
    L = [
        {"type": "user", "message": {"role": "user", "content": "do it"}},
        {"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "t1", "name": tool, "input": tool_input}]}},
        {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "done"}]}},
        {"type": "attachment", "cwd": cwd, "timestamp": ts,
         "attachment": {"type": "hook_blocking_error", "hookName": "Stop", "hookEvent": "Stop",
                        "blockingError": {"blockingError": reason,
                                          "command": '/bin/bash "$HOME/.claude/hooks/%s.sh"' % hook}}},
    ]
    open("%s/projects3/s/%s.jsonl" % (T, name), "w").write("\n".join(json.dumps(x) for x in L) + "\n")
def bash(root, wt):
    return {"command": 'cd "%s/workspaces/demo/%s/src" && cat > a.ts <<EOF\nx\nEOF' % (root, wt)}
W = T + "/orca/workspaces/demo/"
write("g1", W + "wtg1", bash("$HOME/" + REL, "wtg1"), "Bash", "check-verify", "2026-10-25T10:00:00Z")
write("g2", W + "wtg2", bash("${HOME}/" + REL, "wtg2"), "Bash", "check-verify", "2026-10-25T10:01:00Z")
write("g3", W + "wtg3", bash("~/" + REL, "wtg3"), "Bash", "check-verify", "2026-10-25T10:02:00Z")
write("h", W + "wth", {"command": "cd %s/workspaces/demo/wth; cat > src/a.ts <<EOF\nx\nEOF" % (T + "/orca")},
      "Bash", "check-verify", "2026-10-25T10:03:00Z")
write("j", W + "wtj", {"command": "cd %s/projects/demo; sed -i '' s/a/b/ src/a.ts" % (T + "/orca")},
      "Bash", "check-verify", "2026-10-25T10:05:00Z")
write("i", T + "/docs/Motions", {"file_path": T + "/docs/Motions/src/a.css"}, "Edit", "render-verify",
      "2026-10-25T10:04:00Z")
PY
OUT3="$T/out3"
python3 -I "$RB" --since 2026-10-21 --out "$OUT3" --projects "$T/projects3" --orca "$T/orca" --assume-marker motions >/dev/null 2>"$T/err3"; rc=$?
ok "step7 run exits 0" $([ "$rc" = 0 ] && echo 0 || echo 1)
[ "$rc" = 0 ] || cat "$T/err3"
rf3() { OUT="$OUT3" rf "$@"; }
for g in g1 g2 g3; do
  ok "$g standin, new hook blocks" $([ "$(rf3 $g cwd_status) $(rf3 $g new_verdict)" = "standin block" ] && echo 0 || echo 1)
done
ok "j projects/demo; counted in-repo, new hook blocks" $([ "$(rf3 j cwd_status) $(rf3 j new_verdict)" = "standin block" ] && echo 0 || echo 1)
hid=$(rf3 h id)
bad=$(ls "$OUT3/world/$hid/workspaces/demo" 2>/dev/null | grep -c '[;`)]')
ok "h world has no dir with ; in its name" $([ -n "$hid" ] && [ "$bad" = 0 ] && [ -d "$OUT3/world/$hid/workspaces/demo/wth" ] && echo 0 || echo 1)
ok "i live, old block, new allow with --assume-marker" $([ "$(rf3 i cwd_status) $(rf3 i old_verdict) $(rf3 i new_verdict)" = "live block allow" ] && echo 0 || echo 1)
ok "i never writes into the real repo" $([ ! -e "$M/.claude" ] && echo 0 || echo 1)
python3 -I "$RB" --since 2026-10-21 --out "$T/out4" --projects "$T/projects3" --orca "$T/orca" >/dev/null 2>&1
ok "i blocks without --assume-marker" $([ "$(OUT="$T/out4" rf i new_verdict)" = block ] && echo 0 || echo 1)

# --- step 9: assumed marker also when an orca stand-in was built; ignore rules copied into stand-ins ---
python3 -I - "$T" <<'PY'
import json, os, sys
T = sys.argv[1]
os.makedirs(T + "/projects5/s", exist_ok=True)
cwd = T + "/docs/Motions"
gone = T + "/orca/workspaces/demo/gone2"
L = [
    {"type": "user", "message": {"role": "user", "content": "do it"}},
    {"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t0", "name": "Bash", "input": {"command": "ls " + gone}},
        {"type": "tool_use", "id": "t1", "name": "Edit", "input": {"file_path": cwd + "/src/a.css"}}]}},
    {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "done"}]}},
    {"type": "attachment", "cwd": cwd, "timestamp": "2026-10-25T10:06:00Z",
     "attachment": {"type": "hook_blocking_error", "hookName": "Stop", "hookEvent": "Stop",
                    "blockingError": {"blockingError": "blocked by render-verify",
                                      "command": '/bin/bash "$HOME/.claude/hooks/render-verify.sh"'}}},
]
open(T + "/projects5/s/k.jsonl", "w").write("\n".join(json.dumps(x) for x in L) + "\n")
PY
OUT5="$T/out5"
python3 -I "$RB" --since 2026-10-21 --out "$OUT5" --projects "$T/projects5" --orca "$T/orca" --assume-marker motions >/dev/null 2>"$T/err5"; rc=$?
ok "step9 run exits 0" $([ "$rc" = 0 ] && echo 0 || echo 1)
[ "$rc" = 0 ] || cat "$T/err5"
ok "k live cwd + orca stand-in: old block, new allow with --assume-marker" $([ "$(OUT="$OUT5" rf k old_verdict) $(OUT="$OUT5" rf k new_verdict)" = "block allow" ] && echo 0 || echo 1)
ok "k never writes into the real repo" $([ ! -e "$M/.claude" ] && echo 0 || echo 1)

# stand-ins carry the real repo's ignore rules
echo '.rumo/' >> "$R/.git/info/exclude"
mkdir -p "$R/pkg"; echo 'dist/' > "$R/.gitignore"; echo 'build/' > "$R/pkg/.gitignore"
git -C "$R" add -A; git -C "$R" commit -q -m ignores
python3 -I "$RB" --since 2026-10-21 --out "$T/out6" --projects "$T/projects3" --orca "$T/orca" >/dev/null 2>&1
hid6=$(OUT="$T/out6" rf g1 id)
SI="$T/out6/world/$hid6/projects/demo"
ok "stand-in .git/info/exclude has .rumo/" $([ -n "$hid6" ] && grep -qxF '.rumo/' "$SI/.git/info/exclude" && echo 0 || echo 1)
ok "stand-in .gitignore has dist/" $([ -n "$hid6" ] && grep -qxF 'dist/' "$SI/.gitignore" && echo 0 || echo 1)
ok "stand-in nested .gitignore copied" $([ -n "$hid6" ] && grep -qxF 'build/' "$SI/pkg/.gitignore" && echo 0 || echo 1)
ok "stand-in worktree sees the exclude" $([ -n "$hid6" ] && [ -n "$(git -C "$T/out6/world/$hid6/workspaces/demo/wtg1" check-ignore -q .rumo/x && echo y)" ] && echo 0 || echo 1)

# --- step 10: judge pack shows whole commands, heredoc stubs and result tails ---
python3 -I - "$T" <<'PY2'
import json, os, sys
T = sys.argv[1]
os.makedirs(T + "/projects7/s", exist_ok=True)
R = T + "/orca/projects/demo"
def write(name, cmd, result, ts, extra=None):
    use = {"type": "tool_use", "id": "t1", "name": "Bash", "input": dict({"command": cmd}, **(extra or {}))}
    L = [
        {"type": "user", "message": {"role": "user", "content": "do it"}},
        {"type": "assistant", "cwd": R, "message": {"role": "assistant", "content": [use]}},
        {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": result}]}},
        {"type": "attachment", "cwd": R, "timestamp": ts,
         "attachment": {"type": "hook_blocking_error", "hookName": "Stop", "hookEvent": "Stop",
                        "blockingError": {"blockingError": "blocked by check-verify",
                                          "command": '/bin/bash "$HOME/.claude/hooks/check-verify.sh"'}}},
    ]
    open("%s/projects7/s/%s.jsonl" % (T, name), "w").write("\n".join(json.dumps(x) for x in L) + "\n")
long = "sed -i '' s/a/b/ src/a.ts && " + "echo padding && " * 30 + "npx vitest run src"
write("p1", long, "Exit code 1\n... Tests 1 failed", "2026-10-25T10:10:00Z")
heredoc = "cat > src/a.ts <<EOF\n" + "a" * 200 + "\nsecond\nthird_marker\nEOF\npnpm typecheck"
write("p2", heredoc, "ok", "2026-10-25T10:11:00Z", {"run_in_background": True})
PY2
OUT7="$T/out7"
python3 -I "$RB" --since 2026-10-21 --out "$OUT7" --projects "$T/projects7" --orca "$T/orca" --judge-pack "$T/pack7.jsonl" >/dev/null 2>"$T/err7"; rc=$?
ok "step10 run exits 0" $([ "$rc" = 0 ] && echo 0 || echo 1)
[ "$rc" = 0 ] || cat "$T/err7"
# pk ID → prints the record's Bash timeline entry
pk() { python3 -I - "$T/pack7.jsonl" "$1" <<'PY3'
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["id"] == sys.argv[2]:
        print(" | ".join(t for t in e["timeline"] if t.startswith("Bash")))
PY3
}
P1=$(pk "$(OUT="$OUT7" rf p1 id)"); P2=$(pk "$(OUT="$OUT7" rf p2 id)")
case "$P1" in *"npx vitest run src"*) c=0;; *) c=1;; esac
ok "pack keeps the check at the end of a long command" $c
case "$P1" in *"[exit 1]"*"Tests 1 failed"*) c=0;; *) c=1;; esac
ok "pack shows [exit 1] and the result tail" $c
case "$P2" in *"[3 lines:"*) c=0;; *) c=1;; esac
ok "pack stubs a heredoc with its line count" $c
case "$P2" in *third_marker*) c=1;; *) c=0;; esac
ok "pack drops the heredoc body past 160 chars" $c
case "$P2" in *"pnpm typecheck"*"(background)"*) c=0;; *) c=1;; esac
ok "pack keeps the command after the heredoc and flags background" $c

python3 -I "$RB" --since 2026-10-21 --out /tmp/rb-x --projects "$T/projects" --orca "$T/orca" >/dev/null 2>&1; rc=$?
ok "scratch out refused" $([ "$rc" = 2 ] && [ ! -e /tmp/rb-x ] && echo 0 || echo 1)
rmdir /tmp/rb-x 2>/dev/null

# no --out → refused before anything is written (a default once filled ~/.claude/learn/replay with GBs of cuts)
HOME="$T/home" python3 -I "$RB" --since 2026-10-21 --projects "$T/projects" --orca "$T/orca" >/dev/null 2>&1; rc=$?
ok "missing --out refused" $([ "$rc" = 2 ] && [ ! -e "$T/home" ] && echo 0 || echo 1)
exit $fail
