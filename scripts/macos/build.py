#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build a private macOS app; never install or use an account.

Release builds are ad-hoc signed unless --sign-identity (or
CHATLOOM_MACOS_SIGN_IDENTITY) names a local code-signing certificate. A
stable certificate keeps the designated requirement unchanged across builds,
so Keychain "Always Allow" decisions survive app updates.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def disk_image(bundle, path, identity):
    """Package the app with an Applications link for drag-and-drop install."""
    staging = ROOT / 'build/macos-dmg'
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    run('ditto', str(bundle), str(staging / bundle.name))
    (staging / 'Applications').symlink_to('/Applications')
    run('hdiutil', 'create', '-volname', 'ChatLoom', '-srcfolder', str(staging),
        '-fs', 'HFS+', '-format', 'UDZO', '-ov', str(path))
    shutil.rmtree(staging)
    if identity:
        run('codesign', '--force', '--sign', identity, str(path))
    run('hdiutil', 'verify', str(path), capture_output=True)


def resign(bundle, identity):
    """Replace the ad-hoc signature, keeping identifier and entitlements."""
    identities = run('security', 'find-identity', '-p', 'codesigning',
                     capture_output=True, text=True).stdout
    if f'"{identity}"' not in identities:
        raise SystemExit(f'Code-signing identity "{identity}" was not found in '
                         'the Keychain; see docs/macos-client.md')
    run('codesign', '--force', '--deep', '--sign', identity,
        '--preserve-metadata=identifier,entitlements,flags,runtime', str(bundle))
    requirement = run('codesign', '-d', '-r-', str(bundle), capture_output=True,
                      text=True)
    designated = requirement.stdout + requirement.stderr
    # An ad-hoc designated requirement pins the cdhash, which changes per build.
    if 'designated =>' not in designated or 'cdhash' in designated:
        raise SystemExit('The signature has no stable designated requirement')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke-test', action='store_true')
    parser.add_argument('--sign-identity',
                        default=os.environ.get('CHATLOOM_MACOS_SIGN_IDENTITY'),
                        help='code-signing certificate name for the release app')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS and full Xcode are required; use Personal macOS Actions')
    run('xcodebuild', '-version')
    if shutil.disk_usage(ROOT).free < 10 * 1024**3:
        parser.error('At least 10 GiB free build space is required')

    config = ROOT / 'build' / 'personal-macos-signing.xcconfig'
    config.parent.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    if architecture != 'arm64':
        parser.error('ChatLoom for macOS is Apple Silicon only')
    config.write_text('CODE_SIGN_IDENTITY = -\nCODE_SIGN_STYLE = Manual\n'
                      'DEVELOPMENT_TEAM =\nPROVISIONING_PROFILE_SPECIFIER =\n'
                      'ARCHS = arm64\nEXCLUDED_ARCHS = x86_64\n'
                      'ONLY_ACTIVE_ARCH = YES\n')
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
            run('flutter', 'test', 'integration_test/macos/smoke_test.dart',
                '-d', 'macos', env=env)
            revision = run('git', 'rev-parse', 'HEAD', capture_output=True,
                           text=True).stdout.strip()
            (ROOT / 'build/macos-smoke-result.json').write_text(json.dumps({
                'revision': revision, 'status': 'PASS',
                'configuration': 'debug',
                'checks': ['P-256 native agreement', 'vodozemac', 'Keychain', 'SQLCipher restart',
                           'SQLCipher wrong-key preservation',
                           'native Opus/CAF audio decode', 'native H.264/AAC video decode'],
            }) + '\n')
            return
        # Keep pub enabled to regenerate the real release plugin registrant.
        run('flutter', 'build', 'macos', '--release', env=env)
    finally:
        for path, content in originals.items():
            path.write_bytes(content)

    bundle = ROOT / 'build/macos/Build/Products/Release/ChatLoom.app'
    if not bundle.is_dir():
        raise SystemExit('Expected ChatLoom.app was not produced')
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'pl.personal.chat':
        raise SystemExit('Unexpected bundle identifier')
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    if args.sign_identity:
        resign(bundle, args.sign_identity)
    run('codesign', '--verify', '--deep', '--strict', str(bundle))
    architectures = run('lipo', '-archs', str(executable), capture_output=True,
                        text=True).stdout.strip().split()
    if architectures != [architecture]:
        raise SystemExit(f'Expected a native {architecture} executable, got {architectures}')
    # Every embedded Mach-O image, native-hook dylibs included, must be arm64.
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
    archive = output / f'ChatLoom-macos-{architecture}-{revision[:12]}.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(bundle), str(archive))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    image = archive.with_suffix('.dmg')
    disk_image(bundle, image, args.sign_identity)
    image_digest = hashlib.sha256(image.read_bytes()).hexdigest()
    manifest = {
        'revision': revision, 'bundle_id': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'architectures': architectures,
        'archive': archive.name, 'sha256': digest,
        'disk_image': image.name, 'disk_image_sha256': image_digest,
        'signing': args.sign_identity or 'ad-hoc',
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
    (output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n'
                                       f'{image_digest}  {image.name}\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
