#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Coordinator-only, isolated tests of copied *production* round Dart sources.

Run sequentially, outside any other Flutter/pub/analyze/build operation:
  rtk python3 scripts/verify-round-widgets.py --flutter \
    $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter

The managed harness is client/build/round_widget_harness. It has the real
material_ui/video_player versions and reachable hosted dependency versions from
the root lock/config; it never imports the Matrix/app graph, webcrypto or sqlite.
This proves widget/controller fixtures only. It does not run Camera2, native
codec output, Keystore, live permissions, accounts or Telegram delivery.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / 'build/round_widget_harness'
MARKER = '.personal-round-widget-harness'
MARKER_CONTENT = 'managed-by:scripts/verify-round-widgets.py:v1\n'

SOURCES = (
    'lib/ui/notion/notion.dart',
    'lib/ui/notion/notion_theme.dart',
    'lib/ui/notion/details_contract.dart',
    'lib/ui/notion/initial_avatar.dart',
    'assets/notion/fonts/Roboto-Regular.ttf',
    'assets/notion/fonts/Roboto-Medium.ttf',
    'assets/notion/fonts/Roboto-Bold.ttf',
    'assets/notion/fonts/Roboto_LICENSE.txt',
    'lib/personal/media/media_access.dart',
    'lib/personal/media/private_directories_native.dart',
    'lib/personal/media/private_directories_stub.dart',
    'lib/personal/storage/storage_failure.dart',
    'lib/personal/round_video/round_capture_backend.dart',
    'lib/personal/round_video/round_capture_controller.dart',
    'lib/personal/round_video/round_media_preparer.dart',
    'lib/personal/round_video/round_playback_coordinator.dart',
    'lib/personal/round_video/round_record_button.dart',
    'lib/pages/chat/conversation_motion.dart',
    'lib/pages/chat/round_video_recorder.dart',
    'lib/pages/chat/events/round_video_view.dart',
)
def relative_closure(*entries):
    """Entry files plus their relative (non-package) imports/exports, so
    presentation helpers they pull in (Notion tokens, glass, motion) stay
    copied even when the design system grows a file."""
    seen, queue = [], list(entries)
    while queue:
        relative = queue.pop(0)
        if relative in seen:
            continue
        seen.append(relative)
        path = ROOT / relative
        for target in re.findall(r"^(?:import|export)\s+'([^':]+\.dart)'", path.read_text(), re.M):
            resolved = (path.parent / target).resolve().relative_to(ROOT.resolve()).as_posix()
            queue.append(resolved)
    return tuple(seen)


# Notion files/conversation bubble reached through relative imports.
SOURCES += tuple(
    path for path in relative_closure(
        'lib/ui/notion/notion.dart', 'lib/ui/notion/notion_theme.dart',
        'lib/pages/chat/events/round_video_view.dart',
    ) if path not in SOURCES
)
TESTS = (
    'test/personal/round_video/round_capture_controller_test.dart',
    'test/personal/round_video/round_video_recorder_controls_test.dart',
    'test/personal/round_video/round_playback_coordinator_test.dart',
    'test/personal/round_video/round_video_view_test.dart',
    'test/personal/round_video/round_record_button_test.dart',
)


def hosted_versions():
    """Read root lock entries without requiring a system YAML installation."""
    lock = (ROOT / 'pubspec.lock').read_text()
    result = {}
    for match in re.finditer(r'^  ([a-zA-Z0-9_]+):\n(.*?)(?=^  [a-zA-Z0-9_]+:|^sdks:|\Z)', lock, re.M | re.S):
        name, block = match.groups()
        if not re.search(r'^    source: hosted\s*$', block, re.M):
            continue
        version = re.search(r'^    version: ["\']?([^\s"\']+)', block, re.M)
        if version:
            result[name] = version.group(1)
    return result


def package_roots():
    config_path = ROOT / '.dart_tool/package_config.json'
    if not config_path.is_file():
        raise RuntimeError('Root package_config is missing; coordinator must run the existing app pub-get first.')
    config = json.loads(config_path.read_text())
    result = {}
    for package in config['packages']:
        uri = urljoin(config_path.as_uri(), package['rootUri'])
        parsed = urlparse(uri)
        if parsed.scheme != 'file':
            raise RuntimeError('Unsupported package URI')
        result[package['name']] = Path(unquote(parsed.path))
    return result


def dependencies(pubspec):
    """Pub's direct dependencies are simple two-space map keys, not dev deps."""
    section = re.search(r'^dependencies:\s*\n(.*?)(?=^[^\s#]|\Z)', pubspec, re.M | re.S)
    return re.findall(r'^  ([a-zA-Z0-9_]+):', section.group(1), re.M) if section else []


def dependency_closure(roots, versions):
    selected = set()
    visited = set()
    queue = ['material_ui', 'cupertino_ui', 'video_player', 'flutter_lints', 'flutter', 'flutter_test']
    while queue:
        name = queue.pop()
        if name in visited:
            continue
        visited.add(name)
        package_root = roots.get(name)
        if package_root is None or not (package_root / 'pubspec.yaml').is_file():
            raise RuntimeError(f'Reachable package {name} is absent from the root package_config')
        spec = (package_root / 'pubspec.yaml').read_text()
        if name in versions:
            actual = re.search(r'^version:\s*["\']?([^\s"\']+)', spec, re.M)
            if actual is None or actual.group(1) != versions[name]:
                raise RuntimeError(f'Root package_config and lock version disagree for {name}')
            selected.add(name)
        queue.extend(dependencies(spec))
    forbidden = selected.intersection({'webcrypto', 'sqlite3', 'matrix', 'flutter_vodozemac', 'native_imaging'})
    if forbidden:
        raise RuntimeError(f'Unexpected broad app/native graph in widget harness: {sorted(forbidden)}')
    return {name: versions[name] for name in sorted(selected)}


def checked_write(relative, content):
    target = HARNESS / relative
    # Do not traverse symlinks even inside a previously marked harness.
    cursor = target
    while cursor != HARNESS.parent:
        if cursor.is_symlink():
            raise RuntimeError(f'Managed harness contains a symlink at {cursor.name}')
        cursor = cursor.parent
    target.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        target.write_bytes(content)
    else:
        target.write_text(content)


def prepare(flutter):
    versions = hosted_versions()
    roots = package_roots()
    pinned = dependency_closure(roots, versions)
    for name in ['material_ui', 'cupertino_ui', 'video_player', 'flutter_lints']:
        if name not in pinned:
            raise RuntimeError(f'Missing locked hosted version for {name}')
    if HARNESS.is_symlink():
        raise RuntimeError('Refusing a symlinked harness directory')
    if HARNESS.exists():
        marker = HARNESS / MARKER
        if marker.is_symlink() or not marker.is_file() or marker.read_text() != MARKER_CONTENT:
            raise RuntimeError('Existing harness is not marked as managed; no files were overwritten')
    else:
        HARNESS.mkdir(parents=True)
        (HARNESS / MARKER).write_text(MARKER_CONTENT)
    manifest = {}
    for relative in SOURCES + TESTS:
        source = ROOT / relative
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f'Expected production source/test missing or symlinked: {relative}')
        data = source.read_bytes()
        checked_write(relative, data)
        manifest[relative] = hashlib.sha256(data).hexdigest()
    sdk_fonts = Path(flutter).resolve().parents[1] / 'bin/cache/artifacts/material_fonts'
    sdk_manifest = {}
    for name in ('MaterialIcons-Regular.otf', 'MaterialIcons_LICENSE.txt'):
        source = sdk_fonts / name
        if not source.is_file() or source.is_symlink():
            raise RuntimeError('Missing or unsafe isolated Flutter font input')
        data = source.read_bytes()
        checked_write('assets/fonts/' + name, data)
        sdk_manifest[name] = hashlib.sha256(data).hexdigest()
    overrides = ''.join(f'  {name}: "{version}"\n' for name, version in pinned.items())
    checked_write('pubspec.yaml', f'''name: chatloom
publish_to: none
description: Isolated production round widget and controller fixtures.
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  material_ui: "{pinned['material_ui']}"
  cupertino_ui: "{pinned['cupertino_ui']}"
  video_player: "{pinned['video_player']}"
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: "{pinned['flutter_lints']}"
dependency_overrides:
{overrides}flutter:
  uses-material-design: true
  fonts:
    - family: Roboto
      fonts:
        - asset: assets/notion/fonts/Roboto-Regular.ttf
          weight: 400
        - asset: assets/notion/fonts/Roboto-Medium.ttf
          weight: 500
        - asset: assets/notion/fonts/Roboto-Bold.ttf
          weight: 700
  assets:
    - assets/notion/fonts/
    - assets/fonts/
''')
    checked_write('analysis_options.yaml', '''include: package:flutter_lints/flutter.yaml
analyzer:
  errors:
    todo: ignore
''')
    checked_write('SOURCE-MANIFEST.json', json.dumps({
        'sources': manifest,
        'isolated_flutter_fonts': sdk_manifest,
        'hosted_versions': pinned,
        'tests': TESTS,
        'scope': 'Synthetic production widget/controller fixtures; native Android and Telegram runtime NOT RUN',
    }, indent=2) + '\n')
    return manifest, sdk_manifest


def run(argv, environment):
    print('Running:', ' '.join(argv), flush=True)
    subprocess.run(['rtk', *argv], cwd=HARNESS, env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=str(ROOT.parent / 'spikes/toolchains/flutter-3.47.4/bin/flutter'))
    parser.add_argument('--prepare-only', action='store_true', help='Copy sources and pinned manifest without Flutter commands')
    parser.add_argument('--skip-analyze', action='store_true', help='Run fixtures without the final copied-source analyzer')
    args = parser.parse_args()
    manifest, sdk_manifest = prepare(args.flutter)
    print(f'Prepared managed production-source harness: {HARNESS}', flush=True)
    if args.prepare_only:
        return
    environment = os.environ.copy()
    # The dependency graph has no app crypto/native-imaging build hooks. Never
    # change xcode-select or the root checkout to work around unrelated hooks.
    run([args.flutter, 'pub', 'get', '--offline'], environment)
    run([args.flutter, 'test', '--no-pub', '--reporter', 'expanded', *TESTS], environment)
    if not args.skip_analyze:
        run([args.flutter, 'analyze', '--no-pub', 'lib', 'test'], environment)
    for relative, digest in manifest.items():
        if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'Production source changed during verification: {relative}; rerun the harness')
    sdk_fonts = Path(args.flutter).resolve().parents[1] / 'bin/cache/artifacts/material_fonts'
    for name, digest in sdk_manifest.items():
        if hashlib.sha256((sdk_fonts / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('Isolated Flutter font changed during verification')
    print('PASS copied production round widgets/controllers; no physical Android/Telegram runtime claim', flush=True)


if __name__ == '__main__':
    main()
