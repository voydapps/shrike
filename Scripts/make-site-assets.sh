#!/bin/bash
# Builds the generated site assets (favicon, touch icon, OG image) from the icon SVGs.
# Run by hand when the icon changes.
set -euo pipefail
cd "$(dirname "$0")/.."
# The icon SVGs (and og-source.svg) live in Resources/Icon/.
I=Resources/Icon
A=Resources/Icon
O=site
T=$(mktemp -d)
trap '/bin/rm -rf "$T"' EXIT
/bin/cp -f $I/shrike-icon-small.svg $O/favicon.svg
for n in 16 32 48; do rsvg-convert -w $n $I/shrike-icon-small.svg -o "$T/f$n.png"; done
magick "$T/f16.png" "$T/f32.png" "$T/f48.png" $O/favicon.ico
# apple-touch-icon: full bleed square, iOS rounds it itself
sed -e 's/rx="185" ry="185"/rx="0" ry="0"/' \
    -e 's/viewBox="0 0 1024 1024" width="1024" height="1024"/viewBox="100 100 824 824" width="824" height="824"/' \
    $I/shrike-icon.svg > "$T/touch.svg"
rsvg-convert -w 180 "$T/touch.svg" -o $O/apple-touch-icon.png
# og.png (the icon PNG next to og-source.svg is rendered here)
rsvg-convert -w 360 $I/shrike-icon.svg -o $A/og-icon.png
rsvg-convert -w 1200 -h 630 $A/og-source.svg -o $O/og.png
if [ "$(stat -f %z $O/og.png)" -gt 122880 ]; then magick $O/og.png -strip $O/og.png; fi
echo OK
