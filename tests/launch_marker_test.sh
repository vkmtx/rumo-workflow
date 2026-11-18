#!/usr/bin/env bash
# Launch prompt contract (#97): wave.md stamps LAUNCHED-BY:, the markers are documented, and the
# two hooks share one rule (owner_message.py) with no second copy.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

WAVE="$ROOT/skills/rumo/references/wave.md"
CTX="$ROOT/CONTEXT.md"
PBG="$ROOT/scripts/hooks-staged/pr-base-guard.sh"
WTG="$ROOT/scripts/hooks-staged/worktree-guard.py"

n=$(grep -c 'LAUNCHED-BY: wave <name>' "$WAVE")
if [ "$n" -ge 2 ]; then ok "wave.md stamps 'LAUNCHED-BY: wave <name>' ($n lines)"; else bad "wave.md stamps 'LAUNCHED-BY: wave <name>' (found $n, need >= 2)"; fi

markers=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import owner_message as m; print("\n".join(m.LAUNCH_MARKERS))' "$ROOT/scripts/hooks-staged")
if [ -z "$markers" ]; then bad "LAUNCH_MARKERS readable from owner_message.py"; else ok "LAUNCH_MARKERS readable from owner_message.py"; fi
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if grep -qF -- "\`$m\`" "$WAVE"; then ok "wave.md documents \`$m\`"; else bad "wave.md documents \`$m\`"; fi
  if grep -qF -- "\`$m\`" "$CTX"; then ok "CONTEXT.md documents \`$m\`"; else bad "CONTEXT.md documents \`$m\`"; fi
done <<< "$markers"

# Every text the orchestrator types into a lane after launch carries the marker too.
sends=$(grep -n 'orca terminal send' "$WAVE" | grep -e '--text' || true)
if [ -z "$sends" ]; then bad "wave.md has a 'terminal send --text' example"; else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if printf '%s' "$line" | grep -q 'LAUNCHED-BY: wave'; then ok "terminal send carries LAUNCHED-BY (wave.md:${line%%:*})"; else bad "terminal send carries LAUNCHED-BY (wave.md:${line%%:*})"; fi
  done <<< "$sends"
fi

for f in "$PBG" "$WTG"; do
  if grep -q 'import owner_message' "$f"; then ok "$(basename "$f") imports owner_message"; else bad "$(basename "$f") imports owner_message"; fi
  if grep -qF "split('AUTHORIZED:'" "$f"; then bad "$(basename "$f") has no split('AUTHORIZED:' copy"; else ok "$(basename "$f") has no split('AUTHORIZED:' copy"; fi
  if grep -q '_owner_typed' "$f"; then bad "$(basename "$f") has no _owner_typed copy"; else ok "$(basename "$f") has no _owner_typed copy"; fi
done

exit $fail
