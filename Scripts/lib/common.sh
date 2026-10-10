# shellcheck shell=bash
#
# Scripts/lib/common.sh — shared build / sign / verify steps for
# Scripts/install-local.sh and Scripts/make-package.sh.
#
# Sourced, not executed. Written for the stock macOS bash 3.2
# (no associative arrays, no mapfile, no empty-array expansion under set -u).
#
# Signing model:
#   * Xcode builds the Release archive WITHOUT signing (CODE_SIGNING_ALLOWED=NO).
#   * These scripts then sign once, explicitly: hardened runtime, secure
#     timestamp, App/Resources/Shrike.entitlements (so no get-task-allow).
#   * Identity: SHRIKE_SIGN_IDENTITY if set (SHA-1, a name fragment, or
#     "adhoc"), else the first valid "Apple Development" certificate in the
#     keychain, else ad-hoc with a warning. Ad-hoc keeps the scripts working
#     on a Mac without the certificate.

SHRIKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SHRIKE_LIB_DIR/../.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/App/Resources/Shrike.entitlements"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Filled by pick_identity.
SIGN_ID=""
SIGN_DESC=""

# ---------------------------------------------------------------------------
# Output helpers

if [[ -t 1 ]]; then
    _B=$'\033[1m'; _R=$'\033[31m'; _Y=$'\033[33m'; _G=$'\033[32m'; _N=$'\033[0m'
else
    _B=""; _R=""; _Y=""; _G=""; _N=""
fi

step() { printf '%s==> %s%s\n' "$_B" "$*" "$_N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s  %s\n' "$_G" "$_N" "$*"; }
warn() { printf '%swarning:%s %s\n' "$_Y" "$_N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_R" "$_N" "$*" >&2; exit 1; }

# rm -rf, but only for a path strictly inside the given parent directory.
safe_rm() {
    local path="$1" parent="$2"
    [[ -n "$path" && -n "$parent" && "$parent" != "/" ]] || die "safe_rm: bad arguments ($path, $parent)"
    case "$path" in
        "$parent"/?*) rm -rf "$path" ;;
        *) die "safe_rm: refusing to delete $path (not inside $parent)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Preflight

require_tools() {
    [[ "$(uname -s)" == "Darwin" ]] || die "these scripts run on macOS only"
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die "do not run as root (no sudo needed)"
    local t
    for t in xcodebuild xcodegen codesign ditto lipo plutil git; do
        if ! command -v "$t" >/dev/null 2>&1; then
            if [[ "$t" == xcodegen ]]; then
                die "xcodegen not found. Install it with: brew install xcodegen"
            fi
            die "$t not found (install Xcode and its command line tools)"
        fi
    done
}

# Build number = number of commits on HEAD. Always grows, so a newer
# install outranks older copies in Launch Services ("Open With").
build_number() {
    git -C "$REPO_ROOT" rev-list --count HEAD
}

# MARKETING_VERSION from a project.yml (first match).
marketing_version() {
    local yml="$1"
    sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*$/\1/p' "$yml" | head -1
}

# ---------------------------------------------------------------------------
# Signing identity

pick_identity() {
    local want="${SHRIKE_SIGN_IDENTITY:-}" line
    case "$want" in
        adhoc|-)
            SIGN_ID="-"; SIGN_DESC="ad-hoc (requested)"
            return ;;
        "")
            line="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development:' || true)"
            if [[ -z "$line" ]]; then
                SIGN_ID="-"; SIGN_DESC="ad-hoc (no Apple Development certificate found)"
                warn "no valid \"Apple Development\" certificate in the keychain; signing ad-hoc."
                warn "macOS will ask again for folder access (Desktop, Documents, ...) after every install."
                return
            fi ;;
        *)
            line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F -m1 -- "$want" || true)"
            [[ -n "$line" ]] || die "signing identity \"$want\" not found (security find-identity -v -p codesigning)"
            ;;
    esac
    SIGN_ID="$(printf '%s\n' "$line" | awk '{print $2}')"
    SIGN_DESC="$(printf '%s\n' "$line" | sed 's/^[^"]*"\(.*\)"[^"]*$/\1/')"
}

# ---------------------------------------------------------------------------
# Build

_package_pins() { plutil -extract pins json -o - "$1" 2>/dev/null || true; }

# Xcode resolves SwiftPM packages at the project level, in the generated
# (git-ignored) Shrike.xcodeproj. Seed that file from the committed
# Packages/ShrikeKit/Package.resolved so GRDB stays on the pinned version.
_seed_package_resolved() {
    local src="$1"
    local committed="$src/Packages/ShrikeKit/Package.resolved"
    local dir="$src/Shrike.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    [[ -f "$committed" ]] || { warn "no Packages/ShrikeKit/Package.resolved; dependency versions are not pinned"; return; }
    if [[ ! -f "$dir/Package.resolved" ]]; then
        mkdir -p "$dir"
        cp "$committed" "$dir/Package.resolved"
    fi
}

_check_package_pins() {
    local src="$1" strict="$2"
    local committed="$src/Packages/ShrikeKit/Package.resolved"
    local used="$src/Shrike.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    [[ -f "$committed" && -f "$used" ]] || return 0
    if [[ "$(_package_pins "$committed")" != "$(_package_pins "$used")" ]]; then
        if [[ "$strict" == strict ]]; then
            die "the build used other package versions than Packages/ShrikeKit/Package.resolved (compare with $used)"
        fi
        warn "the build used other package versions than Packages/ShrikeKit/Package.resolved:"
        warn "  $used"
    fi
}

# build_archive <source-root> <work-dir> <build-number> [strict]
# Produces <work-dir>/Shrike.xcarchive (Release, universal, stripped, unsigned)
# and leaves the full log in <work-dir>/build.log.
build_archive() {
    local src="$1" work="$2" build="$3" strict="${4:-}"
    local log="$work/build.log" archive="$work/Shrike.xcarchive"
    mkdir -p "$work"

    step "xcodegen generate"
    (cd "$src" && xcodegen generate --quiet) || die "xcodegen failed"
    _seed_package_resolved "$src"

    # GRDB's #file strings (Swift does NOT remap them, not even with
    # -file-prefix-map) end up in the binary as the path of the package
    # checkout, which lives in DerivedData. So DerivedData goes to a neutral
    # folder under /tmp, never under the builder's home or the repo.
    step "xcodebuild archive (Release, arm64 + x86_64, build $build)"
    info "log: $log"
    [[ -e "$archive" ]] && safe_rm "$archive" "$work"
    local start=$SECONDS dd
    dd="/tmp/shrike-dd.$$"
    [[ -e "$dd" ]] && rm -rf "$dd"
    if ! xcodebuild archive \
            -project "$src/Shrike.xcodeproj" \
            -scheme Shrike \
            -configuration Release \
            -destination "generic/platform=macOS" \
            -derivedDataPath "$dd" \
            -archivePath "$archive" \
            CURRENT_PROJECT_VERSION="$build" \
            CODE_SIGNING_ALLOWED=NO \
            >"$log" 2>&1; then
        grep -E '(error|fatal error):' "$log" | sort -u | head -20 >&2 || true
        tail -5 "$log" >&2
        rm -rf "$dd"
        die "xcodebuild archive failed (full log: $log)"
    fi
    ok "archive built in $((SECONDS - start)) s"
    _check_package_pins "$src" "$strict"

    # Xcode registers what it builds with Launch Services. These copies
    # must never show up in "Open With".
    unregister_app "$archive/Products/Applications/Shrike.app"
    unregister_app "$dd/Build/Intermediates.noindex/ArchiveIntermediates/Shrike/InstallationBuildProductsLocation/Applications/Shrike.app"
    rm -rf "$dd"

    [[ -d "$archive/Products/Applications/Shrike.app" ]] || die "archive has no Products/Applications/Shrike.app"
    _check_app_size "$archive/Products/Applications/Shrike.app" "$strict"
}

# Size budget: the app stays under 20 MB (decimal). Only the
# archive is measured: `archive` strips the binary, a plain `xcodebuild
# build` keeps the symbol table (~2x bigger) so profiling still shows names.
# The dSYM (Shrike.xcarchive/dSYMs) keeps crash logs readable either way.
# strict (make-package): over budget is an error; otherwise a warning.
SHRIKE_SIZE_BUDGET_BYTES=20000000
_check_app_size() {
    local app="$1" strict="$2" bytes mb
    bytes="$(find "$app" -type f -print0 | xargs -0 stat -f %z | awk '{s += $1} END {print s + 0}')"
    mb="$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b / 1000000}')"
    if (( bytes > SHRIKE_SIZE_BUDGET_BYTES )); then
        [[ "$strict" == strict ]] && die "Shrike.app is $mb MB, over the 20 MB budget"
        warn "Shrike.app is $mb MB, over the 20 MB budget"
    else
        ok "Shrike.app is $mb MB (budget 20 MB)"
    fi
}

archived_app() { printf '%s\n' "$1/Shrike.xcarchive/Products/Applications/Shrike.app"; }

# ---------------------------------------------------------------------------
# Sign + verify

# sign_app <app> [strict]
# strict: fail instead of signing without a timestamp when offline.
sign_app() {
    local app="$1" strict="${2:-}"
    [[ -n "$SIGN_ID" ]] || pick_identity
    step "codesign ($SIGN_DESC)"
    if [[ "$SIGN_ID" == "-" ]]; then
        codesign --force --options runtime --timestamp=none \
            --entitlements "$ENTITLEMENTS" --sign - "$app" \
            || die "codesign failed"
        return
    fi
    if ! codesign --force --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$app"; then
        if [[ "$strict" == strict && -z "${SHRIKE_ALLOW_NO_TIMESTAMP:-}" ]]; then
            die "codesign with a secure timestamp failed (offline?). Retry online, or set SHRIKE_ALLOW_NO_TIMESTAMP=1."
        fi
        warn "codesign with a secure timestamp failed (offline?); signing without a timestamp."
        codesign --force --options runtime --timestamp=none \
            --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$app" \
            || die "codesign failed"
    fi
}

# verify_app <app>
# Everything that must be true before an app is installed or packaged.
verify_app() {
    local app="$1" exe="$1/Contents/MacOS/Shrike" out details archs ents
    step "verify $app"
    if ! out="$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "codesign --verify failed for $app"
    fi
    ok "signature valid (codesign --verify --deep --strict)"

    details="$(codesign -dvv "$app" 2>&1)"
    printf '%s\n' "$details" | grep -q 'flags=.*runtime' || die "hardened runtime flag missing"
    ok "hardened runtime"
    if [[ "$SIGN_ID" != "-" ]]; then
        codesign -d -r- "$app" 2>&1 | grep -q 'certificate leaf' \
            || die "designated requirement is not certificate-based (still ad-hoc?)"
        ok "signed by: $(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"
        if printf '%s\n' "$details" | grep -q '^Timestamp='; then
            ok "secure timestamp: $(printf '%s\n' "$details" | sed -n 's/^Timestamp=//p')"
        else
            warn "no secure timestamp in the signature"
        fi
    else
        ok "ad-hoc signature"
    fi

    ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
    if printf '%s' "$ents" | grep -q 'get-task-allow'; then
        die "entitlements contain com.apple.security.get-task-allow"
    fi
    ok "no get-task-allow entitlement"

    archs="$(lipo -archs "$exe" 2>/dev/null || true)"
    case " $archs " in
        *" arm64 "*) ;; *) die "binary has no arm64 slice (archs: $archs)" ;;
    esac
    case " $archs " in
        *" x86_64 "*) ;; *) die "binary has no x86_64 slice (archs: $archs)" ;;
    esac
    ok "architectures: $archs"

    # No builder paths in the shipped binary (home folder, repo, temp build dirs).
    leak="$(strings -a "$exe" | grep -F -e "$HOME/" -e "$REPO_ROOT" -e "/Users/" -e "/private/var/folders" -e "/DerivedData/" | head -3 || true)"
    if [[ -n "$leak" ]]; then
        printf '%s\n' "$leak" >&2
        die "the binary contains an absolute build path (see above)"
    fi
    ok "no build paths in the binary"

    plutil -lint "$app/Contents/Info.plist" >/dev/null || die "Info.plist does not lint"
    [[ -f "$app/Contents/Resources/Assets.car" ]] || die "Assets.car missing (no app icon)"
    [[ -n "$(plutil -extract CFBundleIconName raw -o - "$app/Contents/Info.plist" 2>/dev/null)" ]] \
        || die "CFBundleIconName missing (no app icon)"
    ok "app icon present (Assets.car, CFBundleIconName)"
}

app_version() { plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist"; }
app_build()   { plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist"; }

# ---------------------------------------------------------------------------
# Launch Services

unregister_app() {
    [[ -e "$1" ]] || return 0
    "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# Every Shrike.app path Launch Services currently knows about.
registered_shrike_paths() {
    "$LSREGISTER" -dump 2>/dev/null \
        | sed -n 's/^path:[[:space:]]*\(.*\/Shrike\.app\) (0x[0-9a-fA-F]*)$/\1/p' \
        | sort -u
}

# Unregister build-output copies of Shrike (Xcode DerivedData, .derived,
# build/, archives, temp/scratch builds). Real installs elsewhere
# (/Applications, ~/Applications, ...) are left alone, and so is <keep>.
prune_stale_registrations() {
    local keep="$1" p n=0
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != "$keep" ]] || continue
        case "$p" in
            */DerivedData/*|*/.derived/*|*/build/*|*/Build/Products/*|*/ArchiveIntermediates/*|*.xcarchive/*|/private/tmp/*|/tmp/*|/private/var/folders/*)
                "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true
                info "unregistered: $p"
                n=$((n + 1)) ;;
        esac
    done <<EOF
$(registered_shrike_paths)
EOF
    ok "removed $n stale Launch Services entr$([[ $n -eq 1 ]] && echo y || echo ies)"
}
