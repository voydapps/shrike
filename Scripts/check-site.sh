#!/bin/bash
# Checks the website in site/ before it is published. Bash only, no dependencies.
# Runs in CI (.github/workflows/pages.yml) and by hand.
set -u
cd "$(dirname "$0")/.."
fail=0
bad() { echo "FAIL: $1"; fail=1; }

for f in index.html style.css site.js 404.html robots.txt sitemap.xml .nojekyll favicon.svg favicon.ico \
         apple-touch-icon.png og.png img/shot-viewer.webp img/shot-fullscreen.webp \
         img/shot-browser.webp img/shot-edit.webp; do
  [ -f "site/$f" ] || bad "missing site/$f"
done

# The page has no version, hash or size that changes per release, so there is nothing to fill in.
# The download button points at the fixed asset name the release workflow publishes.
grep -q 'releases/latest/download/Shrike.dmg' site/index.html || bad "download link to Shrike.dmg missing in index.html"
grep -n 'PLACEHOLDER' site/*.html && bad "placeholder text left in site/*.html"

# Local files: every relative href/src in index.html must exist.
for ref in $(grep -oE '(href|src)="[^"#:]+"' site/index.html | sed -E 's/^[a-z]+="//; s/"$//' | sort -u); do
  [ -e "site/$ref" ] || bad "index.html points to missing file: $ref"
done

# 404.html is served at any depth, so it uses /shrike/ paths. No other root paths are allowed.
grep -nE '(href|src)="/' site/index.html && bad "root-absolute path in site/index.html"
grep -nE '(href|src)="/' site/404.html | grep -v '"/shrike/' && bad "root-absolute path other than /shrike/ in site/404.html"
# The sitemap namespace is a fixed identifier, not a link.
grep -n 'http://' site/*.html site/robots.txt site/site.js site/style.css && bad "http:// URL in site files"
grep -v 'xmlns=' site/sitemap.xml | grep -n 'http://' && bad "http:// URL in sitemap.xml"

# No third-party requests: every https:// link must stay on voydapps.github.io or github.com/voydapps.
# (Plain <a href> links to github.com/voydapps are navigation, not loads. Loads are src= / stylesheet / fonts.)
grep -nE '(src|srcset|data)="https?:' site/*.html && bad "external src in site/*.html"
grep -nE '<link[^>]+rel="(stylesheet|preload|preconnect|dns-prefetch)"[^>]+href="https?:' site/*.html && bad "external stylesheet or preload"
grep -nE 'url\(\s*["'"'"']?https?:|@import' site/style.css && bad "external url() or @import in style.css"
grep -nE 'fetch\(|XMLHttpRequest|sendBeacon|WebSocket|https?://' site/site.js && bad "network call or URL in site.js"
grep -oE 'https://[^"'"'"' <)]+' site/index.html | grep -vE '^https://(voydapps\.github\.io/shrike/|github\.com/voydapps(/|$))|^https://schema\.org' \
  && bad "link to a host other than voydapps.github.io/shrike or github.com/voydapps"
grep -n 'github.com/dm''voy''tyuk\|dm''voy''tyuk' site/* 2>/dev/null && bad "old owner-handle URL or name found"
grep -n 'Dmy''tro\|Voyt''yuk' site/*.html && bad "real name found on the site"

# Scripts: only the local site.js and the JSON-LD block.
grep -n '<script' site/index.html | grep -v 'type="application/ld+json"' | grep -v 'src="site.js" defer' && bad "script tag other than site.js and JSON-LD"
grep -n '<script' site/404.html && bad "script tag in 404.html"
grep -n 'Ar''gus' site/*.html site/*.js site/robots.txt site/sitemap.xml && bad "old app name found (rename leftover)"
grep -n 'is notarized' site/*.html && bad "phrase 'is notarized' found"
grep -n 'Voyd\|VOYD' site/*.html && bad "voyd must be written in lower case"
grep -n ' style="' site/*.html && bad "inline style attribute (blocked by the page's CSP)"

if [ "$fail" = 0 ]; then echo "site OK"; fi
exit "$fail"
