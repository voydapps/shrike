#!/bin/bash
# Installs the one XcodeGen version Shrike is built with, from the GitHub release,
# checked against a fixed SHA-256 (CI used to run `brew install xcodegen`, which
# serves whatever Homebrew has that day). This file is the single place that names
# the version: change XCODEGEN_VERSION and XCODEGEN_SHA256 together, and keep
# the Mac's `xcodegen --version` the same.
#
#   Scripts/install-xcodegen.sh <install-dir>     (adds <install-dir>/xcodegen/bin to $GITHUB_PATH on CI)
set -eu
XCODEGEN_VERSION="2.45.4"
XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

dest="${1:?usage: $0 <install-dir>}"
mkdir -p "$dest"
zip="$dest/xcodegen-$XCODEGEN_VERSION.zip"
curl -fsSL --retry 3 -o "$zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $zip" | shasum -a 256 -c -
unzip -q -o "$zip" -d "$dest"
bin="$dest/xcodegen/bin"
chmod +x "$bin/xcodegen"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >> "$GITHUB_PATH"; fi
PATH="$bin:$PATH" xcodegen --version
