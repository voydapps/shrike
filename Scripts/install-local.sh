#!/usr/bin/env bash
#
# install-local.sh — build Shrike (Release) and install it into /Applications.
#
# Usage:
#     Scripts/install-local.sh [--no-build] [--keep-old] [--no-prune] [--launch]
#
#     --no-build   Re-use the last archive in the work dir (skip xcodebuild).
#     --keep-old   Move the replaced Shrike.app to the Trash instead of deleting it.
#     --no-prune   Do not unregister stale Shrike builds from Launch Services.
#     --launch     Open the installed app when done.
#
# Environment:
#     SHRIKE_INSTALL_DIR     Destination folder (default: /Applications).
#     SHRIKE_SIGN_IDENTITY   SHA-1 or name of a signing certificate, or "adhoc".
#                           Default: the first "Apple Development" certificate
#                           in the keychain, else ad-hoc.
#     SHRIKE_WORK_DIR        Build folder (default: build/local, git-ignored).
#     SHRIKE_QUIT_MATCH_EXE  Test hook only: treat processes running this
#                           executable as "the running Shrike". Lets the quit
#                           step be tested with a plain program outside any
#                           .app bundle. Never point it at a real app.
#
# Steps: build a universal Release archive from the working tree (uncommitted
# changes included) -> sign (hardened runtime + timestamp) -> verify ->
# quit a running copy of the installed app -> swap the new app in (staged
# next to the old one, then renamed) -> register it with Launch Services and
# unregister stale DerivedData / scratch builds -> print version and build.
# Needs no sudo: /Applications is writable by admin users.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DO_BUILD=1 KEEP_OLD=0 PRUNE=1 LAUNCH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) DO_BUILD=0 ;;
        --keep-old) KEEP_OLD=1 ;;
        --no-prune) PRUNE=0 ;;
        --launch)   LAUNCH=1 ;;
        -h|--help)  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

require_tools

INSTALL_DIR="${SHRIKE_INSTALL_DIR:-/Applications}"
INSTALL_DIR="${INSTALL_DIR%/}"
[[ -n "$INSTALL_DIR" ]] || die "SHRIKE_INSTALL_DIR is empty"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
[[ -w "$INSTALL_DIR" ]] || die "$INSTALL_DIR is not writable by $(id -un)"
DEST="$INSTALL_DIR/Shrike.app"
DEST_EXE="$DEST/Contents/MacOS/Shrike"

WORK="${SHRIKE_WORK_DIR:-$REPO_ROOT/build/local}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
STAGE="$WORK/stage/Shrike.app"

pick_identity
BUILD="$(build_number)"

step "Shrike local install"
info "source:      $REPO_ROOT (working tree)"
info "destination: $DEST"
info "signing:     $SIGN_DESC"
info "work dir:    $WORK"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    info "note:        the working tree has uncommitted changes; they are included"
fi

# 1. Build ---------------------------------------------------------------------
if [[ $DO_BUILD -eq 1 ]]; then
    build_archive "$REPO_ROOT" "$WORK" "$BUILD"
else
    [[ -d "$(archived_app "$WORK")" ]] || die "--no-build: no archive in $WORK yet"
    step "re-using $(archived_app "$WORK")"
fi

# 2. Stage + sign + verify (nothing in the destination is touched yet) ---------
step "stage"
[[ -e "$WORK/stage" ]] && safe_rm "$WORK/stage" "$WORK"
mkdir -p "$WORK/stage"
ditto "$(archived_app "$WORK")" "$STAGE"
sign_app "$STAGE"
verify_app "$STAGE"
VERSION="$(app_version "$STAGE")"
BUILT="$(app_build "$STAGE")"

# 3. Quit the installed copy if it is running ----------------------------------
# Only processes whose executable is exactly $DEST_EXE; DerivedData or other
# test copies keep running. SIGTERM is the same "sudden termination" macOS
# itself uses (Info.plist: NSSupportsSuddenTermination), and it needs no
# Automation permission (osascript "quit" would pop a privacy prompt).
MATCH_EXE="${SHRIKE_QUIT_MATCH_EXE:-$DEST_EXE}"
running_pids() {
    local pid comm
    ps -axo pid=,comm= | while read -r pid comm; do
        [[ "$comm" == "$MATCH_EXE" ]] && printf '%s\n' "$pid"
    done
    return 0
}
PIDS="$(running_pids)"
if [[ -n "$PIDS" ]]; then
    step "quitting the running Shrike (pid $(echo $PIDS))"
    kill -TERM $PIDS 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -z "$(running_pids)" ]] && break
        sleep 0.5
    done
    [[ -z "$(running_pids)" ]] || die "Shrike is still running from $DEST; quit it and run again"
    ok "quit"
fi

# 4. Swap: copy next to the destination, verify the copy, then rename ----------
step "install"
NEW="$INSTALL_DIR/.Shrike.app.new-$$"
OLD="$INSTALL_DIR/.Shrike.app.old-$$"
[[ -L "$DEST" ]] && die "$DEST is a symlink; refusing to replace it"

cleanup_swap() {
    # Runs on any exit. If the new app is not in place, put the old one back.
    if [[ ! -e "$DEST" && -d "$OLD" ]]; then
        mv "$OLD" "$DEST" && warn "install failed; the previous Shrike.app was restored"
    fi
    [[ -e "$NEW" ]] && safe_rm "$NEW" "$INSTALL_DIR"
    return 0
}
trap cleanup_swap EXIT

ditto "$STAGE" "$NEW"
codesign --verify --deep --strict "$NEW" >/dev/null 2>&1 || die "the copied app does not verify: $NEW"
if [[ -e "$DEST" ]]; then
    PREV="$(app_version "$DEST" 2>/dev/null || echo '?') ($(app_build "$DEST" 2>/dev/null || echo '?'))"
    mv "$DEST" "$OLD"
else
    PREV=""
fi
mv "$NEW" "$DEST"
ok "installed $DEST"

if [[ -d "$OLD" ]]; then
    if [[ $KEEP_OLD -eq 1 ]]; then
        TRASHED="$HOME/.Trash/Shrike $PREV $(date +%Y%m%d-%H%M%S).app"
        mv "$OLD" "$TRASHED" && info "previous version moved to the Trash: $(basename "$TRASHED")"
    else
        safe_rm "$OLD" "$INSTALL_DIR"
    fi
fi
trap - EXIT

# 5. Launch Services -----------------------------------------------------------
step "Launch Services"
"$LSREGISTER" -f "$DEST" || warn "lsregister -f failed"
ok "registered $DEST"
unregister_app "$STAGE"
if [[ $PRUNE -eq 1 ]]; then
    prune_stale_registrations "$DEST"
fi

# 6. Report --------------------------------------------------------------------
step "done"
info "Shrike $VERSION (build $BUILT)${PREV:+, replaced $PREV}"
info "path:     $DEST"
info "signed:   $SIGN_DESC"
info "size:     $(du -sh "$DEST" | cut -f1)"
info "Tip: to make Shrike the default viewer, select an image in Finder ->"
info "     File > Get Info > Open with: Shrike > Change All..."
if [[ $LAUNCH -eq 1 ]]; then
    open "$DEST"
fi
