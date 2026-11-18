#!/usr/bin/env bash
# Run: bash scripts/leak-scan.sh [--dir <path>] [--history] [--require-denylist]
# Scans for personal data and credentials before anything is published.
#   default   `git ls-files` of this repo
#   --dir D   every file and symlink under D instead (an export tree, a fixture); .git/, __pycache__/, *.pyc skipped
#   --history also scans author/committer identities and commit messages (`git log --all`)
#   --require-denylist  a missing private denylist is an error (exit 2) instead of being skipped
# Scanned: text files, binary files (as raw bytes, grep -a), every scanned relative path, and each
# symlink's target text (links are never followed).
# Prints `file:line: <rule>: <match>` per content hit, `<path>: path: <rule>: <match>` for a path and
# `<link>: link: <rule>: <match>` for a symlink target; exit 1 when there is any hit, 0 when clean,
# 2 on a usage error.
#
# Generic rules live here (no personal strings). Two optional extras:
#   .leak-scan-allow   in the scanned tree, one fixed string per line: a match equal to a line is suppressed.
#                      Meant for obvious fake fixtures. Lines starting with '#' are comments.
#   private denylist   case-insensitive EREs, '#' comments, read from $RUMO_LEAK_DENYLIST, default
#                      ~/.config/leak-denylist/rumo.txt when that file exists. Hits print the rule name
#                      `denylist` and a redacted match: the pattern and the matched text are never printed.
set -u

usage() { echo "usage: leak-scan.sh [--dir <path>] [--history] [--require-denylist]" >&2; exit 2; }
die() { echo "leak-scan: $*" >&2; exit 2; }

DIR=""; HISTORY=0; REQUIRE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
    --history) HISTORY=1; shift ;;
    --require-denylist) REQUIRE=1; shift ;;
    *) usage ;;
  esac
done

if [ -n "$DIR" ]; then
  [ -d "$DIR" ] || die "not a directory: $DIR"
  ROOT=$(cd "$DIR" && pwd)
else
  ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LIST="$T/files"     # NUL-separated, relative to $ROOT
ALLOW="$T/allow"
DENY="$T/deny"
OUT="$T/out"; : > "$OUT"

# File list ------------------------------------------------------------------
# $ALL every scanned path (files and symlinks); then split into $TEXT, $BIN (grep -I would skip them)
# and the symlinks. A symlink is never followed: its target text is what gets scanned.
ALL="$T/all"; TEXT="$T/text"; BIN="$T/bin"
if [ -n "$DIR" ]; then
  # __pycache__/ and *.pyc are skipped like export-public drops them: local bytecode carries the
  # machine's absolute paths and never ships (git mode still scans a tracked one)
  (cd "$ROOT" && find . \( -name .git -o -name __pycache__ \) -prune -o -name '*.pyc' -o \( -type f -o -type l \) -print0) | while IFS= read -r -d '' f; do
    printf '%s\0' "${f#./}"
  done > "$ALL"
else
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git work tree: $ROOT"
  git -C "$ROOT" ls-files -z > "$T/tracked"
  : > "$ALL"
  while IFS= read -r -d '' f; do
    { [ -L "$ROOT/$f" ] || [ -f "$ROOT/$f" ]; } && printf '%s\0' "$f" >> "$ALL"
  done < "$T/tracked"
fi
: > "$TEXT"; : > "$BIN"; : > "$T/linktext"; : > "$T/linknames"; : > "$T/paths"
NL=$'\n'
while IFS= read -r -d '' f; do
  printf '%s\n' "${f//$NL/?}" >> "$T/paths"   # one path per line; a newline inside a name shows as '?'
  if [ -L "$ROOT/$f" ]; then
    lt=$(readlink "$ROOT/$f"); printf '%s\n' "${lt//$NL/?}" >> "$T/linktext"
    printf '%s\n' "${f//$NL/?}" >> "$T/linknames"
  elif grep -Iq '' "$ROOT/$f" 2>/dev/null; then
    printf '%s\0' "$f" >> "$TEXT"
  else
    printf '%s\0' "$f" >> "$BIN"   # binary or empty: scanned with grep -a
  fi
done < "$ALL"

# Allowlist ------------------------------------------------------------------
: > "$ALLOW"
[ -f "$ROOT/.leak-scan-allow" ] && grep -v -e '^#' -e '^$' "$ROOT/.leak-scan-allow" > "$ALLOW"

# Denylist -------------------------------------------------------------------
DENYFILE="${RUMO_LEAK_DENYLIST:-$HOME/.config/leak-denylist/rumo.txt}"
HAVE_DENY=0
if [ -f "$DENYFILE" ]; then
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$DENYFILE" > "$DENY"
  if [ -s "$DENY" ]; then
    : | grep -iE -f "$DENY" >/dev/null 2>&1; [ $? -lt 2 ] || die "denylist has an invalid pattern ($DENYFILE)"
    HAVE_DENY=1
  fi
fi
[ $REQUIRE -eq 1 ] && [ $HAVE_DENY -eq 0 ] && die "private denylist missing or empty ($DENYFILE) and --require-denylist is set"

# Core -----------------------------------------------------------------------
# Every hit travels as a record `<name>NUL<where>:<match>LF` (grep --null -Hno shape), so a name may
# hold ':'. <where> is a line number, or " path" / " link" for the path and symlink-target sources.
# lines_src <text> <names> <tag> <grep-args...>: grep a one-entry-per-line file, naming hit N after line N of <names>
lines_src() {
  local src="$1" names="$2" tag="$3" l n; shift 3
  [ -s "$src" ] || return 0
  grep -no "$@" "$src" 2>/dev/null | while IFS= read -r l; do
    n=${l%%:*}; printf '%s\0%s:%s\n' "$(sed -n "${n}p" "$names")" "$tag" "${l#*:}"
  done
}
# records <grep-args...>: hit records from every source: text files, binary files (grep -a), paths,
# symlink targets and, with --history, the git log (named git-history)
records() {
  [ -s "$TEXT" ] && (cd "$ROOT" && xargs -0 grep -IHno --null "$@" < "$TEXT" 2>/dev/null)
  [ -s "$BIN" ] && (cd "$ROOT" && LC_ALL=C xargs -0 grep -aHno --null "$@" < "$BIN" 2>/dev/null)
  lines_src "$T/paths" "$T/paths" " path" "$@"
  lines_src "$T/linktext" "$T/linknames" " link" "$@"
  if [ $HISTORY -eq 1 ]; then
    grep -no "$@" "$T/history" 2>/dev/null | while IFS= read -r l; do printf 'git-history\0%s\n' "$l"; done
  fi
  return 0
}

# emit <rule> <exclude-ERE-or-empty> <trim-sed-or-empty> <redact 0|1>   (reads records on stdin)
# redact=1 (denylist): the match is never printed, and is cut out of the name too
emit() {
  local rule="$1" excl="$2" trim="$3" redact="$4" file rest line m
  while IFS= read -r -d '' file && IFS= read -r rest; do
    line=${rest%%:*}; m=${rest#*:}
    [ -n "$trim" ] && m=$(printf '%s' "$m" | sed -E "$trim")
    [ -n "$excl" ] && printf '%s' "$m" | grep -qiE -e "$excl" && continue
    if [ "$redact" -eq 0 ] && [ -s "$ALLOW" ] && printf '%s\n' "$m" | grep -qxF -f "$ALLOW"; then continue; fi
    if [ "$redact" -eq 1 ]; then [ -n "$m" ] && file=${file//"$m"/(redacted)}; m="(redacted)"; fi
    printf '%s:%s: %s: %s\n' "$file" "$line" "$rule" "$m"
  done
}

# scan_rule <rule> <ERE> [exclude-ERE] [trim-sed]
scan_rule() {
  records -E -e "$2" | emit "$1" "${3-}" "${4-}" 0 >> "$OUT"
}

if [ $HISTORY -eq 1 ]; then
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "--history needs a git repository: $ROOT"
  git -C "$ROOT" log --all --format='%an <%ae>%n%cn <%ce>%n%B' > "$T/history" 2>/dev/null
fi

# Generic rules ----------------------------------------------------------------
# email skips documentation domains, GitHub noreply, and filename shapes only: `name@2x.png` and an
# ending that is a file extension but no TLD (`slot@mini.json`). `.md`, `.sh`, `.py` are real TLDs: reported.
scan_rule email '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
  '@([A-Za-z0-9-]+\.)*example\.(com|org|net)$|^noreply@github\.com$|@users\.noreply\.github\.com$|@[0-9]+x\.(png|jpe?g|gif|webp|svg)$|@[0-9]+\.(json|txt|ya?ml|log|lock)$|\.(json|txt|ya?ml|log|lock)$'
scan_rule home-path '/(Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*' \
  '^/(Users|home)/(dev|x|v|me|runner|user|you)$'
scan_rule local-host '[A-Za-z0-9-]+\.local($|[^A-Za-z0-9_./-]|\.([^A-Za-z0-9_-]|$))' \
  '^(env|settings|claude|compose|docker-compose|application|config|appsettings|production|development|test|staging)\.local$' \
  's/\.local.*$/.local/'
scan_rule private-ip '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)' \
  '' 's/^[^0-9]*//; s/[^0-9]*$//'
scan_rule tailnet-host '[A-Za-z0-9.-]+\.ts\.net'
scan_rule credential-sk '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}' '' 's/^[^A-Za-z0-9]//'
scan_rule credential-ghp '(^|[^A-Za-z0-9])ghp_[A-Za-z0-9]{20,}' '' 's/^[^A-Za-z0-9]//'
scan_rule credential-github-pat '(^|[^A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}' '' 's/^[^A-Za-z0-9]//'
scan_rule credential-aws '(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}' '' 's/^[^A-Za-z0-9]//'
scan_rule credential-slack '(^|[^A-Za-z0-9])xox[bp]-[A-Za-z0-9-]{10,}' '' 's/^[^A-Za-z0-9]//'
scan_rule credential-jwt 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*'
scan_rule private-key '-----BEGIN [A-Z ]*PRIVATE KEY'
scan_rule cpf '[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}'
scan_rule cnpj '[0-9]{2}\.[0-9]{3}\.[0-9]{3}/[0-9]{4}-[0-9]{2}'

# Private denylist -------------------------------------------------------------
[ $HAVE_DENY -eq 1 ] && records -iE -f "$DENY" | emit denylist "" "" 1 >> "$OUT"

HITS=$(wc -l < "$OUT" | tr -d ' ')
if [ "$HITS" -gt 0 ]; then cat "$OUT"; echo "leak-scan: $HITS hit(s)" >&2; exit 1; fi
echo "leak-scan: clean" >&2
exit 0
