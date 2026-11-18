#!/usr/bin/env bash
# Mandato + Relatório doc contract (#98): the terms are defined, build/wave name the Mandato file and
# its CLI, every RELATÓRIO: example in build.md parses, and the AUTHORIZED: fallback stays documented.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

CTX="$ROOT/CONTEXT.md"
BUILD="$ROOT/skills/rumo/references/build.md"
WAVE="$ROOT/skills/rumo/references/wave.md"
HELP="$ROOT/skills/rumo/references/help.md"
REL="$ROOT/skills/rumo/scripts/relatorio.py"

for term in '**Mandato**:' '**Relatório**:'; do
  if grep -qF -- "$term" "$CTX"; then ok "CONTEXT.md defines $term"; else bad "CONTEXT.md defines $term"; fi
done

for f in "$BUILD" "$WAVE"; do
  n=$(basename "$f")
  if grep -qF 'rumo-mandato.json' "$f"; then ok "$n names rumo-mandato.json"; else bad "$n names rumo-mandato.json"; fi
  if grep -qE 'mandato\.py (check|sign)' "$f"; then ok "$n names mandato.py check|sign"; else bad "$n names mandato.py check|sign"; fi
done

# wave.md documents the Mandato's fields in a ```json example block (spec#1).
wave_json=$(awk '/^```json[[:space:]]*$/{f=1; next} /^```/{f=0} f' "$WAVE")
for field in '"politica"' '"assinatura"' '"alcance"' '"forca"'; do
  if printf '%s\n' "$wave_json" | grep -qF -- "$field"; then ok "wave.md json block has $field"; else bad "wave.md json block has $field"; fi
done
if grep -qF 'mandato scope' "$BUILD"; then ok "build.md names the scope check (mandato scope)"; else bad "build.md names the scope check (mandato scope)"; fi

lines=$(grep '^RELATÓRIO: ' "$BUILD" || true)
if [ -z "$lines" ]; then bad "build.md has at least one 'RELATÓRIO: ' example line"; else
  while IFS= read -r l; do
    if printf '%s\n' "$l" | python3 -I "$REL" parse >/dev/null 2>&1; then ok "relatorio.py parses: $l"; else bad "relatorio.py parses: $l"; fi
  done <<< "$lines"
fi

if grep -F 'BLOCKED:' "$BUILD" | grep -qF '"estado":"blocked"'; then ok "build.md maps BLOCKED: to \"estado\":\"blocked\""; else bad "build.md maps BLOCKED: to \"estado\":\"blocked\""; fi

if grep -qF 'Mandato' "$HELP"; then ok "help.md mentions Mandato"; else bad "help.md mentions Mandato"; fi
if grep -qF 'RELATÓRIO:' "$HELP"; then ok "help.md mentions RELATÓRIO:"; else bad "help.md mentions RELATÓRIO:"; fi

for f in "$BUILD" "$WAVE" "$CTX"; do
  if grep -qF 'AUTHORIZED:' "$f"; then ok "$(basename "$f") keeps AUTHORIZED: (fallback)"; else bad "$(basename "$f") keeps AUTHORIZED: (fallback)"; fi
done

exit $fail
