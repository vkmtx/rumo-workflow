#!/usr/bin/env bash
# Tests for scripts/issue-trust.sh. A fake gh (ISSUE_TRUST_GH) serves canned answers; no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/issue-trust.sh"
FAILS=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

# Fake gh. Env: FAKE_GQL = JSON for the graphql call, FAKE_PERMS = "login:perm ..." (missing
# login -> 404 exit 1), FAKE_FAIL=1 -> every call fails. Logs argv to $ROOT/gh.log.
FAKE="$ROOT/gh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
[ "${FAKE_FAIL:-0}" = 1 ] && { echo "error connecting to api.github.com" >&2; exit 1; }
[ "$1" = api ] || exit 1
if [ "$2" = graphql ]; then printf '%s\n' "$FAKE_GQL"; exit 0; fi
case $2 in
  repos/*/collaborators/*/permission)
    login=${2#*/collaborators/}; login=${login%/permission}
    for kv in $FAKE_PERMS; do
      if [ "${kv%%:*}" = "$login" ]; then echo "${kv#*:}"; exit 0; fi
    done
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
exit 1
EOF
chmod +x "$FAKE"
export ISSUE_TRUST_GH="$FAKE" FAKE_LOG="$ROOT/gh.log"

gql() { # author, then editor logins ("null" = null editor)
  local a=$1; shift; local nodes="" e
  for e in "$@"; do
    [ -n "$nodes" ] && nodes="$nodes,"
    if [ "$e" = null ]; then nodes="$nodes{\"editor\":null}"; else nodes="$nodes{\"editor\":{\"login\":\"$e\"}}"; fi
  done
  printf '{"data":{"repository":{"issue":{"author":{"login":"%s"},"userContentEdits":{"nodes":[%s]}}}}}' "$a" "$nodes"
}
run() { : > "$FAKE_LOG"; out=$("$SCRIPT" "$@" 2>&1); rc=$?; }

# 1 owner author, no edits
FAKE_GQL=$(gql alice) FAKE_PERMS="alice:admin" run acme/widget 7
ok=0; [ $rc -eq 0 ] && has "$out" "trusted: alice" || ok=1
check "1 admin author, no edits -> 0" $ok

# 2 author with read permission
FAKE_GQL=$(gql bob) FAKE_PERMS="bob:read" run acme/widget 7
ok=0; [ $rc -eq 1 ] && has "$out" "untrusted: bob (read)" || ok=1
check "2 read-only author -> 1" $ok

# 3 edit by a non-collaborator
FAKE_GQL=$(gql alice alice mallory) FAKE_PERMS="alice:admin" run acme/widget 7
ok=0; [ $rc -eq 1 ] && has "$out" "untrusted: mallory" || ok=1
check "3 edit by non-collaborator -> 1" $ok

# 4 null editor
FAKE_GQL=$(gql alice null) FAKE_PERMS="alice:admin" run acme/widget 7
ok=0; [ $rc -eq 1 ] && has "$out" "untrusted:" || ok=1
check "4 null editor -> 1" $ok

# 5 gh failing
FAKE_FAIL=1 FAKE_GQL=x run acme/widget 7
ok=0; [ $rc -eq 2 ] && has "$out" "cannot verify (gh failed)" || ok=1
check "5 gh failure -> 2" $ok

# 6 write + maintain editors trusted, distinct logins queried once each
FAKE_GQL=$(gql alice carol dave carol) FAKE_PERMS="alice:admin carol:write dave:maintain" run acme/widget 7
n=$(grep -c '/collaborators/carol/permission' "$FAKE_LOG")
ok=0; [ $rc -eq 0 ] && has "$out" "trusted: alice carol dave" && [ "$n" -eq 1 ] || ok=1
check "6 write/maintain editors trusted, deduped" $ok

# 7 bot author and ghost / null author untrusted
FAKE_GQL=$(gql 'dependabot[bot]') FAKE_PERMS="dependabot[bot]:write" run acme/widget 7
r1=$rc
FAKE_GQL=$(gql ghost) FAKE_PERMS="ghost:write" run acme/widget 7
r2=$rc
FAKE_GQL='{"data":{"repository":{"issue":{"author":null,"userContentEdits":{"nodes":[]}}}}}' FAKE_PERMS="" run acme/widget 7
r3=$rc
ok=0; [ $r1 -eq 1 ] && [ $r2 -eq 1 ] && [ $r3 -eq 1 ] || ok=1
check "7 bot / ghost / null author -> 1" $ok

# 8 graphql answer without the issue (not found) -> 2
FAKE_GQL='{"data":{"repository":null},"errors":[{"message":"not found"}]}' run acme/widget 7
ok=0; [ $rc -eq 2 ] || ok=1
check "8 missing issue -> 2" $ok

# 8b data plus GraphQL errors (partial answer) -> 2, never trusted
FAKE_GQL='{"data":{"repository":{"issue":{"author":{"__typename":"User","login":"vkmtx"},"userContentEdits":null}}},"errors":[{"message":"x","path":["repository","issue","userContentEdits"]}]}' FAKE_PERMS="vkmtx=admin" run acme/widget 7
ok=0; [ $rc -eq 2 ] || ok=1
check "8b partial answer with errors -> 2" $ok

# 9 usage errors -> 2
run; r1=$rc
run acme 7; r2=$rc
run acme/widget seven; r3=$rc
ok=0; [ $r1 -eq 2 ] && [ $r2 -eq 2 ] && [ $r3 -eq 2 ] || ok=1
check "9 usage errors -> 2" $ok

echo
if [ $FAILS -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
