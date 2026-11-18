#!/usr/bin/env bash
# Run: bash tests/leak_scan_test.sh — exit 1 on any FAIL.
# Fixtures are assembled from fragments at run time so this file never trips the scanner it tests.
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/leak-scan.sh"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export RUMO_LEAK_DENYLIST="$T/none.txt"   # never read the machine's real denylist
AT='@'; U='/Users/'; H='/home/'

# newdir <name> <content...>: a fixture dir with one file, one content line per argument
newdir() { local d="$T/$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/f.txt"; echo "$d"; }
# hit <name> <rule> <content>: scanning that content exits 1 and prints "f.txt:1: <rule>: "
hit() {
  local d out rc; d=$(newdir "$1" "$3"); out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
  ok "$1 hits as $2" "[ \$rc -eq 1 ] && grep -q '^f.txt:1: $2: ' <<<\"\$out\""
}
# clean <name> <content>: scanning that content exits 0 with no output
clean() {
  local d out rc; d=$(newdir "$1" "$2"); out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
  ok "$1 stays clean" '[ $rc -eq 0 ] && [ -z "$out" ]'
}

hit email email "contact: jane.doe${AT}corp-mail.net"
hit home-mac home-path "cd ${U}jdoe/projects"
hit home-linux home-path "cd ${H}jdoe/projects"
hit local-host local-host "ssh studio.lo""cal"
hit ip-10 private-ip "host 10.""1.2.3 up"
hit ip-172 private-ip "host 172.""16.0.9 up"
hit ip-172-top private-ip "host 172.""31.255.1 up"
hit ip-192 private-ip "host 192.""168.1.20 up"
hit ip-cgnat private-ip "host 100.""64.0.5 up"
hit ip-tailscale private-ip "host 100.""101.102.103 up"
hit tailnet tailnet-host "box.tail1234.ts"".net"
hit cred-sk credential-sk "key=sk-""abcdefghijklmnopqrstuvwx"
hit cred-ghp credential-ghp "tok=ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
hit cred-pat credential-github-pat "tok=github_pat_""abcdefghijklmnopqrstuvwxyz0123"
hit cred-aws credential-aws "id=AKIA""ABCDEFGHIJKLMNOP"
hit cred-slack credential-slack "tok=xoxb-""1234567890-abcdef"
hit cred-jwt credential-jwt "t=eyJ""hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij"
hit private-key private-key "-----BEGIN ""RSA PRIVATE KEY-----"
hit cpf cpf "doc 123.456.""789-09"
hit cnpj cnpj "doc 12.345.""678/0001-95"

# The match itself is printed, and the line number is right
d=$(newdir lineno "ok" "ok" "mail jane${AT}corp-mail.net"); out=$(bash "$S" --dir "$d" 2>/dev/null)
ok "line number and match printed" '[ "$out" = "f.txt:3: email: jane${AT}corp-mail.net" ]'

# Things that must NOT hit
clean ok-email-example "a${AT}example.com b${AT}example.org c${AT}example.net d${AT}db.example.com"
clean ok-email-noreply "noreply${AT}github.com 12345+me${AT}users.noreply.github.com"
clean ok-email-actions "uses: actions/checkout${AT}v4 and pkg${AT}1.2.3"
clean ok-email-filenames "slot files like 16${AT}mini.json, guard${AT}mini.json, icon${AT}2x.png and x${AT}2x.png"
hit email-cctld-sh email "mail jane${AT}acme.sh"
hit email-cctld-md email "mail a${AT}b.md"
clean ok-home-names "${U}dev ${U}x/a ${U}v/a ${U}me/a ${H}runner/work ${H}user/a ${U}you/a"
clean ok-local-files "settings.local.json .env.local ~/.local/bin CLAUDE.local.md localhost"
clean ok-public-ips "8.8.8.8 172.32.0.1 172.15.0.1 100.128.0.1 100.63.255.255 11.0.0.1 1.10.1.2.3"
clean ok-cred-lookalikes "risk-assessment-and-review-gate-notes task-orchestrator-with-many-words sk-short"
clean ok-plain "nothing to see here"

# Allowlist: exact match only, '#' comments ignored
d=$(newdir allow "key=sk-""abcdefghijklmnopqrstuvwx" "mail jane${AT}corp-mail.net")
printf '%s\n' "# fixtures" "sk-""abcdefghijklmnopqrstuvwx" > "$d/.leak-scan-allow"
out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
ok "allowlist suppresses its exact match" '! grep -q credential-sk <<<"$out"'
ok "allowlist leaves other hits" '[ $rc -eq 1 ] && grep -q "email" <<<"$out"'
d=$(newdir allow2 "key=sk-""abcdefghijklmnopqrstuvwxYZ"); printf 'sk-%s\n' "abcdefghijklmnopqrstuvwx" > "$d/.leak-scan-allow"
bash "$S" --dir "$d" >/dev/null 2>&1
ok "allowlist is exact, not a prefix" '[ $? -eq 1 ]'

# Clean dir; clean binary file; .git ignored
d=$(newdir cleandir "hello"); mkdir -p "$d/.git"; printf 'x %s\n' "jane${AT}corp-mail.net" > "$d/.git/config"
printf 'a\0b clean\n' > "$d/blob.bin"
mkdir -p "$d/__pycache__"; printf 'a\0%sjdoe\n' "$U" > "$d/__pycache__/m.cpython-39.pyc"; printf 'a\0%sjdoe\n' "$U" > "$d/stray.pyc"
bash "$S" --dir "$d" >/dev/null 2>&1; ok "clean dir exits 0 (.git, __pycache__, *.pyc skipped; clean binary)" '[ $? -eq 0 ]'
# Binary files are scanned too (grep -I would skip them)
d=$(newdir bindir "hello"); printf 'a\0b jane%scorp-mail.net\n' "$AT" > "$d/blob.bin"
out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
ok "binary file content hits" '[ $rc -eq 1 ] && grep -qx "blob.bin:1: email: jane${AT}corp-mail.net" <<<"$out"'

# Paths are scanned with the generic rules
d=$(newdir pathdir "hello"); mkdir -p "$d/jane.doe${AT}corp-mail.net"; printf 'ok\n' > "$d/jane.doe${AT}corp-mail.net/notes.txt"
out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
ok "path hits as email" '[ $rc -eq 1 ] && grep -qx "jane.doe${AT}corp-mail.net/notes.txt: path: email: jane.doe${AT}corp-mail.net" <<<"$out"'
# A path holding ':' is reported whole
d=$(newdir colondir "hello"); printf 'mail jane%scorp-mail.net\n' "$AT" > "$d/a:b.txt"
out=$(bash "$S" --dir "$d" 2>/dev/null)
ok "path with ':' reported whole" 'grep -qx "a:b.txt:1: email: jane${AT}corp-mail.net" <<<"$out"'
# Symlink targets are scanned (the link itself is never followed)
d=$(newdir linkdir "hello"); ln -s "${U}jdoe/secret" "$d/lnk"
out=$(bash "$S" --dir "$d" 2>/dev/null); rc=$?
ok "symlink target hits" '[ $rc -eq 1 ] && grep -qx "lnk: link: home-path: ${U}jdoe" <<<"$out"'
bash "$S" --dir "$T/missing" >/dev/null 2>&1; ok "missing --dir exits 2" '[ $? -eq 2 ]'
bash "$S" --bogus >/dev/null 2>&1; ok "unknown flag exits 2" '[ $? -eq 2 ]'

# Denylist via env: case-insensitive, comments ignored, pattern never printed
d=$(newdir deny "line with Zebra-Secret inside" "plain line")
printf '%s\n' "# a comment zebra" "" "zebra-sec[r]et" > "$T/deny.txt"
out=$(RUMO_LEAK_DENYLIST="$T/deny.txt" bash "$S" --dir "$d" 2>&1); rc=$?
ok "denylist hits (case-insensitive)" '[ $rc -eq 1 ] && grep -q "^f.txt:1: denylist: " <<<"$out"'
ok "denylist output never shows the pattern or the match" '! grep -qi "zebra" <<<"$out"'
d=$(newdir deny-clean "plain line")
RUMO_LEAK_DENYLIST="$T/deny.txt" bash "$S" --dir "$d" >/dev/null 2>&1; ok "denylist clean dir exits 0" '[ $? -eq 0 ]'
printf '%s\n' "# only comments" > "$T/deny-empty.txt"
RUMO_LEAK_DENYLIST="$T/deny-empty.txt" bash "$S" --dir "$d" >/dev/null 2>&1; ok "comment-only denylist matches nothing" '[ $? -eq 0 ]'
printf '%s\n' "(unclosed" > "$T/deny-bad.txt"
RUMO_LEAK_DENYLIST="$T/deny-bad.txt" bash "$S" --dir "$d" >/dev/null 2>&1; ok "invalid denylist pattern exits 2" '[ $? -eq 2 ]'
bash "$S" --dir "$d" --require-denylist >/dev/null 2>&1; ok "--require-denylist without a denylist exits 2" '[ $? -eq 2 ]'
RUMO_LEAK_DENYLIST="$T/deny.txt" bash "$S" --dir "$d" --require-denylist >/dev/null 2>&1
ok "--require-denylist with a denylist passes a clean dir" '[ $? -eq 0 ]'
d=$(newdir deny-path "plain line"); printf 'ok\n' > "$d/Zebra-Secret-notes.txt"
out=$(RUMO_LEAK_DENYLIST="$T/deny.txt" bash "$S" --dir "$d" 2>&1); rc=$?
ok "denylist hits a path, redacting the match in it" '[ $rc -eq 1 ] && grep -qx "(redacted)-notes.txt: path: denylist: (redacted)" <<<"$out"'
ok "denylist path hit never shows the match" '! grep -qi "zebra" <<<"$out"'

# Repo mode (git ls-files) and --history, in a throwaway repo that carries its own copy of the script
R="$T/repo"; mkdir -p "$R/scripts"; cp "$S" "$R/scripts/leak-scan.sh"
git -C "$R" init -q -b main
printf 'clean\n' > "$R/tracked.txt"; printf 'jane%scorp-mail.net\n' "$AT" > "$R/untracked.txt"
git -C "$R" add tracked.txt scripts
GIT_AUTHOR_NAME=fx GIT_AUTHOR_EMAIL="fx${AT}example.com" GIT_COMMITTER_NAME=fx GIT_COMMITTER_EMAIL="fx${AT}example.com" \
  git -C "$R" -c commit.gpgsign=false commit -q -m "first"
bash "$R/scripts/leak-scan.sh" >/dev/null 2>&1; ok "repo mode scans tracked files only" '[ $? -eq 0 ]'
git -C "$R" add untracked.txt
bash "$R/scripts/leak-scan.sh" >/dev/null 2>&1; ok "repo mode hits a tracked file" '[ $? -eq 1 ]'
git -C "$R" rm -q -f --cached untracked.txt
GIT_AUTHOR_NAME=fx GIT_AUTHOR_EMAIL="fx${AT}corp-mail.net" GIT_COMMITTER_NAME=fx GIT_COMMITTER_EMAIL="fx${AT}example.com" \
  git -C "$R" -c commit.gpgsign=false commit -q --allow-empty -m "second"
bash "$R/scripts/leak-scan.sh" >/dev/null 2>&1; ok "history is not scanned without --history" '[ $? -eq 0 ]'
out=$(bash "$R/scripts/leak-scan.sh" --history 2>/dev/null); rc=$?
ok "--history hits a commit identity" '[ $rc -eq 1 ] && grep -q "^git-history:[0-9]*: email: fx${AT}corp-mail.net" <<<"$out"'
R2="$T/repo2"; mkdir -p "$R2/scripts"; cp "$S" "$R2/scripts/leak-scan.sh"; git -C "$R2" init -q -b main; git -C "$R2" add scripts
GIT_AUTHOR_NAME=fx GIT_AUTHOR_EMAIL="fx${AT}example.com" GIT_COMMITTER_NAME=fx GIT_COMMITTER_EMAIL="fx${AT}example.com" \
  git -C "$R2" -c commit.gpgsign=false commit -q -m "see ${U}jdoe/notes"
out=$(bash "$R2/scripts/leak-scan.sh" --history 2>/dev/null); rc=$?
ok "--history reads commit messages" '[ $rc -eq 1 ] && grep -q "^git-history:[0-9]*: home-path: ${U}jdoe" <<<"$out"'
RUMO_LEAK_DENYLIST="$T/deny.txt" bash "$R/scripts/leak-scan.sh" --require-denylist >/dev/null 2>&1
ok "repo mode honours --require-denylist with a denylist" '[ $? -eq 0 ]'
ln -s "${U}jdoe/x" "$R/lnk"; printf 'a\0 jane%scorp-mail.net\n' "$AT" > "$R/b.bin"; git -C "$R" add lnk b.bin
out=$(bash "$R/scripts/leak-scan.sh" 2>/dev/null); rc=$?
ok "repo mode scans symlink targets" '[ $rc -eq 1 ] && grep -qx "lnk: link: home-path: ${U}jdoe" <<<"$out"'
ok "repo mode scans binary files" 'grep -qx "b.bin:1: email: jane${AT}corp-mail.net" <<<"$out"'

exit $fail
