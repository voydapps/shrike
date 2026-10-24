#!/bin/bash
# Checks the website in site/ before it is published. Bash, plus node for the changelog page check.
# Runs in CI (ci.yml and pages.yml) and by hand.
set -u
cd "$(dirname "$0")/.."
fail=0
bad() { echo "FAIL: $1"; fail=1; }

for f in index.html changelog.html style.css site.js 404.html robots.txt sitemap.xml .nojekyll favicon.svg favicon.ico \
         apple-touch-icon.png og.png screenshots/viewer.webp screenshots/viewer.png screenshots/full/viewer.png screenshots/info-histogram.webp screenshots/info-histogram.png screenshots/full/info-histogram.png \
         screenshots/browser.webp screenshots/browser.png screenshots/full/browser.png screenshots/edit.webp screenshots/edit.png screenshots/full/edit.png \
         screenshots/fullscreen.webp screenshots/fullscreen.png screenshots/full/fullscreen.png screenshots/compare.webp screenshots/compare.png screenshots/full/compare.png \
         screenshots/batch.webp screenshots/batch.png screenshots/full/batch.png screenshots/contact-sheet.webp screenshots/contact-sheet.png screenshots/full/contact-sheet.png; do
  [ -f "site/$f" ] || bad "missing site/$f"
done

# Keep current-version labels and download claims aligned with the verified public release.
# The download button uses the fixed asset name; update availability copy only after publication.
grep -q 'releases/latest/download/Shrike.dmg' site/index.html || bad "download link to Shrike.dmg missing in index.html"
grep -n 'PLACEHOLDER' site/*.html && bad "placeholder text left in site/*.html"

# Local files: every relative href/src in index.html and changelog.html must exist.
for ref in $(grep -ohE '(href|src)="[^"#:]+"' site/index.html site/changelog.html | sed -E 's/^[a-z]+="//; s/"$//' | sort -u); do
  [ -e "site/$ref" ] || bad "a page points to missing file: $ref"
done

# 404.html is served at any depth, so it uses /shrike/ paths. No other root paths are allowed.
grep -nE '(href|src)="/' site/index.html site/changelog.html && bad "root-absolute path in index.html or changelog.html"
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
grep -ohE 'https://[^"'"'"' <)]+' site/index.html site/changelog.html | grep -vE '^https://(voydapps\.github\.io/shrike/|github\.com/voydapps(/|$))|^https://schema\.org' \
  && bad "link to a host other than voydapps.github.io/shrike or github.com/voydapps"
grep -n 'github.com/dm''voy''tyuk\|dm''voy''tyuk' site/* 2>/dev/null && bad "old owner-handle URL or name found"
grep -n 'Dmy''tro\|Voyt''yuk' site/*.html && bad "real name found on the site"

# Scripts: only the local site.js and the JSON-LD block.
grep -n '<script' site/index.html site/changelog.html | grep -v 'type="application/ld+json"' | grep -v 'src="site.js" defer' && bad "script tag other than site.js and JSON-LD"
grep -n '<script' site/404.html && bad "script tag in 404.html"
grep -n 'Ar''gus' site/*.html site/*.js site/robots.txt site/sitemap.xml && bad "old app name found (rename leftover)"
grep -n 'is notarized' site/*.html && bad "phrase 'is notarized' found"
grep -n 'Voyd\|VOYD' site/*.html && bad "voyd must be written in lower case"
grep -n ' style="' site/*.html && bad "inline style attribute (blocked by the page's CSP)"

# The source candidate and generated changelog must agree. Download availability
# stays tied to the published asset and is checked separately above.
candidate_version=$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml)
[ -n "$candidate_version" ] || bad "source candidate version is missing"
grep -Fq "## $candidate_version - " CHANGELOG.md || bad "source candidate is missing from CHANGELOG.md"

# The changelog page is generated from CHANGELOG.md; it must match.
if command -v node >/dev/null 2>&1; then
  node Scripts/make-changelog-page.mjs --check || bad "site/changelog.html is out of date"
else
  bad "node is needed to check site/changelog.html"
fi

if [ "$fail" = 0 ]; then echo "site OK"; fi
exit "$fail"
