#!/usr/bin/env bash
# Run: bash tests/wave_host_test.sh — offline: sync-host, the remote shell and orca are stubs over a throwaway
# git clone standing in for the host's home; exit 1 on any FAIL. Never runs ssh or a real orca.
H="$(cd "$(dirname "$0")/.." && pwd)/scripts/wave-host.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
has() { printf '%s\n' "$out" | grep -qFx -- "$1"; }   # has LINE: that exact line is in $out
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export T CALLS="$T/calls"; : > "$CALLS"
mkdir -p "$T/bin" "$T/hosthome/orca/projects" "$T/seed"
git init -q --bare -b master "$T/origin.git"
(cd "$T/seed" && git init -q -b master && echo hi > f && git add f && git commit -qm init && git push -q "$T/origin.git" master)
git clone -q "$T/origin.git" "$T/hosthome/orca/projects/rumo"
CLONE="$T/hosthome/orca/projects/rumo"
printf '# brief\nline two\n' > "$T/rumo-w1.md"
cat > "$T/sync" <<'STUB'
#!/bin/bash
echo "sync $*" >> "$CALLS"
echo "syncenv ${SYNC_REMOTE_SH:-unset}" >> "$CALLS"
echo "syncwrap ${SYNC_REMOTE_WRAP:-unset}" >> "$CALLS"
exit "${STUB_PF:-0}"
STUB
cat > "$T/rsh" <<'STUB'
#!/bin/bash
echo "rsh $1 $2" >> "$CALLS"
cd "$T/hosthome" && HOME="$T/hosthome" bash -c "$2"
STUB
cat > "$T/bin/orca" <<'STUB'
#!/bin/bash
echo "orca $*" >> "$CALLS"
case "$1 $2" in
  "repo list") printf '{"ok":true,"result":{"repos":['
    [ -s "$T/repos" ] && awk '{printf "%s{\"id\":\"%s\",\"path\":\"%s\"}", (NR>1?",":""), $1, $2}' "$T/repos"
    printf ']}}\n' ;;
  "repo add") while [ $# -gt 0 ]; do [ "$1" = --path ] && echo "r9 $2" >> "$T/repos"; shift; done
    echo '{"ok":true}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/sync" "$T/rsh" "$T/bin/orca"
export PATH="$T/bin:$PATH" WAVE_SYNC_HOST="$T/sync" WAVE_REMOTE_SH="$T/rsh"
run() { bash "$H" "$@" 2>"$T/err"; }

# (a) happy path, repo not yet registered in the host's Orca
out=$(run mini rumo master "$T/rumo-w1.md"); rc=$?
ok "(a) exit 0" '[ "$rc" = 0 ]'
ok "(a) PLACE line" 'has "PLACE mini repo=id:r9 path=$CLONE brief=$T/hosthome/.claude/learn/waves/rumo-w1.md"'
ok "(a) brief copied byte-equal" 'cmp -s "$T/rumo-w1.md" "$T/hosthome/.claude/learn/waves/rumo-w1.md"'
ok "(a) one repo add on the host's orca" '[ "$(grep -c "^orca repo add --environment mini --path $CLONE" "$CALLS")" = 1 ]'
ok "(a) preflight ran" 'grep -q "^sync mini --preflight" "$CALLS"'
(cd "$T/seed" && echo more >> f && git commit -qam second && git push -q "$T/origin.git" master)
# (b) second run: registered already
out=$(run mini rumo master "$T/rumo-w1.md"); rc=$?
ok "(b) exit 0, same PLACE" '[ "$rc" = 0 ] && has "PLACE mini repo=id:r9 path=$CLONE brief=$T/hosthome/.claude/learn/waves/rumo-w1.md"'
ok "(b) fetched <base> from origin" '[ "$(git -C "$CLONE" rev-parse origin/master)" = "$(git -C "$T/origin.git" rev-parse master)" ]'
ok "(b) no second repo add" '[ "$(grep -c "^orca repo add" "$CALLS")" = 1 ]'
ok "(j) every remote string goes through bash -c" 'grep -q "^rsh " "$CALLS" && ! grep "^rsh " "$CALLS" | grep -qv "^rsh mini bash -c "'
# (c) extra flags reach sync-host
: > "$CALLS"
out=$(run mini rumo master "$T/rumo-w1.md" --runtime node); rc=$?
ok "(c) --runtime node passed to sync-host" 'grep -qx "sync mini --preflight --runtime node" "$CALLS"'
ok "(k) WAVE_REMOTE_SH reaches sync-host as SYNC_REMOTE_SH" 'grep -qxF "syncenv $T/rsh mini" "$CALLS"'
ok "(m) WAVE_REMOTE_SH set → SYNC_REMOTE_WRAP=1" 'grep -qx "syncwrap 1" "$CALLS"'
: > "$CALLS"
out=$(env -u WAVE_REMOTE_SH -u SYNC_REMOTE_SH STUB_PF=1 bash "$H" mini rumo master "$T/rumo-w1.md" 2>/dev/null)
ok "(k) WAVE_REMOTE_SH unset → SYNC_REMOTE_SH left unset" 'grep -qx "syncenv unset" "$CALLS" && grep -qx "syncwrap unset" "$CALLS" && [ "$out" = "PLACE local reason=preflight-fail" ]'
ok "(l) wave-host.sh has no ssh default or orca repo add of its own" '! grep -q "ssh -o BatchMode" "$H" && ! grep -q "orca repo add" "$H" && grep -q "orca_repo_add" "$H" && [ "$(grep -c '"'"'bash "$sync"'"'"' "$H")" = 1 ]'
# (d) preflight FAIL → local, nothing else touches the host
: > "$CALLS"
out=$(STUB_PF=1 run mini rumo master "$T/rumo-w1.md"); rc=$?
ok "(d) PLACE local reason=preflight-fail, exit 0" '[ "$rc" = 0 ] && [ "$out" = "PLACE local reason=preflight-fail" ]'
ok "(d) WARN on stderr" 'grep -q "^WARN: mini: preflight-fail" "$T/err"'
ok "(d) no orca, no rsh call" '! grep -qE "^(orca|rsh)" "$CALLS"'
# (e) host unreachable
: > "$CALLS"
out=$(STUB_PF=3 run mini rumo master "$T/rumo-w1.md"); rc=$?
ok "(e) reason=unreachable, exit 0" '[ "$rc" = 0 ] && [ "$out" = "PLACE local reason=unreachable" ]'
ok "(e) no orca, no rsh call" '! grep -qE "^(orca|rsh)" "$CALLS"'
# (f) repo not cloned on the host
: > "$CALLS"
out=$(run mini nosuch master "$T/rumo-w1.md"); rc=$?
ok "(f) reason=no-clone, exit 0" '[ "$rc" = 0 ] && [ "$out" = "PLACE local reason=no-clone" ]'
ok "(f) no repo add" '! grep -q "^orca repo add" "$CALLS"'
# (h) clone present, <base> missing on origin → fetch-fail, not no-clone
: > "$CALLS"; : > "$T/repos"
out=$(run mini rumo nosuchbranch "$T/rumo-w1.md"); rc=$?
ok "(h) reason=fetch-fail, exit 0" '[ "$rc" = 0 ] && [ "$out" = "PLACE local reason=fetch-fail" ]'
ok "(h) WARN on stderr" 'grep -q "^WARN: mini: fetch-fail" "$T/err"'
ok "(h) no repo add" '! grep -q "^orca repo add" "$CALLS"'
# (i) remote shell strings carry the Homebrew PATH prefix
ok "(i) clone check has /opt/homebrew/bin" 'grep -q "^rsh mini bash -c .*/opt/homebrew/bin.*rev-parse" "$CALLS"'
ok "(i) fetch has /opt/homebrew/bin" 'grep -q "^rsh mini bash -c .*/opt/homebrew/bin.*git.*fetch" "$CALLS"'
# (g) usage errors
bash "$H" mini rumo master >/dev/null 2>&1; rc=$?; ok "(g) 3 args → exit 2" '[ "$rc" = 2 ]'
bash "$H" local rumo master "$T/rumo-w1.md" >/dev/null 2>&1; rc=$?; ok "(g) host local → exit 2" '[ "$rc" = 2 ]'
bash "$H" mini rumo master "$T/missing.md" >/dev/null 2>&1; rc=$?; ok "(g) missing brief → exit 2" '[ "$rc" = 2 ]'
exit $fail
