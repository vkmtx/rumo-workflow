#!/usr/bin/env bash
# Run: bash tests/wave_lane_prep_test.sh — offline: throwaway git repos and a fake $HOME; the remote shell is a stub. Exit 1 on any FAIL.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/wave-lane-prep.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$T/home" CALLS="$T/calls"; : > "$CALLS"
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"enabledPlugins":{"typescript-lsp@claude-plugins-official":true,"pyright-lsp@claude-plugins-official":true,"rumo@rumo":true,"gopls-lsp@x":false}}
EOF
mkrepo() { git init -q -b master "$1" && (cd "$1" && echo hi > f && git add f && git commit -qm init); }
setting() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["enabledPlugins"].get(sys.argv[2]))' "$1/.claude/settings.local.json" "$2"; }

# main repo + a linked worktree, as Orca makes them
mkrepo "$T/main"; git -C "$T/main" worktree add -q -b feat/1-a "$T/wt" 2>/dev/null
out=$(bash "$S" "$T/wt"); rc=$?
ok "exit 0" '[ "$rc" = 0 ]'
ok "last line names the plugins turned off, sorted" '[ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP $T/wt off=pyright-lsp@claude-plugins-official,typescript-lsp@claude-plugins-official" ]'
ok "typescript-lsp off in the worktree" '[ "$(setting "$T/wt" typescript-lsp@claude-plugins-official)" = False ]'
ok "pyright-lsp off in the worktree" '[ "$(setting "$T/wt" pyright-lsp@claude-plugins-official)" = False ]'
ok "non-LSP plugin untouched" '[ "$(setting "$T/wt" rumo@rumo)" = None ]'
ok "an LSP plugin already disabled is not listed" '[ "$(setting "$T/wt" gopls-lsp@x)" = None ]'
ok "git status stays clean (file excluded via the common info/exclude)" '[ -z "$(git -C "$T/wt" status --porcelain)" ] && grep -qxF "/.claude/settings.local.json" "$T/main/.git/info/exclude"'
out=$(bash "$S" "$T/wt"); rc=$?
ok "idempotent: exclude line written once" '[ "$rc" = 0 ] && [ "$(grep -cxF "/.claude/settings.local.json" "$T/main/.git/info/exclude")" = 1 ]'

# an existing settings.local.json keeps its keys; a project-enabled LSP plugin is caught too
mkrepo "$T/r2"; mkdir -p "$T/r2/.claude"
echo '{"permissions":{"allow":["Bash(ls)"]},"enabledPlugins":{"rumo@rumo":true}}' > "$T/r2/.claude/settings.local.json"
echo '{"enabledPlugins":{"rust-lsp@m":true}}' > "$T/r2/.claude/settings.json"
(cd "$T/r2" && git add .claude/settings.json && git commit -qm proj)
out=$(bash "$S" "$T/r2"); rc=$?
ok "merge keeps permissions and other plugins" '[ "$rc" = 0 ] && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"permissions\"]=={\"allow\":[\"Bash(ls)\"]} and d[\"enabledPlugins\"][\"rumo@rumo\"] is True" "$T/r2/.claude/settings.local.json"'
ok "project-enabled LSP plugin turned off too" '[ "$(setting "$T/r2" rust-lsp@m)" = False ] && printf "%s\n" "$out" | tail -n 1 | grep -q "rust-lsp@m"'

# refusals: tracked file, not a worktree top level, bad JSON, usage
mkrepo "$T/r3"; mkdir -p "$T/r3/.claude"; echo '{}' > "$T/r3/.claude/settings.local.json"
(cd "$T/r3" && git add -f .claude/settings.local.json && git commit -qm tracked)
out=$(bash "$S" "$T/r3"); rc=$?
ok "tracked settings.local.json → PREP-FAIL tracked, exit 1, file untouched" '[ "$rc" = 1 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP-FAIL $T/r3 reason=tracked" ] && [ "$(cat "$T/r3/.claude/settings.local.json")" = "{}" ]'
mkdir -p "$T/r3/sub"
out=$(bash "$S" "$T/r3/sub"); rc=$?
ok "subdirectory → PREP-FAIL not-a-worktree" '[ "$rc" = 1 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP-FAIL $T/r3/sub reason=not-a-worktree" ]'
mkrepo "$T/r4"; mkdir -p "$T/r4/.claude"; echo 'not json' > "$T/r4/.claude/settings.local.json"
out=$(bash "$S" "$T/r4"); rc=$?
ok "unparsable settings.local.json → PREP-FAIL bad-json, file untouched" '[ "$rc" = 1 ] && printf "%s\n" "$out" | tail -n 1 | grep -q "reason=bad-json" && [ "$(cat "$T/r4/.claude/settings.local.json")" = "not json" ]'
echo '{"enabledPlugins":{"rumo@rumo":true}}' > "$HOME/.claude/settings.json"; mkrepo "$T/r5"
out=$(bash "$S" "$T/r5"); rc=$?
ok "no LSP plugin enabled → off=none, no file written" '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP $T/r5 off=none" ] && [ ! -e "$T/r5/.claude/settings.local.json" ]'
bash "$S" >/dev/null 2>&1; ok "no args → exit 2" '[ "$?" = 2 ]'

# #121 security: repo content must not aim the write at another file (a planted temp-name link, a linked .claude)
echo '{"hooks":{"PreToolUse":["guard"]},"enabledPlugins":{"rumo@rumo":true}}' > "$HOME/.claude/settings.json"; VICTIM=$(cat "$HOME/.claude/settings.json")
mkrepo "$T/s1"; mkdir -p "$T/s1/.claude"; echo '{"enabledPlugins":{"evil-lsp@x":true}}' > "$T/s1/.claude/settings.json"
ln -s "$HOME/.claude/settings.json" "$T/s1/.claude/settings.local.json.tmp"; (cd "$T/s1" && git add -A && git commit -qm planted)
out=$(bash "$S" "$T/s1"); rc=$?
ok "planted settings.local.json.tmp link → PREP-FAIL symlink, user settings untouched" '[ "$rc" = 1 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP-FAIL $T/s1 reason=symlink" ] && [ "$(cat "$HOME/.claude/settings.json")" = "$VICTIM" ]'
mkrepo "$T/s2"; mkdir -p "$T/elsewhere"; echo '{"enabledPlugins":{"evil-lsp@x":true}}' > "$T/elsewhere/settings.json"
ln -s "$T/elsewhere" "$T/s2/.claude"; (cd "$T/s2" && git add -A && git commit -qm linked)
out=$(bash "$S" "$T/s2"); rc=$?
ok "linked .claude dir → PREP-FAIL symlink, nothing written through it" '[ "$rc" = 1 ] && printf "%s\n" "$out" | tail -n 1 | grep -q "reason=symlink" && [ ! -e "$T/elsewhere/settings.local.json" ]'
ok "no temp file left behind after a normal run" '[ -z "$(ls -A "$T/wt/.claude" | grep -v "^settings.local.json$")" ]'

# remote: the script ships itself over WAVE_REMOTE_SH through remote_wrap and runs on the host
cat > "$T/rsh" <<'EOF'
#!/bin/bash
echo "rsh $1 $2" >> "$CALLS"
bash -c "$2"
EOF
chmod +x "$T/rsh"
echo '{"enabledPlugins":{"typescript-lsp@claude-plugins-official":true}}' > "$HOME/.claude/settings.json"; mkrepo "$T/r6"
out=$(WAVE_REMOTE_SH="$T/rsh" bash "$S" "$T/r6" mini); rc=$?
ok "remote: exit 0 and the host's PREP line" '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP $T/r6 off=typescript-lsp@claude-plugins-official" ]'
ok "remote: one rsh call through remote_wrap (bash -c + PATH)" '[ "$(grep -c "^rsh mini bash -c .*opt/homebrew" "$CALLS")" = 1 ]'
out=$(WAVE_REMOTE_SH=false bash "$S" "$T/r6" mini); rc=$?
ok "remote unreachable → PREP-FAIL unreachable, exit 1" '[ "$rc" = 1 ] && [ "$(printf "%s\n" "$out" | tail -n 1)" = "PREP-FAIL $T/r6 reason=unreachable" ]'
exit $fail
