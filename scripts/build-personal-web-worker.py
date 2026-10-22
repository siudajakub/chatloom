#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compile a reproducible current-source worker; optionally publish after backup.

Run only in the coordinator's sequential Dart/Flutter queue. No pub resolution,
browser access, deployment or archive worker copying is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse


FLAGS = ['-O2', '--no-source-maps']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(deps, root, sdk_root):
    paths = {root / 'pubspec.lock', root / '.dart_tool/package_config.json'}
    for line in deps.read_text().splitlines():
        uri = urlparse(line)
        if uri.netloc or uri.query or uri.fragment:
            raise ValueError('Unexpected dependency URI')
        decoded = unquote(uri.path)
        if uri.scheme == 'org-dartlang-sdk':
            path = (sdk_root / decoded.lstrip('/')).resolve()
            if not path.is_relative_to(sdk_root) or not decoded.startswith('/lib/'):
                raise ValueError('Unexpected SDK dependency URI')
        elif uri.scheme in ('file', ''):
            path = Path(decoded)
            if not path.is_absolute():
                path = root / path
        else:
            raise ValueError('Unexpected dependency URI')
        # Every input must map to a real file; unknown URIs are never skipped.
        if not path.is_file():
            raise ValueError('Dependency source is unavailable')
        paths.add(path.resolve())
    return [{'uri': p.resolve().as_uri(), 'sha256': sha(p)} for p in sorted(paths)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--artifact-dir', type=Path, required=True, help='New directory; existing evidence is never overwritten')
    parser.add_argument('--publish', action='store_true', help='Backup current ignored worker files, then replace only generated JS/deps/manifest')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dart = args.dart.absolute()
    if not dart.is_file() or not os.access(dart, os.X_OK):
        parser.error('Real Dart executable is unavailable')
    # Accept Flutter's bin/dart launcher and the SDK's actual bin/dart.
    sdk_candidates = [dart.parent / 'cache/dart-sdk', dart.resolve().parent.parent]
    sdk_root = next((p.resolve() for p in sdk_candidates
                     if (p / 'lib/libraries.json').is_file() and (p / 'bin/dart').is_file()), None)
    if sdk_root is None:
        parser.error('Cannot resolve the actual Dart SDK source root')
    artifact = args.artifact_dir.absolute()
    artifact.mkdir(parents=True, exist_ok=False)
    target = artifact / 'native_executor.js'
    deps = artifact / 'native_executor.js.deps'
    command = [str(dart), 'compile', 'js', str(root / 'web/native_executor.dart'),
               *FLAGS, '-o', str(target)]
    version = subprocess.check_output([str(dart), '--version'], text=True, stderr=subprocess.STDOUT).strip()
    with (artifact / 'compile.log').open('xb') as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
        before = inputs(deps, root, sdk_root)
        first = sha(target)
        compiler_before = sha(dart)
        # The first pass supplies the compiler's exact dependency list. The
        # second establishes that unchanged real inputs produce identical JS.
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
    after = inputs(deps, root, sdk_root)
    if before != after or compiler_before != sha(dart) or first != sha(target):
        raise SystemExit('REPRODUCIBILITY_CHECK_FAILED: generated files preserved in artifact directory')
    manifest = {
        'schema': 1, 'kind': 'personal-native-executor',
        'flags': FLAGS, 'dart_version': version,
        'compiler': {'uri': dart.as_uri(), 'sha256': compiler_before},
        'entrypoint': (root / 'web/native_executor.dart').as_uri(),
        'worker_sha256': sha(target), 'inputs': after,
        'matching_compilations': 2,
    }
    manifest_path = artifact / 'native_executor.js.personal-manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    if args.publish:
        backup = artifact / 'previous-worker'
        backup.mkdir()
        for previous in (root / 'web').glob('native_executor.js*'):
            if previous.is_symlink() or not previous.is_file():
                raise SystemExit('WORKER_BACKUP_REFUSED: expected regular generated files')
            shutil.copy2(previous, backup / previous.name)
        for generated in [target, deps, manifest_path]:
            destination = root / 'web' / generated.name
            temporary = destination.with_name('.' + destination.name + '.personal-new')
            with temporary.open('xb') as output:
                output.write(generated.read_bytes())
            os.replace(temporary, destination)
    print(json.dumps({'worker': 'PASS', 'worker_sha256': manifest['worker_sha256'],
                      'source_inputs': len(after), 'matching_compilations': 2,
                      'published': args.publish, 'account_E2EE_runtime': 'NOT RUN'}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
