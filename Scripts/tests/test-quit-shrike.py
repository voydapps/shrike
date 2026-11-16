#!/usr/bin/env python3
"""Tests for Scripts/lib/quit-shrike.sh (J-1) without any Shrike app.

A plain program (a copy of /bin/sleep, outside any .app bundle) plays "the
running Shrike". SHRIKE_QUIT_CMD replaces the Apple event: `kill -TERM` is an
app that agrees to quit, `true` is an app that keeps its unsaved work open.
No Apple event is sent and no real app is touched.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / 'lib' / 'quit-shrike.sh'


class QuitShrikeTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='shrike-quit-test-')).resolve()
        self.exe = self.dir / 'FakeShrike'
        shutil.copy('/bin/sleep', self.exe)
        # A copied system binary has a broken signature and is killed at start.
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(self.exe)],
                       check=True, capture_output=True)
        self.procs = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
        shutil.rmtree(self.dir)

    def start(self):
        p = subprocess.Popen([str(self.exe), '120'])
        self.procs.append(p)
        time.sleep(0.5)
        self.assertIsNone(p.poll(), 'the fake app did not start')
        return p

    def run_quit(self, force, **env):
        script = f'''
set -u
. "{LIB}"
shrike_pids() {{
    ps -axo pid=,comm= | while read -r pid comm; do
        [ "$comm" = "{self.exe}" ] && printf '%s\\n' "$pid"
    done
    return 0
}}
shrike_quit_running "/nonexistent/Shrike.app" {force}
'''
        e = {k: v for k, v in os.environ.items()}
        e.update(env)
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                              env=e, stdin=subprocess.DEVNULL, timeout=60)

    def test_nothing_running_is_fine(self):
        r = self.run_quit(0, SHRIKE_QUIT_CMD='false')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_app_that_agrees_to_quit_ends(self):
        p = self.start()
        r = self.run_quit(0, SHRIKE_QUIT_CMD='kill -TERM', SHRIKE_QUIT_WAIT='10')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNotNone(p.poll())

    def test_app_with_unsaved_work_is_not_killed(self):
        p = self.start()
        r = self.run_quit(0, SHRIKE_QUIT_CMD='true', SHRIKE_QUIT_WAIT='2')
        self.assertEqual(r.returncode, 1)
        self.assertIn('still open', r.stderr)
        self.assertIsNone(p.poll(), 'the process must still be running')

    def test_force_kills(self):
        p = self.start()
        r = self.run_quit(1, SHRIKE_QUIT_CMD='true', SHRIKE_QUIT_WAIT='2')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNotNone(p.poll())

    def test_scripts_wire_the_polite_quit_and_never_kill_by_default(self):
        scripts = LIB.parent.parent
        install = (scripts / 'install-local.sh').read_text()
        smoke = (scripts / 'smoke-launch.sh').read_text()
        self.assertIn('shrike_quit_running', install)
        self.assertIn('--force)', install)
        self.assertNotIn('kill -TERM', install)
        self.assertNotIn('pkill', smoke)
        self.assertIn('shrike_quit_running', smoke)


if __name__ == '__main__':
    unittest.main(verbosity=2)
