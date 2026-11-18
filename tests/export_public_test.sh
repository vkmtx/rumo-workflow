#!/usr/bin/env bash
# Run: bash tests/export_public_test.sh — exit 1 on any FAIL.
# Exports a throwaway git repo (carrying copies of the two scripts) into throwaway targets.
SRC="$(cd "$(dirname "$0")/.." && pwd)/scripts"; fail=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PH='__REPO''__'; AT='@'
# Isolate from the machine: no global git config, a test denylist, a hostile identity in the environment
export GIT_CONFIG_GLOBAL="$T/gitconfig"; printf '[user]\n\tname = Someone Else\n\temail = someone%selse.test\n' "$AT" > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_SYSTEM=/dev/null
export RUMO_LEAK_DENYLIST="$T/deny.txt"; printf '%s\n' "# test denylist" "zebra-sec[r]et" > "$RUMO_LEAK_DENYLIST"
export GIT_AUTHOR_NAME="Host Author" GIT_AUTHOR_EMAIL="host${AT}example.com" GIT_COMMITTER_NAME="Host Committer" GIT_COMMITTER_EMAIL="host${AT}example.com"

R="$T/src"; mkdir -p "$R/scripts" "$R/.claude-plugin" "$R/.rumo" "$R/pkg/__pycache__" "$R/docs"
cp "$SRC/export-public.sh" "$SRC/leak-scan.sh" "$R/scripts/"
printf '{\n  "name": "fixture",\n  "version": "1.2.3"\n}\n' > "$R/.claude-plugin/plugin.json"
printf 'install from https://github.com/%s/releases\n' "$PH" > "$R/README.md"
printf 'plan\n' > "$R/.rumo/plan.md"
printf 'x = 1\n' > "$R/pkg/mod.py"; printf '\0\1\2' > "$R/pkg/__pycache__/mod.cpython-39.pyc"; printf '\0\1\2' > "$R/pkg/stray.pyc"
printf 'slug %s here\n' "$PH" > "$R/docs/a.md"
printf '\0%s\0' "$PH" > "$R/docs/blob.bin"
git -C "$R" init -q -b main
git -C "$R" add -A; git -C "$R" add -f .rumo/plan.md pkg/__pycache__/mod.cpython-39.pyc pkg/stray.pyc
git -C "$R" commit -q -m "fixture"
X="bash $R/scripts/export-public.sh"

# Dirty tree: modified tracked file, then an untracked file
printf 'edit\n' >> "$R/pkg/mod.py"
out=$($X --slug acme/widget --target "$T/t0" 2>&1); rc=$?
ok "dirty tree (modified) refused" '[ $rc -eq 1 ] && grep -q "dirty" <<<"$out"'
ok "dirty refusal leaves the target without files" '[ -z "$(ls -A "$T/t0" 2>/dev/null)" ]'
git -C "$R" checkout -q -- pkg/mod.py
printf 'new\n' > "$R/untracked.txt"
$X --slug acme/widget --target "$T/t0" >/dev/null 2>&1; ok "dirty tree (untracked) refused" '[ $? -eq 1 ]'
rm "$R/untracked.txt"

# Bad arguments
$X --slug nonsense --target "$T/t0" >/dev/null 2>&1; ok "slug without owner/name exits 2" '[ $? -eq 2 ]'
$X --target "$T/t0" >/dev/null 2>&1; ok "missing --slug exits 2" '[ $? -eq 2 ]'

# Happy path
out=$($X --slug acme/widget --target "$T/t1" 2>/dev/null); rc=$?
ok "export succeeds" '[ $rc -eq 0 ]'
ok "placeholder replaced in text files" 'grep -q "github.com/acme/widget/releases" "$T/t1/README.md" && grep -q "slug acme/widget here" "$T/t1/docs/a.md"'
ok "no placeholder left in text files" '! grep -rIq -e "$PH" "$T/t1" --exclude-dir=.git'
ok "binary files are not rewritten" 'grep -aq -e "$PH" "$T/t1/docs/blob.bin"'
ok ".rumo/ excluded" '[ ! -e "$T/t1/.rumo" ]'
ok "__pycache__ and *.pyc excluded" '[ ! -e "$T/t1/pkg/__pycache__" ] && [ ! -e "$T/t1/pkg/stray.pyc" ]'
ok "other files exported" '[ -f "$T/t1/pkg/mod.py" ] && [ -f "$T/t1/scripts/leak-scan.sh" ] && [ -f "$T/t1/.claude-plugin/plugin.json" ]'
ok "target is a repo on main with one commit" '[ "$(git -C "$T/t1" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(git -C "$T/t1" rev-list --count HEAD)" = 1 ]'
ok "author is the noreply identity" '[ "$(git -C "$T/t1" log -1 --format="%an <%ae>")" = "vkmtx <110697534+vkmtx${AT}users.noreply.github.com>" ]'
ok "committer is the noreply identity" '[ "$(git -C "$T/t1" log -1 --format="%cn <%ce>")" = "vkmtx <110697534+vkmtx${AT}users.noreply.github.com>" ]'
ok "default message carries the plugin version" '[ "$(git -C "$T/t1" log -1 --format=%s)" = "Export 1.2.3" ]'
sha=$(git -C "$T/t1" rev-parse HEAD); n=$(git -C "$T/t1" ls-files | wc -l | tr -d ' ')
ok "prints target, commit and file count" 'grep -q "^target: " <<<"$out" && grep -q "^commit: $sha\$" <<<"$out" && grep -q "^files: *$n\$" <<<"$out"'
ok "no remote configured, nothing pushed" '[ -z "$(git -C "$T/t1" remote)" ]'
ok "source repo untouched" '[ -z "$(git -C "$R" status --porcelain)" ]'

# Second export: a second commit, deletions propagate, .git preserved, custom message
git -C "$R" rm -q pkg/stray.pyc docs/a.md; printf 'y = 2\n' > "$R/pkg/other.py"; git -C "$R" add pkg/other.py; git -C "$R" commit -q -m "second"
$X --slug acme/widget --target "$T/t1" --message "Release 2" >/dev/null 2>&1; rc=$?
ok "second export succeeds" '[ $rc -eq 0 ]'
ok "second export makes a second commit" '[ "$(git -C "$T/t1" rev-list --count HEAD)" = 2 ] && [ "$(git -C "$T/t1" log -1 --format=%s)" = "Release 2" ]'
ok "second export deletes removed files and adds new ones" '[ ! -e "$T/t1/docs/a.md" ] && [ -f "$T/t1/pkg/other.py" ]'
ok "second commit keeps the noreply identity" '[ "$(git -C "$T/t1" log -1 --format="%ae")" = "110697534+vkmtx${AT}users.noreply.github.com" ]'
$X --slug acme/widget --target "$T/t1" >/dev/null 2>&1
ok "unchanged re-export makes no extra commit" '[ "$(git -C "$T/t1" rev-list --count HEAD)" = 2 ]'

# Leak hits abort before anything is written
printf 'the zebra-secret is here\n' > "$R/docs/leak.md"; git -C "$R" add docs/leak.md; git -C "$R" commit -q -m "leak"
out=$($X --slug acme/widget --target "$T/t2" 2>&1); rc=$?
ok "denylist hit aborts" '[ $rc -eq 1 ] && grep -q "leak scan failed" <<<"$out" && grep -q "docs/leak.md:1: denylist" <<<"$out"'
ok "aborted export wrote nothing" '[ -z "$(ls -A "$T/t2" 2>/dev/null)" ]'
ok "denylist pattern not echoed on abort" '! grep -qi "zebra" <<<"$out"'
git -C "$R" rm -q docs/leak.md; printf 'mail jane%scorp-mail.net\n' "$AT" > "$R/docs/mail.md"; git -C "$R" add docs/mail.md; git -C "$R" commit -q -m "mail"
$X --slug acme/widget --target "$T/t2" >/dev/null 2>&1; ok "generic leak (email) aborts" '[ $? -eq 1 ] && [ -z "$(ls -A "$T/t2" 2>/dev/null)" ]'
$X --slug acme/widget --target "$T/t1" >/dev/null 2>&1
ok "aborted re-export leaves the earlier target untouched" '[ "$(git -C "$T/t1" rev-list --count HEAD)" = 2 ] && [ ! -e "$T/t1/docs/mail.md" ]'
git -C "$R" rm -q docs/mail.md; git -C "$R" commit -q -m "clean again"

# Existing target repos: must be clean and carry only the noreply identity (or no commits)
printf 'local edit\n' > "$T/t1/scratch.txt"
out=$($X --slug acme/widget --target "$T/t1" 2>&1); rc=$?
ok "dirty target repo refused, its files kept" '[ $rc -eq 1 ] && grep -q "uncommitted" <<<"$out" && [ -f "$T/t1/scratch.txt" ]'
rm "$T/t1/scratch.txt"
echo 'keep/' >> "$T/t1/.git/info/exclude"; mkdir -p "$T/t1/keep"; printf 'notes\n' > "$T/t1/keep/notes"
out=$($X --slug acme/widget --target "$T/t1" 2>&1); rc=$?
ok "git-ignored file in target refused, kept" '[ $rc -eq 1 ] && grep -q "uncommitted" <<<"$out" && [ -f "$T/t1/keep/notes" ]'
rm -r "$T/t1/keep"
mkdir -p "$T/t5"; git -C "$T/t5" init -q -b main; printf 'mine\n' > "$T/t5/own.txt"; git -C "$T/t5" add own.txt
git -C "$T/t5" -c commit.gpgsign=false commit -q -m "someone else's repo"
out=$($X --slug acme/widget --target "$T/t5" 2>&1); rc=$?
ok "target repo with a foreign author refused, untouched" '[ $rc -eq 1 ] && grep -q "another identity" <<<"$out" && [ -f "$T/t5/own.txt" ] && [ "$(git -C "$T/t5" rev-list --count HEAD)" = 1 ]'
ok "foreign-author refusal does not print the email" '! grep -q "host${AT}example.com" <<<"$out"'
mkdir -p "$T/t7"; git -C "$T/t7" init -q -b main
$X --slug acme/widget --target "$T/t7" >/dev/null 2>&1; ok "empty target repo (no commits) accepted" '[ $? -eq 0 ] && [ "$(git -C "$T/t7" rev-list --count HEAD)" = 1 ]'
# A .git file (worktree of an earlier export) survives the sync
git -C "$T/t1" worktree add -q -b side "$T/t6" 2>/dev/null
printf 'z = 3\n' > "$R/pkg/z.py"; git -C "$R" add pkg/z.py; git -C "$R" commit -q -m "z"
$X --slug acme/widget --target "$T/t6" >/dev/null 2>&1; rc=$?
ok "export into a worktree keeps its .git file" '[ $rc -eq 0 ] && [ -f "$T/t6/.git" ] && [ -f "$T/t6/pkg/z.py" ] && [ "$(git -C "$T/t1" log -1 --format=%s side)" = "Export 1.2.3" ]'

# The commit message is leak-scanned too
out=$($X --slug acme/widget --target "$T/t8" --message "see /Users/""jdoe/notes" 2>&1); rc=$?
ok "leaky --message aborts, nothing written" '[ $rc -eq 1 ] && grep -q "message" <<<"$out" && [ -z "$(ls -A "$T/t8" 2>/dev/null)" ]'
out=$($X --slug acme/widget --target "$T/t8" --message "the zebra-secret release" 2>&1); rc=$?
ok "denylisted --message aborts without echoing it" '[ $rc -eq 1 ] && ! grep -qi "zebra" <<<"$out" && [ -z "$(ls -A "$T/t8" 2>/dev/null)" ]'

# Private slug: whole-word, not followed by [-A-Za-z0-9_.], in *.md only
printf '%s\n' "gh -R acme/secret-src issue list" "keep acme/secret-src-two acme/secret-src.git xacme/secret-src" "default vkmtx/rumo here" > "$R/docs/tracker.md"
printf 'R=acme/secret-src\n' > "$R/scripts/fx.sh"
git -C "$R" add docs/tracker.md scripts/fx.sh; git -C "$R" commit -q -m "slugs"
$X --slug acme/widget --target "$T/t9" --private-slug acme/secret-src >/dev/null 2>&1; rc=$?
ok "private slug replaced in *.md" '[ $rc -eq 0 ] && grep -qx "gh -R acme/widget issue list" "$T/t9/docs/tracker.md"'
ok "private slug kept when followed by -/. or preceded by a word char" 'grep -qx "keep acme/secret-src-two acme/secret-src.git xacme/secret-src" "$T/t9/docs/tracker.md"'
ok "private slug untouched outside *.md" 'grep -qx "R=acme/secret-src" "$T/t9/scripts/fx.sh"'
$X --slug acme/widget --target "$T/t10" >/dev/null 2>&1
ok "default private slug is vkmtx/rumo" 'grep -qx "default acme/widget here" "$T/t10/docs/tracker.md"'
$X --slug acme/widget --target "$T/t11" --private-slug nonsense >/dev/null 2>&1; ok "malformed --private-slug exits 2" '[ $? -eq 2 ]'

# Missing denylist is an error (--require-denylist)
RUMO_LEAK_DENYLIST="$T/missing.txt" $X --slug acme/widget --target "$T/t3" >/dev/null 2>&1
ok "missing denylist aborts the export" '[ $? -eq 1 ] && [ -z "$(ls -A "$T/t3" 2>/dev/null)" ]'

# Target safety
mkdir -p "$T/t4"; printf 'precious\n' > "$T/t4/keep.txt"
$X --slug acme/widget --target "$T/t4" >/dev/null 2>&1
ok "non-empty non-git target refused, content kept" '[ $? -eq 1 ] && [ -f "$T/t4/keep.txt" ]'
$X --slug acme/widget --target "$R/out" >/dev/null 2>&1; rc=$?
ok "target inside the source repo refused" '[ $rc -eq 1 ]'
rm -rf "$R/out"

exit $fail
