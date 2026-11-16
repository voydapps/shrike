#!/usr/bin/env python3
"""Run `swift test` in Packages/ShrikeKit and stop it if it hangs.

Why: one full test run once hung at 0% CPU (xctest stuck, test windows left
open) and no stack was captured. This wrapper makes the next hang leave
evidence and stop by itself.

What it does:
  * runs `swift test <args>` in its own process group;
  * copies all output to the terminal and to <out>/swift-test.log (it runs
    the tests on a pseudo-terminal so xctest prints each line at once);
  * if the output does not grow for --stall seconds (default 120), or the
    whole run takes more than --total seconds (default 1500), it runs
    `/usr/bin/sample` on every xctest process in the group, prints the last
    "Test Case ... started" line and the sample file paths, kills the whole
    group and exits 124. Otherwise it exits with swift test's own code.

The stall timer starts only when the tests start (first "Test Suite ...
started" line). A cold compile can be silent for minutes and is not a hang;
only --total applies before that.

Before starting it checks the login session: if the screen is locked (or this
is not the console session) it refuses with exit code 3. If the screen locks
during the run, a warning is printed at once and again in the summary.

Usage:
  Scripts/swift-test-guarded.py [--stall S] [--total S] [--out DIR] -- <swift test args>
"""
import argparse
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SESSION_SWIFT = (
    "import CoreGraphics\n"
    "let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]\n"
    "print(d[\"CGSSessionScreenIsLocked\"] as? Bool ?? false, "
    "d[\"kCGSSessionOnConsoleKey\"] as? Bool ?? true)\n"
)


def session_state():
    """(screen_locked, on_console), or None if it cannot be read.

    CGSSessionScreenIsLocked is absent while the screen is unlocked. Quartz
    (pyobjc) is not on the system python, so a tiny `swift -e` call reads it.
    """
    try:
        r = subprocess.run(["swift", "-e", SESSION_SWIFT], capture_output=True,
                           text=True, timeout=60)
        a, b = r.stdout.split()
        return a == "true", b == "true"
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def group_pids(pgid):
    """PIDs of xctest processes in the process group, or below the root."""
    found = set()
    r = subprocess.run(["/usr/bin/pgrep", "-g", str(pgid), "-x", "xctest"],
                       capture_output=True, text=True)
    found.update(int(x) for x in r.stdout.split())
    r = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="],
                       capture_output=True, text=True)
    procs = {}
    for line in r.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            procs[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    for pid, (_, pg, comm) in procs.items():
        if os.path.basename(comm) != "xctest":
            continue
        cur, hops = pid, 0
        while cur in procs and hops < 50:
            if cur == pgid or procs[cur][1] == pgid:
                found.add(pid)
                break
            cur, hops = procs[cur][0], hops + 1
        if pg == pgid:
            found.add(pid)
    return sorted(found)


def main():
    argv = sys.argv[1:]
    if "--" in argv:
        i = argv.index("--")
        own, swift_args = argv[:i], argv[i + 1:]
    else:
        own, swift_args = argv, []
    ap = argparse.ArgumentParser(add_help=True, usage="%(prog)s [--stall S] [--total S] [--out DIR] -- <swift test args>")
    ap.add_argument("--stall", type=int, default=120)
    ap.add_argument("--total", type=int, default=1500)
    ap.add_argument("--out", default=None)
    opts = ap.parse_args(own)

    state = session_state()
    if state is not None:
        if state[0]:
            print("[guard] screen is locked - unlock and run again", flush=True)
            return 3
        if not state[1]:
            print("[guard] this is not the console session (no screen) - "
                  "log in on the Mac itself and run again", flush=True)
            return 3

        print("[guard] session check: screen unlocked, console session", flush=True)
    else:
        print("[guard] session check: could not be read, continuing", flush=True)

    pkg = Path(__file__).resolve().parent.parent / "Packages" / "ShrikeKit"
    if not pkg.is_dir():
        sys.exit(f"package folder not found: {pkg}")
    out = Path(opts.out) if opts.out else Path(tempfile.mkdtemp(prefix="swift-test-guarded-"))
    out.mkdir(parents=True, exist_ok=True)
    log_path = out / "swift-test.log"
    print(f"[guard] output folder: {out}", flush=True)

    # A pseudo-terminal, not a pipe: xctest holds its output back in a block
    # buffer when stdout is a pipe, so a stuck test would look like silence
    # from the very start. On a terminal it prints each line at once.
    master, slave = pty.openpty()
    p = subprocess.Popen(["swift", "test", *swift_args], cwd=pkg,
                         stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                         start_new_session=True)
    os.close(slave)
    start = last = time.time()
    tests_started = False
    last_case = "(none)"
    pending = b""
    verdict = None
    locked_midrun = False
    next_session_check = time.time() + 20

    def kill_group():
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        with open(log_path, "wb") as log:
            fd = master
            while True:
                ready, _, _ = select.select([fd], [], [], 1.0)
                now = time.time()
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:  # the other end closed: the run is over
                        chunk = b""
                    if not chunk:
                        break
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    log.write(chunk)
                    log.flush()
                    last = now
                    pending += chunk
                    *lines, pending = pending.split(b"\n")
                    for ln in lines:
                        s = ln.decode("utf-8", "replace")
                        if s.startswith("Test Suite ") and " started" in s:
                            tests_started = True
                        if s.startswith("Test Case ") and " started" in s:
                            last_case = s
                if now >= next_session_check:
                    next_session_check = now + 20
                    st = session_state()
                    if st is not None and st[0] and not locked_midrun:
                        locked_midrun = True
                        print("\n[guard] WARNING: the screen locked during the run - "
                              "failures after this point are likely caused by the lock",
                              flush=True)
                if tests_started and not ready and now - last > opts.stall:
                    verdict = f"STALLED (no output for {opts.stall}s)"
                elif now - start > opts.total:
                    verdict = f"TOTAL TIMEOUT ({opts.total}s)"
                if verdict:
                    break
        if verdict:
            pids = group_pids(p.pid)
            samples = []
            for pid in pids:
                f = out / f"xctest-{pid}.sample.txt"
                try:
                    subprocess.run(["/usr/bin/sample", str(pid), "3", "-file", str(f)],
                                   capture_output=True, timeout=90)
                except subprocess.TimeoutExpired:
                    pass
                samples.append(str(f))
            kill_group()
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            p.wait()
            if locked_midrun:
                print("[guard] the screen was locked during the run", flush=True)
            print(f"\n[guard] {verdict}; killed the test run", flush=True)
            print(f"[guard] last test started: {last_case}", flush=True)
            print(f"[guard] xctest processes sampled: {len(pids)}", flush=True)
            for f in samples:
                print(f"[guard] sample: {f}", flush=True)
            print(f"[guard] log: {log_path}", flush=True)
            return 124
        code = p.wait()
        if locked_midrun:
            print("[guard] SUMMARY: the screen was locked during the run - "
                  "treat failures as suspect and run again unlocked", flush=True)
        return code
    except KeyboardInterrupt:
        kill_group()
        p.wait()
        return 130


if __name__ == "__main__":
    sys.exit(main())
