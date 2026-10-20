#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Rename the internal FluffyChat identifiers of this client to ChatLoom.

Renames (idempotent; a second run changes nothing):
  * Dart package `fluffychat` -> `chatloom` (pubspec name, every
    `package:fluffychat/` import in lib/, test/, integration_test/, scripts/,
    packages/, worker/ and the active agent guides; harness pubspec templates
    in scripts/*.py).
  * Dart identifiers and files: FluffyChatApp, FluffyThemes, FluffyShare,
    FluffyChatPushPayload, FluffyChatNotificationActions,
    buildFluffyChatCallKitParams, FluffyChatTester, startFluffyChatTest and
    lib/widgets/fluffy_chat_app.dart, lib/utils/fluffy_share.dart,
    integration_test/utils/fluffy_chat_tester.dart.
  * Android: Gradle namespace, Kotlin `package`/`import` declarations, the
    source directories src/{main,test,androidTest}/kotlin/chat/fluffy/fluffychat,
    and an <activity-alias> that keeps the old launcher component name so
    home-screen icons and pinned shortcuts of the installed app survive.

Never renamed (deny-list, verified by counting before and after): persisted
or externally registered identifiers such as SharedPreferences keys
(`chat.fluffy.*`), Matrix account-data/store namespaces (`im.fluffychat.*`),
notification channel IDs, cache directories, the Android applicationId and
URL schemes (`pl.personal.chat*`), push app IDs, Firebase projects, iOS app
groups, Linux/Windows application IDs and binary names, the l10n keys, SPDX
licence attribution and historical documents.

The app-side MethodChannel `pl.personal.chat/round_capture` contains no
FluffyChat name and stays as is on both sides; the `im.fluffychat.*` shortcut
channel belongs to the flutter_shortcuts_new plugin and must not change.

Usage (from client/):
  python3 scripts/rename-internal-chatloom.py --dry-run   # report only
  python3 scripts/rename-internal-chatloom.py             # apply
  python3 scripts/rename-internal-chatloom.py --check     # exit 1 if pending
Afterwards (through scripts/flutter-queue.py):
  flutter pub get                                   # .dart_tool, registrant
  dart fix --apply --code=directives_ordering lib   # `package:chatloom`
  dart fix --apply --code=directives_ordering test  # sorts differently
  flutter analyze --no-pub --no-fatal-infos lib test
Gradle/Kotlin compilation is not exercised by this script; build a debug APK
before release.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

DEFAULT_NAMESPACE = 'pl.personal.chatloom'
OLD_NAMESPACE = 'chat.fluffy.fluffychat'
OLD_LAUNCHER = f'{OLD_NAMESPACE}.MainActivity'

SKIP_DIRS = {
    '.git', 'build', '.dart_tool', '.idea', '.vscode', '.gradle', '.cxx',
    'node_modules', 'Pods', '.symlinks', 'ephemeral', '.pub-cache',
    # Historical records keep their original names.
    'docs', 'session-logs', 'artifacts',
}
# Vendored upstream SDK: no app imports; leave byte-identical.
SKIP_PREFIXES = ('packages/matrix/',)
CODE_EXT = {
    '.dart', '.py', '.sh', '.yaml', '.yml', '.kt', '.kts', '.java', '.xml',
    '.gradle', '.pro', '.properties', '.toml', '.ps1',
}
ACTIVE_DOCS = {'AGENTS.md', 'CLAUDE.md', 'DESIGN.md', 'README.personal.md'}
GENERATED = re.compile(r'^lib/l10n/l10n(_[A-Za-z_]+)?\.dart$')
# This script names the old identifiers on purpose.
SELF = 'scripts/rename-internal-chatloom.py'

DART_IDENTIFIERS = [
    ('FluffyChatNotificationActions', 'ChatLoomNotificationActions'),
    ('FluffyChatPushPayload', 'ChatLoomPushPayload'),
    ('buildFluffyChatCallKitParams', 'buildChatLoomCallKitParams'),
    ('startFluffyChatTest', 'startChatLoomTest'),
    ('FluffyChatTester', 'ChatLoomTester'),
    ('FluffyChatApp', 'ChatLoomApp'),
    ('FluffyThemes', 'ChatLoomThemes'),
    ('FluffyShare', 'ChatLoomShare'),
]
DART_FILES = [
    ('lib/widgets/fluffy_chat_app.dart', 'lib/widgets/chatloom_app.dart'),
    ('lib/utils/fluffy_share.dart', 'lib/utils/chatloom_share.dart'),
    (
        'integration_test/utils/fluffy_chat_tester.dart',
        'integration_test/utils/chatloom_tester.dart',
    ),
]

# (token or regex, reason, path regex the count is limited to or None)
DENY = [
    (r"re:'chat\.fluffy\.[A-Za-z0-9_.]+'", 'SharedPreferences / secure-storage keys of existing installs', r'\.dart$'),
    (r're:im\.fluffychat\.[A-Za-z0-9_.]+', 'Matrix account data, store namespaces, relation type, shortcut plugin channel', None),
    ('group.im.fluffychat.app', 'iOS app group / keychain access group', None),
    ('sharemedia-im.fluffychat.app', 'iOS share-extension URL scheme', None),
    ('fluffychat_push', 'Android notification channel ID (messages)', None),
    ('fluffychat_sync', 'Android notification channel ID (foreground sync)', None),
    ('fluffychat_download_cache', 'on-disk cache directory', None),
    ('.fluffybackup', 'export file extension accepted by import', None),
    (r're:pl\.personal\.chat(?![A-Za-z0-9_])', 'applicationId, bundle ID, deep-link/SSO schemes, pusher app_id', None),
    ("legacyStorageAppName = 'Personal Chat'", 'secure-storage session-backup key and login client names', None),
    (f'APPLICATION_ID "{OLD_NAMESPACE}"', 'Linux GApplication ID / data directory', r'^linux/'),
    ('BINARY_NAME "fluffychat"', 'Linux/Windows executable name', None),
    (r're:(?m)^name: fluffychat$', 'snap store name', r'^snap/'),
    (OLD_NAMESPACE, 'upstream Play/snap/Linux IDs and the release test fixture (not this app)', r'^(android/fastlane/|snap/|linux/|\.github/|scripts/test_build_personal_release\.py)'),
    ('"CompanyName", "chat.fluffy"', 'Windows app-data directory (path_provider)', None),
    ('"ProductName", "fluffychat"', 'Windows app-data directory (path_provider)', None),
    ('PRODUCT_NAME = Personal Chat', 'macOS .app bundle / executable of existing installs', None),
    (r're:fluffychat-[0-9a-f]{5}', 'Firebase project IDs', None),
    ('Contributors to FluffyChat', 'SPDX licence attribution (AGPL)', None),
    ('supportFluffyChat', 'l10n key (values are rebranded)', None),
    ('newMessageInFluffyChat', 'l10n key (values are rebranded)', None),
    (f'android:name="{OLD_LAUNCHER}"', 'launcher component of existing installs (activity-alias)', None),
]

ALIAS_BLOCK = '''
        <!-- Keeps the launcher component name of existing installs (home-screen
             icons, pinned shortcuts) after the Kotlin package rename. -->
        <activity-alias
            android:name="{old}"
            android:targetActivity="{ns}.MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>
'''
LAUNCHER_FILTER = re.compile(
    r'\n[ \t]*<intent-filter>\s*'
    r'<action android:name="android\.intent\.action\.MAIN"\s*/>\s*'
    r'<category android:name="android\.intent\.category\.LAUNCHER"\s*/>\s*'
    r'</intent-filter>[ \t]*'
)


def rel(root: Path, p: Path) -> str:
    return p.relative_to(root).as_posix()


def walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            p = Path(dirpath) / name
            r = rel(root, p)
            if (p.is_symlink() or r.startswith(SKIP_PREFIXES)
                    or GENERATED.match(r) or r == SELF):
                continue
            yield p, r


def read_text(p: Path):
    try:
        data = p.read_bytes()
    except OSError:
        return None
    if b'\0' in data[:8192]:
        return None
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        return None


def in_scope(r: str) -> bool:
    if r in ACTIVE_DOCS:
        return True
    return Path(r).suffix in CODE_EXT


class Rule:
    def __init__(self, name, pattern, repl, applies):
        self.name = name
        self.pattern = re.compile(pattern)
        self.repl = repl
        self.applies = applies


def build_rules(ns: str):
    ns_path = ns.replace('.', '/')
    is_dart_like = lambda r: r.endswith(('.dart', '.py')) or r in ACTIVE_DOCS
    # Everywhere the app's own Kotlin package is meant; not the upstream
    # Play/snap/Linux IDs, upstream CI or the release test's wrong-package fixture.
    ns_scope = lambda r: not r.startswith(
        ('android/fastlane/', 'linux/', 'snap/', '.github/', 'scripts/test_build_personal_release.py')
    )
    rules = [
        Rule('dart-package-import', r'package:fluffychat/', 'package:chatloom/', lambda r: True),
        Rule(
            'pubspec-name', r"(?m)(^|''')name: fluffychat$", r'\1name: chatloom',
            lambda r: r == 'pubspec.yaml' or (r.startswith('scripts/') and r.endswith('.py')),
        ),
        Rule('kotlin-source-path', r'kotlin/chat/fluffy/fluffychat\b', f'kotlin/{ns_path}',
             lambda r: True),
        # The alias name is protected by placeholder (see apply_rules).
        Rule('android-namespace', r'\bchat\.fluffy\.fluffychat\b', ns, ns_scope),
    ]
    for old, new in DART_IDENTIFIERS:
        rules.append(Rule(f'dart-identifier:{old}', rf'\b{old}\b', new, is_dart_like))
    for old, new in DART_FILES:
        o, n = Path(old).name, Path(new).name
        rules.append(Rule(f'dart-file:{o}', rf'(?<![\w]){re.escape(o)}', n, is_dart_like))
    return rules


PROTECT = [f'android:name="{OLD_LAUNCHER}"']


def apply_rules(text, r, rules, stats):
    holders = {}
    for i, token in enumerate(PROTECT):
        if token in text:
            h = f'\0KEEP{i}\0'
            holders[h] = token
            text = text.replace(token, h)
    for rule in rules:
        if not rule.applies(r):
            continue
        text, n = rule.pattern.subn(rule.repl, text)
        if n:
            stats[rule.name] += n
    for h, token in holders.items():
        text = text.replace(h, token)
    return text


def add_launcher_alias(text, ns):
    if f'android:name="{OLD_LAUNCHER}"' in text:
        return text, False
    m = re.search(r'<activity\s+android:name="\.MainActivity"', text)
    if not m:
        raise SystemExit('AndroidManifest: .MainActivity not found')
    end = text.index('</activity>', m.end()) + len('</activity>')
    block = text[m.start():end]
    new_block, n = LAUNCHER_FILTER.subn('', block, count=1)
    if n != 1:
        raise SystemExit('AndroidManifest: MAIN/LAUNCHER filter not found on .MainActivity')
    alias = ALIAS_BLOCK.format(old=OLD_LAUNCHER, ns=ns).rstrip('\n')
    return text[:m.start()] + new_block + '\n' + alias + text[end:], True


def deny_regex(pattern):
    if pattern.startswith('re:'):
        return re.compile(pattern[3:])
    return re.compile(re.escape(pattern))


def count_deny(root: Path, files):
    counts = Counter()
    for (pattern, _reason, scope) in DENY:
        rx = deny_regex(pattern)
        srx = re.compile(scope) if scope else None
        for r, text in files.items():
            if srx and not srx.search(r):
                continue
            counts[pattern] += len(rx.findall(text))
    return counts


def load_all(root: Path):
    files = {}
    for p, r in walk(root):
        t = read_text(p)
        if t is not None:
            files[r] = t
    return files


def kotlin_dirs(root: Path):
    out = []
    src = root / 'android/app/src'
    if src.is_dir():
        for set_dir in sorted(src.iterdir()):
            old = set_dir / 'kotlin/chat/fluffy/fluffychat'
            if old.is_dir():
                out.append(old)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=Path(__file__).resolve().parent.parent, type=Path)
    ap.add_argument('--namespace', default=DEFAULT_NAMESPACE)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--check', action='store_true', help='exit 1 when a run would change anything')
    args = ap.parse_args()
    root = args.root.resolve()
    ns = args.namespace
    if not re.fullmatch(r'[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+', ns):
        raise SystemExit(f'invalid namespace {ns!r}')
    if not (root / 'pubspec.yaml').is_file():
        raise SystemExit(f'{root} is not the client checkout')
    write = not (args.dry_run or args.check)
    rules = build_rules(ns)

    before = load_all(root)
    deny_before = count_deny(root, before)

    stats = Counter()
    changed = {}
    for r, text in before.items():
        if not in_scope(r):
            continue
        new = apply_rules(text, r, rules, stats)
        if r == 'android/app/src/main/AndroidManifest.xml':
            new, added = add_launcher_alias(new, ns)
            if added:
                stats['android-launcher-alias'] += 1
        if new != text:
            changed[r] = new

    moves = []
    for old_dir in kotlin_dirs(root):
        new_dir = old_dir.parent.parent.parent / ns.replace('.', '/')
        moves.append((old_dir, new_dir))
    for old, new in DART_FILES:
        if (root / old).exists() and not (root / new).exists():
            moves.append((root / old, root / new))

    if write:
        for r, text in changed.items():
            (root / r).write_text(text, encoding='utf-8')
        for src, dst in moves:
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                if dst.exists():
                    raise SystemExit(f'refusing to merge into existing {dst}')
                shutil.move(str(src), str(dst))
                # Remove now-empty chat/fluffy parents.
                for parent in (src.parent, src.parent.parent):
                    try:
                        parent.rmdir()
                    except OSError:
                        pass
            else:
                src.rename(dst)

    after = load_all(root) if write else {**before, **changed}
    deny_after = count_deny(root, after)

    print(f'root: {root}')
    print(f'namespace: {OLD_NAMESPACE} -> {ns}')
    print(f'mode: {"apply" if write else ("check" if args.check else "dry-run")}')
    print(f'files changed: {len(changed)}')
    by_dir = Counter(r.split('/')[0] if '/' in r else '.' for r in changed)
    for d, n in sorted(by_dir.items()):
        print(f'  {d}/: {n}')
    print('replacements by rule:')
    for name, n in sorted(stats.items()):
        print(f'  {name}: {n}')
    print(f'moves: {len(moves)}')
    for s, d in moves:
        print(f'  {rel(root, s)} -> {rel(root, d)}')

    print('kept (deny-list) occurrences before -> after:')
    broken = False
    for pattern, reason, scope in DENY:
        b, a = deny_before[pattern], deny_after[pattern]
        note = ''
        if pattern == f'android:name="{OLD_LAUNCHER}"':
            ok = a == 1 and b in (0, 1)
            note = ' (added once)' if b == 0 else ''
        else:
            ok = a == b
        broken |= not ok
        print(f'  [{"ok" if ok else "CHANGED"}] {b:4d} -> {a:4d}  {pattern}{note}  -- {reason}')

    residual = defaultdict(list)
    rx = re.compile(r'fluffy', re.I)
    deny_rx = [deny_regex(p) for p, _, _ in DENY]
    for r, text in after.items():
        if not in_scope(r):
            continue
        for i, line in enumerate(text.split('\n'), 1):
            if not rx.search(line):
                continue
            stripped = line
            for d in deny_rx:
                stripped = d.sub('', stripped)
            stripped = re.sub(r'https?://\S*fluffy\S*', '', stripped, flags=re.I)
            if rx.search(stripped):
                residual[r].append((i, line.strip()[:140]))
    total_res = sum(len(v) for v in residual.values())
    print(f'residual "fluffy" lines not covered by the deny-list or URLs: {total_res} in {len(residual)} files (comments, upstream mentions, harness fixtures; review)')
    for r in sorted(residual)[:40]:
        for i, line in residual[r][:3]:
            print(f'  {r}:{i}: {line}')

    if broken:
        print('ERROR: a deny-listed identifier changed', file=sys.stderr)
        return 2
    if args.check and (changed or moves):
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
