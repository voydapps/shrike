#!/bin/bash
# Makes the website pictures from your local screenshot sources.
#
#   Scripts/make-screenshots.sh [name ...]
#
# Put each new capture in  site/screenshots/src/<name>.png  (a .jpg also works).
# That folder is git-ignored: sources are never committed. <name> is one of the
# names used in site/index.html (viewer, browser, fullscreen, edit,
# info-histogram, compare, batch, contact-sheet). Without arguments every file
# in src/ is processed.
#
# For each source the script writes the only two files git tracks:
#   site/screenshots/<name>.webp        the picture on the page (2400 px wide for
#                                       "viewer", 1400 px for the others; never enlarged)
#   site/screenshots/full/<name>.webp   the Enlarge version (up to 5120 px wide)
# Both are converted to sRGB, stripped of metadata, WebP quality 85.
#
# Afterwards: check the width/height attributes printed below against
# site/index.html, update site/screenshots/README.md (version, source commit,
# date, sample imagery credits), then run  bash Scripts/check-site.sh.
#
# Needs ImageMagick (`magick`) with WebP support:  brew install imagemagick
# SHRIKE_SHOTS_OUT overrides the output folder (used for tests).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v magick >/dev/null 2>&1 || { echo "error: magick (ImageMagick) not found; brew install imagemagick" >&2; exit 1; }

SRC="site/screenshots/src"
OUT="${SHRIKE_SHOTS_OUT:-site/screenshots}"
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
[ -d "$SRC" ] || { echo "error: $SRC does not exist; put the source PNGs there" >&2; exit 1; }
mkdir -p "$OUT/full"

if [ $# -gt 0 ]; then names=("$@"); else
  names=()
  for f in "$SRC"/*.png "$SRC"/*.jpg "$SRC"/*.jpeg; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; names+=("${b%.*}")
  done
fi
[ ${#names[@]} -gt 0 ] || { echo "error: no sources in $SRC" >&2; exit 1; }

for name in "${names[@]}"; do
  in=""
  for ext in png jpg jpeg; do [ -f "$SRC/$name.$ext" ] && in="$SRC/$name.$ext" && break; done
  [ -n "$in" ] || { echo "error: no source for '$name' in $SRC" >&2; exit 1; }
  w=1400; [ "$name" = "viewer" ] && w=2400
  prof=(); [ -f "$SRGB" ] && prof=(-profile "$SRGB")
  magick "$in" -auto-orient ${prof[@]+"${prof[@]}"} -strip -resize "${w}x>" -quality 85 "$OUT/$name.webp"
  magick "$in" -auto-orient ${prof[@]+"${prof[@]}"} -strip -resize "5120x>" -quality 85 "$OUT/full/$name.webp"
  echo "$name: page $(magick identify -format '%wx%h' "$OUT/$name.webp") $(stat -f %z "$OUT/$name.webp") bytes; full $(magick identify -format '%wx%h' "$OUT/full/$name.webp") $(stat -f %z "$OUT/full/$name.webp") bytes"
done
echo "done. Now check width/height in site/index.html, update site/screenshots/README.md, run: bash Scripts/check-site.sh"
