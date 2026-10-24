#!/usr/bin/env python3
"""Fail-closed exact-commit release gate. This command NEVER publishes.

The CLI uses only the pinned Xcode. Tests inject a runner into Gate to exercise
failure boundaries without building, signing or contacting GitHub.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import threading

XCODE = Path('/Applications/Xcode_26.4.1.app/Contents/Developer')
XCODE_VERSION = 'Xcode 26.4.1'
# A hung test must not wait for the 90-minute job limit (one full run takes ~10 minutes).
TEST_RUN_TIMEOUT = 30 * 60
PACKAGE_TIMEOUT = 40 * 60


def digest(path):
    with Path(path).open('rb') as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
        return result.hexdigest()


def assert_clean_release_inputs(run):
    """Reject tracked edits and untracked inputs consumed outside git archive.

    SwiftPM reads new sources/resources directly from the checkout; packaging
    exports HEAD. Private untracked audit notes may remain, but App/package/
    tooling/site/workflow inputs must already belong to the tested commit.
    Porcelain -z keeps spaces/newlines literal and never C-quotes file names.
    """
    output = run(['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
    if not output:
        return
    if not output.endswith('\0'):
        raise RuntimeError('invalid NUL-terminated git status response')
    input_roots = {'app', 'packages', 'scripts', 'site', '.github'}
    for record in output.split('\0')[:-1]:
        if len(record) < 4 or record[2] != ' ':
            raise RuntimeError('invalid git status record')
        state, path = record[:2], record[3:]
        if state != '??':
            # Renames have a second path record, but any tracked change blocks
            # immediately, so that record never needs ambiguous parsing.
            raise RuntimeError('tracked source must be clean')
        parts = PurePosixPath(path).parts
        if not parts or path.startswith('/') or any(part in ('.', '..') for part in parts):
            raise RuntimeError('invalid untracked path in git status')
        if parts[0].lower() in input_roots or path.lower() == 'project.yml':
            raise RuntimeError(f'untracked release build/test input must be committed: {path!r}')


class Gate:
    def __init__(self, root, tag, run=None, developer=XCODE, smoke=None):
        self.root = Path(root).resolve()
        self.tag = tag
        self.developer = Path(developer)
        self.env = dict(os.environ, DEVELOPER_DIR=str(self.developer))
        self.work = self.root / 'build/release-gate'
        self.run = run or self.command
        # The smoke launch opens the real app, so only the CI runner asks for it.
        self.smoke = os.environ.get('SHRIKE_SMOKE_LAUNCH') == '1' if smoke is None else smoke

    def command(self, args, log=None):
        # Full output is retained per phase and streamed for CI diagnostics.
        # The watchdog kills a hung command: a hung test blocks the stdout loop
        # itself, so a timeout on wait() alone would never fire.
        if log:
            timeout = TEST_RUN_TIMEOUT if args[:3] == ['xcrun', 'swift', 'test'] else PACKAGE_TIMEOUT
            with log.open('w') as output:
                process = subprocess.Popen(args, cwd=self.root, env=self.env,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True)
                expired = threading.Event()
                def expire():
                    expired.set()
                    process.kill()
                watchdog = threading.Timer(timeout, expire) if timeout else None
                if watchdog:
                    watchdog.start()
                try:
                    for line in process.stdout:
                        print(line, end='', flush=True)
                        output.write(line)
                    status = process.wait()
                finally:
                    if watchdog:
                        watchdog.cancel()
                if expired.is_set():
                    raise RuntimeError(f'timed out after {timeout} s: {args[0]} (see {log})')
                if status:
                    raise RuntimeError(f'failed: {args[0]} (see {log})')
            return ''
        output = subprocess.check_output(args, cwd=self.root, env=self.env,
                                         stderr=subprocess.STDOUT, text=True)
        # Do not strip leading status columns or whitespace in NUL paths.
        return output if args[:2] == ['git', 'status'] else output.strip()

    def revision(self):
        return self.run(['git', 'rev-parse', 'HEAD'])

    def assert_revision(self, sha):
        if self.revision() != sha:
            raise RuntimeError('HEAD changed during release gate')
        assert_clean_release_inputs(self.run)

    def execute(self):
        # Invalidate any previous success even when a new preflight fails.
        (self.work / 'gate.json').unlink(missing_ok=True)
        if not re.fullmatch(r'v\d+\.\d+\.\d+', self.tag):
            raise RuntimeError('release requires an existing vMAJOR.MINOR.PATCH tag')
        if not self.developer.is_dir():
            raise RuntimeError(f'intended Xcode missing: {self.developer}')
        xcode = self.run(['xcodebuild', '-version'])
        if xcode.splitlines()[0] != XCODE_VERSION:
            raise RuntimeError(f'wrong Xcode: {xcode}')
        swift_path = self.run(['xcrun', '--find', 'swift'])
        if not Path(swift_path).is_relative_to(self.developer):
            raise RuntimeError('Swift is outside intended Xcode')
        swift = self.run(['xcrun', 'swift', '--version'])
        if 'Apple Swift version 6.' not in swift:
            raise RuntimeError('intended Swift 6 toolchain unavailable')
        sha = self.revision()
        if self.run(['git', 'rev-parse', f'refs/tags/{self.tag}^{{commit}}']) != sha:
            raise RuntimeError('HEAD does not equal release tag commit')
        # A missing origin/main or non-ancestor exits nonzero.
        self.run(['git', 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main'])
        self.assert_revision(sha)
        version = self.tag[1:]
        match = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)',
                          (self.root / 'project.yml').read_text(), re.M)
        if not match or match[1] != version:
            raise RuntimeError('tag does not match MARKETING_VERSION')
        self.work.mkdir(parents=True, exist_ok=True)
        receipt = self.work / 'gate.json'
        receipt.unlink(missing_ok=True)  # a failed rerun cannot leave a green receipt
        self.run(['node', 'Scripts/make-changelog-page.mjs', '--section', version],
                 self.work / 'changes.md')
        runs = []
        for attempt in range(1, 4):
            self.assert_revision(sha)
            log = self.work / f'swift-test-{attempt}.log'
            self.run(['xcrun', 'swift', 'test', '--package-path', 'Packages/ShrikeKit',
                      '--scratch-path', str(self.work / 'swiftpm')], log)
            runs.append({'run': attempt, 'status': 'passed', 'log_sha256': digest(log)})
        self.assert_revision(sha)
        # This script archives Release/universal, enforces the 20 MB stripped app
        # budget, signs ad-hoc, validates the signature and mounted DMG.
        self.env['SHRIKE_WORK_DIR'] = str(self.work / 'package')
        # The producer and attestation reader must use the same destination;
        # inherited local packaging overrides must never redirect fresh bytes.
        self.env['SHRIKE_DIST_DIR'] = str(self.root / 'dist')
        dmg = self.root / f'dist/Shrike-{version}.dmg'
        if dmg.exists():
            raise RuntimeError('versioned artifact already exists; use a fresh release checkout')
        self.run(['bash', 'Scripts/make-package.sh', '--adhoc', version],
                 self.work / 'release-package.log')
        self.assert_revision(sha)
        stable = self.root / 'dist/Shrike.dmg'
        if stable.exists():
            raise RuntimeError('stable artifact already exists; use a fresh release checkout')
        stable.write_bytes(dmg.read_bytes())
        checksum = self.root / 'dist/Shrike.dmg.sha256'
        checksum.write_text(f'{digest(stable)}  Shrike.dmg\n')
        app = self.work / 'package/dmg-root/Shrike.app'
        # codesign's Executable= line includes the runner/local checkout path;
        # retain signature evidence without publishing a builder's home path.
        signature = '\n'.join(line for line in self.run(['codesign', '-dvvv', str(app)]).splitlines()
                              if not line.startswith('Executable='))
        if 'Signature=adhoc' not in signature:
            raise RuntimeError('public artifact must have an ad-hoc signature')
        archs = self.run(['lipo', '-archs', str(app / 'Contents/MacOS/Shrike')])
        app_bytes = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
        if app_bytes > 20_000_000 or set(archs.split()) != {'arm64', 'x86_64'}:
            raise RuntimeError('universal archive or stripped app budget check failed')
        # The Release binary is otherwise never started (tests run in Debug).
        smoke = 'skipped (not requested; runs on the CI runner)'
        if self.smoke:
            fixture = self.work / 'smoke-photo.jpg'
            fixture.write_bytes((self.root / 'Packages/ShrikeKit/Tests/ShrikeEditTests/Fixtures/small.jpg').read_bytes())
            self.run(['bash', 'Scripts/smoke-launch.sh', str(app), str(fixture)],
                     self.work / 'smoke-launch.log')
            smoke = 'passed'
        data = {'schema': 1, 'commit': sha, 'tag': self.tag, 'version': version,
                'developer_dir': str(self.developer), 'xcode': xcode, 'swift': swift,
                'swiftpm': runs, 'release': 'passed', 'signature': signature,
                'signature_policy': 'ad-hoc; not notarized', 'architectures': archs,
                'app_bytes': app_bytes, 'app_budget_bytes': 20_000_000,
                'smoke_launch': smoke, 'artifact': 'Shrike.dmg', 'artifact_sha256': digest(stable),
                'package_log_sha256': digest(self.work / 'release-package.log'),
                'runtime_limits': 'Runner only; universal compilation does not verify macOS 14 or Intel runtime.'}
        receipt.write_text(json.dumps(data, indent=2) + '\n')
        (self.root / 'dist/Shrike.provenance.json').write_text(receipt.read_text())
        return data


if __name__ == '__main__':
    try:
        Gate(Path(__file__).resolve().parent.parent, sys.argv[1]).execute()
    except (RuntimeError, subprocess.CalledProcessError, IndexError) as error:
        sys.exit(f'Release gate blocked: {error}')
