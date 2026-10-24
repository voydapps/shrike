#!/bin/bash
# Smoke launch of the packaged Release app: open one photo, watch that the app
# stays alive and writes no crash report, then quit it. Used by the release gate
# on the GitHub runner (the Release build is otherwise never started).
#
#   Scripts/smoke-launch.sh <path/to/Shrike.app> <photo.jpg>
#
# It writes into the user's real app data (Recent Folders etc.), so it only runs
# on GitHub Actions, or when SHRIKE_ALLOW_LOCAL_SMOKE=1 is set on purpose.
set -u
app="${1:-}"; photo="${2:-}"
[ -d "$app" ] && [ -f "$photo" ] || { echo "usage: $0 <Shrike.app> <photo>"; exit 2; }
if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SHRIKE_ALLOW_LOCAL_SMOKE:-}" != "1" ]; then
  echo "smoke launch skipped: not on GitHub Actions (set SHRIKE_ALLOW_LOCAL_SMOKE=1 to force)"; exit 3
fi
reports="$HOME/Library/Logs/DiagnosticReports"
count_reports() { find "$reports" -maxdepth 1 \( -name 'Shrike*.ips' -o -name 'Shrike*.crash' \) 2>/dev/null | wc -l | tr -d ' '; }
before=$(count_reports)

pkill -x Shrike 2>/dev/null; sleep 1
open -a "$app" "$photo" || { echo "FAIL: open failed"; exit 1; }

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

pkill -TERM -x Shrike
for _ in $(seq 1 10); do pgrep -x Shrike >/dev/null || break; sleep 1; done
pgrep -x Shrike >/dev/null && pkill -KILL -x Shrike
echo "smoke launch OK: Shrike started, stayed alive for 10 s, no crash report"
exit 0
