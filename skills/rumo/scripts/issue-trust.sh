#!/usr/bin/env bash
# issue-trust.sh - decide whether an issue body was written only by people with write access,
# before issue-criteria.sh is allowed to run its [cmd] lines (--trusted).
#
# Usage: issue-trust.sh <owner/repo> <issue-number>
#   Reads the issue's author and every editor of its body (GraphQL userContentEdits), then
#   each distinct login's repo permission. Trusted = admin, maintain or write. Bots, ghost,
#   deleted (null) accounts and non-collaborators are untrusted. Calls gh (network); never
#   executes anything from the issue body. ISSUE_TRUST_GH overrides the gh binary (tests).
#
# Exit codes:
#   0  trusted: <logins>
#   1  untrusted: <login> (<permission or error>)   one line per untrusted account
#   2  usage error, or cannot verify (gh failed) - callers must treat 2 as untrusted
set -uo pipefail

GH=${ISSUE_TRUST_GH:-gh}

if [ $# -ne 2 ] || [[ ! $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ ! $2 =~ ^[0-9]+$ ]]; then
  echo "usage: issue-trust.sh <owner/repo> <issue-number>" >&2
  exit 2
fi
OWNER=${1%%/*}; NAME=${1#*/}; NUM=$2
command -v jq >/dev/null 2>&1 || { echo "cannot verify (jq not found)"; exit 2; }

Q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){author{__typename login} userContentEdits(first:100){totalCount nodes{editor{__typename login}}}}}}'
JSON=$("$GH" api graphql -f query="$Q" -F o="$OWNER" -F r="$NAME" -F n="$NUM" 2>/dev/null) \
  || { echo "cannot verify (gh failed)"; exit 2; }
if printf '%s' "$JSON" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
  echo "cannot verify (GraphQL errors)"; exit 2
fi

# One line per account, author first: "<typename>|<login>" ("-" for a null account).
ACCTS=$(printf '%s' "$JSON" | jq -r '
  .data.repository.issue as $i
  | if $i == null then error("no issue") else . end
  | if ($i.userContentEdits.totalCount // 0) > 100 then error("too many edits") else . end
  | ([$i.author] + [$i.userContentEdits.nodes[]?.editor])[]
  | if . == null then "-|-" else "\(.__typename // "")|\(.login // "-")" end' 2>/dev/null) \
  || { echo "cannot verify (gh failed)"; exit 2; }

SEEN=" "; TRUSTED=(); BAD=0
while IFS='|' read -r typ login; do
  key="$typ/$login"
  case $SEEN in *" $key "*) continue ;; esac
  SEEN="$SEEN$key "
  if [ "$login" = - ]; then echo "untrusted: (null) (deleted or unknown account)"; BAD=1; continue; fi
  if [ -n "$typ" ] && [ "$typ" != User ]; then echo "untrusted: $login ($typ)"; BAD=1; continue; fi
  if [ "$login" = ghost ] || [[ $login == *'[bot]' ]] || [[ ! $login =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "untrusted: $login (bot, ghost or invalid login)"; BAD=1; continue
  fi
  perm=$("$GH" api "repos/$OWNER/$NAME/collaborators/$login/permission" --jq .permission 2>&1); rc=$?
  perm=$(printf '%s' "$perm" | head -n 1)
  if [ $rc -ne 0 ]; then echo "untrusted: $login (${perm:-gh error})"; BAD=1; continue; fi
  case $perm in
    admin|maintain|write) TRUSTED+=("$login") ;;
    *) echo "untrusted: $login (${perm:-none})"; BAD=1 ;;
  esac
done <<< "$ACCTS"

[ $BAD -eq 0 ] || exit 1
echo "trusted: ${TRUSTED[*]}"
