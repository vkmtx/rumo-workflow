#!/usr/bin/env bash
# visual_lint_test.sh - visual-lint.sh: usage, no node, env preflight, and one case per rule (h-overflow, native-control, touch-target, sticky-header, clipped-text, contrast), --scheme, --shots, load errors.
# VISUAL_LINT_PROJECT=<dir with a usable Playwright> runs the browser cases on a machine where the pinned fallback is not installed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/visual-lint.sh"
FIX="$HERE/fixtures/visual-lint"
FAILS=0
ROOT="$(mktemp -d)"
SRV=""
trap 'rm -rf "$ROOT"; [ -n "$SRV" ] && kill "$SRV" 2>/dev/null' EXIT
check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
PROJ="${VISUAL_LINT_PROJECT:-$ROOT}"
run() { local f="$1"; shift; OUT=$(bash "$SCRIPT" --project "$PROJ" "$@" "file://$FIX/$f" 2>&1); RC=$?; }
count() { printf '%s\n' "$OUT" | grep -c -- "$1"; }

# (a) no args -> usage, exit 2
OUT=$(bash "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "usage:"; check "usage: no args exits 2 with usage" $?

# (a2) no node on PATH -> exit 2 with an env line
NB="$ROOT/nonode-bin"; mkdir "$NB"
for t in dirname mktemp cat rm; do ln -s "$(command -v "$t")" "$NB/$t"; done
OUT=$(PATH="$NB" "$BASH" "$SCRIPT" --project "$ROOT" "file://$FIX/clean.html" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "visual-lint: env: node not found"; check "no-node: exits 2 with visual-lint: env:" $?

# (a3) bad option values -> usage, exit 2
OUT=$(bash "$SCRIPT" --scheme sepia "file://$FIX/clean.html" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "usage:"; check "usage: --scheme sepia exits 2" $?
OUT=$(bash "$SCRIPT" --name ../x "file://$FIX/clean.html" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "usage:"; check "usage: --name with a slash exits 2" $?

# (b) clean page; no usable Playwright -> SKIP (only that case skips)
run clean.html
if [ "$RC" -eq 2 ] && has "$OUT" "visual-lint: env:"; then echo "SKIP: $OUT"; exit 77; fi
[ "$RC" -eq 0 ] && has "$OUT" "visual-lint: OK"; check "clean: rc 0 and OK" $?

# (d) overflow at 390 only
run overflow.html
[ "$RC" -eq 1 ] && has "$OUT" "FAIL h-overflow @390 div.wide" && ! has "$OUT" "h-overflow @1440"; check "overflow: h-overflow @390 only" $?

# (d2) body overflow-x: clip means the viewport cannot scroll sideways: no h-overflow
run clipped.html
! has "$OUT" "h-overflow"; check "clipped: no h-overflow when body clips x" $?

# (d3) clipped text: the ellipsis label and the line-clamped paragraph, at both viewports; the one with a matching title and the scroller are exempt
[ "$RC" -eq 1 ] && [ "$(count '^FAIL clipped-text @390 ')" = 2 ] && [ "$(count '^FAIL clipped-text @1440 ')" = 2 ] \
  && has "$OUT" 'FAIL clipped-text @390 p#ell.ell' && has "$OUT" 'FAIL clipped-text @1440 p#clamp.clamp' \
  && has "$OUT" '"Quarterly revenue by region and channel" scrollWidth' && ! has "$OUT" "p#titled" && ! has "$OUT" "div#scroller"; check "clipped: clipped-text for the ellipsis and the clamp only" $?

# (d3b) text cut inside display:contents or a float-only parent is clipped-text, not sr-only; a real sr-only span stays exempt (#110)
run clipped-wrap.html
[ "$RC" -eq 1 ] && [ "$(count '^FAIL clipped-text @390 ')" = 2 ] && [ "$(count '^FAIL clipped-text @1440 ')" = 2 ] \
  && has "$OUT" 'FAIL clipped-text @390 p#incontents' && has "$OUT" 'FAIL clipped-text @390 p#infloat' && ! has "$OUT" 'span#sr'; check "clipped-wrap: display:contents and float parent are clipped-text, sr-only exempt" $?

# (d4) contrast: grey on white (one line for the two elements sharing the pair) and the white-on-grey chip; the 3.2:1 large heading passes
run contrast.html
[ "$RC" -eq 1 ] && [ "$(count '^FAIL contrast @390 ')" = 2 ] && [ "$(count '^FAIL contrast @1440 ')" = 2 ] \
  && has "$OUT" 'FAIL contrast @390 p#muted "Muted helper text" — 2.81:1 < 4.5, #9a9a9a on #ffffff, 14px (2 elements)' \
  && has "$OUT" 'FAIL contrast @390 span#chip "New" — 1.11:1 < 4.5, #ffffff on #f2f2f2, 16px' \
  && ! has "$OUT" "h2#big" && ! has "$OUT" "p#dm" && ! has "$OUT" "-dark"; check "contrast: two pairs per viewport, large heading passes, light only by default" $?

# (d5) a dark-only failure shows only with the dark scheme; "both" labels the dark pass
run contrast.html --scheme both
[ "$RC" -eq 1 ] && has "$OUT" 'FAIL contrast @390-dark p#dm' && has "$OUT" 'FAIL contrast @1440-dark p#dm' \
  && [ "$(count '^FAIL contrast @390 ')" = 2 ] && [ "$(count '^FAIL contrast @390-dark ')" = 3 ] && ! has "$OUT" 'FAIL contrast @390 p#dm'; check "scheme both: dark-only contrast failure at @390-dark and @1440-dark" $?
run contrast.html --scheme dark
[ "$RC" -eq 1 ] && has "$OUT" 'FAIL contrast @390 p#dm' && ! has "$OUT" "-dark"; check "scheme dark: plain viewport labels" $?

# (e) native date input flagged
run date.html
[ "$RC" -eq 1 ] && has "$OUT" "FAIL native-control @390 input"; check "date: native-control @390 input" $?

# (e2) only a 100%-default control is native-control (a disabled one too); border/padding/background, base-select, a page stylesheet or a position-dependent rule (:last-child) count as styled
run native.html
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^FAIL native-control @390')" = 2 ] && has "$OUT" "FAIL native-control @390 select#plain" \
  && has "$OUT" "FAIL native-control @390 select#dis" && ! has "$OUT" "native-control @390 select#lastchild"; check "native: only the default select is native-control" $?

# (f) touch targets: only the 40px button (sr-only, inline link, labelled checkbox exempt)
run touch.html
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^FAIL touch-target @390')" = 1 ] \
  && has "$OUT" 'FAIL touch-target @390 button "Go" — 40x40px' && ! has "$OUT" "touch-target @1440"; check "touch: exactly one touch-target, the 40px button" $?

# (g) issue's bad fixture: translucent sticky header covering text, plus a small button
run bad.html
[ "$RC" -eq 1 ] && has "$OUT" "FAIL sticky-header @390 header" && has "$OUT" "translucent" \
  && has "$OUT" "covers p" && has "$OUT" "FAIL touch-target @390 button"; check "bad: sticky-header (translucent, covers) and touch-target" $?

# (h) its fix passes
run good.html
[ "$RC" -eq 0 ] && has "$OUT" "visual-lint: OK"; check "good: rc 0 and OK" $?

# (h2) --shots writes one full-page PNG per viewport into a dir it creates, and prints its absolute path
SH="$ROOT/shots/deep"
run good.html --shots "$SH" --name home
[ "$RC" -eq 0 ] && [ "$(count '^SHOT ')" = 2 ] && has "$OUT" "SHOT $SH/home-390.png" && has "$OUT" "SHOT $SH/home-1440.png" \
  && [ -s "$SH/home-390.png" ] && [ -s "$SH/home-1440.png" ] && [ "$(head -c 4 "$SH/home-1440.png" | tail -c 3)" = PNG ]; check "shots: home-390.png and home-1440.png, two SHOT lines" $?
# default name = slug of the URL path; a failing page is shot too; "both" adds the dark files
run bad.html --shots "$SH" --scheme both
[ "$RC" -eq 1 ] && [ "$(count '^SHOT ')" = 4 ] && [ -s "$SH/bad-390.png" ] && [ -s "$SH/bad-1440-dark.png" ]; check "shots: failing page still shot, name from the URL, dark labels" $?
# no viewport meta: the 390 page lays out at 980, so the shot is not a 390 shot
printf '<!doctype html><title>t</title><p>No viewport meta</p>' > "$ROOT/nometa.html"
OUT=$(bash "$SCRIPT" --project "$PROJ" --shots "$SH" "file://$ROOT/nometa.html" 2>&1); RC=$?
[ "$RC" -eq 1 ] && has "$OUT" "FAIL shot-width @390 " && ! has "$OUT" "shot-width @1440"; check "shots: innerWidth != viewport width is FAIL shot-width" $?

# (i) sticky below the top at scroll 0 still gets the opacity check
run sticky-offset.html
[ "$RC" -eq 1 ] && has "$OUT" "sticky-header" && has "$OUT" "translucent"; check "sticky-offset: translucent sticky header with top:0 below a bar" $?

# (j) a nav row of inline links is not prose: every link is a touch target
run navrow.html
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^FAIL touch-target @390')" = 3 ]; check "navrow: exactly 3 touch-target lines" $?

# (j2) links separated only by punctuation are not prose; a digit in the parent text is
run navpunct.html
[ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^FAIL touch-target @390')" = 6 ] && ! has "$OUT" 'a "Page"'; check "navpunct: 6 touch-target lines, digit-prose link exempt" $?

# (i2) a transparent full-width sticky section title with top, far down the page, is checked as a header (owner, #55)
run sticky-title.html
[ "$RC" -eq 1 ] && has "$OUT" 'FAIL sticky-header @390 h2' && has "$OUT" 'FAIL sticky-header @1440 h2' && has "$OUT" "translucent"; check "sticky-title: sticky section title is a header" $?

# (k) HTTP error status -> cannot load, exit 2
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FIX" >/dev/null 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/clean.html" && break; sleep 0.3; done
OUT=$(bash "$SCRIPT" --project "$PROJ" "http://127.0.0.1:$PORT/does-not-exist.html" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "HTTP 404"; check "http-404: missing page exits 2 with HTTP 404" $?

# (l) a check that throws -> exit 2 with one line, not a stack and exit 1
OUT=$(bash "$SCRIPT" --project "$PROJ" 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "$OUT" "check failed"; check "thrown-check: exits 2 with 'check failed'" $?

if [ $FAILS -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
