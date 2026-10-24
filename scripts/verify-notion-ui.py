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
 # A Claude worktree lives outside the project; devbox-env.sh names it.
 shared = [Path(os.environ['PERSONAL_CHAT_ROOT'])] if os.environ.get('PERSONAL_CHAT_ROOT') else []
 for candidate in (checkout, *checkout.parents, *shared):
  if (candidate / 'docs/notion-ui/SOURCE-SNAPSHOT.json').is_file():
   return candidate
 raise RuntimeError('Cannot locate the Personal Chat project from ' + str(checkout))

PROJECT = project_root(ROOT)
HARNESS = ROOT / 'build/notion_widget_harness'
MARKER = HARNESS / '.notion-ui-harness'
# Every lib/ui/notion/*.dart file is added in prepare(); new primitives need no
# edit here. Motion packages (flutter_animate, skeletonizer) are pinned below.
SOURCES = (
 'lib/personal/encryption/key_recovery_stage.dart',
 'lib/pages/chat/events/waiting_message_view.dart', 'lib/pages/chat/undecryptable_chat_hint.dart',
 'lib/personal/ui/inbox_health_notice.dart',
 'lib/personal/ui/notion_transcribe_button.dart',
 'lib/personal/ui/notion_inbox_page.dart', 'lib/personal/ui/notion_inbox_row.dart',
 'lib/personal/ui/notion_inbox_view_chips.dart', 'lib/personal/ui/notion_inbox_network_badge.dart',
 'lib/personal/ui/notion_inbox_pins.dart', 'lib/personal/ui/notion_inbox_dock.dart',
 'lib/personal/ui/notion_network_filter.dart', 'lib/personal/ui/notion_network_selector.dart',
 'lib/personal/ui/notion_search_controls.dart',
 'lib/personal/ui/notion_chat_details_page.dart', 'lib/personal/ui/notion_settings_page.dart',
 'lib/personal/ui/notion_chat_details_notifications.dart',
 'lib/personal/ui/notion_privacy_preferences.dart', 'lib/personal/ui/notion_settings_body.dart',
 'lib/pages/chat/notion_conversation.dart',
 'lib/pages/chat/conversation_grouping.dart', 'lib/pages/chat/conversation_bubble.dart',
 'lib/pages/chat/conversation_motion.dart', 'lib/pages/chat/conversation_message_gestures.dart',
 'lib/pages/chat/compact_composer.dart', 'lib/pages/chat/conversation_source_picker.dart',
 'lib/pages/chat/composer_action_tray.dart', 'lib/pages/chat/voice_record_button.dart',
 'lib/pages/chat/conversation_service_chip.dart',
 'lib/config/themes.dart', 'lib/widgets/layouts/two_column_layout.dart',
)

# UI motion packages; only lib/ui/notion imports them (design lint).
MOTION_PACKAGES = ('flutter_animate', 'skeletonizer')

# A directive runs to its ';'; every quoted string in it is a URI (conditional imports too).
DIRECTIVE = re.compile(r'^(?:import|export|part)\s+([^;]*);', re.M)
URI = re.compile(r'''['"]([^'"]+)['"]''')
# Tests that read app sources at runtime (File('lib/...dart')) depend on them too.
SOURCE_LITERAL = re.compile(r'''['"](lib/[^'"$]+\.dart)['"]''')

def local_closure(start, packages):
 """Files reachable from start through imports/exports/parts, and what cannot resolve.

 package:chatloom maps to lib/, package:personal_core is copied whole; any other
 package must be in the harness dependency graph. Returns (files, unresolved).
 """
 seen, unresolved, stack = set(), set(), [start]
 while stack:
  relative = stack.pop()
  if relative in seen:
   continue
  seen.add(relative)
  path = ROOT / relative
  if not path.is_file():
   unresolved.add(relative)
   continue
  for uri in (uri for match in DIRECTIVE.finditer(path.read_text()) for uri in URI.findall(match.group(1))):
   if uri.startswith('dart:'):
    continue
   if uri.startswith('package:'):
    package, _, rest = uri[len('package:'):].partition('/')
    if package == 'chatloom':
     stack.append('lib/' + rest)
    elif package != 'personal_core' and package not in packages:
     unresolved.add(uri)
    continue
   stack.append(os.path.normpath(str(Path(relative).parent / uri)))
 return seen, unresolved

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
 queue = ['material_ui', 'cupertino_ui', 'flutter_svg', *MOTION_PACKAGES, 'flutter_lints', 'flutter', 'flutter_test']
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
 # metadata_actions.dart reaches into the app graph (PersonalClient).
 sources = [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'lib/ui/notion').glob('*.dart')) if path.name != 'metadata_actions.dart']
 sources += list(SOURCES)
 # Presenter sources must be self-contained: a missing import is a SOURCES gap.
 packages = visited | {'flutter', 'flutter_test'}
 allowed = set(sources)
 for name in list(sources):
  files, unresolved = local_closure(name, packages)
  gaps = sorted(unresolved | {f for f in files if f.startswith('lib/') and f not in allowed})
  if gaps:
   raise RuntimeError(f'{name} imports outside the harness; add pure-UI files to SOURCES: ' + ', '.join(gaps))
 # A test/notion suite is harness-eligible only if its whole import closure
 # resolves here (harness sources, test/notion helpers, harness packages) and
 # every lib/*.dart path literal it reads at runtime is a harness source.
 # Suites reaching the matrix SDK, providers, plugins or app controllers run
 # with native hooks in the full app suite (run-personal-app-tests.py) instead.
 full_graph_only = []
 for path in sorted((ROOT / 'test/notion').glob('*_test.dart')):
  name = str(path.relative_to(ROOT))
  files, unresolved = local_closure(name, packages)
  files |= set(SOURCE_LITERAL.findall(path.read_text()))
  outside = {f for f in files if f.startswith('lib/') and f not in allowed}
  if unresolved or outside:
   full_graph_only.append(path.name)
   continue
  sources += sorted(f for f in files if f.startswith('test/') and f not in sources)
 print(f'Harness skips {len(full_graph_only)} full-app suites (run by the app suite): ' + ', '.join(full_graph_only), flush=True)
 sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'assets/notion').rglob('*')) if path.is_file()]
 sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'test/notion/goldens').rglob('*.png'))]
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
  if name.startswith('Roboto-') and name.endswith('.ttf'):
   write('assets/notion/fonts/' + name, (ROOT / 'assets/notion/fonts' / name).read_bytes())
 reference = PROJECT / 'artifacts/ui-mockups-2026-10-12/notion-dark-v2/chat.png'
 write('assets/reference/chat.png', reference.read_bytes())
 overrides = ''.join(f'  {name}: "{version}"\n' for name, version in sorted(pinned.items()))
 motion = ''.join(f'  {name}: "{pinned[name]}"\n' for name in MOTION_PACKAGES)
 write('pubspec.yaml', f'''name: chatloom
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  material_ui: "{pinned['material_ui']}"
  cupertino_ui: "{pinned['cupertino_ui']}"
  flutter_svg: "{pinned['flutter_svg']}"
{motion}  personal_core:
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
 parser.add_argument('--capture-dir', type=Path, help='Separate directory for synthetic screenshots')
 parser.add_argument('--update-goldens', action='store_true', help='Rewrite test/notion/goldens from this run')
 args = parser.parse_args()
 manifest = prepare(args.flutter)
 print(f'Prepared {len(manifest)} hashed production inputs at {HARNESS}', flush=True)
 if args.prepare_only:
  return
 environment = dict(os.environ)
 environment['NOTION_CAPTURE_DIR'] = str(args.capture_dir or ROOT / 'docs/notion-ui/evidence/screenshots')
 environment['NOTION_APPROVED_PHOTOS'] = '1'
 def run(arguments):
  subprocess.run(['rtk', args.flutter, *arguments], cwd=HARNESS, env=environment, check=True)
 run(['pub', 'get', '--offline'])
 test_sources = [name for name in manifest if name.startswith('test/notion/') and name.endswith('_test.dart')]
 run(['test', '--no-pub', '--concurrency=1', '--reporter', 'expanded', *(['--update-goldens'] if args.update_goldens else []), *test_sources])
 if not args.skip_analyze:
  run(['analyze', '--no-pub', '--no-fatal-infos', 'lib', *test_sources])
 drift = [name for name, digest in manifest.items() if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
 if drift:
  raise RuntimeError('Production sources changed during verification; rerun: ' + ', '.join(drift))
 if args.update_goldens:
  goldens = sorted((HARNESS / 'test/notion/goldens').rglob('*.png'))
  for golden in goldens:
   target = ROOT / golden.relative_to(HARNESS)
   target.parent.mkdir(parents=True, exist_ok=True)
   target.write_bytes(golden.read_bytes())
  print(f'Updated {len(goldens)} goldens under test/notion/goldens', flush=True)
 print('PASS production presentation fixtures; native/real-account acceptance NOT RUN', flush=True)

if __name__ == '__main__':
 main()
