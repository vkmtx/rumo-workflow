#!/usr/bin/env bash
# visual-lint.sh - mechanical visual checks (Playwright, 390 touch + 1440) to run before the visual-judge.
#
# Usage: visual-lint.sh [--project <dir>] [--scheme light|dark|both] [--shots <dir>] [--name <slug>] <url>
#   --project defaults to $PWD; its own Playwright is used first, else a pinned fallback via npm exec.
#   --scheme  colour scheme the checks run under (default light); "both" adds the labels 390-dark and 1440-dark.
#   --shots   after each viewport's checks, save a full-page PNG <dir>/<name>-<viewport label>.png (fonts loaded,
#             animations off, width asserted) and print "SHOT <abs path>"; --name defaults to a slug of the URL path.
#   Prints "FAIL <rule> @<viewport> <element> — <detail>" lines, then a summary line, all on stdout.
#
# Exit codes:
#   0  clean
#   1  violations found
#   2  usage error, page not loadable, no node, or no usable Playwright
set -uo pipefail

USAGE='usage: visual-lint.sh [--project <dir>] [--scheme light|dark|both] [--shots <dir>] [--name <slug>] <url>'
PROJECT="$PWD"; URL=""; N=0; SCHEME=light; SHOTS=""; NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
    --scheme) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; SCHEME="$2"; shift 2 ;;
    --shots) [ $# -ge 2 ] && [ -n "$2" ] || { echo "$USAGE" >&2; exit 2; }; SHOTS="$2"; shift 2 ;;
    --name) [ $# -ge 2 ] && [ -n "$2" ] || { echo "$USAGE" >&2; exit 2; }; NAME="$2"; shift 2 ;;
    -*) echo "$USAGE" >&2; exit 2 ;;
    *) URL="$1"; N=$((N+1)); shift ;;
  esac
done
{ [ "$N" -eq 1 ] && [ -d "$PROJECT" ]; } || { echo "$USAGE" >&2; exit 2; }
case "$SCHEME" in light|dark|both) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
case "$NAME" in *[!A-Za-z0-9._-]*|[._-]*) echo "$USAGE" >&2; exit 2 ;; esac
case "$SHOTS" in ""|/*) ;; *) SHOTS="$PWD/$SHOTS" ;; esac
PROJECT="$(cd "$PROJECT" && pwd)"
OPTS=(--scheme "$SCHEME")
[ -n "$SHOTS" ] && OPTS+=(--shots "$SHOTS")
[ -n "$NAME" ] && OPTS+=(--name "$NAME")

HERE="$(cd "$(dirname "$0")" && pwd)"
PIN=1.64.1   # fallback Playwright; its chromium-1248 must be installed (bump both together)
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

env_error() { echo "visual-lint: env: no usable Playwright (tried $PROJECT and playwright@$PIN) — install its browser once: npx --yes playwright@$PIN install chromium" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "visual-lint: env: node not found in PATH" >&2; exit 2; }

# visual-lint.mjs exits 3 when it cannot load Playwright or launch chromium from --pw-from: retry with the pinned fallback
node "$HERE/visual-lint.mjs" --pw-from "$PROJECT" "${OPTS[@]}" "$URL" 2>"$ERR"
rc=$?
if [ "$rc" -ne 3 ]; then cat "$ERR" >&2; exit "$rc"; fi

command -v npm >/dev/null 2>&1 || env_error
# the +10 tells visual-lint.mjs's own exit (10/11/12 = 0/1/2) apart from a failure of npm exec itself (anything else -> env_error)
VL_MJS="$HERE/visual-lint.mjs" VL_URL="$URL" VL_SCHEME="$SCHEME" VL_SHOTS="$SHOTS" VL_NAME="$NAME" npm exec --yes --loglevel=error --package="playwright@$PIN" -c 'node "$VL_MJS" --pw-from "$(dirname "$(printf %s "$PATH" | tr : "\n" | grep -m1 "/_npx/.*/node_modules/.bin$")")" --scheme "$VL_SCHEME" ${VL_SHOTS:+--shots "$VL_SHOTS"} ${VL_NAME:+--name "$VL_NAME"} "$VL_URL"; exit $(( $? + 10 ))'
rc=$?
case "$rc" in
  10) exit 0 ;;
  11) exit 1 ;;
  12) exit 2 ;;
  *) env_error ;;
esac
