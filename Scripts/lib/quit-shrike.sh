# shellcheck shell=bash
#
# Scripts/lib/quit-shrike.sh — ask a running Shrike to quit, never kill it.
#
# Sourced by install-local.sh and smoke-launch.sh. Written for bash 3.2.
#
#   shrike_quit_running <app-path> <force 0|1>
#
# The caller defines `shrike_pids` first: it prints the pids of the Shrike
# processes that count (one per line, nothing when none run).
#
# Default (force = 0): send the normal "quit" Apple event to the app at
# <app-path>. Shrike then shows its own question about unsaved work, and the
# user can answer it. Wait up to SHRIKE_QUIT_WAIT seconds (default 45) for
# the process to end. If it is still running, print one clear message and
# return 1. Nothing is ever killed.
#
# force = 1 (CI only): SIGTERM, then SIGKILL after the wait. Never the default.
#
# The quit is sent only while the app is running (`if ... is running`), so a
# process that ends in between is not launched again by the Apple event.
# Needs no terminal and never reads from stdin. The whole Apple event has a
# 5 s time-out, so an unresponsive app cannot hang the script. If macOS
# refuses it (Automation permission, error -1743), the poll still runs and
# the same "still open" message is printed.
#
# Test hook: SHRIKE_QUIT_CMD replaces the Apple event; it is run as
# `$SHRIKE_QUIT_CMD <pid>...`. Tests use `kill -TERM` (an app that agrees to
# quit) or `true` (an app that keeps its unsaved work open).

shrike_quit_running() {
    local app="$1" force="${2:-0}" pids wait
    wait="${SHRIKE_QUIT_WAIT:-45}"
    pids="$(shrike_pids)"
    [[ -n "$pids" ]] || return 0

    if [[ "$force" == "1" ]]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        _shrike_wait_gone "$wait" && return 0
        # shellcheck disable=SC2046
        kill -KILL $(shrike_pids) 2>/dev/null || true
        _shrike_wait_gone 5 && return 0
        echo "Shrike did not stop even after SIGKILL" >&2
        return 1
    fi

    if [[ -n "${SHRIKE_QUIT_CMD:-}" ]]; then
        # shellcheck disable=SC2086
        $SHRIKE_QUIT_CMD $pids 2>/dev/null || true
    else
        local err rc=0
        err="$(/usr/bin/osascript \
            -e 'on run argv' \
            -e 'set appPath to item 1 of argv' \
            -e 'with timeout of 5 seconds' \
            -e 'if application appPath is running then tell application appPath to quit' \
            -e 'end timeout' \
            -e 'end run' "$app" 2>&1 </dev/null)" || rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "note: the quit request failed ($(printf '%s' "$err" | head -n 1))" >&2
        fi
    fi

    _shrike_wait_gone "$wait" && return 0
    echo "Shrike is still open — finish or close your work, then run again." >&2
    return 1
}

# Polls once a second for up to $1 seconds until shrike_pids prints nothing.
_shrike_wait_gone() {
    local secs="$1" i=0
    while [[ $i -lt $secs ]]; do
        [[ -z "$(shrike_pids)" ]] && return 0
        sleep 1
        i=$((i + 1))
    done
    [[ -z "$(shrike_pids)" ]]
}
