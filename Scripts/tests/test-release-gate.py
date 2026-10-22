#!/usr/bin/env python3
"""Offline release-control harness; no app bundle, Swift build or network calls.

Failure tests execute a deliberately failing Python test through the injected
SwiftPM command boundary. Production always invokes xcrun swift test directly.
"""
from importlib.util import spec_from_file_location, module_from_spec
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent.parent

def load(name):
    spec = spec_from_file_location(name.replace('-', '_'), SCRIPTS / f'{name}.py')
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

gate = load('release-gate')
publisher = load('publish-release')
SHA = 'a' * 40


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shrike-release-harness-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.developer = self.root / 'intended-toolchain'
        self.developer.mkdir()
        (self.root / 'project.yml').write_text('MARKETING_VERSION: "1.2.3"\n')
        self.calls = []
        self.fail_test = None
        self.xcode_version = gate.XCODE_VERSION
        self.tag_sha = SHA
        self.head = SHA
        self.dirty = ''
        self.main_missing = False
        self.release_pages = [[]]
        self.lookup_failure = None
        self.raw_lookup = None
        self.push_access = True
        self.auth_patch = patch.dict(os.environ, {'GH_TOKEN': 'offline-harness-token',
                                                 'GITHUB_REPOSITORY': 'voydapps/shrike'})
        self.auth_patch.start()
        self.addCleanup(self.auth_patch.stop)

    def runner(self, args, log=None):
        self.calls.append(args)
        if args[:2] == ['gh', 'api']:
            if self.lookup_failure:
                raise subprocess.CalledProcessError(1, args, output=self.lookup_failure)
            if self.raw_lookup is not None:
                return self.raw_lookup
            endpoint = args[4]
            if endpoint == 'repos/voydapps/shrike':
                return json.dumps({'full_name': 'voydapps/shrike',
                                   'permissions': {'push': self.push_access}})
            self.assertTrue(endpoint.startswith('repos/voydapps/shrike/releases?per_page=100&page='))
            page = int(endpoint.rsplit('=', 1)[1])
            return json.dumps(self.release_pages[page - 1])
        if args[:3] == ['gh', 'release', 'create']:
            return 'offline harness: create boundary reached'
        if args == ['xcodebuild', '-version']:
            return self.xcode_version + '\nBuild version harness'
        if args == ['xcrun', '--find', 'swift']:
            return str(self.developer / 'Toolchains/Swift.xctoolchain/usr/bin/swift')
        if args == ['xcrun', 'swift', '--version']:
            return 'Apple Swift version 6.0 (offline harness)'
        if args[:2] == ['git', 'merge-base']:
            if self.main_missing:
                raise subprocess.CalledProcessError(1, args)
            return ''
        if args == ['git', 'rev-parse', 'HEAD']:
            return self.head
        if args[:2] == ['git', 'rev-parse']:
            return self.tag_sha
        if args[:2] == ['git', 'status']:
            return self.dirty
        if args[:3] == ['xcrun', 'swift', 'test']:
            count = len([a for a in self.calls if a[:3] == ['xcrun', 'swift', 'test']])
            if count == self.fail_test:
                result = subprocess.run(['python3', '-c',
                    'import unittest\nclass DeliberateFailure(unittest.TestCase):\n'
                    ' def test_blocks_release(self): self.assertTrue(False, "deliberate gate failure")\n'
                    'unittest.main()'], capture_output=True, text=True)
                log.write_text(result.stdout + result.stderr)
                if result.returncode:
                    raise subprocess.CalledProcessError(result.returncode, args)
            log.write_text('offline successful full-suite boundary\n')
            return ''
        if args[:2] == ['bash', 'Scripts/make-package.sh']:
            raise RuntimeError('package boundary reached: harness deliberately stops before build')
        if log:
            log.write_text('changes\n')
        return ''

    def execute(self):
        return gate.Gate(self.root, 'v1.2.3', self.runner, self.developer).execute()

    def assert_no_package_or_publication(self):
        self.assertFalse(any(a[0] == 'gh' or 'Scripts/make-package.sh' in a for a in self.calls))
        self.assertFalse((self.root / 'build/release-gate/gate.json').exists())

    def test_each_deliberately_failing_test_run_blocks_package_and_publish(self):
        for attempt in (1, 2, 3):
            with self.subTest(attempt=attempt):
                self.calls.clear()
                self.fail_test = attempt
                with self.assertRaises(subprocess.CalledProcessError):
                    self.execute()
                self.assertEqual(len([a for a in self.calls if a[:3] == ['xcrun', 'swift', 'test']]), attempt)
                self.assert_no_package_or_publication()

    def test_three_green_suites_are_required_before_release_archive(self):
        with self.assertRaisesRegex(RuntimeError, 'package boundary reached'):
            self.execute()
        self.assertEqual(len([a for a in self.calls if a[:3] == ['xcrun', 'swift', 'test']]), 3)
        self.assertEqual(self.calls[-1], ['bash', 'Scripts/make-package.sh', '--adhoc', '1.2.3'])
        self.assertFalse((self.root / 'build/release-gate/gate.json').exists())

    def test_distribution_override_is_pinned_to_the_attested_fresh_output(self):
        redirected = self.root / 'redirected-dist'
        normal_runner = self.runner
        release = None
        def package_writer(args, log=None):
            if args[:2] == ['bash', 'Scripts/make-package.sh']:
                # Stand in only for the package producer's output path. No
                # image/app/build is fabricated; stop before a green receipt.
                self.calls.append(args)
                destination = Path(release.env['SHRIKE_DIST_DIR'])
                self.assertEqual(destination, self.root / 'dist')
                destination.mkdir(parents=True)
                (destination / 'Shrike-1.2.3.dmg').write_bytes(b'fresh ordinary harness bytes')
                raise RuntimeError('fresh pinned output boundary reached')
            return normal_runner(args, log)
        with patch.dict(os.environ, {'SHRIKE_DIST_DIR': str(redirected)}):
            release = gate.Gate(self.root, 'v1.2.3', package_writer, self.developer)
            with self.assertRaisesRegex(RuntimeError, 'fresh pinned output boundary'):
                release.execute()
        self.assertEqual((self.root / 'dist/Shrike-1.2.3.dmg').read_bytes(), b'fresh ordinary harness bytes')
        self.assertFalse(redirected.exists())
        self.assertFalse((self.root / 'build/release-gate/gate.json').exists())

    def test_redirected_distribution_cannot_attest_a_stale_root_artifact(self):
        stale = self.root / 'dist/Shrike-1.2.3.dmg'
        stale.parent.mkdir()
        stale.write_bytes(b'stale unrelated previous build bytes')
        redirected = self.root / 'redirected-dist'
        with patch.dict(os.environ, {'SHRIKE_DIST_DIR': str(redirected)}):
            release = gate.Gate(self.root, 'v1.2.3', self.runner, self.developer)
            with self.assertRaisesRegex(RuntimeError, 'versioned artifact already exists'):
                release.execute()
        self.assertEqual(release.env['SHRIKE_DIST_DIR'], str(self.root / 'dist'))
        self.assertEqual(stale.read_bytes(), b'stale unrelated previous build bytes')
        self.assertFalse((self.root / 'dist/Shrike.dmg').exists())
        self.assertFalse(redirected.exists())
        self.assert_no_package_or_publication()

    def test_missing_toolchain_invalidates_old_receipt(self):
        self.developer.rmdir()
        old = self.root / 'build/release-gate/gate.json'
        old.parent.mkdir(parents=True)
        old.write_text('previous success')
        with self.assertRaisesRegex(RuntimeError, 'intended Xcode missing'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_wrong_toolchain_blocks_tests(self):
        self.xcode_version = 'Xcode 26.6'
        with self.assertRaisesRegex(RuntimeError, 'wrong Xcode'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_missing_main_blocks(self):
        self.main_missing = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute()
        self.assert_no_package_or_publication()

    def test_tag_revision_mismatch_blocks(self):
        self.tag_sha = 'b' * 40
        with self.assertRaisesRegex(RuntimeError, 'tag commit'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_version_mismatch_blocks(self):
        (self.root / 'project.yml').write_text('MARKETING_VERSION: "1.2.4"\n')
        with self.assertRaisesRegex(RuntimeError, 'MARKETING_VERSION'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_dirty_source_blocks(self):
        self.dirty = ' M source.swift\0'
        with self.assertRaisesRegex(RuntimeError, 'source must be clean'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_untracked_swift_source_blocks_before_tests_or_package(self):
        self.dirty = '?? Packages/ShrikeKit/Sources/ShrikeCore/New File\nWith Newline.swift\0'
        with self.assertRaisesRegex(RuntimeError, 'untracked release build/test input'):
            self.execute()
        self.assert_no_package_or_publication()
        self.assertFalse(any(a[:3] == ['xcrun', 'swift', 'test'] for a in self.calls))

    def test_untracked_test_fixture_blocks_before_tests_or_package(self):
        self.dirty = '?? Packages/ShrikeKit/Tests/ShrikeCoreTests/Fixtures/new photo.png\0'
        with self.assertRaisesRegex(RuntimeError, 'untracked release build/test input'):
            self.execute()
        self.assert_no_package_or_publication()

    def test_untracked_private_audit_notes_do_not_block_release_inputs(self):
        # A newline containing an apparent package path remains part of the
        # private filename, rather than being interpreted as a second record.
        self.dirty = '?? private-notes/audit/QA notes\nPackages/looks-like-code.swift\0'
        with self.assertRaisesRegex(RuntimeError, 'package boundary reached'):
            self.execute()
        self.assertEqual(len([a for a in self.calls if a[:3] == ['xcrun', 'swift', 'test']]), 3)

    def test_untracked_input_added_after_gate_blocks_publication(self):
        self.receipt_fixture()
        self.dirty = '?? Scripts/new-gate-helper.py\0'
        with self.assertRaisesRegex(RuntimeError, 'untracked release build/test input'):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assertFalse(any(a[0] == 'gh' for a in self.calls))

    def test_real_git_status_preserves_spaces_newlines_and_private_notes(self):
        checkout = self.root / 'git-status-fixture'
        checkout.mkdir()
        subprocess.run(['git', 'init', '--quiet', str(checkout)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def git_runner(args):
            self.assertEqual(args, ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
            return subprocess.check_output(args, cwd=checkout, text=True)
        private = checkout / 'private-notes/audit/private notes\nwith newline.md'
        private.parent.mkdir(parents=True)
        private.write_text('private audit evidence')
        gate.assert_clean_release_inputs(git_runner)
        source = checkout / 'Packages/ShrikeKit/Sources/New File\nWith Newline.swift'
        source.parent.mkdir(parents=True)
        source.write_text('untracked test input')
        with self.assertRaisesRegex(RuntimeError, 'untracked release build/test input'):
            gate.assert_clean_release_inputs(git_runner)

    def test_mid_gate_revision_change_blocks_archive(self):
        normal_runner = self.runner
        def changed(args, log=None):
            value = normal_runner(args, log)
            if args[:3] == ['xcrun', 'swift', 'test']:
                self.head = 'b' * 40
            return value
        with self.assertRaisesRegex(RuntimeError, 'HEAD changed'):
            gate.Gate(self.root, 'v1.2.3', changed, self.developer).execute()
        self.assert_no_package_or_publication()

    def receipt_fixture(self):
        work = self.root / 'build/release-gate'
        work.mkdir(parents=True)
        dist = self.root / 'dist'
        dist.mkdir()
        artifact = dist / 'Shrike.dmg'
        artifact.write_bytes(b'ordinary harness bytes, never a disk image or app bundle')
        runs = []
        for attempt in (1, 2, 3):
            log = work / f'swift-test-{attempt}.log'
            log.write_text('offline harness fixture\n')
            runs.append({'run': attempt, 'status': 'passed', 'log_sha256': gate.digest(log)})
        package = work / 'release-package.log'
        package.write_text('offline package evidence fixture\n')
        (work / 'changes.md').write_text('Harness fixture only\n')
        data = {'schema': 1, 'signature_policy': 'ad-hoc; not notarized',
                'signature': 'Signature=adhoc', 'app_budget_bytes': 20_000_000,
                'app_bytes': 100, 'architectures': 'arm64 x86_64', 'commit': SHA, 'tag': 'v1.2.3', 'version': '1.2.3', 'release': 'passed',
                'xcode': gate.XCODE_VERSION, 'developer_dir': str(gate.XCODE),
                'swiftpm': runs, 'artifact_sha256': gate.digest(artifact),
                'package_log_sha256': gate.digest(package)}
        (dist / 'Shrike.dmg.sha256').write_text(f'{data["artifact_sha256"]}  Shrike.dmg\n')
        (dist / 'Shrike.provenance.json').write_text(json.dumps(data))
        (work / 'gate.json').write_text(json.dumps(data))
        return data

    def assert_no_release_mutation(self):
        self.assertFalse(any(a[:2] == ['gh', 'release'] for a in self.calls))
        self.assertTrue(all('--method' in a and 'GET' in a
                            for a in self.calls if a[:2] == ['gh', 'api']))

    def test_existing_published_version_cannot_change_remote_bytes(self):
        self.receipt_fixture()
        self.release_pages = [[{'tag_name': 'v1.2.3', 'draft': False}]]
        remote_asset = self.root / 'existing-release-asset'
        remote_asset.write_bytes(b'original published bytes')
        with self.assertRaisesRegex(RuntimeError, 'existing published release'):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assertEqual(remote_asset.read_bytes(), b'original published bytes')
        self.assert_no_release_mutation()

    def test_existing_draft_or_partial_version_cannot_change_remote_bytes(self):
        self.receipt_fixture()
        # Full first page exercises pagination: a draft beyond page one must
        # block before any mutation, even if its asset upload is incomplete.
        self.release_pages = [[{'tag_name': f'v0.0.{n}', 'draft': False} for n in range(100)],
                              [{'tag_name': 'v1.2.3', 'draft': True, 'assets': []}]]
        remote_asset = self.root / 'existing-draft-asset'
        remote_asset.write_bytes(b'original partial draft bytes')
        with self.assertRaisesRegex(RuntimeError, 'existing draft/partial release'):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assertEqual(remote_asset.read_bytes(), b'original partial draft bytes')
        self.assertTrue(any('page=2' in part for args in self.calls for part in args))
        self.assert_no_release_mutation()

    def test_network_or_auth_lookup_failure_blocks_create(self):
        self.receipt_fixture()
        for reason in ('network timeout', 'HTTP 401 Bad credentials', 'HTTP 403 Forbidden'):
            with self.subTest(reason=reason):
                self.calls.clear()
                self.lookup_failure = reason
                with self.assertRaises(subprocess.CalledProcessError):
                    publisher.publish(self.root, 'v1.2.3', self.runner)
                self.assert_no_release_mutation()

    def test_invalid_json_or_schema_blocks_create(self):
        self.receipt_fixture()
        for raw in ('{', 'null', '[]', '{"full_name":"voydapps/shrike","permissions":null}'):
            with self.subTest(raw=raw):
                self.calls.clear()
                self.raw_lookup = raw
                with self.assertRaises((RuntimeError, ValueError)):
                    publisher.publish(self.root, 'v1.2.3', self.runner)
                self.assert_no_release_mutation()

    def test_insufficient_draft_visibility_blocks_create(self):
        self.receipt_fixture()
        self.push_access = False
        with self.assertRaisesRegex(RuntimeError, 'authenticated push access'):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assert_no_release_mutation()

    def test_missing_explicit_token_blocks_create(self):
        self.receipt_fixture()
        with patch.dict(os.environ):
            os.environ.pop('GH_TOKEN', None)
            os.environ.pop('GITHUB_TOKEN', None)
            with self.assertRaisesRegex(RuntimeError, 'requires a GitHub token'):
                publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assert_no_release_mutation()

    def test_no_existing_release_reaches_one_create_boundary(self):
        self.receipt_fixture()
        publisher.publish(self.root, 'v1.2.3', self.runner)
        creates = [a for a in self.calls if a[:3] == ['gh', 'release', 'create']]
        self.assertEqual(len(creates), 1)
        self.assertIn('--verify-tag', creates[0])
        self.assertEqual(creates[0][-2:], ['--repo', 'voydapps/shrike'])
        self.assertNotIn('--clobber', creates[0])
        self.assertFalse(any(a[:3] in (['gh', 'release', 'upload'], ['gh', 'release', 'edit'],
                                      ['gh', 'release', 'delete']) for a in self.calls))

    def test_create_failure_never_retries_or_mutates_existing_assets(self):
        self.receipt_fixture()
        remote_asset = self.root / 'unrelated-existing-release-asset'
        remote_asset.write_bytes(b'unchanged older release bytes')
        normal_runner = self.runner
        def create_failure(args):
            if args[:3] == ['gh', 'release', 'create']:
                self.calls.append(args)
                raise subprocess.CalledProcessError(1, args, output='new release create/upload failure')
            return normal_runner(args)
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish(self.root, 'v1.2.3', create_failure)
        self.assertEqual(remote_asset.read_bytes(), b'unchanged older release bytes')
        self.assertEqual(len([a for a in self.calls if a[:2] == ['gh', 'release']]), 1)

    def test_changed_artifact_blocks_publication(self):
        self.receipt_fixture()
        (self.root / 'dist/Shrike.dmg').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'artifact changed'):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assertFalse(any(a[0] == 'gh' for a in self.calls))

    def test_missing_green_receipt_blocks_publication(self):
        with self.assertRaises(FileNotFoundError):
            publisher.publish(self.root, 'v1.2.3', self.runner)
        self.assertFalse(any(a[0] == 'gh' for a in self.calls))

    def test_workflow_enforces_gate_before_publish(self):
        workflow = (SCRIPTS.parent / '.github/workflows/release.yml').read_text()
        self.assertLess(workflow.index('python3 Scripts/release-gate.py'),
                        workflow.index('python3 Scripts/publish-release.py'))
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('--clobber', workflow)


if __name__ == '__main__':
    unittest.main(verbosity=2)
