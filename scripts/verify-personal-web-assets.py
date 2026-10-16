#!/usr/bin/env python3
"""Verify pinned web binaries; optionally restore missing files from a local archive.

No downloads, dependency resolution, account access or build are performed. Existing
files (including mismatches) are never replaced. Worker verification requires a
the current source graph manifest produced by build-personal-web-worker.py.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tarfile
from urllib.parse import unquote, urlparse


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(root, lock, archive=None, restore=False, worker_manifest=None):
    root = root.resolve()
    errors = []
    results = []
    lockfile = (root / 'pubspec.lock').read_text()
    for package, version in lock['packages'].items():
        match = re.search(r'^  ' + re.escape(package) + r':\n(.*?)(?=^  \S|\Z)', lockfile, re.M | re.S)
        if not match or not re.search(r'^    version: "' + re.escape(version) + r'"$', match[1], re.M):
            errors.append('PACKAGE_VERSION_MISMATCH:' + package)
    if errors:
        return {'assets': [], 'errors': errors, 'worker': 'NOT RUN'}, False

    # Validate every selected member before making even missing-only writes.
    payloads = {}
    if archive is not None:
        if digest(archive.read_bytes()) != lock['archive']['sha256']:
            return {'assets': [], 'errors': ['ARCHIVE_HASH_MISMATCH'], 'worker': 'NOT RUN'}, False
        with tarfile.open(archive, 'r:gz') as bundle:
            for asset in lock['assets']:
                member = bundle.getmember(asset['member'])
                if not member.isfile() or member.size > 8 * 1024 * 1024:
                    raise ValueError('INVALID_ARCHIVE_MEMBER')
                payload = bundle.extractfile(member).read()
                if digest(payload) != asset['sha256']:
                    raise ValueError('MEMBER_HASH_MISMATCH')
                payloads[asset['path']] = payload

    for asset in lock['assets']:
        target = root / asset['path']
        # Refuse symlinks so restoration cannot escape the chosen checkout.
        if any(path.is_symlink() for path in [target, *target.parents] if path != root.parent):
            errors.append('SYMLINK_REFUSED:' + asset['path'])
            continue
        if not target.exists() and restore:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as output:
                output.write(payloads[asset['path']])
        state = 'MISSING' if not target.is_file() else (
            'PASS' if digest(target.read_bytes()) == asset['sha256'] else 'HASH_MISMATCH')
        results.append({'path': asset['path'], 'status': state})
        if state != 'PASS':
            errors.append(state + ':' + asset['path'])

    worker = root / 'web/native_executor.js'
    worker_result = 'NOT RUN: current-source correspondence requires build-personal-web-worker.py manifest'
    manifest_path = worker_manifest or root / 'web/native_executor.js.personal-manifest.json'
    if not worker.is_file():
        worker_result = 'MISSING'
        errors.append('WORKER_MISSING')
    elif manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text())
        valid = (manifest.get('schema') == 1
                 and manifest.get('kind') == 'personal-native-executor'
                 and manifest.get('flags') == ['-O2', '--no-source-maps']
                 and manifest.get('matching_compilations') == 2
                 and manifest.get('entrypoint') == (root / 'web/native_executor.dart').as_uri()
                 and manifest.get('worker_sha256') == digest(worker.read_bytes()))
        records = manifest.get('inputs', [])
        required = {(root / 'web/native_executor.dart').as_uri(),
                    (root / 'pubspec.lock').as_uri(),
                    (root / '.dart_tool/package_config.json').as_uri()}
        valid = valid and required.issubset({item['uri'] for item in records})
        for item in [manifest['compiler'], *records]:
            uri = urlparse(item['uri'])
            if uri.scheme != 'file' or uri.netloc:
                valid = False
                continue
            source = Path(unquote(uri.path))
            valid = valid and source.is_file() and digest(source.read_bytes()) == item['sha256']
        worker_result = 'PASS' if valid else 'SOURCE_OR_OUTPUT_MISMATCH'
        if not valid:
            errors.append('WORKER_MANIFEST_MISMATCH')
    return {
        'assets': results, 'errors': errors, 'worker': worker_result,
        'worker_sha256': digest(worker.read_bytes()) if worker.is_file() else None,
        'account_E2EE_runtime': 'NOT RUN',
    }, not errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--archive', type=Path, help='Local upstream archive; SHA256 must match the lock')
    parser.add_argument('--restore-missing', action='store_true', help='Only create absent pinned binary files')
    parser.add_argument('--worker-manifest', type=Path, help='Manifest generated by build-personal-web-worker.py; defaults beside current worker')
    args = parser.parse_args()
    if args.restore_missing and args.archive is None:
        parser.error('--restore-missing requires --archive')
    lock = json.loads(Path(__file__).with_name('personal-web-assets.lock.json').read_text())
    try:
        result, passed = verify(args.root.resolve(), lock, args.archive, args.restore_missing, args.worker_manifest)
    except (OSError, KeyError, ValueError, tarfile.TarError):
        # File paths supplied by callers are not dumped as part of exception text.
        result, passed = {'errors': ['ASSET_INPUT_ERROR']}, False
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
