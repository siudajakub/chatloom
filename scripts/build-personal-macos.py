#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build an ad-hoc signed private macOS app; never install or use an account."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke-test', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS and full Xcode are required; use Personal macOS Actions')
    run('xcodebuild', '-version')
    if shutil.disk_usage(ROOT).free < 10 * 1024**3:
        parser.error('At least 10 GiB free build space is required')

    config = ROOT / 'build' / 'personal-macos-signing.xcconfig'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('CODE_SIGN_IDENTITY = -\nCODE_SIGN_STYLE = Manual\n'
                      'DEVELOPMENT_TEAM =\nPROVISIONING_PROFILE_SPECIFIER =\n')
    env = {**os.environ, 'XCODE_XCCONFIG_FILE': str(config)}
    # An empty access-group array in the inherited template is invalid for
    # ad-hoc signing. Preserve all other sandbox entitlements and restore files.
    entitlements = [ROOT / 'macos/Runner' / name for name in
                    ('DebugProfile.entitlements', 'Release.entitlements')]
    originals = {path: path.read_bytes() for path in entitlements}
    try:
        for path in entitlements:
            value = plistlib.loads(originals[path])
            if value.get('keychain-access-groups') == []:
                del value['keychain-access-groups']
            path.write_bytes(plistlib.dumps(value))
        if args.smoke_test:
            run('flutter', 'test', 'integration_test/macos_smoke_test.dart',
                '-d', 'macos', env=env)
            revision = run('git', 'rev-parse', 'HEAD', capture_output=True,
                           text=True).stdout.strip()
            (ROOT / 'build/macos-smoke-result.json').write_text(json.dumps({
                'revision': revision, 'status': 'PASS',
                'configuration': 'debug',
                'checks': ['vodozemac', 'Keychain', 'SQLCipher restart',
                           'SQLCipher wrong-key preservation',
                           'native Opus/CAF audio decode', 'native H.264/AAC video decode'],
            }) + '\n')
            return
        # Keep pub enabled to regenerate the real release plugin registrant.
        run('flutter', 'build', 'macos', '--release', env=env)
    finally:
        for path, content in originals.items():
            path.write_bytes(content)

    bundle = ROOT / 'build/macos/Build/Products/Release/Personal Chat.app'
    if not bundle.is_dir():
        raise SystemExit('Expected Personal Chat.app was not produced')
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'pl.personal.chat':
        raise SystemExit('Unexpected bundle identifier')
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    run('codesign', '--verify', '--deep', '--strict', str(bundle))
    architectures = run('lipo', '-archs', str(executable), capture_output=True,
                        text=True).stdout.strip().split()
    # A universal launcher with an arm64-only native plugin is not an Intel app.
    # Inspect every embedded Mach-O image, including native-hook dylibs.
    macho_magic = {bytes.fromhex(value) for value in
                   ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    native_images = 0
    for path in bundle.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as handle:
            magic = handle.read(4)
        if magic in macho_magic:
            run('lipo', str(path), '-verify_arch', *architectures,
                capture_output=True)
            native_images += 1
    output = ROOT / 'artifacts/macos'
    output.mkdir(parents=True, exist_ok=True)
    revision = run('git', 'rev-parse', 'HEAD', capture_output=True,
                   text=True).stdout.strip()
    archive = output / f'ChatLoom-macos-{revision[:12]}.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(archive))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = {
        'revision': revision, 'bundle_id': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'architectures': architectures,
        'archive': archive.name, 'sha256': digest, 'signing': 'ad-hoc',
        'notarized': False, 'system_notifications': False,
        'minimum_macos': info.get('LSMinimumSystemVersion'),
        'verified_native_images': native_images,
        'account_acceptance': 'NOT RUN',
    }
    smoke = ROOT / 'build/macos-smoke-result.json'
    manifest['native_smoke'] = {'status': 'NOT RUN'}
    if smoke.is_file():
        result = json.loads(smoke.read_text())
        if result.get('revision') == revision:
            manifest['native_smoke'] = result
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
