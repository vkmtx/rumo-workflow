#!/usr/bin/env bash
# Rebuild every image in docs/assets from these HTML sources.
# Needs a Chromium-family binary (CHROME=..., else google-chrome / chromium / Chrome.app) and pngquant.
set -euo pipefail
cd "$(dirname "$0")"
CHROME=${CHROME:-$(command -v google-chrome || command -v chromium || echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")}
OUT=..
shot() { # <html> <out> <w> <h> <scale> [query]
  local tmp; tmp=$(mktemp -t rumo-asset).png
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor="$5" --virtual-time-budget=6000 \
    --window-size="$3,$4" --screenshot="$tmp" "file://$PWD/$1${6:+?$6}" 2>/dev/null
  pngquant --quality=70-92 --speed 1 --strip --force --output "$OUT/$2" "$tmp"; rm -f "$tmp"; echo "$2"
}
shot banner.html banner-light.png 1600 560 2
shot banner.html banner-dark.png 1600 560 2 dark
shot social.html social-preview.png 1280 640 1
for spec in "workflow 860" "architecture 960" "agents 880" "review-gate 700" "learn-loop 640"; do
  set -- $spec
  shot "$1.html" "$1.png" 1600 "$2" 2
  shot "$1.html" "$1-dark.png" 1600 "$2" 2 dark
done
