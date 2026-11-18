#!/usr/bin/env bash
# wave-lane-prep.sh <worktree> [host] — before a wave lane launches (wave.md §4), turn off its LSP plugins.
# Why: each Claude session with an LSP plugin runs a full semantic language server over its own worktree
# (typescript-lsp: 1.1–1.9 GB per lane in a monorepo, nothing shared across worktrees), and lanes don't use it —
# builders typecheck in VERIFY (#121).
# Writes <worktree>/.claude/settings.local.json with every `*-lsp@*` plugin that the host's ~/.claude/settings.json
# or the repo's .claude/settings.json enables set to false (other keys kept), and adds /.claude/settings.local.json
# to the repo's common info/exclude, so `git status` and wt-gc.sh see nothing. Idempotent.
# With [host], ships itself to that host through $WAVE_REMOTE_SH (default host-lib.sh's REMOTE_SH_DEFAULT) and
# remote_wrap, and runs there against the host's settings.
#   PREP <worktree> off=<plugin,…>|none                                   (stdout, last line; exit 0)
#   PREP-FAIL <worktree> reason=tracked|symlink|not-a-worktree|bad-json|unreachable   (exit 1: launch anyway, the lane is only heavier)
# symlink: <wt>/.claude, its settings.local.json or a leftover temp file is a symlink, or .claude resolves outside the
# worktree: repo content could aim the write at another file (~/.claude/settings.json and its hooks), so nothing is written.
# Exit 2 usage.
set -uo pipefail
[ $# -ge 1 ] && [ -n "$1" ] || { echo "usage: wave-lane-prep.sh <worktree> [host]" >&2; exit 2; }
wt=$1
if [ $# -ge 2 ] && [ "$2" != local ]; then
  . "$(dirname "$0")/host-lib.sh"
  remote=${WAVE_REMOTE_SH:-$REMOTE_SH_DEFAULT}
  out=$($remote "$2" "$(remote_wrap "bash -s -- $(printf %q "$wt")")" < "$0")
  last=$(printf '%s\n' "$out" | tail -n 1)
  case $last in
    "PREP "*|"PREP-FAIL "*) printf '%s\n' "$out"; [[ $last == "PREP "* ]]; exit $? ;;
    *) echo "PREP-FAIL $wt reason=unreachable"; exit 1 ;;
  esac
fi
fail() { echo "PREP-FAIL $wt reason=$1"; exit 1; }
top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || fail not-a-worktree
[ "$(cd "$wt" && pwd -P)" = "$(cd "$top" && pwd -P)" ] || fail not-a-worktree
git -C "$wt" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1 && fail tracked
off=$(python3 -I - "$wt" "$HOME/.claude/settings.json" <<'PY'
import glob, json, os, re, sys, tempfile
wt, user = sys.argv[1], sys.argv[2]
cdir = os.path.join(wt, '.claude')
local = os.path.join(cdir, 'settings.local.json')
# repo content controls .claude: refuse any link that could aim the write elsewhere
if (os.path.islink(cdir) or os.path.islink(local) or any(os.path.islink(p) for p in glob.glob(local + '*'))
        or (os.path.exists(cdir) and os.path.realpath(cdir) != os.path.join(os.path.realpath(wt), '.claude'))):
    print('symlink'); sys.exit(1)
def enabled(path):
    try:
        d = json.load(open(path))
    except (OSError, ValueError):
        return set()
    p = d.get('enabledPlugins') if isinstance(d, dict) else None
    return {k for k, v in p.items() if v is True} if isinstance(p, dict) else set()
lsp = sorted(k for k in enabled(user) | enabled(os.path.join(wt, '.claude', 'settings.json'))
             if re.fullmatch(r'[^@]+-lsp@.+', k))
cur = {}
if os.path.exists(local):
    try:
        cur = json.load(open(local))
        assert isinstance(cur, dict)
    except (ValueError, AssertionError):
        print('bad-json'); sys.exit(1)
if lsp:
    plugins = cur.get('enabledPlugins') if isinstance(cur.get('enabledPlugins'), dict) else {}
    plugins.update({k: False for k in lsp})
    cur['enabledPlugins'] = plugins
    os.makedirs(cdir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=cdir, prefix='.settings.local.')   # O_EXCL: never follows a planted name
    with os.fdopen(fd, 'w') as f:
        json.dump(cur, f, indent=2); f.write('\n')
    os.replace(tmp, local)
print(','.join(lsp) or 'none')
PY
) || fail "${off:-bad-json}"
if [ "$off" != none ]; then
  ex="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF /.claude/settings.local.json "$ex" 2>/dev/null || echo /.claude/settings.local.json >> "$ex"
fi
echo "PREP $wt off=$off"
