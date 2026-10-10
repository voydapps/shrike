#!/bin/bash
# Builds every PNG of AppIcon.appiconset from the two icon SVGs.
# Reads Resources/Icon/shrike-icon.svg (128 px and up) and
# shrike-icon-small.svg (16, 32, 64 px). Never changes the SVGs.
set -euo pipefail
cd "$(dirname "$0")/.."
A=Resources/Icon
OUT=App/Resources/Assets.xcassets/AppIcon.appiconset
T=$(mktemp -d)
trap '/bin/rm -rf "$T"' EXIT

# Shadowed 1024 master (shadow only for sizes >= 128).
rsvg-convert -w 1024 -h 1024 "$A/shrike-icon.svg" -o "$T/m.png"
magick "$T/m.png" \( +clone -background black -shadow 35x14+0+10 \) +swap \
  -background none -layers merge +repage -gravity center -extent 1024x1024 "$T/master.png"

big() { # name px
  if [ "$2" = 1024 ]; then /bin/cp -f "$T/master.png" "$OUT/$1"
  else magick "$T/master.png" -filter Lanczos -resize "${2}x${2}" "$OUT/$1"; fi
}
big icon_128x128.png 128
big icon_128x128@2x.png 256
big icon_256x256.png 256
big icon_256x256@2x.png 512
big icon_512x512.png 512
big icon_512x512@2x.png 1024

rsvg-convert -w 64 "$A/shrike-icon-small.svg" -o "$OUT/icon_32x32@2x.png"
rsvg-convert -w 16 "$A/shrike-icon-small.svg" -o "$OUT/icon_16x16.png"
rsvg-convert -w 32 "$A/shrike-icon-small.svg" -o "$OUT/icon_16x16@2x.png"
/bin/cp -f "$OUT/icon_16x16@2x.png" "$OUT/icon_32x32.png"

fail=0
check() { # name px
  f="$OUT/$1"
  if [ ! -f "$f" ]; then echo "missing $1"; fail=1; return; fi
  s=$(magick identify -format '%wx%h' "$f")
  c=$(magick identify -format '%[channels]' "$f")
  [ "$s" = "$2x$2" ] || { echo "$1 is $s, want $2x$2"; fail=1; }
  case "$c" in *a*) ;; *) echo "$1 has no alpha ($c)"; fail=1;; esac
}
check icon_16x16.png 16; check icon_16x16@2x.png 32
check icon_32x32.png 32; check icon_32x32@2x.png 64
check icon_128x128.png 128; check icon_128x128@2x.png 256
check icon_256x256.png 256; check icon_256x256@2x.png 512
check icon_512x512.png 512; check icon_512x512@2x.png 1024
[ "$fail" = 0 ] || exit 1
echo OK
