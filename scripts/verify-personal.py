#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Reproducible synthetic checks without Flutter's unrelated native hooks."""
import argparse
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--dart', default='dart')
parser.add_argument('--design-strict', action='store_true',
                    help='fail when raw design values grow above scripts/design-baseline.json')
args = parser.parse_args()

def run(argv, cwd):
    subprocess.run(argv, cwd=cwd, check=True)

# Design-system ratchet (DESIGN.md). Report mode until the baseline is paid down.
run([sys.executable, str(root / 'scripts/check-design-tokens.py'), *(['--strict'] if args.design_strict else [])], root)

run([args.dart, 'test'], root / 'packages/personal_core')
with tempfile.TemporaryDirectory(prefix='personal_checks_') as temporary:
    sandbox = pathlib.Path(temporary)
    for folder in ['lib/personal/storage', 'lib/personal/media', 'test/personal', 'packages/personal_core/lib']:
        shutil.copytree(root / folder, sandbox / folder)
    (sandbox / 'lib/personal/immediate_outbox.dart').write_bytes((root / 'lib/personal/immediate_outbox.dart').read_bytes())
    (sandbox / 'lib/personal/privacy_transport.dart').write_bytes((root / 'lib/personal/privacy_transport.dart').read_bytes())
    (sandbox / 'lib/personal/round_video').mkdir()
    (sandbox / 'lib/personal/round_video/telegram_media_protocol.dart').write_bytes((root / 'lib/personal/round_video/telegram_media_protocol.dart').read_bytes())
    (sandbox / 'packages/personal_core/pubspec.yaml').write_bytes((root / 'packages/personal_core/pubspec.yaml').read_bytes())
    manifest = """name: personal_checks
publish_to: none
environment:
  sdk: '>=3.11.1 <4.0.0'
dependencies:
  personal_core:
    path: packages/personal_core
  crypto: ^3.0.7
  http: ^1.6.0
  sqflite_common_ffi: ^2.4.2
  sqlite3: ^3.0.0
hooks:
  user_defines:
    sqlite3:
      source: SOURCE
"""
    for source, tests in [('sqlite3', ['storage/missing_cipher_test.dart', 'storage/pending_missing_cipher_test.dart']), ('sqlcipher', ['storage/storage_policy_test.dart', 'storage/sql_cipher_store_test.dart', 'storage/pending_media_store_test.dart', 'integration/immediate_outbox_test.dart', 'integration/immediate_media_outbox_test.dart', 'integration/privacy_transport_test.dart', 'integration/round_privacy_transport_test.dart', 'capabilities/bridge_capabilities_test.dart', 'capabilities/round_video_test.dart'])]:
        (sandbox / 'pubspec.yaml').write_text(manifest.replace('SOURCE', source))
        run([args.dart, 'pub', 'get'], sandbox)
        for test in tests:
            run([args.dart, 'run', 'test/personal/' + test], sandbox)
    for filename in ('media_access.dart', 'private_directories_native.dart', 'private_directories_stub.dart'):
        media_source = pathlib.Path('lib/personal/media') / filename
        assert hashlib.sha256((sandbox / media_source).read_bytes()).digest() == hashlib.sha256((root / media_source).read_bytes()).digest(), 'Media harness must use unmodified production source'
    regression = 'test/personal/storage/media_permissions_test.dart'
    if os.name != 'posix':
        raise RuntimeError('Native media permission regressions require a POSIX host')
    for mask in (0o022, 0o000, 0o077):
        print(f'Media source regression: process umask {mask:04o}', flush=True)
        # subprocess umask applies only in the child before Dart starts.
        subprocess.run([args.dart, regression], cwd=sandbox, check=True, umask=mask)
    failed_root = sandbox / 'permission_failure_root'
    failed_root.mkdir(mode=0o700)
    failed_root.chmod(0o700)
    subprocess.run([args.dart, regression, 'failure', str(failed_root)],
                   cwd=sandbox, check=True, umask=0o777)
print('PASS synthetic personal client suites; no live accounts or provider requests')
