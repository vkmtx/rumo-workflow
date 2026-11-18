#!/usr/bin/env bash
# Run: bash tests/sync_host_test.sh — builds throwaway local/host ~/.claude fixtures, exit 1 on any FAIL.
# Never touches the real ~/.claude: HOME, every SYNC_* variable and PATH point into $T.
G="$(cd "$(dirname "$0")/.." && pwd)/scripts/sync-host.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
row() { printf '%s\n' "$out" | grep -qE "^$1 +$2( |$)"; }   # row STATE PATH: that state on that path's own line
T=$(cd "$(mktemp -d)" && pwd -P)
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$T/home"
mkdir -p "$HOME" "$T/hostbin" "$T/localbin" "$T/logs"

# --- local fixture
L="$T/local/.claude"
mkdir -p "$L/hooks/__pycache__" "$L/hooks/tests" "$L/skills/toolbelt" "$L/skills/synced/u" "$T/agents/linked"
printf 'local rules\n' > "$L/CLAUDE.md"
printf 'stack\n' > "$L/STACK.md"
printf 'echo new-gate\n' > "$L/hooks/pr-base-guard.sh"; chmod 755 "$L/hooks/pr-base-guard.sh"
printf "print('wg')\n" > "$L/hooks/worktree-guard.py"
printf "print('sb')\n" > "$L/hooks/subagent-budget.py"
printf "print('sg')\n" > "$L/hooks/secret-guard.py"   # 'secret' in a .py name must keep syncing
printf 'TOKEN=LEAK\n' > "$L/hooks/.env"
printf 'old\n' > "$L/hooks/old.py.bak-20261017"
printf 'pyc\n' > "$L/hooks/__pycache__/x.pyc"
printf 'echo t\n' > "$L/hooks/tests/t.sh"
printf 'toolbelt\n' > "$L/skills/toolbelt/SKILL.md"
printf 'LEAK\n' > "$L/skills/toolbelt/.env"
printf '//registry/:_authToken=LEAK\n' > "$L/skills/toolbelt/.npmrc"
printf '{"token":"LEAK"}\n' > "$L/skills/toolbelt/token.json"
mkdir -p "$L/skills/toolbelt/.playwright-cli"; printf 'tool state\n' > "$L/skills/toolbelt/.playwright-cli/console.log"
printf 'synced\n' > "$L/skills/synced/u/SKILL.md"
printf 'elsewhere\n' > "$T/agents/linked/SKILL.md"
ln -s "$T/agents/linked" "$L/skills/linked"
printf '{"token":"LEAK"}\n' > "$L/.credentials.json"
printf '{"h":1}\n' > "$L/history.jsonl"

# --- host fixture
H="$T/host/.claude"
mkdir -p "$H/hooks" "$H/skills/srv-stack"
printf 'old rules\n' > "$H/CLAUDE.md"
printf 'stack\n' > "$H/STACK.md"
printf 'echo old-gate\n' > "$H/hooks/pr-base-guard.sh"
printf "print('wg')\n" > "$H/hooks/worktree-guard.py"
printf 'echo srv\n' > "$H/hooks/host-only.sh"
printf 'srv\n' > "$H/skills/srv-stack/SKILL.md"
mkdir -p "$T/hostagents/linked"; printf 'elsewhere\n' > "$T/hostagents/linked/SKILL.md"
ln -s "$T/hostagents/linked" "$H/skills/linked"   # the host's own copy of the linked skill (same content)
git config --file "$T/host/gitconfig" user.name host; git config --file "$T/host/gitconfig" user.email host@t   # the host's git identity (#42)
cat > "$L/settings.json" <<'JSON'
{"env":{"SHELL":"/bin/zsh","TOKEN":"LOCAL-SECRET-VALUE"},"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/pr-base-guard.sh\""}]},{"matcher":"*","hooks":[{"type":"command","command":"python3 \"$HOME/.claude/hooks/subagent-budget.py\""},{"type":"command","command":"orca-hook local"}]}]}}
JSON
cat > "$H/settings.json" <<'JSON'
{"env":{"SHELL":"/bin/zsh","HOSTVAR":"HOST-VALUE"},"model":"sonnet","hooks":{"PreToolUse":[{"matcher":"mcp__github__create_pull_request|Bash","hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/pr-base-guard.sh\""}]},{"matcher":"*","hooks":[{"type":"command","command":"orca-hook host"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/bash \"$HOME/.claude/hooks/host-only.sh\""}]}]}}
JSON

# --- rumo checkouts, plugin files, Claude Code version state, stubs (step 3+)
mkdir -p "$T/src/.claude-plugin" "$T/hoststate" "$L/plugins" "$H/plugins"
printf '{"name":"rumo","version":"0.4.0"}\n' > "$T/src/.claude-plugin/plugin.json"
git init -q -b master "$T/src" && git -C "$T/src" add -A && git -C "$T/src" commit -qm v0.4.0
printf '{"name":"rumo","version":"0.8.1"}\n' > "$T/src/.claude-plugin/plugin.json"
git -C "$T/src" commit -qam v0.8.1
git clone -q --bare "$T/src" "$T/origin.git"
git clone -q "$T/origin.git" "$T/local/rumo"
git clone -q "$T/origin.git" "$T/host/rumo" && git -C "$T/host/rumo" reset -q --hard HEAD~1
printf '{"plugins":{"rumo@rumo":[{"scope":"user","version":"0.8.1"}]}}\n' > "$L/plugins/installed_plugins.json"
printf '{"plugins":{"rumo@rumo":[{"scope":"user","version":"0.4.0"}]}}\n' > "$H/plugins/installed_plugins.json"
printf '{"rumo":{"source":{"source":"github","repo":"vkmtx/rumo"}}}\n' > "$H/plugins/known_marketplaces.json"
echo 2.1.305 > "$T/hoststate/claude-version"
cat > "$T/localbin/claude" <<STUB
#!/bin/bash
echo "\$*" >> "$T/logs/local-claude.log"
[ "\$1" = --version ] && { echo "2.1.312 (Claude Code)"; exit 0; }
exit 1
STUB
cat > "$T/localbin/gh" <<STUB
#!/bin/bash
[ "\$*" = "api user --jq .login" ] && { echo vkmtx; exit 0; }
exit 1
STUB
cp "$T/localbin/gh" "$T/hostbin/gh"
cat > "$T/localbin/orca" <<STUB
#!/bin/bash
echo "\$*" >> "$T/logs/orca.log"
case "\$1 \$2" in
  "repo list") printf '{"ok":true,"result":{"repos":['
    [ -s "$T/logs/orca-repos" ] && sed 's/.*/{"path":"&"}/' "$T/logs/orca-repos" | paste -sd, - | tr -d '\n'
    printf ']}}\n' ;;
  "repo add") while [ \$# -gt 0 ]; do [ "\$1" = --path ] && echo "\$2" >> "$T/logs/orca-repos"; shift; done ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/hostbin/claude" <<STUB
#!/bin/bash
echo "\$*" >> "$T/logs/host-claude.log"
case "\$1" in
  --version) echo "\$(cat "$T/hoststate/claude-version") (Claude Code)" ;;
  install) echo "\$2" > "$T/hoststate/claude-version" ;;
  plugin) case "\$2" in
      marketplace) case "\$3" in
          add) printf '{"rumo":{"source":{"source":"directory","path":"%s"}}}\n' "\$4" > "$T/host/.claude/plugins/known_marketplaces.json" ;;
          remove|update) : ;;
          *) exit 1 ;; esac ;;
      install|update) v=\$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$T/host/rumo/.claude-plugin/plugin.json")
        printf '{"plugins":{"rumo@rumo":[{"scope":"user","version":"%s"}]}}\n' "\$v" > "$T/host/.claude/plugins/installed_plugins.json" ;;
      *) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/localbin/claude" "$T/localbin/gh" "$T/hostbin/gh" "$T/localbin/orca" "$T/hostbin/claude"

HOSTENV="env PATH=$T/hostbin:/usr/bin:/bin GIT_CONFIG_GLOBAL=$T/host/gitconfig GIT_CONFIG_NOSYSTEM=1"   # the host side of every remote stub
export SYNC_LOCAL_ROOT="$T/local/.claude" SYNC_HOST_ROOT="$T/host/.claude" SYNC_LOCAL_RUMO="$T/local/rumo" SYNC_HOST_RUMO="$T/host/rumo" SYNC_BACKUP_DIR="$T/backups" SYNC_REMOTE_SH="$HOSTENV bash -c"
run() { PATH="$T/localbin:/usr/bin:/bin" bash "$G" "$@"; }
snap() { (cd "$T/host" && find . | sort; find . -type f | sort | while IFS= read -r f; do shasum -a 256 "$f"; done) | shasum -a 256; }

# --- step 1: CLI, transport, dry-run file table
run >/dev/null 2>&1; rc=$?
ok "no host → exit 2" '[ $rc = 2 ]'
run testhost --bogus >/dev/null 2>&1; rc=$?
ok "unknown flag → exit 2" '[ $rc = 2 ]'
before=$(snap)
out=$(run testhost 2>&1); rc=$?
after=$(snap)
ok "dry run exits 0" '[ $rc = 0 ]'
ok "dry run leaves the host byte-identical" '[ "$before" = "$after" ]'
ok "row CHANGED CLAUDE.md" 'row CHANGED CLAUDE.md'
ok "row SAME STACK.md" 'row SAME STACK.md'
ok "row CHANGED hooks/pr-base-guard.sh" 'row CHANGED hooks/pr-base-guard.sh'
ok "row SAME hooks/worktree-guard.py" 'row SAME hooks/worktree-guard.py'
ok "row NEW hooks/subagent-budget.py" 'row NEW hooks/subagent-budget.py'
ok "row HOST-ONLY hooks/host-only.sh" 'row HOST-ONLY hooks/host-only.sh'
ok "row NEW skills/toolbelt/SKILL.md" 'row NEW skills/toolbelt/SKILL.md'
ok "row HOST-ONLY skills/srv-stack/SKILL.md" 'row HOST-ONLY skills/srv-stack/SKILL.md'
leaked=0; for s in .env .credentials history.jsonl .bak __pycache__ hooks/tests skills/synced skills/linked/ .playwright-cli .npmrc token.json; do
  case "$out" in *"$s"*) echo "  leaked: $s"; leaked=1 ;; esac; done
ok "denylisted and out-of-scope paths never listed" '[ $leaked = 0 ]'
ok "ends with the dry-run line" '[[ "$out" == *"dry run — nothing written"* ]]'
SYNC_REMOTE_SH=false run testhost >/dev/null 2>&1; rc=$?
ok "unreachable host → exit 3" '[ $rc = 3 ]'

# --- step 2: settings.json diff (rumo gate entries only; values never printed)
before=$(snap)
out=$(run testhost 2>&1); rc=$?
after=$(snap)
ok "row CHANGED settings.json" 'row CHANGED settings.json'
ok "keys line names env and model" '[[ "$out" == *"stay host-owned: env, model"* ]]'
ok "no settings value is ever printed" '[[ "$out" != *LOCAL-SECRET-VALUE* && "$out" != *HOST-VALUE* ]]'
ok "dry run still leaves the host byte-identical" '[ "$before" = "$after" ]'
cp "$H/settings.json" "$T/settings.keep"; printf '{not json\n' > "$H/settings.json"
out=$(run testhost 2>&1); rc=$?
ok "invalid host settings.json → exit 1 and ERROR" '[ $rc = 1 ] && [[ "$out" == *"ERROR"*"settings.json"* ]]'
cp "$T/settings.keep" "$H/settings.json"; rm -f "$T/settings.keep"

# --- step 3: preflight (exit 0/1) and the report-only block in the dry run
before=$(snap)
out=$(run testhost --preflight --runtime git --repo "$T/host/rumo" 2>&1); rc=$?
ok "--preflight before apply exits 1" '[ $rc = 1 ]'
for l in "FAIL claude-code" "FAIL rumo-installed" "FAIL rumo-checkout" "FAIL hooks" "FAIL settings-hooks" "PASS gh" "PASS git-identity" "PASS runtime:git" "FAIL orca-repo"; do
  ok "preflight line $l" 'printf "%s\n" "$out" | grep -q "^$l:"'
done
out=$(run testhost --preflight --runtime nonexistent-xyz 2>&1)
ok "--runtime nonexistent-xyz → FAIL runtime:nonexistent-xyz" 'printf "%s\n" "$out" | grep -q "^FAIL runtime:nonexistent-xyz:"'
out=$(SYNC_GH_USER=someone-else run testhost --preflight 2>&1)
ok "SYNC_GH_USER=someone-else → FAIL gh" 'printf "%s\n" "$out" | grep -q "^FAIL gh:"'
run testhost --apply --preflight >/dev/null 2>&1; rc=$?
ok "--apply --preflight → exit 2" '[ $rc = 2 ]'
git config --file "$T/host/gitconfig" --unset user.email
out=$(run testhost --preflight 2>&1); rc=$?
ok "#42 host without user.email → FAIL git-identity" '[ $rc = 1 ] && printf "%s\n" "$out" | grep -q "^FAIL git-identity: user.email unset" && [[ "$out" == *"git config --global user.email"* ]]'
git init -q "$T/dothome"; git -C "$T/dothome" config user.email dot@t   # #42 fix: $HOME as a dotfiles repo
out=$(HOME="$T/dothome" run testhost --preflight 2>&1); rc=$?
ok "#42 fix repo-local user.email in a git \$HOME does not satisfy git-identity" '[ $rc = 1 ] && printf "%s\n" "$out" | grep -q "^FAIL git-identity: user.email unset"'
git config --file "$T/host/gitconfig" user.email host@t
out=$(run testhost --runtime git --repo "$T/host/rumo" 2>&1); rc=$?
after=$(snap)
ok "dry run shows preflight (report only): and still exits 0" '[ $rc = 0 ] && [[ "$out" == *"preflight (report only):"*"FAIL claude-code"*"dry run — nothing written"* ]]'
ok "preflight and dry run write nothing" '[ "$before" = "$after" ] && ! grep -q "repo add" "$T/logs/orca.log" && ! grep -qE "^(install|plugin)" "$T/logs/host-claude.log" && ! grep -qv "^--version$" "$T/logs/local-claude.log"'

# --- step 4: --apply (backup first, sync, rumo checkout + plugin, Orca repo, then preflight)
before=$(snap)
out=$(SYNC_BACKUP_DIR=/dev/null/nope run testhost --apply 2>&1); rc=$?
after=$(snap)
ok "backup failure aborts before any write" '[ $rc = 1 ] && [ "$before" = "$after" ] && [[ "$out" == *"backup failed"* ]]'
out=$(run testhost --apply --runtime git --repo "$T/host/rumo" 2>&1); rc=$?
ok "apply never installs Claude Code" '[ $rc = 1 ] && printf "%s\n" "$out" | grep -q "^FAIL claude-code:" && [[ "$out" == *"upgrade the host by hand"* ]] && ! grep -q "^install" "$T/logs/host-claude.log"'
echo 2.1.312 > "$T/hoststate/claude-version"   # the owner upgraded the host by hand
out=$(run testhost --apply --runtime git --repo "$T/host/rumo" 2>&1); rc=$?
ok "apply exits 0" '[ $rc = 0 ]' || printf '%s\n' "$out" | sed 's/^/  | /'
nb=$(ls "$T"/backups/claude-*.tgz 2>/dev/null | wc -l | tr -d ' ')
oldgate=0; for b in "$T"/backups/claude-*.tgz; do [ "$(tar -xOzf "$b" hooks/pr-base-guard.sh 2>/dev/null)" = "echo old-gate" ] && oldgate=1; done
ok "one backup per apply, the first holds the old gate" '[ "$nb" = 2 ] && [ $oldgate = 1 ]'
same=1; for f in pr-base-guard.sh worktree-guard.py subagent-budget.py secret-guard.py; do cmp -s "$L/hooks/$f" "$H/hooks/$f" || same=0; done
ok "every local hook has the same hash on the host" '[ $same = 1 ]'
ok "host-only files kept" '[ -f "$H/hooks/host-only.sh" ] && [ -f "$H/skills/srv-stack/SKILL.md" ]'
leaked=0; for p in hooks/.env skills/toolbelt/.env .credentials.json history.jsonl hooks/old.py.bak-20261017 hooks/__pycache__ hooks/tests skills/synced skills/toolbelt/.playwright-cli skills/toolbelt/.npmrc skills/toolbelt/token.json; do
  [ -e "$H/$p" ] || [ -L "$H/$p" ] && { echo "  reached host: $p"; leaked=1; }; done
ok "nothing denylisted reached the host" '[ $leaked = 0 ]'
ok "hooks/secret-guard.py reached the host" 'cmp -s "$L/hooks/secret-guard.py" "$H/hooks/secret-guard.py"'
ok "host's symlinked skill left as the host had it" '[ -L "$H/skills/linked" ] && [ "$(readlink "$H/skills/linked")" = "$T/hostagents/linked" ] && [ "$(cat "$T/hostagents/linked/SKILL.md")" = elsewhere ]'
hs=$(cat "$H/settings.json")
ok "settings merged" '[[ "$hs" == *HOST-VALUE* && "$hs" == *\"sonnet\"* && "$hs" == *"orca-hook host"* && "$hs" == *host-only.sh* && "$hs" == *subagent-budget.py* && "$hs" != *LOCAL-SECRET-VALUE* && "$hs" != *"orca-hook local"* && "$hs" != *"mcp__github__create_pull_request|Bash"* ]]'
ok "plugin from the host checkout" 'grep -qxF "plugin marketplace add $T/host/rumo" "$T/logs/host-claude.log" && [ "$(sed -n "s/.*\"version\":\"\([^\"]*\)\".*/\1/p" "$H/plugins/installed_plugins.json")" = 0.8.1 ]'
ok "repo registered" 'grep -qF "repo add --environment testhost --path $T/host/rumo" "$T/logs/orca.log"'
ok "local side untouched" '! grep -qv "^--version$" "$T/logs/local-claude.log"'
run testhost --preflight --runtime git --repo "$T/host/rumo" >/dev/null 2>&1; rc=$?
ok "--preflight after apply exits 0" '[ $rc = 0 ]'
out=$(run testhost 2>&1)
ok "second dry run has no CHANGED/NEW row" '! row CHANGED ".*" && ! row NEW ".*"'

# --- step 7: review fixes
# (1) a failed host read is not "absent": fail closed, before the backup or any write
cat > "$T/flaky-rsh" <<STUB
#!/bin/bash
case "\$1" in *sync-tmp*) ;; *"$H/settings.json"*) exit 255 ;; esac   # only the host settings.json read drops
exec $HOSTENV bash -c "\$1"
STUB
chmod +x "$T/flaky-rsh"
hs0=$(shasum -a 256 < "$H/settings.json"); nb0=$(ls "$T"/backups/claude-*.tgz | wc -l | tr -d ' ')
out=$(SYNC_REMOTE_SH="$T/flaky-rsh" run testhost --apply 2>&1); rc=$?
nb1=$(ls "$T"/backups/claude-*.tgz | wc -l | tr -d ' ')
ok "failed host settings read → --apply exit 1, ERROR, host settings.json untouched, no backup" '[ $rc = 1 ] && [[ "$out" == *reading*failed* ]] && [ "$hs0" = "$(shasum -a 256 < "$H/settings.json")" ] && [ "$nb0" = "$nb1" ]'
out=$(SYNC_REMOTE_SH="$T/flaky-rsh" run testhost --preflight 2>&1); rc=$?
ok "failed host settings read → --preflight exit 1" '[ $rc = 1 ] && [[ "$out" == *reading*failed* ]]'
out=$(SYNC_REMOTE_SH="$T/flaky-rsh" run testhost 2>&1); rc=$?
ok "failed host settings read → dry run exit 1" '[ $rc = 1 ] && [[ "$out" == *reading*failed* ]]'
mv "$H/settings.json" "$T/settings.keep"
out=$(run testhost 2>&1); rc=$?
ok "truly absent host settings.json → NEW row, exit 0" '[ $rc = 0 ] && row NEW settings.json'
mv "$T/settings.keep" "$H/settings.json"

# (2) symlinked skills: reported, compared by preflight, never written
printf 'host drifted\n' > "$T/hostagents/linked/SKILL.md"
out=$(run testhost 2>&1)
ok "dry run: row UNSYNCED skills/linked with its target" 'row UNSYNCED skills/linked && [[ "$out" == *"skills/linked (symlink → $T/agents/linked)"* ]]'
out=$(run testhost --preflight 2>&1); rc=$?
ok "--preflight: FAIL linked-skills: linked" '[ $rc = 1 ] && printf "%s\n" "$out" | grep -q "^FAIL linked-skills: linked"'
printf 'elsewhere\n' > "$T/hostagents/linked/SKILL.md"
out=$(run testhost --preflight 2>&1)
ok "--preflight: PASS linked-skills once the host target matches" 'printf "%s\n" "$out" | grep -q "^PASS linked-skills: 1 match"'
rm "$H/skills/linked"
out=$(run testhost --preflight 2>&1)
ok "--preflight: host linked skill missing → FAIL linked-skills" 'printf "%s\n" "$out" | grep -q "^FAIL linked-skills: linked"'
ln -s "$T/hostagents/linked" "$H/skills/linked"
mkdir -p "$L/skills/hl" "$T/hostagents/hl"; printf 'local hl\n' > "$L/skills/hl/SKILL.md"; printf 'host hl\n' > "$T/hostagents/hl/SKILL.md"
ln -s "$T/hostagents/hl" "$H/skills/hl"
out=$(run testhost 2>&1)
ok "dry run: row CONFLICT skills/hl, its files not listed" 'row CONFLICT skills/hl && ! row NEW skills/hl/SKILL.md'
out=$(run testhost --apply 2>&1); rc=$?
ok "--apply with a host-side symlinked skill: no ABORT, host link and target untouched" '[[ "$out" != *ABORT* ]] && [ -L "$H/skills/hl" ] && [ "$(cat "$T/hostagents/hl/SKILL.md")" = "host hl" ]'
rm -rf "$L/skills/hl" "$H/skills/hl"

# (4) messages name the side that is broken; --help names the hidden-path rule
cp "$L/settings.json" "$T/settings.keep"; printf '{not json\n' > "$L/settings.json"
out=$(run testhost 2>&1); rc=$?
ok "invalid local settings.json → exit 1, says on this machine (not on the host)" '[ $rc = 1 ] && [[ "$out" == *"on this machine"* && "$out" != *"on the host"* ]]'
out=$(run testhost --preflight 2>&1)
ok "invalid local settings.json → preflight says on this machine" '[[ "$out" == *"on this machine"* && "$out" != *"on the host is not valid"* ]]'
cp "$T/settings.keep" "$L/settings.json"; rm -f "$T/settings.keep"
out=$(run --help 2>&1)
ok "--help mentions the hidden-path rule" '[[ "$out" == *hidden* ]]'

# --- #39: the default transport and the repo registration come from host-lib.sh
printf '#!/bin/bash\necho "$*" >> "%s/logs/ssh.log"\nexit 255\n' "$T" > "$T/localbin/ssh"; chmod +x "$T/localbin/ssh"
SYNC_REMOTE_SH= run testhost --preflight >/dev/null 2>&1; rc=$?
ok "#39 default transport: ssh batch mode + bash -c, unreachable → exit 3" '[ $rc = 3 ] && grep -q "^-o BatchMode=yes -o ConnectTimeout=10 testhost bash -c " "$T/logs/ssh.log"'
ok "#39 sync-host.sh has no ssh default or orca repo add of its own" '! grep -q "ssh -o BatchMode" "$G" && ! grep -q "orca repo add --environment" "$G" && grep -q "host-lib.sh" "$G"'
ok "#39 host-lib.sh holds the one ssh default" '[ "$(grep -c "ssh -o BatchMode" "$(dirname "$G")/host-lib.sh")" = 1 ]'

# SYNC_REMOTE_WRAP=1 wraps SYNC_REMOTE_SH strings (wave-host.sh's custom WAVE_REMOTE_SH path)
printf '#!/bin/bash\necho "$*" >> "%s/logs/wrap.log"\nexit 255\n' "$T" > "$T/wrapstub"; chmod +x "$T/wrapstub"
: > "$T/logs/wrap.log"; SYNC_REMOTE_SH="$T/wrapstub" SYNC_REMOTE_WRAP=1 run testhost --preflight >/dev/null 2>&1; rc=$?
wrapped=$(head -n 1 "$T/logs/wrap.log")
: > "$T/logs/wrap.log"; SYNC_REMOTE_SH="$T/wrapstub" run testhost --preflight >/dev/null 2>&1; rc2=$?
raw=$(head -n 1 "$T/logs/wrap.log")
ok "#39 SYNC_REMOTE_WRAP=1 wraps SYNC_REMOTE_SH strings in bash -c" '[ $rc = 3 ] && [ $rc2 = 3 ] && [[ "$wrapped" == "bash -c "* && "$wrapped" == *"/opt/homebrew/bin"* ]] && [ "$raw" = true ]'

rm -rf "$T"; exit $fail
