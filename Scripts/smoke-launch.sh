#!/bin/bash
# Smoke launch of the packaged Release app: open one photo, check that the app
# stays alive, writes no crash report, shows a window, and has put a decoded
# photo on screen, then quit it. Used by the release gate on the GitHub runner
# (the Release build is otherwise never started).
#
#   Scripts/smoke-launch.sh <path/to/Shrike.app> <photo.jpg>
#
# It writes into the user's real app data (Recent Folders etc.), so it only runs
# on GitHub Actions, or when SHRIKE_ALLOW_LOCAL_SMOKE=1 is set on purpose.
#
# Quitting: on GitHub Actions a running Shrike is stopped with SIGTERM/SIGKILL
# (nobody works there). On any other Mac Shrike is asked to quit the normal way
# and the script stops if it stays open (see Scripts/lib/quit-shrike.sh).
#
# What counts as proof that a photo was shown (nothing in the app had to change):
#   1. a normal on-screen window of the Shrike process, at least 200 x 200 points
#      (CGWindowList, needs no permission);
#   2. the signpost event `firstImageFrame` (subsystem app.shrike, category
#      launch), which Shrike emits once, when the first real (not placeholder)
#      photo frame has been presented on screen (MetalImageView.noteFirstRealImageFrame).
#      Read with `log show --signpost` from a start time taken before the launch.
set -u
app="${1:-}"; photo="${2:-}"
[ -d "$app" ] && [ -f "$photo" ] || { echo "usage: $0 <Shrike.app> <photo>"; exit 2; }
if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SHRIKE_ALLOW_LOCAL_SMOKE:-}" != "1" ]; then
  echo "smoke launch skipped: not on GitHub Actions (set SHRIKE_ALLOW_LOCAL_SMOKE=1 to force)"; exit 3
fi
# shellcheck source=lib/quit-shrike.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quit-shrike.sh"

force=0
[ "${GITHUB_ACTIONS:-}" = "true" ] && { force=1; SHRIKE_QUIT_WAIT="${SHRIKE_QUIT_WAIT:-10}"; }
shrike_pids() { pgrep -x Shrike 2>/dev/null; return 0; }
# Path of the .app a running Shrike pid was started from.
app_of_pid() {
  local exe; exe="$(ps -o comm= -p "$1" 2>/dev/null)"
  case "$exe" in */Contents/MacOS/Shrike) printf '%s\n' "${exe%/Contents/MacOS/Shrike}" ;; *) printf '%s\n' "$app" ;; esac
}

reports="$HOME/Library/Logs/DiagnosticReports"
count_reports() { find "$reports" -maxdepth 1 \( -name 'Shrike*.ips' -o -name 'Shrike*.crash' \) 2>/dev/null | wc -l | tr -d ' '; }
before=$(count_reports)

# Number of normal on-screen windows (layer 0, >= 200 x 200) that belong to a pid.
count_windows() {
  /usr/bin/osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("CoreGraphics");
    var pid = parseInt(argv[0], 10);
    var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    var n = 0;
    for (var i = 0; i < list.length; i++) {
      var w = list[i], b = w.kCGWindowBounds;
      if (w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 && b && b.Width >= 200 && b.Height >= 200) n++;
    }
    return String(n);
  }' "$1" 2>/dev/null
}

first_pid="$(shrike_pids | head -n 1)"
if [ -n "$first_pid" ]; then
  shrike_quit_running "$(app_of_pid "$first_pid")" "$force" || { echo "FAIL: an older Shrike is still running; not touching it"; exit 1; }
fi

started="$(date '+%Y-%m-%d %H:%M:%S')"
# On a runner without Metal the app must print the no-Metal notice and fail
# (not wait on a modal alert): `open` drops the environment, so pass the flag on.
env_args=()
[ "${GITHUB_ACTIONS:-}" = "true" ] && env_args=(--env GITHUB_ACTIONS=true)
open ${env_args[@]+"${env_args[@]}"} -a "$app" "$photo" || { echo "FAIL: open failed"; exit 1; }

# Wait up to 30 s for the process, then it must stay alive for 10 more seconds.
alive=0
for _ in $(seq 1 30); do pgrep -x Shrike >/dev/null && { alive=1; break; }; sleep 1; done
[ "$alive" = 1 ] || { echo "FAIL: Shrike never started"; exit 1; }
for i in $(seq 1 10); do
  pgrep -x Shrike >/dev/null || { echo "FAIL: Shrike exited $i s after it started"; sleep 3; exit 1; }
  sleep 1
done
after=$(count_reports)
if [ "$after" != "$before" ]; then echo "FAIL: new Shrike crash report ($before -> $after)"; exit 1; fi

# Proof 1: a window is on screen.
pid="$(shrike_pids | head -n 1)"
windows="$(count_windows "$pid")"
if [ -z "$windows" ]; then echo "FAIL: could not list the windows of Shrike (pid $pid)"; exit 1; fi
if [ "$windows" -lt 1 ]; then echo "FAIL: Shrike runs but shows no on-screen window of at least 200 x 200 points"; exit 1; fi

# Proof 2: the first real photo frame was presented. The log store fills a
# moment after the event, so retry for up to 10 s.
signpost=0; log_failed=0; out=""
for _ in 1 2 3 4 5; do
  if out="$(/usr/bin/log show --start "$started" --signpost --info --debug --style compact \
        --predicate 'subsystem == "app.shrike" AND category == "launch"' 2>&1)"; then
    log_failed=0
    if printf '%s\n' "$out" | grep -q 'firstImageFrame'; then signpost=1; break; fi
  else
    log_failed=1
  fi
  sleep 2
done
if [ "$signpost" != 1 ]; then
  if [ "$log_failed" = 1 ]; then echo "FAIL: 'log show' failed, so the photo proof could not be read: $(printf '%s' "$out" | head -n 1)"
  else echo "FAIL: no firstImageFrame signpost since $started: Shrike has a window ($windows) but no photo was shown in it"; fi
  exit 1
fi

shrike_quit_running "$app" "$force" || { echo "FAIL: Shrike did not quit after the check"; exit 1; }
echo "smoke launch OK: Shrike started, stayed alive for 10 s, no crash report, $windows window(s) on screen, first photo frame presented"
exit 0
