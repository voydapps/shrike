#!/bin/bash
#
# measure-launch.sh — cold launch -> first photo frame, from the app's own signposts.
#
#     Scripts/measure-launch.sh [--warmup N] <photo.jpg> <runs> <Shrike.app> [<Shrike.app> ...]
#
# Give it one app to time one build, or several apps to compare builds: the
# runs alternate (A, B, A, B, ...), so machine noise hits every build alike.
# --warmup N (default 1) launches each app N times first and does not count them.
#
# For each run: take the wall-clock time t0, `open -a <app> <photo>`, find the
# pid started from exactly that app path, wait for the signpost event
#     subsystem app.shrike, category launch, event firstImageFrame
# (the first real, non-placeholder photo frame on screen), print
# (event time - t0) in ms, then stop that pid with SIGTERM. At the end it prints
# every value and min / median / max per app.
#
# What the number is: wall-clock from just before `open` to the frame on screen.
# It includes Launch Services' start-up work and the ~10-20 ms of `open`; compare
# builds with this script only, never with Instruments numbers.
#
# Safety. It never sends keys or clicks and never uses System Events. It stops
# (exit 2) before every launch if
#   - the screen is locked or the session is not on the console (checked with
#     CGSessionCopyCurrentDictionary, compiled once into a temp folder),
#   - any Shrike process is already running (it never touches one it did not start),
#   - an app is not a Shrike bundle (CFBundleIdentifier app.shrike) or is installed
#     (/Applications, ~/Applications, /System).
# Use it only on scratch Release builds (an archive app, e.g. from
# Scripts/lib/common.sh build_archive): it stops the app with SIGTERM.
#
# Side effects: the app writes into the real user data (Recent Folders, the header
# cache in metadata.sqlite, a few defaults) and registers with Launch Services.
# The script runs `lsregister -u` on every app at the end; remove the rows that
# point at the photo folder yourself, with Shrike not running.
set -u

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "REFUSED: $*" >&2; exit 2; }
usage() { echo "usage: $0 [--warmup N] <photo.jpg> <runs> <Shrike.app> [<Shrike.app> ...]" >&2; exit 64; }

warmup=1
if [ "${1:-}" = "--warmup" ]; then warmup="${2:-}"; shift 2 || usage; fi
case "$warmup" in ''|*[!0-9]*) usage ;; esac
[ $# -ge 3 ] || usage
photo="$1"; runs="$2"; shift 2
case "$runs" in ''|*[!0-9]*) usage ;; esac
[ "$runs" -ge 1 ] || usage
[ -f "$photo" ] || die "no photo at $photo"
photo="$(cd "$(dirname "$photo")" && pwd -P)/$(basename "$photo")"

apps=()
for a in "$@"; do
    [ -d "$a" ] || die "no app at $a"
    a="$(cd "$a" && pwd -P)"
    case "$a" in
        /Applications/*|/System/*|"$HOME"/Applications/*) die "$a is an installed app; use a scratch build" ;;
    esac
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null)" = "app.shrike" ] \
        || die "$a is not a Shrike bundle"
    [ -x "$a/Contents/MacOS/Shrike" ] || die "no executable in $a"
    apps+=("$a")
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/measure-launch.XXXXXX")" || die "mktemp failed"
started_pid=""
cleanup() {
    if [ -n "$started_pid" ] && kill -0 "$started_pid" 2>/dev/null; then
        kill -TERM "$started_pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$started_pid" 2>/dev/null || break; sleep 1; done
    fi
    for a in "${apps[@]}"; do "$LSREGISTER" -u "$a" >/dev/null 2>&1; done
    case "$tmp" in */measure-launch.*) /bin/rm -rf "$tmp" ;; esac
}
trap cleanup EXIT

# Screen-lock check: prints "<locked> <onConsole>"; "false true" means safe.
cat >"$tmp/sess.swift" <<'SWIFT'
import CoreGraphics
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print(d["CGSSessionScreenIsLocked"] as? Bool ?? false, d["kCGSSessionOnConsoleKey"] as? Bool ?? false)
SWIFT
/usr/bin/swiftc -O -o "$tmp/sess" "$tmp/sess.swift" >/dev/null 2>&1 || die "could not build the screen-lock check"
screen_ok() { [ "$("$tmp/sess" 2>/dev/null)" = "false true" ]; }
any_shrike() { pgrep -x Shrike >/dev/null 2>&1; }
now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }

# ndjson from `log show` on stdin; prints ms from t0 to the first event for the pid.
event_offset_ms() {
    /usr/bin/python3 -I -c '
import sys, json, datetime
pid, t0, name = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
best = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"): continue
    try: o = json.loads(line)
    except ValueError: continue
    if o.get("processID") != pid or o.get("signpostName") != name: continue
    ts = datetime.datetime.strptime(o["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    if best is None or ts < best: best = ts
if best is not None: print("%.1f" % ((best - t0) * 1000.0))
' "$1" "$2" "$3"
}

# launch_once <app> -> sets LAST_MS; exits on any failure (runs in this shell,
# not a subshell, so the EXIT trap can still stop the pid it started).
launch_once() {
    local app="$1" exe="$1/Contents/MacOS/Shrike" start_str t0 pid p pc ms gone
    screen_ok || die "the screen is locked or the session is not on the console"
    any_shrike && die "a Shrike process is already running; not touching it"
    start_str="$(date -v-5S '+%Y-%m-%d %H:%M:%S')"   # before t0, so it adds nothing to the number
    t0="$(now)"
    /usr/bin/open -a "$app" "$photo" || die "open failed"
    pid=""
    for _ in $(seq 1 100); do
        for p in $(pgrep -x Shrike 2>/dev/null); do
            pc="$(ps -o comm= -p "$p" 2>/dev/null)"
            if [ -n "$pc" ] && [ "$pc" -ef "$exe" ]; then pid="$p"
            elif [ -n "$pc" ]; then die "a Shrike that is not $app started ($pc, pid $p); not touching it"
            fi
        done
        [ -n "$pid" ] && break
        sleep 0.1
    done
    [ -n "$pid" ] || die "no process started from $exe"
    started_pid="$pid"
    ms=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do   # the log store fills a moment after the event
        sleep 1.5
        kill -0 "$pid" 2>/dev/null || die "Shrike (pid $pid) exited before showing a photo"
        ms="$(/usr/bin/log show --start "$start_str" --signpost --info --debug --style ndjson \
              --predicate 'subsystem == "app.shrike" AND category == "launch"' 2>/dev/null \
              | event_offset_ms "$pid" "$t0" firstImageFrame)"
        [ -n "$ms" ] && break
    done
    [ -n "$ms" ] || die "no firstImageFrame signpost for pid $pid"
    kill -TERM "$pid" 2>/dev/null
    gone=0
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
    [ "$gone" = 1 ] || die "pid $pid did not exit within 10 s after SIGTERM"
    started_pid=""
    sleep 2
    LAST_MS="$ms"
}

n=${#apps[@]}
for w in $(seq 1 "$warmup"); do
    [ "$warmup" -ge 1 ] || break
    for i in $(seq 0 $((n - 1))); do
        launch_once "${apps[$i]}"; ms="$LAST_MS"
        printf 'warm-up %d  app %d: %s ms (not counted)\n' "$w" $((i + 1)) "$ms"
    done
done

for i in $(seq 0 $((n - 1))); do : >"$tmp/values.$i"; done
for r in $(seq 1 "$runs"); do
    for i in $(seq 0 $((n - 1))); do
        launch_once "${apps[$i]}"; ms="$LAST_MS"
        printf 'run %d  app %d: %s ms\n' "$r" $((i + 1)) "$ms"
        echo "$ms" >>"$tmp/values.$i"
    done
done

for i in $(seq 0 $((n - 1))); do
    printf 'app %d  %s\n' $((i + 1)) "${apps[$i]}"
    sort -n "$tmp/values.$i" | awk '{a[NR]=$1} END {
        if (NR % 2) m = a[(NR + 1) / 2]; else m = (a[NR / 2] + a[NR / 2 + 1]) / 2;
        printf "    runs %d   min %.1f   median %.1f   max %.1f ms (open -> firstImageFrame)\n", NR, a[1], m, a[NR] }'
done
