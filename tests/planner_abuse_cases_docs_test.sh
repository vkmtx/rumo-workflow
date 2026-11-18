#!/usr/bin/env bash
# Abuse-cases doc contract (#113, #115): planner, plan template and case map name the rule plan-check.sh
# enforces — a push/merge/deploy/delete/shell/hook step is Risk: security and lists hook:,
# third-party input:, check-to-use:, deletion: before happy: — and planner.md stays within budget.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
has() { if grep -qF -- "$2" "$1"; then ok "$(basename "$1") has '$2'"; else bad "$(basename "$1") has '$2'"; fi; }

PLANNER="$ROOT/agents/planner.md"
TEMPLATE="$ROOT/skills/rumo/references/plan-template.md"
HELP="$ROOT/skills/rumo/references/help.md"
CONTEXT="$ROOT/CONTEXT.md"
BUILD="$ROOT/skills/rumo/references/build.md"
LABELS=('hook:' 'third-party input:' 'check-to-use:' 'deletion:')

has "$PLANNER" 'Abuse cases first'
has "$PLANNER" 'Risk: security'
for l in "${LABELS[@]}"; do has "$PLANNER" "$l"; done

for l in "${LABELS[@]}"; do has "$TEMPLATE" "$l"; done
has "$TEMPLATE" 'happy:'

has "$HELP" 'abuse cases'
has "$HELP" 'Risk: security'

has "$CONTEXT" '**Abuse case**:'
has "$BUILD" 'Rule A ('
has "$BUILD" 'Rule B ('
has "$BUILD" 'each followed by a case or'

if python3 -I "$ROOT/skills/learn/scripts/learn.py" budget "$PLANNER" >/dev/null; then
  ok "planner.md within its byte budget"
else
  bad "planner.md within its byte budget"
fi

exit $fail
