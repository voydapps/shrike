#!/usr/bin/env python3
"""Publish only a passing exact-commit artifact. Existing releases are immutable.

Authenticated paginated preflight rejects every existing release for the tag,
including drafts. The only mutation command creates a new release; the CLI
may create a draft, upload its assets, publish it, or clean up its new draft.
That multi-request process is not an atomic all-assets operation.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
from importlib.util import spec_from_file_location, module_from_spec

# This CLI is run immediately before a clean-input check. Loading the release
# gate from source must not leave an untracked .pyc in the checkout.
sys.dont_write_bytecode = True

spec = spec_from_file_location('release_gate', Path(__file__).with_name('release-gate.py'))
gate = module_from_spec(spec)
spec.loader.exec_module(gate)


def require_no_existing_release(repository, tag, run):
    """Read every release page using an authenticated principal with push access.

    GitHub lists drafts only to principals with push access. A successful public
    unauthenticated listing cannot establish absence of drafts, so both explicit
    token presence and the authenticated repository permission check are required.
    Every lookup, permission, JSON or schema error propagates as a hard failure.
    """
    if not (os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')):
        raise RuntimeError('authenticated release lookup requires a GitHub token')
    if not repository or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise RuntimeError('GITHUB_REPOSITORY must identify the publication repository')

    def read(endpoint):
        return json.loads(run(['gh', 'api', '--method', 'GET', endpoint,
                              '-H', 'Accept: application/vnd.github+json',
                              '-H', 'X-GitHub-Api-Version: 2022-11-28']))

    info = read(f'repos/{repository}')
    if (not isinstance(info, dict)
            or str(info.get('full_name', '')).lower() != repository.lower()
            or not isinstance(info.get('permissions'), dict)
            or info['permissions'].get('push') is not True):
        raise RuntimeError('cannot establish authenticated push access needed to see drafts')
    page = 1
    while True:
        releases = read(f'repos/{repository}/releases?per_page=100&page={page}')
        if not isinstance(releases, list) or len(releases) > 100:
            raise RuntimeError('invalid release-list response')
        for release in releases:
            if (not isinstance(release, dict) or not isinstance(release.get('tag_name'), str)
                    or not isinstance(release.get('draft'), bool)):
                raise RuntimeError('invalid release-list entry')
            if release['tag_name'] == tag:
                kind = 'draft/partial' if release['draft'] else 'published'
                raise RuntimeError(f'existing {kind} release for {tag}; version is immutable')
        if len(releases) < 100:
            return
        page += 1


def publish(root, tag, run=None):
    root = Path(root)
    def command(args):
        output = subprocess.check_output(args, cwd=root, stderr=subprocess.STDOUT, text=True)
        return output if args[:2] == ['git', 'status'] else output.strip()
    run = run or command
    data = json.loads((root / 'build/release-gate/gate.json').read_text())
    sha = run(['git', 'rev-parse', 'HEAD'])
    if (data['commit'] != sha or data['tag'] != tag or
            run(['git', 'rev-parse', f'refs/tags/{tag}^{{commit}}']) != sha):
        raise RuntimeError('gate/tag/HEAD revision mismatch')
    run(['git', 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main'])
    gate.assert_clean_release_inputs(run)
    if (data['release'] != 'passed' or [r['run'] for r in data['swiftpm']] != [1, 2, 3]
            or any(r['status'] != 'passed' for r in data['swiftpm'])):
        raise RuntimeError('three passing full tests and Release archive required')
    if (data.get('schema') != 1 or data.get('signature_policy') != 'ad-hoc; not notarized'
            or 'Signature=adhoc' not in data.get('signature', '')
            or data.get('app_budget_bytes') != 20_000_000
            or not 0 < data.get('app_bytes', 0) <= 20_000_000
            or set(data.get('architectures', '').split()) != {'arm64', 'x86_64'}):
        raise RuntimeError('missing ad-hoc signature, universal architecture or size evidence')
    if data['xcode'].splitlines()[0] != gate.XCODE_VERSION or data['developer_dir'] != str(gate.XCODE):
        raise RuntimeError('receipt has wrong toolchain')
    for result in data['swiftpm']:
        if gate.digest(root / f'build/release-gate/swift-test-{result["run"]}.log') != result['log_sha256']:
            raise RuntimeError('test evidence changed after gate')
    if gate.digest(root / 'build/release-gate/release-package.log') != data['package_log_sha256']:
        raise RuntimeError('Release evidence changed after gate')
    if gate.digest(root / 'dist/Shrike.dmg') != data['artifact_sha256']:
        raise RuntimeError('artifact changed after gate')
    expected_checksum = f'{data["artifact_sha256"]}  Shrike.dmg\n'
    if (root / 'dist/Shrike.dmg.sha256').read_text() != expected_checksum:
        raise RuntimeError('checksum changed after gate')
    if json.loads((root / 'dist/Shrike.provenance.json').read_text()) != data:
        raise RuntimeError('public provenance changed after gate')
    changes = (root / 'build/release-gate/changes.md').read_text()
    notes = root / 'build/release-gate/notes.md'
    notes.write_text(f'Shrike {data["version"]} for macOS 14 or newer (Apple silicon and Intel).\n\n'
                     f'## What changed\n\n{changes}\n\n## Download\n\n'
                     'Download **Shrike.dmg**, open it, and drag Shrike to Applications.\n'
                     'This app is ad-hoc signed and is not notarized. Read the first-launch '
                     'instructions inside the disk image or in the README.\n\n'
                     f'SHA-256 of Shrike.dmg: `{data["artifact_sha256"]}`\n\n'
                     f'Exact source commit: `{sha}`. Three full SwiftPM runs and Release archive passed. '
                     'See Shrike.provenance.json for toolchain, signature, size and runtime limits.\n')
    repository = os.environ.get('GITHUB_REPOSITORY')
    require_no_existing_release(repository, tag, run)
    # Workflow concurrency serializes this workflow; gh additionally checks for
    # an existing published tag. External publishers can still race this read.
    # gh creates a new draft, uploads, then publishes via separate requests.
    # Never resume, append to, overwrite or delete any pre-existing release.
    run(['gh', 'release', 'create', tag, 'dist/Shrike.dmg', 'dist/Shrike.dmg.sha256',
         'dist/Shrike.provenance.json', '--title', f'Shrike {data["version"]}',
         '--notes-file', str(notes), '--verify-tag', '--repo', repository])


if __name__ == '__main__':
    try:
        publish(Path(__file__).resolve().parent.parent, sys.argv[1])
    except (RuntimeError, subprocess.CalledProcessError, OSError, KeyError, IndexError, ValueError) as error:
        sys.exit(f'Publication blocked: {error}')
