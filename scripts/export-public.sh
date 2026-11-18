#!/usr/bin/env bash
# Run: bash scripts/export-public.sh --slug <owner/name> --target <dir> [--message <msg>]
#        [--private-slug <owner/name>]
# Publishes a clean snapshot of HEAD into <target>, a separate git repo with its own history.
#   1. refuses on a dirty work tree (uncommitted or untracked files), and on a <target> repo that has
#      uncommitted changes or any commit whose author or committer is not the public noreply identity
#   2. `git archive HEAD` into a temp dir; drops .rumo/, __pycache__/ and *.pyc
#   3. replaces the repo-slug placeholder with --slug in every text file, and in *.md files only the
#      private slug (--private-slug, default vkmtx/rumo) as a whole word not followed by [-A-Za-z0-9_.]
#   4. runs scripts/leak-scan.sh --require-denylist on the result and on the commit message; aborts on any hit
#   5. syncs into <target> (rsync --delete, <target>/.git kept, dir or file), `git init -b main` when
#      needed, and commits as the public noreply identity. It never pushes.
# Prints the target, the commit SHA and the file count.
set -u

PUBLIC_NAME="vkmtx"
PUBLIC_EMAIL="110697534+vkmtx@users.noreply.github.com"
PH="__REPO""__"   # split so this script is not rewritten by its own substitution

usage() { echo "usage: export-public.sh --slug <owner/name> --target <dir> [--message <msg>] [--private-slug <owner/name>]" >&2; exit 2; }
die() { echo "export-public: $*" >&2; exit 1; }

SLUG=""; TARGET=""; MSG=""; PRIV="vkmtx/rumo"
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || usage; SLUG="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || usage; TARGET="$2"; shift 2 ;;
    --message) [ $# -ge 2 ] || usage; MSG="$2"; shift 2 ;;
    --private-slug) [ $# -ge 2 ] || usage; PRIV="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$SLUG" ] && [ -n "$TARGET" ] || usage
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "export-public: --slug must look like owner/name" >&2; exit 2; }
[[ "$PRIV" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "export-public: --private-slug must look like owner/name" >&2; exit 2; }

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null || die "the repository has no commits"

# 1. Dirty tree --------------------------------------------------------------
[ -z "$(git -C "$ROOT" status --porcelain)" ] || die "work tree is dirty: commit or stash first"

# Target safety: never sync over a directory that is not an earlier export
CREATED=0; [ -e "$TARGET" ] || CREATED=1
mkdir -p "$TARGET" || die "cannot create $TARGET"
TARGET=$(cd "$TARGET" && pwd -P)
refuse() { [ $CREATED -eq 1 ] && rmdir "$TARGET" 2>/dev/null; die "$1"; }
ROOT_REAL=$(cd "$ROOT" && pwd -P)
case "$TARGET/" in "$ROOT_REAL"/*) refuse "target is inside the source repository" ;; esac
case "$ROOT_REAL/" in "$TARGET"/*) refuse "target contains the source repository" ;; esac
[ "$TARGET" != "/" ] && [ "$TARGET" != "$(cd "$HOME" 2>/dev/null && pwd -P)" ] || die "refusing to sync into $TARGET"
if [ ! -e "$TARGET/.git" ] && [ -n "$(ls -A "$TARGET")" ]; then
  die "target is not empty and is not a git repository: $TARGET"
fi
if [ -e "$TARGET/.git" ]; then
  [ "$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" = "$TARGET" ] || die "target has a .git but is not a usable git repository: $TARGET"
  [ -z "$(git -C "$TARGET" status --porcelain --ignored 2>/dev/null)" ] || die "target repository has uncommitted changes: $TARGET"
  if git -C "$TARGET" rev-parse --verify -q HEAD >/dev/null 2>&1 || [ -n "$(git -C "$TARGET" for-each-ref 2>/dev/null)" ]; then
    # the email itself is not printed: it may be private
    git -C "$TARGET" log --all --format='%ae%n%ce' 2>/dev/null | grep -qvxF "$PUBLIC_EMAIL" \
      && die "target repository has commits by another identity (not $PUBLIC_NAME noreply); refusing to export into it: $TARGET"
  fi
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TREE="$T/tree"; mkdir -p "$TREE"

# 2. Archive -------------------------------------------------------------------
git -C "$ROOT" archive HEAD | tar -x -C "$TREE" || die "git archive failed"
rm -rf "$TREE/.rumo"
find "$TREE" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
find "$TREE" -name '*.pyc' -type f -delete 2>/dev/null

# 3. Placeholder ---------------------------------------------------------------
grep -rIl -e "$PH" "$TREE" 2>/dev/null | while IFS= read -r f; do
  SLUG="$SLUG" PH="$PH" perl -pi -e 's/\Q$ENV{PH}\E/$ENV{SLUG}/g' "$f"
done

# Private slug, in *.md only: tests and scripts keep their fixtures
find "$TREE" -type f -name '*.md' -print0 | xargs -0 -r grep -lF -e "$PRIV" 2>/dev/null | while IFS= read -r f; do
  SLUG="$SLUG" PRIV="$PRIV" perl -pi -e 's/(?<![-A-Za-z0-9_.])\Q$ENV{PRIV}\E(?![-A-Za-z0-9_.])/$ENV{SLUG}/g' "$f"
done

if [ -z "$MSG" ]; then
  VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TREE/.claude-plugin/plugin.json" 2>/dev/null | head -1)
  MSG="Export${VER:+ $VER}"
fi

# 4. Leak scan: the tree, then the commit message (with the tree's allowlist) ----------
if ! bash "$SELF_DIR/leak-scan.sh" --dir "$TREE" --require-denylist > "$T/scan.out" 2> "$T/scan.err"; then
  echo "export-public: leak scan failed, nothing was exported" >&2
  cat "$T/scan.out" "$T/scan.err" >&2
  exit 1
fi
mkdir -p "$T/msg"; printf '%s\n' "$MSG" > "$T/msg/commit-message"
[ -f "$TREE/.leak-scan-allow" ] && cp "$TREE/.leak-scan-allow" "$T/msg/"
if ! bash "$SELF_DIR/leak-scan.sh" --dir "$T/msg" --require-denylist > "$T/scan.out" 2> "$T/scan.err"; then
  echo "export-public: leak scan of the commit message failed, nothing was exported" >&2
  cat "$T/scan.out" "$T/scan.err" >&2
  exit 1
fi

# 5. Sync and commit -------------------------------------------------------------
rsync -a --delete --exclude=/.git "$TREE"/ "$TARGET"/ || die "rsync failed"
if [ ! -e "$TARGET/.git" ]; then
  git -C "$TARGET" init -q -b main || die "git init failed"
fi

export GIT_AUTHOR_NAME="$PUBLIC_NAME" GIT_AUTHOR_EMAIL="$PUBLIC_EMAIL"
export GIT_COMMITTER_NAME="$PUBLIC_NAME" GIT_COMMITTER_EMAIL="$PUBLIC_EMAIL"
git -C "$TARGET" add -A >/dev/null || die "git add failed"
if git -C "$TARGET" rev-parse --verify -q HEAD >/dev/null && git -C "$TARGET" diff --cached --quiet; then
  echo "export-public: no changes since the last export, no commit made" >&2
else
  git -C "$TARGET" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$MSG" >/dev/null || die "git commit failed"
fi

echo "target: $TARGET"
echo "commit: $(git -C "$TARGET" rev-parse HEAD)"
echo "files:  $(git -C "$TARGET" ls-files | wc -l | tr -d ' ')"
exit 0
