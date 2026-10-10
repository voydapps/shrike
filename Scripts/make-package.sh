#!/usr/bin/env bash
#
# make-package.sh — build the downloadable Shrike DMG for the website.
#
# Usage:
#     Scripts/make-package.sh [<version>] [--zip] [--force]
#
#     <version>  Optional check: must equal MARKETING_VERSION in project.yml.
#     --zip      Also write Shrike-<version>.zip (made with ditto, keeps the
#                signature intact).
#     --force    Overwrite an existing dist/Shrike-<version>.dmg.
#     --adhoc    Sign ad-hoc (no certificate). Use this for the PUBLIC download:
#                an Apple Development certificate puts the developer's real
#                name into the signature. Same as SHRIKE_SIGN_IDENTITY=adhoc.
#
# Environment:
#     SHRIKE_SIGN_IDENTITY       SHA-1 or name of a signing certificate, or
#                               "adhoc". Default: the first "Apple Development"
#                               certificate in the keychain, else ad-hoc.
#     SHRIKE_WORK_DIR            Build folder (default: build/package, git-ignored).
#     SHRIKE_DIST_DIR            Output folder (default: dist, git-ignored).
#     SHRIKE_ALLOW_NO_TIMESTAMP  Set to 1 to allow signing without a secure
#                               timestamp when offline (not recommended).
#
# It builds the last COMMIT, not the working tree: HEAD is exported with
# `git archive` into the work dir. Uncommitted changes never end up in a
# download, and every DMG maps to exactly one commit.
#
# Output: dist/Shrike-<version>.dmg (+ .sha256): the signed universal app,
# an "Applications" shortcut and "How to open Shrike.txt"
# (Scripts/dmg/How to open Shrike.txt). Not notarized:

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WANT_VERSION="" MAKE_ZIP=0 FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip)   MAKE_ZIP=1 ;;
        --force) FORCE=1 ;;
        --adhoc) export SHRIKE_SIGN_IDENTITY=adhoc ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *)  [[ -z "$WANT_VERSION" ]] || die "only one version argument"; WANT_VERSION="$1" ;;
    esac
    shift
done

require_tools
command -v hdiutil >/dev/null || die "hdiutil not found"
command -v shasum  >/dev/null || die "shasum not found"

WORK="${SHRIKE_WORK_DIR:-$REPO_ROOT/build/package}"
DIST="${SHRIKE_DIST_DIR:-$REPO_ROOT/dist}"
mkdir -p "$WORK" "$DIST"
WORK="$(cd "$WORK" && pwd -P)"
DIST="$(cd "$DIST" && pwd -P)"
SRC="$WORK/src"
ROOT="$WORK/dmg-root"
MNT="$WORK/mnt"
TXT_TEMPLATE="$REPO_ROOT/Scripts/dmg/How to open Shrike.txt"
[[ -f "$TXT_TEMPLATE" ]] || die "missing $TXT_TEMPLATE"

COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
BUILD="$(build_number)"

# 1. Export HEAD ---------------------------------------------------------------
step "export HEAD ($COMMIT) to $SRC"
[[ -e "$SRC" ]] && safe_rm "$SRC" "$WORK"
mkdir -p "$SRC"
git -C "$REPO_ROOT" archive --format=tar HEAD | tar -x -C "$SRC"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    info "note: the working tree has uncommitted changes; they are NOT in this package"
fi

VERSION="$(marketing_version "$SRC/project.yml")"
[[ -n "$VERSION" ]] || die "MARKETING_VERSION not found in project.yml"
if [[ -n "$WANT_VERSION" && "$WANT_VERSION" != "$VERSION" ]]; then
    die "version mismatch: asked for $WANT_VERSION, project.yml (HEAD) has MARKETING_VERSION $VERSION. Bump it and commit first."
fi
NAME="Shrike-$VERSION"
DMG="$DIST/$NAME.dmg"
if [[ -e "$DMG" && $FORCE -ne 1 ]]; then
    die "$DMG already exists. Use --force to overwrite it, or bump MARKETING_VERSION."
fi

pick_identity
step "Shrike $VERSION (build $BUILD, commit $COMMIT)"
info "signing: $SIGN_DESC"
info "output:  $DMG"

# 2. Build + sign + verify -----------------------------------------------------
build_archive "$SRC" "$WORK" "$BUILD" strict

step "stage the disk image contents"
[[ -e "$ROOT" ]] && safe_rm "$ROOT" "$WORK"
mkdir -p "$ROOT"
ditto "$(archived_app "$WORK")" "$ROOT/Shrike.app"
sign_app "$ROOT/Shrike.app" strict
verify_app "$ROOT/Shrike.app"
[[ "$(app_version "$ROOT/Shrike.app")" == "$VERSION" ]] || die "app version $(app_version "$ROOT/Shrike.app") != $VERSION"
[[ "$(app_build "$ROOT/Shrike.app")" == "$BUILD" ]] || die "app build $(app_build "$ROOT/Shrike.app") != $BUILD"
ln -s /Applications "$ROOT/Applications"
sed "s/@VERSION@/$VERSION/g" "$TXT_TEMPLATE" > "$ROOT/How to open Shrike.txt"
ok "Shrike.app, Applications shortcut, How to open Shrike.txt"
# Nothing may touch $ROOT/Shrike.app after this point (a changed bundle
# = "Shrike is damaged" for the downloader).

# 3. Disk image ----------------------------------------------------------------
step "hdiutil create (compressed, read-only)"
TMP_DMG="$WORK/$NAME.dmg"
[[ -e "$TMP_DMG" ]] && safe_rm "$TMP_DMG" "$WORK"
hdiutil create -quiet -volname "Shrike $VERSION" -srcfolder "$ROOT" \
    -format ULMO -ov "$TMP_DMG" || die "hdiutil create failed"
hdiutil verify -quiet "$TMP_DMG" || die "hdiutil verify failed"
ok "$(du -h "$TMP_DMG" | cut -f1 | tr -d ' ') image, checksum verified"

# 4. Mount (hidden from Finder) and check what a downloader gets ---------------
step "check the mounted image"
[[ -e "$MNT" ]] && { hdiutil detach -quiet "$MNT" 2>/dev/null || true; safe_rm "$MNT" "$WORK"; }
mkdir -p "$MNT"
detach_mnt() { hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; }
trap detach_mnt EXIT
hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MNT" "$TMP_DMG" \
    || die "hdiutil attach failed"
verify_app "$MNT/Shrike.app"
[[ "$(readlink "$MNT/Applications")" == "/Applications" ]] || die "Applications shortcut missing"
[[ -f "$MNT/How to open Shrike.txt" ]] || die "How to open Shrike.txt missing"
ok "Applications shortcut + How to open Shrike.txt present"
# Gatekeeper's verdict, as a query only (nothing is opened, no dialog).
# "rejected" is expected: the app is not notarized, so a downloader has to
# approve it once (see "How to open Shrike.txt"). A signature problem would
# show up here as "invalid" / "damaged"-class errors instead.
GK="$(spctl --assess --type execute -vv "$MNT/Shrike.app" 2>&1 || true)"
info "Gatekeeper (spctl --assess, informational): $(printf '%s' "$GK" | sed -n 's/^.*: //p' | head -1)"
printf '%s\n' "$GK" | sed -En 's/^(source|origin)=/    \1=/p'
unregister_app "$MNT/Shrike.app"
detach_mnt
trap - EXIT
rmdir "$MNT" 2>/dev/null || true

# 5. Publish to dist/ ----------------------------------------------------------
step "write $DIST"
mv -f "$TMP_DMG" "$DMG"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
# A zip from an earlier run would no longer match this DMG: always drop it.
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
if [[ $MAKE_ZIP -eq 1 ]]; then
    ditto -c -k --keepParent "$ROOT/Shrike.app" "$DIST/$NAME.zip"
    (cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
fi
unregister_app "$ROOT/Shrike.app"

step "done"
info "$DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
info "sha256: $(cut -d' ' -f1 "$DMG.sha256")"
[[ $MAKE_ZIP -eq 1 ]] && info "$DIST/$NAME.zip  ($(du -h "$DIST/$NAME.zip" | cut -f1 | tr -d ' '))"
info "Shrike $VERSION, build $BUILD, commit $COMMIT"
info "signed: $SIGN_DESC (not notarized)"
info "Install steps for users: README.md and the text file inside the DMG."
