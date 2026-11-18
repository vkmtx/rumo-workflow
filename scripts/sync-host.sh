#!/usr/bin/env bash
# sync-host — make a remote host's ~/.claude match the local one (dry run by default).
# sync-host.sh <host> [--apply | --preflight] [--runtime <cmd>]... [--repo <host-path>]
#   (default)    dry run: print what would change + the preflight report; writes nothing; exit 0
#   --apply      backup, sync, update host's rumo checkout + plugin, register --repo in Orca, then preflight; exit = preflight's (never installs Claude Code: a version mismatch is a preflight FAIL the owner fixes by hand)
#   --preflight  checks only; exit 0 all PASS, 1 any FAIL
#   --runtime X  preflight also requires `command -v X` on the host (repeatable: --runtime node --runtime pnpm)
#   --repo P     preflight requires host path P registered in the host's Orca; --apply registers it
# Exit: 0 ok · 1 preflight FAIL / apply aborted / host settings.json invalid · 2 usage · 3 host unreachable
# Syncs only: CLAUDE.md, STACK.md, hooks/*.sh|*.py (top level), files under real (non-symlink) skills/<name>/
#   except dot-named and synced/, plus the rumo hook entries of settings.json (merged, never copied whole).
#   Never syncs denylisted names (.env*, credentials*, *.pem, *.key, id_*, *.bak*, __pycache__, *.pyc, token/secret/service-account *.json) or any hidden file or directory.
#   Symlinked skills are never written: listed as UNSYNCED and compared by the linked-skills preflight check.
# Environment (defaults are the real setup; tests override all of them):
#   SYNC_LOCAL_ROOT  $HOME/.claude               local root
#   SYNC_HOST_ROOT   .claude                     host root (relative = host's $HOME, which is ssh's cwd)
#   SYNC_LOCAL_RUMO  $HOME/orca/projects/rumo    local rumo checkout (what the MacBook plugin reads)
#   SYNC_HOST_RUMO   orca/projects/rumo          host rumo checkout
#   SYNC_BACKUP_DIR  .claude-sync-backups        host backup dir — outside ~/.claude on purpose
#   SYNC_REMOTE_SH   unset → ssh                 command prefix that runs one shell string on the host
#   SYNC_REMOTE_WRAP unset                       1 → SYNC_REMOTE_SH strings go through host-lib.sh's remote_wrap (bash -c + PATH)
#   SYNC_ORCA_ENV    <host>                      Orca --environment selector
#   SYNC_GH_USER     local `gh api user --jq .login`   the gh login the host must have
set -uo pipefail
. "$(dirname "$0")/host-lib.sh"
usage() { sed -n '2,23p' "$0"; }
host=""; apply=0; preflight_only=0; runtimes=(); repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --preflight) preflight_only=1 ;;
    --runtime) [ -n "${2:-}" ] || { echo "--runtime needs a command name" >&2; exit 2; }; runtimes+=("$2"); shift ;;
    --repo) [ -n "${2:-}" ] || { echo "--repo needs a host path" >&2; exit 2; }; repo="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$host" ]; then host="$1"; else echo "unexpected argument: $1" >&2; exit 2; fi ;;
  esac; shift
done
[ -n "$host" ] || { usage >&2; exit 2; }
[ $apply = 1 ] && [ $preflight_only = 1 ] && { echo "--apply and --preflight are exclusive" >&2; exit 2; }

SYNC_LOCAL_ROOT=${SYNC_LOCAL_ROOT:-$HOME/.claude}
SYNC_HOST_ROOT=${SYNC_HOST_ROOT:-.claude}
SYNC_LOCAL_RUMO=${SYNC_LOCAL_RUMO:-$HOME/orca/projects/rumo}
SYNC_HOST_RUMO=${SYNC_HOST_RUMO:-orca/projects/rumo}
SYNC_BACKUP_DIR=${SYNC_BACKUP_DIR:-.claude-sync-backups}
SYNC_ORCA_ENV=${SYNC_ORCA_ENV:-$host}
LR=$SYNC_LOCAL_ROOT
[ -d "$LR" ] || { echo "no local root: $LR" >&2; exit 2; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

q() { printf '%q' "$1"; }
rsh() {  # rsh "<shell string>" — runs on the host, stdin/stdout pass through
  if [ -n "${SYNC_REMOTE_SH:-}" ]; then   # word-split on purpose
    if [ "${SYNC_REMOTE_WRAP:-}" = 1 ]; then $SYNC_REMOTE_SH "$(remote_wrap "$1")"; else $SYNC_REMOTE_SH "$1"; fi
  else $REMOTE_SH_DEFAULT "$host" "$(remote_wrap "$1")"; fi   # word-split on purpose
}
rsh true >/dev/null 2>&1 || { echo "host unreachable: $host" >&2; exit 3; }

# Local JSON helper (python 3.9, stdlib only; the host needs no python). Missing/empty file = {};
# invalid JSON → stderr + exit 4 (file on this machine) or 5 (file fetched from the host).
# Prints key names only — never a settings value.
PYHELP=$(cat <<'PY'
import json, re, sys
OWN = re.compile(r"/\.claude/hooks/([A-Za-z0-9._-]+)")
def load(p, bad=4):
    try:
        s = open(p, encoding="utf-8").read()
    except OSError:
        return {}
    if not s.strip():
        return {}
    try:
        return json.loads(s)
    except ValueError:
        sys.stderr.write("invalid JSON: %s\n" % p); sys.exit(bad)
def names(item):
    return set(OWN.findall(item.get("command", "") or ""))
def owned(settings):  # [(event, group_without_hooks, item)] for rumo-owned items
    out = []
    for ev, groups in (settings.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if names(h):
                    out.append((ev, {k: v for k, v in g.items() if k != "hooks"}, h))
    return out
def merge(local, host):
    mine = owned(local)
    ours = set().union(*[names(h) for _, _, h in mine]) if mine else set()
    hooks = {}
    for ev, groups in (host.get("hooks") or {}).items():
        kept = []
        for g in groups:
            items = [h for h in g.get("hooks", []) if not (names(h) & ours)]
            if items:
                g2 = dict(g); g2["hooks"] = items; kept.append(g2)
        if kept:
            hooks[ev] = kept
    for ev, g, h in mine:
        g2 = dict(g); g2["hooks"] = [h]; hooks.setdefault(ev, []).append(g2)
    out = dict(host)
    if hooks: out["hooks"] = hooks
    else: out.pop("hooks", None)
    return out
def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "merge" and len(argv) == 3:
        sys.stdout.write(json.dumps(merge(load(argv[1]), load(argv[2], 5)), indent=2) + "\n"); return 0
    if cmd == "same-merge" and len(argv) == 3:
        L, H = load(argv[1]), load(argv[2], 5)
        return 0 if json.dumps(merge(L, H), sort_keys=True) == json.dumps(H, sort_keys=True) else 1
    if cmd == "keysdiff" and len(argv) == 3:
        L, H = load(argv[1]), load(argv[2], 5)
        sys.stdout.write(", ".join(sorted(k for k in set(L) | set(H) if k != "hooks" and L.get(k) != H.get(k))) + "\n"); return 0
    if cmd == "owned-eq" and len(argv) == 3:  # rumo-owned hook items identical on both sides
        L, H = load(argv[1]), load(argv[2], 5)
        mine = owned(L)
        ours = set().union(*[names(h) for _, _, h in mine]) if mine else set()
        a = sorted(json.dumps([ev, g, h], sort_keys=True) for ev, g, h in mine)
        b = sorted(json.dumps([ev, g, h], sort_keys=True) for ev, g, h in owned(H) if names(h) & ours)
        return 0 if a == b else 1
    if cmd == "installed" and len(argv) == 2:
        d = load(argv[1]); v = ""
        try:
            v = d["plugins"]["rumo@rumo"][0]["version"]
        except (KeyError, IndexError, TypeError):
            pass
        sys.stdout.write("%s\n" % (v if isinstance(v, str) else "")); return 0
    if cmd == "pjversion" and len(argv) == 2:
        d = load(argv[1]); v = d.get("version", "") if isinstance(d, dict) else ""
        sys.stdout.write("%s\n" % (v if isinstance(v, str) else "")); return 0
    if cmd == "mkt-path" and len(argv) == 2:  # the rumo marketplace's directory path, or empty
        d = load(argv[1]); v = ""
        try:
            src = d["rumo"]["source"]
            if src.get("source") == "directory":
                v = src.get("path", "")
        except (KeyError, TypeError, AttributeError):
            pass
        sys.stdout.write("%s\n" % (v if isinstance(v, str) else "")); return 0
    if cmd == "orca-has" and len(argv) == 3:
        d = load(argv[1]); want = argv[2].rstrip("/")
        repos = d if isinstance(d, list) else ((d.get("result", d) or {}).get("repos", []) if isinstance(d, dict) else [])
        if not isinstance(repos, list):
            return 1
        return 0 if any(isinstance(r, dict) and str(r.get("path", "")).rstrip("/") == want for r in repos) else 1
    sys.stderr.write("py helper: bad usage: %s\n" % " ".join(argv)); return 2
sys.exit(main(sys.argv[1:]))
PY
)
py() { python3 -I -c "$PYHELP" "$@"; }

# Allowlist → denylist → sha256, sorted by path. Run from inside a root; identical on both sides.
# The last alternative drops any hidden file or directory component (.npmrc, .netrc, tool state such as
# .playwright-cli/). `secret` matches only as a *.json name, so hooks/secret-guard.py keeps syncing.
DENY_RE='(^|/)(\.env[^/]*|[^/]*\.env|\.credentials\.json|credentials[^/]*|[^/]*\.pem|[^/]*\.key|id_[^/]*|[^/]*\.bak[^/]*|__pycache__|[^/]*\.pyc|\.DS_Store|token[^/]*\.json|[^/]*secret[^/]*\.json|service-account[^/]*\.json)(/|$)|(^|/)\.[^/]+(/|$)'
MANIFEST='{ for f in CLAUDE.md STACK.md; do [ -f "$f" ] && echo "$f"; done; find hooks -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null; find skills -mindepth 1 -maxdepth 1 -type d ! -name ".*" ! -name synced 2>/dev/null | while IFS= read -r d; do find "$d" -type f; done; } | sed "s|^\./||" | grep -vE '"$(q "$DENY_RE")"' | sort | while IFS= read -r f; do shasum -a 256 "$f"; done; find skills -mindepth 1 -maxdepth 1 -type l ! -name ".*" ! -name synced 2>/dev/null | sort | while IFS= read -r d; do printf "LINK %s\t%s\n" "$d" "$(readlink "$d")"; done'

split_links() {  # split_links SIDE: $TMPD/SIDE.man keeps the hashed files, $TMPD/SIDE.links gets "skills/<name>\t<target>"
  grep '^LINK ' "$TMPD/$1.man" | sed 's/^LINK //' > "$TMPD/$1.links"
  grep -v '^LINK ' "$TMPD/$1.man" > "$TMPD/$1.man.f"; mv "$TMPD/$1.man.f" "$TMPD/$1.man"
}
bash -c "cd $(q "$LR") && $MANIFEST" > "$TMPD/local.man"; split_links local
fetch_host() {  # host manifest + host settings.json into $TMPD (read-only on the host). A failed read is
  # never taken for "absent" (an empty host settings.json would merge into a file without the host's keys).
  local rc
  rsh "cd $(q "$SYNC_HOST_ROOT") 2>/dev/null || exit 0; $MANIFEST" > "$TMPD/host.man" </dev/null; rc=$?
  [ $rc = 0 ] || { echo "ERROR    reading the file manifest from the host failed (rc $rc) — $1"; exit 1; }
  split_links host
  rsh "f=$(q "$SYNC_HOST_ROOT/settings.json"); if [ -e \"\$f\" ]; then cat \"\$f\"; fi" > "$TMPD/host-settings.json" </dev/null; rc=$?
  [ $rc = 0 ] || { echo "ERROR    reading settings.json from the host failed (rc $rc) — $1"; exit 1; }
}
fetch_host "nothing written"

# Join by path → "<path>\t<STATE>" lines in $TMPD/table (path order).
awk -v OFS='\t' '
  { h = substr($0, 1, 64); p = substr($0, 67); if (FILENAME == ARGV[1]) L[p] = h; else H[p] = h; P[p] = 1 }
  END { for (p in P) {
          if ((p in L) && (p in H)) s = (L[p] == H[p]) ? "SAME" : "CHANGED"
          else if (p in L) s = "NEW"
          else s = "HOST-ONLY"
          print p, s } }' "$TMPD/local.man" "$TMPD/host.man" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 > "$TMPD/table"
# A host skills/<name> that is a symlink while the local one is a real dir: CONFLICT, its files leave the
# table (so the copy list) — extracting through the host's link would write outside ~/.claude.
: > "$TMPD/conflicts"
while IFS="$(printf '\t')" read -r d t; do
  if awk -F '\t' -v d="$d/" 'index($1, d) == 1 { f = 1 } END { exit !f }' "$TMPD/table"; then
    echo "$d" >> "$TMPD/conflicts"
    awk -F '\t' -v d="$d/" 'index($1, d) != 1' "$TMPD/table" > "$TMPD/table.f"; mv "$TMPD/table.f" "$TMPD/table"
  fi
done < "$TMPD/host.links"

# preflight — one PASS/FAIL line per check; returns 1 when any FAIL. Reads only, writes nothing
# outside $TMPD (local or host).
preflight() {
  local pf=0 a b br lv hv bad x exp
  pass() { echo "PASS $1: $2"; }
  failc() { echo "FAIL $1: $2"; pf=1; }
  # 1. Claude Code version (never installed by this script)
  a=$(claude --version 2>/dev/null | awk '{print $1}')
  b=$(rsh "claude --version 2>/dev/null" | awk '{print $1}')
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass claude-code "$a"; else failc claude-code "local ${a:-none} host ${b:-none}"; fi
  # 2. installed rumo plugin version
  rsh "cat $(q "$SYNC_HOST_ROOT/plugins/installed_plugins.json") 2>/dev/null" > "$TMPD/host-installed.json"
  a=$(py installed "$LR/plugins/installed_plugins.json" 2>/dev/null)
  b=$(py installed "$TMPD/host-installed.json" 2>/dev/null)
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass rumo-installed "$a"; else failc rumo-installed "local ${a:-none} host ${b:-none}"; fi
  # 3. host rumo checkout: on master, same plugin.json version as the local checkout
  br=$(rsh "git -C $(q "$SYNC_HOST_RUMO") rev-parse --abbrev-ref HEAD 2>/dev/null")
  rsh "cat $(q "$SYNC_HOST_RUMO/.claude-plugin/plugin.json") 2>/dev/null" > "$TMPD/host-plugin.json"
  lv=$(py pjversion "$SYNC_LOCAL_RUMO/.claude-plugin/plugin.json" 2>/dev/null)
  hv=$(py pjversion "$TMPD/host-plugin.json" 2>/dev/null)
  if [ -z "$br" ]; then failc rumo-checkout "missing ($SYNC_HOST_RUMO)"
  else
    bad=""
    [ "$br" = master ] || bad="branch $br"
    if [ -z "$lv" ] || [ "$lv" != "$hv" ]; then bad="${bad:+$bad, }version local ${lv:-none} host ${hv:-none}"; fi
    if [ -z "$bad" ]; then pass rumo-checkout "master $hv"; else failc rumo-checkout "$bad"; fi
  fi
  # 4. every local hook present on the host with the same hash
  bad=""
  while IFS= read -r x; do
    grep -qxF "$x" "$TMPD/host.man" || bad="${bad:+$bad }${x:66}"
  done < <(grep -E '^[0-9a-f]{64}  hooks/' "$TMPD/local.man")
  if [ -z "$bad" ]; then pass hooks "$(grep -cE '^[0-9a-f]{64}  hooks/' "$TMPD/local.man" | tr -d ' ') files match"; else failc hooks "$bad"; fi
  # 4b. symlinked skills: files under the resolved target, local vs host (host missing = differ)
  if [ ! -s "$TMPD/local.links" ]; then pass linked-skills none
  else
    bad=""; n=0
    while IFS="$(printf '\t')" read -r x lv; do
      n=$((n + 1))
      a=$(cd "$LR/$x/" 2>/dev/null && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done)
      b=$(rsh "cd $(q "$SYNC_HOST_ROOT/$x/") 2>/dev/null && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 \"\$f\"; done" </dev/null)
      if [ -z "$b" ] || [ "$a" != "$b" ]; then bad="${bad:+$bad }${x#skills/}"; fi
    done < "$TMPD/local.links"
    if [ -z "$bad" ]; then pass linked-skills "$n match"; else failc linked-skills "$bad differ (update Orca on the host or copy by hand)"; fi
  fi
  # 5. settings.json rumo gate entries identical
  py owned-eq "$LR/settings.json" "$TMPD/host-settings.json" 2>/dev/null; x=$?
  case $x in
    0) pass settings-hooks "rumo hook entries match" ;;
    4) failc settings-hooks "settings.json on this machine is not valid JSON" ;;
    5) failc settings-hooks "settings.json on the host is not valid JSON" ;;
    *) failc settings-hooks "rumo hook entries differ" ;;
  esac
  # 6. gh login
  exp=${SYNC_GH_USER:-$(gh api user --jq .login 2>/dev/null)}
  b=$(rsh "gh api user --jq .login 2>/dev/null")
  if [ -n "$exp" ] && [ "$exp" = "$b" ]; then pass gh "$exp"; else failc gh "expected ${exp:-none} host ${b:-none}"; fi
  # 6b. git identity: commits on the host need user.name and user.email (global or system config)
  a=$(rsh "cd / && git config --get user.name 2>/dev/null"); b=$(rsh "cd / && git config --get user.email 2>/dev/null")
  if [ -n "$a" ] && [ -n "$b" ]; then pass git-identity "user.name and user.email set"
  else x=""; [ -n "$a" ] || x=user.name; [ -n "$b" ] || x="${x:+$x, }user.email"
    failc git-identity "$x unset on the host — the owner runs there: git config --global user.name \"<name>\"; git config --global user.email <email>"; fi
  # 7. runtimes
  for x in ${runtimes[@]+"${runtimes[@]}"}; do
    if rsh "command -v $(q "$x") >/dev/null"; then pass "runtime:$x" "found"; else failc "runtime:$x" "not on the host PATH"; fi
  done
  # 8. Orca repo registration (local orca CLI, host environment)
  if [ -n "$repo" ]; then
    if ! command -v orca >/dev/null 2>&1; then failc orca-repo "orca CLI not found"
    elif orca repo list --environment "$SYNC_ORCA_ENV" --json > "$TMPD/orca.json" 2>/dev/null && py orca-has "$TMPD/orca.json" "$repo" 2>/dev/null; then
      pass orca-repo "$repo"
    else failc orca-repo "$repo not registered in Orca env $SYNC_ORCA_ENV"; fi
  fi
  return $pf
}

if [ $preflight_only = 1 ]; then
  echo "sync-host $host — preflight"
  preflight; exit $?
fi

if [ $apply = 1 ]; then echo "sync-host $host — apply"; else echo "sync-host $host — dry run"; fi
printf '%-9s %s\n' STATE PATH
while IFS="$(printf '\t')" read -r p s; do printf '%-9s %s\n' "$s" "$p"; done < "$TMPD/table"
while IFS="$(printf '\t')" read -r p t; do printf '%-9s %s\n' UNSYNCED "$p (symlink → $t)"; done < "$TMPD/local.links"
while IFS= read -r p; do printf '%-9s %s\n' CONFLICT "$p (symlink on the host — not copied)"; done < "$TMPD/conflicts"

# settings.json: merged (rumo gate entries only), never copied whole; key names only, never values.
settings_state=SAME
if [ -f "$LR/settings.json" ]; then
  py same-merge "$LR/settings.json" "$TMPD/host-settings.json" 2>/dev/null; src=$?
  case $src in
    0) printf '%-9s %s\n' SAME settings.json ;;
    1) if grep -q '[^[:space:]]' "$TMPD/host-settings.json"; then
         settings_state=CHANGED; printf '%-9s %s\n' CHANGED 'settings.json (rumo hook entries; host-owned keys kept)'
       else settings_state=NEW; printf '%-9s %s\n' NEW 'settings.json (rumo hook entries)'; fi ;;
    4) echo "ERROR    settings.json on this machine is not valid JSON — fix it by hand"; exit 1 ;;
    5) echo "ERROR    settings.json on the host is not valid JSON — fix it by hand"; exit 1 ;;
    *) echo "ERROR    settings.json comparison failed (helper exit $src)"; exit 1 ;;
  esac
  kd=$(py keysdiff "$LR/settings.json" "$TMPD/host-settings.json" 2>/dev/null)
  [ -n "$kd" ] && echo "settings.json keys that differ and stay host-owned: $kd"
fi
if [ $apply = 0 ]; then
  echo "preflight (report only):"
  preflight
  echo "dry run — nothing written; re-run with --apply to write (backup first)"
  exit 0
fi

# --- apply. Order matters: nothing on the host is written before the backup succeeds.
# The local side is never written (only read-only local commands below).
R=$(q "$SYNC_HOST_RUMO")
stamp=$(date +%Y%m%d-%H%M%S)-$$
bname="claude-$stamp.tgz"
case "$SYNC_BACKUP_DIR" in
  /*) btarget=$(q "$SYNC_BACKUP_DIR/$bname") ;;
  *)  btarget="\$HOME/$(q "$SYNC_BACKUP_DIR/$bname")" ;;   # relative = host's home; $HOME expands on the host
esac
bshow="$SYNC_BACKUP_DIR/$bname"
restore="(restore: tar -C $SYNC_HOST_ROOT -xzf $bshow)"
# `|| exit 1` guards the setup: a failed mkdir/cd must fail the backup (not fall through to an
# empty `$#` and exit 0, nor tar from the wrong directory).
bout=$(rsh "{ mkdir -p $(q "$SYNC_BACKUP_DIR") && mkdir -p $(q "$SYNC_HOST_ROOT") && cd $(q "$SYNC_HOST_ROOT"); } || exit 1; set --; for p in hooks skills CLAUDE.md STACK.md settings.json plugins/installed_plugins.json plugins/known_marketplaces.json; do [ -e \"\$p\" ] && set -- \"\$@\" \"\$p\"; done; if [ \$# -eq 0 ]; then echo EMPTY; else COPYFILE_DISABLE=1 tar -czf $btarget \"\$@\"; fi")
if [ $? != 0 ]; then echo "backup failed — nothing written"; exit 1; fi
if [ "$bout" = EMPTY ]; then echo "backup: none needed (nothing to back up in $SYNC_HOST_ROOT)"; restore=""
else echo "backup: $bshow $restore"; fi

# Files: NEW and CHANGED rows only (never HOST-ONLY, never settings.json), deny re-checked.
awk -F '\t' '$2 == "NEW" || $2 == "CHANGED" { print $1 }' "$TMPD/table" > "$TMPD/copy.list"
if grep -qE "$DENY_RE" "$TMPD/copy.list"; then
  echo "ABORT    denylisted path in the copy list: $(grep -E "$DENY_RE" "$TMPD/copy.list" | tr '\n' ' ')$restore"; exit 1
fi
if [ -s "$TMPD/copy.list" ]; then
  if (cd "$LR" && COPYFILE_DISABLE=1 tar -cf - -T "$TMPD/copy.list") | rsh "cd $(q "$SYNC_HOST_ROOT") && tar -xpf -"; then
    echo "copied:  $(wc -l < "$TMPD/copy.list" | tr -d ' ') file(s)"
  else echo "ABORT    copying files failed $restore"; exit 1; fi
else echo "copied:  nothing (no NEW/CHANGED file)"; fi

# settings.json: merged result written through a temp file + mv.
if [ "$settings_state" = CHANGED ] || [ "$settings_state" = NEW ]; then
  if py merge "$LR/settings.json" "$TMPD/host-settings.json" > "$TMPD/merged.json" \
     && rsh "cat > $(q "$SYNC_HOST_ROOT/settings.json.sync-tmp") && mv $(q "$SYNC_HOST_ROOT/settings.json.sync-tmp") $(q "$SYNC_HOST_ROOT/settings.json")" < "$TMPD/merged.json"; then
    echo "merged:  settings.json (rumo hook entries)"
  else echo "ABORT    writing settings.json failed $restore"; exit 1; fi
fi

# Host rumo checkout on master (fast-forward only), or a fresh clone of the local checkout's origin.
if rsh "test -d $(q "$SYNC_HOST_RUMO/.git")"; then
  if rsh "git -C $R fetch -q origin && git -C $R checkout -q master && git -C $R merge -q --ff-only origin/master"; then
    echo "rumo:    $SYNC_HOST_RUMO fast-forwarded to origin/master"
  else echo "FAIL apply: rumo checkout"; fi
else
  url=$(git -C "$SYNC_LOCAL_RUMO" remote get-url origin 2>/dev/null)
  if [ -n "$url" ] && rsh "mkdir -p \"\$(dirname $R)\" && git clone -q $(q "$url") $R"; then
    echo "rumo:    cloned into $SYNC_HOST_RUMO"
  else echo "FAIL apply: rumo checkout"; fi
fi

# Plugin: the host's rumo marketplace must be the host checkout (a directory source).
rabs=$(rsh "cd $R 2>/dev/null && pwd -P")
rsh "cat $(q "$SYNC_HOST_ROOT/plugins/known_marketplaces.json") 2>/dev/null" > "$TMPD/host-mkt.json"
mpath=$(py mkt-path "$TMPD/host-mkt.json" 2>/dev/null)
if [ -z "$rabs" ]; then echo "FAIL apply: plugin (no host rumo checkout)"
elif [ "$mpath" != "$rabs" ]; then
  if rsh "claude plugin marketplace remove rumo >/dev/null 2>&1; claude plugin marketplace add $(q "$rabs") && claude plugin install rumo@rumo --scope user" >/dev/null; then
    echo "plugin:  marketplace rumo → $rabs, rumo@rumo installed"
  else echo "FAIL apply: plugin"; fi
else
  if rsh "claude plugin marketplace update rumo && claude plugin update rumo@rumo" >/dev/null; then
    echo "plugin:  rumo@rumo updated from $rabs"
  else echo "FAIL apply: plugin"; fi
fi

# Claude Code: never installed or upgraded here (owner's gate decision 2026-10-29).
a=$(claude --version 2>/dev/null | awk '{print $1}')
b=$(rsh "claude --version 2>/dev/null" | awk '{print $1}')
[ "$a" = "$b" ] || echo "NOTE claude-code differs: local ${a:-none} host ${b:-none} — upgrade the host by hand"

# Orca: register --repo in the host's environment when absent.
if [ -n "$repo" ]; then
  if command -v orca >/dev/null 2>&1 && orca repo list --environment "$SYNC_ORCA_ENV" --json > "$TMPD/orca.json" 2>/dev/null \
     && py orca-has "$TMPD/orca.json" "$repo" 2>/dev/null; then
    echo "orca:    $repo already registered"
  elif command -v orca >/dev/null 2>&1 && orca_repo_add "$SYNC_ORCA_ENV" "$repo"; then
    echo "orca:    registered $repo in env $SYNC_ORCA_ENV"
  else echo "FAIL apply: orca repo add"; fi
fi

fetch_host "preflight not run"
echo "preflight:"
preflight; exit $?
