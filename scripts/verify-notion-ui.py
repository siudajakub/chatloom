#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Sequential, hashed copies of production Notion presenters, tests and captures.

No application/native-crypto hook is disabled. This separate package verifies
the production presentation sources without an account or private runtime.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def project_root(checkout):
 for candidate in (checkout, *checkout.parents):
  if (candidate / 'docs/notion-ui/SOURCE-SNAPSHOT.json').is_file():
   return candidate
 raise RuntimeError('Cannot locate the Personal Chat project from ' + str(checkout))

PROJECT = project_root(ROOT)
HARNESS = ROOT / 'build/notion_widget_harness'
MARKER = HARNESS / '.notion-ui-harness'
SOURCES = (
 'lib/ui/notion/notion.dart', 'lib/ui/notion/notion_theme.dart',
 'lib/ui/notion/details_contract.dart', 'lib/ui/notion/initial_avatar.dart',
 'lib/personal/ui/notion_inbox_page.dart', 'lib/personal/ui/notion_inbox_row.dart',
 'lib/personal/ui/notion_inbox_pins.dart', 'lib/personal/ui/notion_inbox_dock.dart',
 'lib/personal/ui/notion_network_filter.dart', 'lib/personal/ui/notion_network_selector.dart',
 'lib/personal/ui/notion_search_controls.dart',
 'lib/personal/ui/notion_chat_details_page.dart', 'lib/personal/ui/notion_settings_page.dart',
 'lib/personal/ui/notion_chat_details_notifications.dart',
 'lib/pages/chat/notion_conversation.dart',
 'lib/config/themes.dart', 'lib/widgets/layouts/two_column_layout.dart',
)

def write(relative, data):
 target = HARNESS / relative
 if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
  raise RuntimeError('Refusing symlinked harness output')
 target.parent.mkdir(parents=True, exist_ok=True)
 target.write_bytes(data if isinstance(data, bytes) else data.encode())

def prepare(flutter):
 if HARNESS.exists() and (not MARKER.is_file() or MARKER.read_text() != 'notion-production-widget-harness-v1\n'):
  raise RuntimeError('Refusing to overwrite an unowned directory')
 HARNESS.mkdir(parents=True, exist_ok=True)
 MARKER.write_text('notion-production-widget-harness-v1\n')
 spec = importlib.util.spec_from_file_location('round_checks', ROOT / 'scripts/verify-round-widgets.py')
 helper = importlib.util.module_from_spec(spec)
 spec.loader.exec_module(helper)
 versions, roots = helper.hosted_versions(), helper.package_roots()
 queue = ['material_ui', 'flutter_svg', 'flutter_lints', 'flutter', 'flutter_test']
 visited, pinned = set(), {}
 while queue:
  name = queue.pop()
  if name in visited:
   continue
  visited.add(name)
  package = roots[name]
  text = (package / 'pubspec.yaml').read_text()
  if name in versions:
   actual = re.search(r'^version:\s*["\']?([^\s"\']+)', text, re.M)
   if actual is None or actual.group(1) != versions[name]:
    raise RuntimeError('Root lock and package configuration disagree')
   pinned[name] = versions[name]
  queue.extend(helper.dependencies(text))
 if visited.intersection({'matrix', 'webcrypto', 'sqlite3', 'native_imaging', 'flutter_vodozemac'}):
  raise RuntimeError('Unexpected native app graph in presentation harness')
 manifest = {}
 sources = list(SOURCES)
 sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'test/notion').glob('*.dart')) if not path.name.endswith(('_controller_test.dart', '_adapter_test.dart'))]
 sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'assets/notion').rglob('*')) if path.is_file()]
 sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'packages/personal_core/lib').rglob('*.dart'))]
 sources += ['packages/personal_core/pubspec.yaml']
 for name in sources:
  path = ROOT / name
  if path.is_symlink() or not path.is_file():
   raise RuntimeError('Missing or unsafe production input: ' + name)
  data = path.read_bytes()
  write(name, data)
  manifest[name] = hashlib.sha256(data).hexdigest()
 fonts = Path(flutter).resolve().parents[1] / 'bin/cache/artifacts/material_fonts'
 for name in ('Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto_LICENSE.txt', 'MaterialIcons-Regular.otf', 'MaterialIcons_LICENSE.txt'):
  data = (fonts / name).read_bytes()
  write('assets/fonts/' + name, data)
 reference = PROJECT / 'artifacts/ui-mockups-2026-10-12/notion-dark-v2/chat.png'
 write('assets/reference/chat.png', reference.read_bytes())
 overrides = ''.join(f'  {name}: "{version}"\n' for name, version in sorted(pinned.items()))
 write('pubspec.yaml', f'''name: fluffychat
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  material_ui: "{pinned['material_ui']}"
  flutter_svg: "{pinned['flutter_svg']}"
  personal_core:
    path: packages/personal_core
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
    - assets/notion/pinned/
    - assets/notion/fonts/
    - assets/fonts/
    - assets/reference/
''')
 write('analysis_options.yaml', 'include: package:flutter_lints/flutter.yaml\n')
 write('SOURCE-MANIFEST.json', json.dumps({'sha256': manifest, 'pinned': pinned, 'scope': 'Copied actual production presenters and core; fictional state; live account/native transport NOT RUN'}, indent=2) + '\n')
 return manifest

def main():
 parser = argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--flutter', default=str(PROJECT / 'spikes/toolchains/flutter-3.47.4/bin/flutter'))
 parser.add_argument('--prepare-only', action='store_true')
 parser.add_argument('--skip-analyze', action='store_true')
 args = parser.parse_args()
 manifest = prepare(args.flutter)
 print(f'Prepared {len(manifest)} hashed production inputs at {HARNESS}', flush=True)
 if args.prepare_only:
  return
 environment = dict(os.environ)
 environment['NOTION_CAPTURE_DIR'] = str(ROOT / 'docs/notion-ui/evidence/screenshots')
 environment['NOTION_APPROVED_PHOTOS'] = '1'
 def run(arguments):
  subprocess.run(['rtk', args.flutter, *arguments], cwd=HARNESS, env=environment, check=True)
 run(['pub', 'get', '--offline'])
 run(['test', '--no-pub', '--concurrency=1', '--reporter', 'expanded', 'test/notion'])
 if not args.skip_analyze:
  run(['analyze', '--no-pub', '--no-fatal-infos', 'lib', 'test'])
 drift = [name for name, digest in manifest.items() if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
 if drift:
  raise RuntimeError('Production sources changed during verification; rerun: ' + ', '.join(drift))
 print('PASS production presentation fixtures; native/real-account acceptance NOT RUN', flush=True)

if __name__ == '__main__':
 main()
