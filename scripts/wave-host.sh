#!/usr/bin/env bash
# wave-host.sh <host> <repo> <base> <brief> [sync-host flags…] — make a remote host ready for wave lanes (wave.md §4).
# Runs `sync-host.sh <host> --preflight [flags…]`, checks the host has a clone of <repo> at
# ~/<WAVE_HOST_PROJECTS>/<repo> and fetches <base> from origin, makes sure the host's Orca has that clone
# registered (host-lib.sh's orca_repo_add when missing), and copies <brief> to the host.
#   PLACE <host> repo=id:<id> path=<host path> brief=<host brief path>   (stdout, last line: launch there)
#   PLACE local reason=<reason>                                          (every lane planned for <host> goes local)
# <reason>: preflight-fail | unreachable | preflight-rc<n> | no-clone | fetch-fail | orca-repo | brief-copy. A fallback also
# prints `WARN: <host>: <reason> — lanes fall back to local` to stderr, and nothing runs after it (no clone, no
# Orca call). Never auto-clones: a repo missing on the host is `no-clone`.
# Env: WAVE_SYNC_HOST (default: sync-host.sh beside this script), WAVE_REMOTE_SH (default: host-lib.sh's
# REMOTE_SH_DEFAULT; run as `$WAVE_REMOTE_SH <host> "$(remote_wrap '<shell string>')"`, in the host's $HOME; when set,
# sync-host gets it as SYNC_REMOTE_SH="$WAVE_REMOTE_SH <host>" with SYNC_REMOTE_WRAP=1), WAVE_HOST_PROJECTS (default
# orca/projects, relative to the host's home).
# Exit 0 (PLACE line printed, fallback included) · 2 usage (<4 args, host `local`, brief not a readable file).
set -uo pipefail
. "$(dirname "$0")/host-lib.sh"
usage() { echo "usage: wave-host.sh <host> <repo> <base> <brief> [sync-host flags…]  (host is a remote host, not local)" >&2; exit 2; }
[ $# -ge 4 ] || usage
host=$1; repo=$2; base=$3; brief=$4
[ "$host" != local ] && [ -f "$brief" ] && [ -r "$brief" ] || usage
sync=${WAVE_SYNC_HOST:-$(dirname "$0")/sync-host.sh}
remote=${WAVE_REMOTE_SH:-$REMOTE_SH_DEFAULT}
projects=${WAVE_HOST_PROJECTS:-orca/projects}

fallback() { echo "WARN: $host: $1 — lanes fall back to local" >&2; echo "PLACE local reason=$1"; exit 0; }
rsh() { $remote "$host" "$(remote_wrap "$1")"; }   # word-split on purpose: WAVE_REMOTE_SH is a command prefix; remote_wrap adds the PATH prefix and bash -c

env ${WAVE_REMOTE_SH:+"SYNC_REMOTE_SH=$WAVE_REMOTE_SH $host" SYNC_REMOTE_WRAP=1} bash "$sync" "$host" --preflight "${@:5}" >&2; rc=$?
case $rc in
  0) ;;
  1) fallback preflight-fail ;;
  3) fallback unreachable ;;
  *) fallback "preflight-rc$rc" ;;
esac

cd_clone="cd $(printf %q "$projects/$repo")"
path=$(rsh "$cd_clone && git rev-parse --show-toplevel" </dev/null | head -n 1)
[ -n "$path" ] || fallback no-clone
rsh "$cd_clone && git fetch --quiet origin $(printf %q "$base")" </dev/null >/dev/null || fallback fetch-fail

pick() {   # id of the registered repo whose path is $path
  orca repo list --environment "$host" --json 2>/dev/null | python3 -I -c '
import json, sys
try:
    repos = json.load(sys.stdin)["result"]["repos"]
except Exception:
    sys.exit(0)
for r in repos:
    if str(r.get("path", "")).rstrip("/") == sys.argv[1]:
        print(r.get("id", ""))
        break
' "$path"
}
id=$(pick)
if [ -z "$id" ]; then
  orca_repo_add "$host" "$path"
  id=$(pick)
fi
[ -n "$id" ] || fallback orca-repo

name=$(basename "$brief")
hb=$(rsh "mkdir -p .claude/learn/waves && cat > .claude/learn/waves/$(printf %q "$name") && printf '%s\\n' \"\$HOME/.claude/learn/waves/\"$(printf %q "$name")" < "$brief") || fallback brief-copy
hb=$(printf '%s\n' "$hb" | tail -n 1)
[ -n "$hb" ] || fallback brief-copy

echo "PLACE $host repo=id:$id path=$path brief=$hb"
