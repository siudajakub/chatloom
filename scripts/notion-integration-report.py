#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compare an isolated UI checkout with BASE and the current original client.

Sources and existing delivery evidence remain read-only. Fresh report artifacts
go to the invoking checkout's build directory unless --output-dir is specified.
"""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path
import tarfile

SCRIPT_ROOT = Path(__file__).resolve().parents[1]

def project_root(checkout):
 for candidate in (checkout, *checkout.parents):
  if (candidate / 'docs/notion-ui/SOURCE-SNAPSHOT.json').is_file():
   return candidate
 raise RuntimeError('Cannot locate the Personal Chat project from ' + str(checkout))

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ui-root', type=Path, default=SCRIPT_ROOT,
                    help='Isolated UI checkout; must differ from the original client')
parser.add_argument('--output-dir', type=Path,
                    help='Fresh report output directory; existing source/evidence directories are refused')
args = parser.parse_args()
ROOT = args.ui_root.resolve()
if not ROOT.is_dir() or not (ROOT / 'lib/ui/notion/notion.dart').is_file():
 parser.error('--ui-root must identify an existing Notion UI checkout')
PROJECT = project_root(ROOT)
MANIFEST = PROJECT / 'docs/notion-ui/SOURCE-SNAPSHOT.json'
manifest = json.loads(MANIFEST.read_text())
original = Path(manifest['source']).resolve()
if ROOT == original:
 parser.error('Refusing to compare the original client with itself; pass --ui-root for the isolated UI checkout')
if not original.is_dir():
 parser.error('The manifest original client directory is unavailable')
OUTPUT = (args.output_dir or SCRIPT_ROOT / 'build/notion-integration-report').resolve()
for source in (ROOT, original):
 if OUTPUT.is_relative_to(source) and not OUTPUT.is_relative_to(source / 'build'):
  parser.error('Report output must be outside source/evidence directories or inside build/')
archive = Path(manifest['immutable_base']['path'])
assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['immutable_base']['sha256']
translation_tree = ast.parse((ROOT / 'scripts/notion-protected-copy.py').read_text())
copy = {}
copy_paths = []
for node in translation_tree.body:
 if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
  if node.targets[0].id == 'COPY': copy = ast.literal_eval(node.value)
  if node.targets[0].id == 'PATHS': copy_paths = ast.literal_eval(node.value)

def digest(data):
 return None if data is None else hashlib.sha256(data).hexdigest()

def read(root, name):
 path = root / name
 assert not path.is_symlink()
 return path.read_bytes() if path.is_file() else None

protected_prefixes = ('packages/matrix/', 'packages/personal_core/', 'lib/personal/storage/', 'lib/personal/media/', 'lib/personal/round_video/', 'android/', 'worker/', 'push-gateway/')
protected_files = {
 'lib/main.dart', 'lib/personal/personal_client.dart', 'lib/personal/privacy.dart',
 'lib/personal/privacy_transport.dart', 'lib/personal/capabilities.dart', 'lib/personal/immediate_outbox.dart',
 'lib/utils/client_manager.dart', 'lib/utils/init_with_restore.dart', 'lib/utils/background_push.dart',
 'lib/utils/push_helper.dart', 'lib/utils/notification_background_handler.dart',
 'lib/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart',
 'lib/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart',
}
records, patches, unchanged, copy_only, protected_review = [], [], [], [], []
with tarfile.open(archive) as base_archive:
 for item in manifest['files']:
  name = item['path']
  relative = Path(name)
  assert not relative.is_absolute() and '..' not in relative.parts
  assert not any(part in ('.runtime', '.dart_tool') for part in relative.parts)
  base = base_archive.extractfile(name).read()
  assert digest(base) == item['sha256'] and len(base) == item['bytes']
  ours, theirs = read(ROOT, name), read(original, name)
  ours_changed, theirs_changed = ours != base, theirs != base
  if not ours_changed and not theirs_changed: continue
  record = {'path': name, 'base_sha256': digest(base), 'ui_sha256': digest(ours), 'original_sha256': digest(theirs), 'ui_changed': ours_changed, 'original_changed': theirs_changed, 'overlap': ours_changed and theirs_changed and ours != theirs}
  records.append(record)
  protected = name.startswith(protected_prefixes) or name in protected_files
  if ours_changed:
   if name in copy_paths:
    expected = base.decode()
    for source, target in sorted(copy.items(), key=lambda item: -len(item[0])): expected = expected.replace(source, target)
    if ours == expected.encode(): copy_only.append(name)
    else: protected_review.append(name)
   elif protected: protected_review.append(name)
   if ours is not None and relative.suffix in ('.dart', '.py', '.yaml', '.kts', '.xml', '.md'):
    patches.extend(difflib.unified_diff(base.decode().splitlines(keepends=True), ours.decode().splitlines(keepends=True), fromfile='BASE/' + name, tofile='UI/' + name))
  elif protected: unchanged.append(name)
 # Record protected files that did not differ on either side as UI unchanged.
 for item in manifest['files']:
  name = item['path']
  if (name.startswith(protected_prefixes) or name in protected_files) and read(ROOT, name) is not None and digest(read(ROOT, name)) == item['sha256'] and name not in unchanged: unchanged.append(name)

known = {item['path'] for item in manifest['files']}
new_paths = []
for folder in ('lib/ui/notion', 'lib/personal/ui', 'lib/pages/chat', 'lib/widgets', 'test/notion', 'assets/notion', 'scripts'):
 for path in sorted((ROOT / folder).rglob('*')):
  if not path.is_file() or path.is_symlink() or '__pycache__' in path.parts: continue
  name = str(path.relative_to(ROOT))
  if name in known or (folder == 'scripts' and 'notion' not in path.name): continue
  if folder in ('lib/personal/ui', 'lib/pages/chat', 'lib/widgets') and not path.name.startswith('notion_'): continue
  data = path.read_bytes()
  new_paths.append({'path': name, 'sha256': digest(data), 'bytes': len(data)})
  if path.suffix in ('.dart', '.py', '.svg'):
   patches.extend(difflib.unified_diff([], data.decode().splitlines(keepends=True), fromfile='/dev/null', tofile='UI/' + name))

report = {
 'base_sha256': manifest['immutable_base']['sha256'], 'base_files_verified': len(manifest['files']),
 'ui_root': str(ROOT), 'original_source': str(original), 'output_dir': str(OUTPUT),
 'code_only': True, 'original_writes': 0,
 'reintegration': 'Not inferred from this source comparison; inspect the separate integration checkpoint and verification evidence',
 'non_atomic_original_read': True, 'paths': records, 'new_ui_paths': new_paths,
 'protected_exact_unchanged': sorted(unchanged), 'protected_copy_only_verified': sorted(copy_only),
 'protected_changes_requiring_semantic_review': sorted(protected_review),
 'overlapping_changed_paths': [record['path'] for record in records if record['overlap']],
 'note': 'Patch is a review artifact against immutable dirty-source BASE; not safe to blindly apply to the changing original client. Generated registrants must be regenerated normally.',
}
OUTPUT.mkdir(parents=True, exist_ok=True)
(OUTPUT / 'integration-three-way.json').write_text(json.dumps(report, indent=2) + '\n')
(OUTPUT / 'ui-against-base.patch').write_text(''.join(patches))
print(json.dumps({
 'base_verified': report['base_files_verified'],
 'changed_ui_files': sum(record['ui_changed'] for record in records),
 'changed_original_files': sum(record['original_changed'] for record in records),
 'new_ui_files': len(new_paths), 'overlaps': report['overlapping_changed_paths'],
 'protected_unchanged': len(unchanged), 'protected_copy_only': len(copy_only),
 'protected_review': protected_review,
 'original_writes': 0, 'output_dir': str(OUTPUT),
}, indent=2))
