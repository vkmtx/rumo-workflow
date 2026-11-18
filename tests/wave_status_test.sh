#!/usr/bin/env bash
# Run: bash tests/wave_status_test.sh — offline: gh, orca, sysctl, memory_pressure and pgrep are PATH stubs; exit 1 on any FAIL.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/wave-status.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
has() { printf '%s\n' "$out" | grep -qFx -- "$1"; }   # has LINE: that exact line is in $out
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P="$T/home/.claude/learn/waves"; B="$T/bin"; W="$P/w1.state"; mkdir -p "$B" "$W" "$T/tmp"; export CALLS="$T/calls"
# launch results as wave.md §4 saves them: the shape orca returns today (result.outcome) and the nested one (result.launch.outcome)
echo '{"ok":true,"result":{"outcome":{"kind":"terminal","handle":"term_alive"},"worktreeId":"r1::/wt/13-a"}}' > "$W/13.json"
echo '{"ok":true,"result":{"launch":{"outcome":{"handle":"term_dead"},"worktreeId":"r1::/wt/14-b"}}}' > "$W/14.json"
echo '{"ok":false}' > "$W/15.json"
echo '{"ok":true,"result":{"worktree":{"id":"r1::/wt/13-a"}}}' > "$W/wt13.json"   # a worktree-create result, not a slot
echo '{"ok":true,"result":{"outcome":{"handle":"term_r"},"worktreeId":"r2::/wt/16-c"}}' > "$W/16@mini.json"   # a remote lane
mkdir -p "$P/w2.state"   # a wave with no slots
cat > "$B/orca" <<'EOF'
#!/bin/bash
echo "orca $*" >> "$CALLS"
[ -n "${STUB_FAIL:-}" ] && { echo 'not json'; exit 1; }
case "$*" in
  "terminal show --terminal term_alive --json") echo '{"ok":true,"result":{"terminal":{"handle":"term_alive","connected":true}}}' ;;
  "terminal show --terminal term_dead --json") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}' ;;
  "worktree show --worktree id:r1::/wt/13-a --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/feat/13-a","comment":"PR #40","path":"/nonexistent/13-a"}}}' ;;
  "worktree show --worktree id:r1::/wt/14-b --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/feat/14-b","comment":"built","path":"/nonexistent/14-b"}}}' ;;
  "terminal show --environment mini --terminal term_r --json") echo '{"ok":true,"result":{"terminal":{"handle":"term_r","connected":true}}}' ;;
  "worktree show --environment mini --worktree id:r2::/wt/16-c --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/feat/16-c","comment":"built","path":"/nonexistent/16-c"}}}' ;;
  "worktree show --worktree id:r1::/wt/17-sp --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/feat/17-sp","comment":"spaced","path":"/nonexistent/17 sp"}}}' ;;
  "worktree show --worktree id:r1::/wt/19-m --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/feat/19-m","comment":"built","path":"'"$WT19"'"}}}' ;;
  "worktree show --worktree id:r1::/wt/18-ch --json") echo '{"ok":true,"result":{"worktree":{"branch":"refs/heads/fix/18-ch","comment":"started","path":"/nonexistent/18-ch"}}}' ;;
  *) echo '{"ok":false,"error":{"code":"not_found"}}' ;;
esac
EOF
cat > "$B/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$CALLS"
[ -n "${STUB_GH_FAIL:-}" ] && { echo 'not json'; exit 1; }
case "$*" in
  "pr list --head feat/13-a --state all --json number,state") echo '[{"number":40,"state":"OPEN"}]' ;;
  "pr list --head feat/16-c --state all --json number,state --repo vkmtx/demo") echo '[{"number":41,"state":"OPEN"}]' ;;
  *) echo '[]' ;;
esac
EOF
cat > "$B/sysctl" <<'EOF'
#!/bin/bash
case "$*" in
  "-n vm.loadavg") if [ -n "${STUB_LOAD:-}" ]; then echo "$STUB_LOAD"; else echo '{ 2.37 2.12 2.54 }'; fi ;;
  "-n hw.ncpu") echo 10 ;;
  "-n hw.memsize") echo 17179869184 ;;
  "-n kern.memorystatus_vm_pressure_level") echo "${STUB_VM:-1}" ;;
esac
EOF
cat > "$B/memory_pressure" <<'EOF'
#!/bin/bash
printf 'The system has 2097152 pages\nSystem-wide memory free percentage: %s%%\n' "${STUB_FREE:-50}"
EOF
# the remote shell (WAVE_REMOTE_SH): logs the call, then runs the command string against the same sysctl/memory_pressure stubs
cat > "$T/rsh" <<'EOF'
#!/bin/bash
echo "rsh $*" >> "$CALLS"
[ -n "${REMOTE_DOWN:-}" ] && exit 255
HOME="${REMOTE_HOME:-$HOME}" STUB_LOAD="${REMOTE_LOAD:-{ 1.40 1.20 1.00 }}" STUB_FREE="${REMOTE_FREE:-40}" bash -c "$2"
EOF
cat > "$B/pgrep" <<'EOF'
#!/bin/bash
echo "pgrep $*" >> "$CALLS"
exit "${STUB_PGREP:-1}"
EOF
printf '#!/bin/bash\necho "ssh $*" >> "$CALLS"\nexit 255\n' > "$B/ssh"
chmod +x "$B"/* "$T/rsh"; export PATH="$B:$PATH" TMPDIR="$T/tmp" HOME="$T/home" WAVE_REMOTE_SH="$T/rsh" WAVE_TASKS_ROOT="$T/tasks"
out=$(bash "$S" w1); rc=$?
ok "exit 0" '[ "$rc" = 0 ]'
ok "#13: open PR, live session, card" 'has "#13 host=local pr=#40:OPEN session=alive idle=? stalled=no mem=? branch=feat/13-a card=\"PR #40\""'
ok "#14: no PR, stale handle (result.launch shape)" 'has "#14 host=local pr=none session=dead:terminal_handle_stale idle=? stalled=? mem=? branch=feat/14-b card=\"built\""'
ok "#15: no handle, no worktree" 'has "#15 host=local pr=? session=no-handle idle=? stalled=? mem=? branch=? card=?"'
ok "#16: remote slot read through --environment" 'has "#16 host=mini pr=none session=alive idle=? stalled=? mem=? branch=feat/16-c card=\"built\""'
ok "machine line (local)" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=4 pressure=no awake=no"'
ok "machine line (mini)" 'has "machine host=mini load=1.40 1.20 1.00 cores=10 free=40% vm=normal fit=1 pressure=no"'
ok "only <N>.json slots, numeric order, machine last" '[ "$(printf "%s\n" "$out" | awk "{print \$1}" | paste -sd" " -)" = "#13 #14 #15 #16 machine machine" ]'
ok "one read per source per slot" '[ "$(grep -c "^orca " "$CALLS")" = 6 ] && [ "$(grep -c "^gh " "$CALLS")" = 3 ] && [ "$(grep -c "^rsh " "$CALLS")" = 3 ]'
ok "read-only: only show/list calls" '! grep -qvE "^(orca (terminal|worktree) show|gh pr list|rsh mini|pgrep -f) " "$CALLS"'
ok "#42 load probe goes through remote_wrap (bash -c + PATH)" 'grep -q "^rsh mini bash -c .*opt/homebrew" "$CALLS"'
ok "#42 wave.md plan read uses remote_wrap" 'grep -q "remote_wrap .cat ~/.claude/learn/plans" "$(dirname "$S")/../skills/rumo/references/wave.md"'
out=$(STUB_LOAD='{ 31.00 20.00 10.00 }' bash "$S" w1)
ok "load above 3x cores → pressure=yes" 'has "machine host=local load=31.00 20.00 10.00 cores=10 free=50% vm=normal fit=0 pressure=yes awake=no"'
out=$(STUB_FREE=8 bash "$S" w1)
ok "free under 10% → pressure=yes" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=8% vm=normal fit=0 pressure=yes awake=no"'
out=$(STUB_FAIL=1 bash "$S" w1); rc=$?
ok "orca failing → ? fields, exit 0" '[ "$rc" = 0 ] && has "#13 host=local pr=? session=? idle=? stalled=? mem=? branch=? card=?"'
out=$(REMOTE_FREE=20 bash "$S" w1)
ok "mini free under 25% → pressure=yes, local unaffected" 'has "machine host=mini load=1.40 1.20 1.00 cores=10 free=20% vm=normal fit=0 pressure=yes" && has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=4 pressure=no awake=no"'
out=$(REMOTE_FREE=30 STUB_FREE=8 bash "$S" w1)
ok "free 30% is fine on mini; local under 10% is not" 'has "machine host=mini load=1.40 1.20 1.00 cores=10 free=30% vm=normal fit=0 pressure=no" && has "machine host=local load=2.37 2.12 2.54 cores=10 free=8% vm=normal fit=0 pressure=yes awake=no"'
out=$(REMOTE_LOAD='{ 31.00 20.00 10.00 }' bash "$S" w1)
ok "mini load above 3x cores → pressure=yes" 'has "machine host=mini load=31.00 20.00 10.00 cores=10 free=40% vm=normal fit=0 pressure=yes"'
out=$(REMOTE_DOWN=1 bash "$S" w1); rc=$?
ok "host unreachable → ? fields, exit 0" '[ "$rc" = 0 ] && has "machine host=mini load=? cores=? free=? vm=? fit=? pressure=?"'
out=$(bash "$S" w2 mini); rc=$?
ok "no slots + host arg → exactly the two machine lines" '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | awk "{print \$1\" \"\$2}" | paste -sd, -)" = "machine host=local,machine host=mini" ]'
W3="$P/w3.state"; mkdir -p "$W3"; cp "$W/16@mini.json" "$W3/"; echo 'vkmtx/demo' > "$W3/repo"
: > "$CALLS"; out=$(cd "$T" && bash "$S" w3); rc=$?
ok "#39 remote slot, cwd outside the repo: PR resolved through --repo" '[ "$rc" = 0 ] && has "#16 host=mini pr=#41:OPEN session=alive idle=? stalled=no mem=? branch=feat/16-c card=\"built\""'
ok "#39 gh pr list carries --repo from the wave dir" 'grep -q "^gh pr list .*--repo vkmtx/demo" "$CALLS"'
: > "$CALLS"; out=$(env -u WAVE_REMOTE_SH bash "$S" w2 mini); rc=$?
ok "#39 WAVE_REMOTE_SH unset → host-lib.sh default ssh" '[ "$rc" = 0 ] && grep -q "^ssh -o BatchMode=yes -o ConnectTimeout=10 mini " "$CALLS" && has "machine host=mini load=? cores=? free=? vm=? fit=? pressure=?"'
ok "#39 wave-status.sh has no ssh default of its own" '! grep -q "ssh -o BatchMode" "$S" && grep -q "host-lib.sh" "$S"'
bash "$S" >/dev/null 2>&1; rc=$?; ok "no name → exit 2" '[ "$rc" = 2 ]'
bash "$S" nosuch >/dev/null 2>&1; rc=$?; ok "no such wave dir → exit 2" '[ "$rc" = 2 ]'
# #59 state dir: the persistent one first, the legacy $TMPDIR/wave-<name> only when it is absent
E="$T/emptytmp"; mkdir -p "$E"
out=$(TMPDIR="$E" bash "$S" w1); rc=$?
ok "#59 status read from the persistent dir, nothing in \$TMPDIR" '[ "$rc" = 0 ] && [ -z "$(ls -A "$E")" ] && has "#13 host=local pr=#40:OPEN session=alive idle=? stalled=no mem=? branch=feat/13-a card=\"PR #40\""'
L="$T/tmp/wave-w5"; mkdir -p "$L"; cp "$W/13.json" "$L/"
out=$(bash "$S" w5); rc=$?
ok "#59 legacy \$TMPDIR/wave-<name> read when the persistent dir is absent" '[ "$rc" = 0 ] && has "#13 host=local pr=#40:OPEN session=alive idle=? stalled=no mem=? branch=feat/13-a card=\"PR #40\""'
mkdir -p "$T/tmp/wave-w6" "$P/w6.state"; cp "$W/13.json" "$T/tmp/wave-w6/"; cp "$W/14.json" "$P/w6.state/"
out=$(bash "$S" w6)
ok "#59 persistent dir wins when both exist" 'has "#14 host=local pr=none session=dead:terminal_handle_stale idle=? stalled=? mem=? branch=feat/14-b card=\"built\"" && ! printf "%s\n" "$out" | grep -q "^#13 "'
ok "#59 usage names the persistent dir" 'bash "$S" nosuch 2>&1 | grep -q "learn/waves/<wave-name>.state"'
# #68 idle/stalled/awake: fake transcripts under the fake HOME, fake tasks under WAVE_TASKS_ROOT
age() { python3 -I -c 'import os,sys,time; t=time.time()-60*float(sys.argv[1]); os.utime(sys.argv[2],(t,t))' "$1" "$2"; }   # age MIN FILE
mk() { mkdir -p "$(dirname "$2")"; : > "$2"; age "$1" "$2"; }   # mk MIN FILE
L14='#14 host=local pr=none session=dead:terminal_handle_stale'; T14='mem=? branch=feat/14-b card="built"'
PD="$T/home/.claude/projects/-nonexistent-14-b"; TD="$T/tasks/-nonexistent-14-b/s1/tasks"; mkdir -p "$TD"
mk 5.5 "$PD/s1.jsonl"; out=$(bash "$S" w1)
ok "#68 transcript 5 min ago → idle=5" 'has "$L14 idle=5 stalled=no $T14"'
age 29.5 "$PD/s1.jsonl"; out=$(bash "$S" w1)
ok "#68 29 min, pr=none → stalled=no" 'has "$L14 idle=29 stalled=no $T14"'
age 30.5 "$PD/s1.jsonl"; out=$(bash "$S" w1)
ok "#68 30 min, pr=none → stalled=yes" 'has "$L14 idle=30 stalled=yes $T14"'
age 40.5 "$PD/s1.jsonl"; mk 0 "$PD/s1/subagents/agent-a.meta.json"; mk 0 "$PD/s1/tool-results/r.txt"; out=$(bash "$S" w1)
ok "#68 40 min, only meta and tool-results newer → idle=40, stalled=yes" 'has "$L14 idle=40 stalled=yes $T14"'
mk 7.5 "$PD/s1/subagents/agent-a.jsonl"; out=$(bash "$S" w1)
ok "#68 newer subagent transcript → idle from it" 'has "$L14 idle=7 stalled=no $T14"'
mk 6.5 "$PD/s1/subagents/workflows/wf_x/agent-w.jsonl"; out=$(bash "$S" w1)
ok "#68 newer workflow subagent transcript → idle from it" 'has "$L14 idle=6 stalled=no $T14"'
age 50.5 "$PD/s1/subagents/workflows/wf_x/agent-w.jsonl"
age 50.5 "$PD/s1/subagents/agent-a.jsonl"; mk 3.5 "$TD/b.output"; out=$(bash "$S" w1)
ok "#68 old transcript, recent task output → idle from the task" 'has "$L14 idle=3 stalled=no $T14"'
age 50.5 "$TD/b.output"; mk 12.5 "$T/elsewhere.jsonl"; ln -s "$T/elsewhere.jsonl" "$TD/c.output"; out=$(bash "$S" w1)
ok "#68 symlinked task output → target mtime" 'has "$L14 idle=12 stalled=no $T14"'
rm "$TD/c.output"; ln -s "$T/gone" "$TD/d.output"; out=$(bash "$S" w1)
ok "#68 dangling task symlink skipped" 'has "$L14 idle=40 stalled=yes $T14"'
out=$(env -u WAVE_TASKS_ROOT bash "$S" w1)
ok "#68 default task root still reads" 'has "$L14 idle=40 stalled=yes $T14"'
mk 2.5 "$PD/s2.jsonl"; out=$(bash "$S" w1)
ok "#68 relaunch: newest session wins" 'has "$L14 idle=2 stalled=no $T14"'
age -10 "$PD/s2.jsonl"; out=$(bash "$S" w1)
ok "#68 future mtime clamps to 0" 'has "$L14 idle=0 stalled=no $T14"'
rm "$PD/s2.jsonl"; out=$(STUB_GH_FAIL=1 bash "$S" w1)
ok "#68 idle over the limit, pr=? → stalled=?" 'has "#14 host=local pr=? session=dead:terminal_handle_stale idle=40 stalled=? $T14"'
mk 40.5 "$T/home/.claude/projects/-nonexistent-13-a/s1.jsonl"; out=$(bash "$S" w1)
ok "#68 open PR → stalled=no" 'has "#13 host=local pr=#40:OPEN session=alive idle=40 stalled=no mem=? branch=feat/13-a card=\"PR #40\""'
ok "#68 no local file for the remote slot → idle=?" 'has "#16 host=mini pr=none session=alive idle=? stalled=? mem=? branch=feat/16-c card=\"built\""'
mk 40.5 "$T/rhome/.claude/projects/-nonexistent-16-c/s1.jsonl"; : > "$CALLS"; out=$(REMOTE_HOME="$T/rhome" bash "$S" w1)
ok "#68 remote idle read on the host" 'has "#16 host=mini pr=none session=alive idle=40 stalled=yes mem=? branch=feat/16-c card=\"built\""'
ok "#68 remote idle goes through rsh and remote_wrap" 'grep -q "^rsh mini WAVE_WT=/nonexistent/16-c bash -c .*opt/homebrew" "$CALLS"'
out=$(REMOTE_DOWN=1 REMOTE_HOME="$T/rhome" bash "$S" w1)
ok "#68 host unreachable → idle=?" 'has "#16 host=mini pr=none session=alive idle=? stalled=? mem=? branch=feat/16-c card=\"built\""'
W7="$P/w7.state"; mkdir -p "$W7"; echo '{"ok":true,"result":{"outcome":{"handle":"term_alive"},"worktreeId":"r1::/wt/17-sp"}}' > "$W7/17.json"
mk 5.5 "$T/home/.claude/projects/-nonexistent-17-sp/s1.jsonl"; out=$(bash "$S" w7)
ok "#68 worktree path with a space" 'has "#17 host=local pr=none session=alive idle=5 stalled=no mem=? branch=feat/17-sp card=\"spaced\""'
: > "$CALLS"; out=$(STUB_PGREP=0 bash "$S" w2)
ok "#68 pgrep exit 0 → awake=yes" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=4 pressure=no awake=yes"'
ok "#68 awake matches the -w binding" 'grep -qxF "pgrep -f ^caffeinate -i -w " "$CALLS"'
out=$(bash "$S" w2)
ok "#68 pgrep exit 1 → awake=no" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=4 pressure=no awake=no"'
out=$(STUB_PGREP=3 bash "$S" w2)
ok "#68 any other pgrep exit → awake=?" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=4 pressure=no awake=?"'
WM="$(dirname "$S")/../skills/rumo/references/wave.md"
ok "#59 wave.md points at the persistent dir, no \$TMPDIR/wave-" '! grep -q "TMPDIR/wave-" "$WM" && grep -q "learn/waves/<name>.state" "$WM"'
ok "#59 wave.md: a reused wave name stops at mkdir (no -p on the state dir)" 'grep -q "&& mkdir ~/.claude/learn/waves/<name>.state" "$WM" && ! grep -q "mkdir -p ~/.claude/learn/waves/<name>.state" "$WM"'
ok "#59 wave.md: this machine is updated before sync-host --apply" 'grep -q "pull --ff-only origin master && claude plugin update rumo@rumo.*sync-host.sh <host> --apply" "$WM"'
S5() { sed -n '/^## 5\. /,/^## 6\. /p' "$WM"; }; S6() { sed -n '/^## 6\. /,/^## 7\. /p' "$WM"; }
HM="$(dirname "$S")/../skills/rumo/references/help.md"
FMT='session=alive|disconnected|dead:<code>|chat|no-handle idle=<min>|? stalled=yes|no|? mem=<MB>|? branch=<branch> card="<comment>"'
ok "#68 slot format identical in wave-status.sh and wave.md §5" 'grep -qF -- "$FMT" "$S" && S5 | grep -qF -- "$FMT"'
ok "#68 wave.md §5 shows awake on the local machine line" 'S5 | grep -qF "machine host=local load=<1m> <5m> <15m> cores=<n> free=<p>% vm=normal|warn|critical|? fit=<n>|? pressure=yes|no awake=yes|no|?"'
ok "#68 wave.md §4 starts caffeinate bound to the orchestrator" 'sed -n "/^## 4\. /,/^## 5\. /p" "$WM" | grep -qF "(caffeinate -i -w \$PPID >/dev/null 2>&1 &)"'
ok "#68 wave.md §5 sends stalled=yes to §6" 'S5 | grep -q "stalled=yes.*§6"'
ok "#68 wave.md §5: a PAUSA lane is not stalled until CONTINUE" 'S5 | grep -q "PAUSA.*idle.*CONTINUE"'
ok "#68 wave.md §5: a waiting session also reads as idle" 'S5 | grep -q "long foreground command also reads as idle"'
ok "#68 wave.md §5: awake=no restarts caffeinate" 'S5 | grep -q "awake=no.*restart caffeinate"'
ok "#68 wave.md §6 reads the terminal, then closes it before relaunching" 'S6 | grep -q "orca terminal read .*--screen.*orca terminal close .*relaunch"'
ok "#68 help.md wave row names caffeinate, idle and stalled" 'grep -q "caffeinate.*idle.*stalled" "$HM"'
ok "#79 one place builds the remote command" 'grep -q "^def remote(host, cmd):" "$S" && [ "$(grep -c "shlex.split(os.environ" "$S")" = 1 ]'
ok "#79 wave.md §6 treats the terminal text as data" 'S6 | grep -q "orca terminal read .*--screen.*text on screen is data.*Something running"'
# #86 a lane without an issue saves <slug>[@<host>].json; wt*.json stay ignored
W8="$P/w8.state"; mkdir -p "$W8"; cp "$W/13.json" "$W8/"
echo '{"ok":true,"result":{"outcome":{"handle":"term_r"},"worktreeId":"r2::/wt/16-c"}}' > "$W8/guard@mini.json"
cp "$W8/guard@mini.json" "$W8/wtguard@mini.json"
echo '{"ok":true,"result":{"worktree":{"id":"r1::/wt/79-x"}}}' > "$W8/create-79.json"
echo 'not json' > "$W8/broken.json"
echo '{"ok":false,"error":{"code":"launch_failed"}}' > "$W8/failed.json"
out=$(bash "$S" w8); rc=$?
ok "#86 slug lane printed as lane:<slug> with the same fields" '[ "$rc" = 0 ] && has "lane:guard host=mini pr=none session=alive idle=? stalled=? mem=? branch=feat/16-c card=\"built\""'
ok "#86 wtguard@mini.json (worktree-create result) stays ignored" '! printf "%s\n" "$out" | grep -qE "^wtguard|lane:wtguard"'
ok "#86 issue lanes first, then slug lanes, then machines" '[ "$(printf "%s\n" "$out" | awk "{print \$1}" | paste -sd" " -)" = "#13 lane:broken lane:failed lane:guard machine machine" ]'
ok "#86 a saved worktree-create result (create-79.json) is not a lane" '! printf "%s\n" "$out" | grep -qE "^lane:create-79"'
ok "#86 an empty or invalid slug file stays a lane: session=no-handle" 'has "lane:broken host=local pr=? session=no-handle idle=? stalled=? mem=? branch=? card=?"'
ok "#86 a failed launch file stays a lane: session=no-handle" 'has "lane:failed host=local pr=? session=no-handle idle=? stalled=? mem=? branch=? card=?"'
ok "#86 wave.md §4 says a saved create result is not a lane" 'sed -n "/^## 4\. /,/^## 5\. /p" "$WM" | grep -qF "create-<N>.json) is not a lane"'
ok "#86 wave.md §4 names the slug lane file" 'sed -n "/^## 4\. /,/^## 5\. /p" "$WM" | grep -qF "<slug>[@<host>].json"'
# #102 a lane launched as a chat (outcome.kind=structured) has no terminal handle: session=chat, no terminal show
W9="$P/w9.state"; mkdir -p "$W9"
echo '{"ok":true,"result":{"outcome":{"kind":"structured","sessionId":"claude_x","handle":"structured-agent-session-claude_x","tabId":"structured-agent-session-claude_x"},"worktreeId":"r1::/wt/18-ch","receipt":{"mode":"structured"},"prompt":{"outcome":"journaled"}}}' > "$W9/18.json"
: > "$CALLS"; out=$(bash "$S" w9); rc=$?
ok "#102 structured launch → session=chat" '[ "$rc" = 0 ] && has "#18 host=local pr=none session=chat idle=? stalled=? mem=? branch=fix/18-ch card=\"started\""'
ok "#102 structured launch → no orca terminal show call" '! grep -q "terminal show" "$CALLS"'
# #121 kernel pressure level and fit=: warn blocks new lanes, critical also pauses; an unread level leaves fit to free
out=$(STUB_VM=2 bash "$S" w2)
ok "#121 vm=warn → fit=0, pressure stays no" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=warn fit=0 pressure=no awake=no"'
out=$(STUB_VM=4 bash "$S" w2)
ok "#121 vm=critical → fit=0 and pressure=yes" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=critical fit=0 pressure=yes awake=no"'
out=$(STUB_VM=7 bash "$S" w2)
ok "#121 unknown level → vm=?, fit from free (40% of 16 GB ÷ 1500 MB = 4)" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=? fit=4 pressure=no awake=no"'
out=$(STUB_FREE=? bash "$S" w2)
ok "#121 free unread → fit=?" 'printf "%s\n" "$out" | grep -q "^machine host=local .* free=? vm=normal fit=? pressure=?"'
# #121 a live local lane: mem= from lane-mem.py (ps/top/lsof stubs), and it sizes fit=
export WT19="$T/wt19"; mkdir -p "$WT19"; W10="$P/w10.state"; mkdir -p "$W10"
echo '{"ok":true,"result":{"outcome":{"kind":"terminal","handle":"term_alive"},"worktreeId":"r1::/wt/19-m"}}' > "$W10/19.json"
cat > "$B/ps" <<'EOF2'
#!/bin/bash
printf '  900     1 100000 claude --dangerously-skip-permissions\n  901   900 500000 node tsserver.js\n'
EOF2
printf '#!/bin/bash\nprintf "PID MEM\\n900 1000M\\n901 2000M\\n"\n' > "$B/top"
printf '#!/bin/bash\nprintf "p900\\nfcwd\\nn%%s\\n" "$WT19"\n' > "$B/lsof"
chmod +x "$B/ps" "$B/top" "$B/lsof"
out=$(bash "$S" w10); rc=$?
ok "#121 live lane → mem=3000" '[ "$rc" = 0 ] && has "#19 host=local pr=none session=alive idle=? stalled=? mem=3000 branch=feat/19-m card=\"built\""'
ok "#121 fit sized by the largest live lane (6553 MB ÷ 3000 = 2)" 'has "machine host=local load=2.37 2.12 2.54 cores=10 free=50% vm=normal fit=2 pressure=no awake=no"'
rm -f "$B/ps" "$B/top" "$B/lsof"
: > "$CALLS"; out=$(bash "$S" w1)
ok "#121 remote mem read once per host, through remote_wrap, path as an argument" '[ "$(grep -c "^rsh mini bash -c .*python3.*_ /nonexistent/16-c$" "$CALLS")" = 1 ]'
ok "#121 wave.md §5 machine line shows vm and fit" 'S5 | grep -qF "free=<p>% vm=normal|warn|critical|? fit=<n>|? pressure=yes|no"'
exit $fail
