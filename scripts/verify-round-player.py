#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Coordinator-only source-exact round playback fixtures, separate from capture.

Run sequentially, with no concurrent Flutter/pub/test/analyze/build command:
  rtk python3 scripts/verify-round-player.py --flutter \
    $PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter

--prepare-only writes client/build/round_player_harness without executing Flutter.
Actual loader, renderer, mini-player, leases, coordinator and tests are copied
byte-for-byte and checked against their SHA-256 snapshots before/after execution.
Vendored Matrix/personal_core are real dependencies; all reachable hosted versions
come from the app lock. Native SDK hooks use the isolated Cargo/Rust/native tools.
Unrelated app services/UI peers are API-only stubs and are enumerated in PORTS.md.
No credentials, real accounts, native textures, receipts/forward dispatch, recovery,
real Keystore, physical Android/audio focus or Telegram runtime is exercised.
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
HARNESS = ROOT / 'build/round_player_harness'
MARKER = '.personal-round-player-harness'
MARKER_CONTENT = 'managed-by:scripts/verify-round-player.py:v1\n'
SOURCES = (
    'lib/personal/media/media_access.dart',
    'lib/personal/media/private_directories_native.dart',
    'lib/personal/media/private_directories_stub.dart',
    'lib/personal/storage/storage_failure.dart',
    'lib/personal/round_video/round_media_loader.dart',
    'lib/personal/round_video/round_playback_coordinator.dart',
    'lib/personal/round_video/round_playback_queue.dart',
    'lib/personal/round_video/round_playback_receipts.dart',
    'lib/pages/chat/events/round_video_view.dart',
    'lib/pages/chat/events/round_video_message.dart',
    'lib/pages/chat/events/round_video_bridge_message.dart',
    'lib/pages/chat/events/round_mini_player.dart',
    'lib/pages/chat/events/message_content.dart',
    'lib/utils/matrix_sdk_extensions/event_extension.dart',
    'lib/utils/size_string.dart',
)
TESTS = (
    'test/personal/round_video/round_playback_coordinator_test.dart',
    'test/personal/round_video/round_media_loader_test.dart',
    'test/personal/round_video/round_video_view_test.dart',
    'test/personal/round_video/round_rendering_guard_test.dart',
    'test/personal/round_video/round_mini_player_lifecycle_test.dart',
)
DIRECT = (
    'material_ui', 'video_player', 'just_audio', 'path_provider', 'http',
    'path_provider_platform_interface', 'shared_preferences', 'async',
)
FORBIDDEN = {
    'flutter_secure_storage', 'flutter_secure_storage_darwin', 'webcrypto',
    'flutter_vodozemac', 'native_imaging', 'flutter_webrtc', 'livekit_client',
}
VENDORED = {'matrix': ROOT / 'packages/matrix', 'personal_core': ROOT / 'packages/personal_core'}

STUBS = {
    'lib/personal/privacy.dart': '''abstract final class PersonalPrivacy {
  static bool surfaceUnlocked = true;
}
''',
    'lib/personal/round_video/telegram_round_service.dart': '''import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'round_playback_receipts.dart';
class TelegramRoundService extends ChangeNotifier implements RoundPlaybackReceipts {
  static final _instances = <Client, TelegramRoundService>{};
  static TelegramRoundService of(Client client) => _instances.putIfAbsent(client, TelegramRoundService.new);
  Map<String, dynamic>? verifiedMediaStateSnapshot(Event event) => null;
  Future<Map<String, dynamic>?> mediaState(Event event) async => null;
  @override bool get incognito => true;
  @override bool canExplicitlyReport(Event event) => false;
  bool canNativeForward(Event event) => false;
  @override Future<void> onUserStartedPlaying(Event event) async => throw StateError('Real played transport is excluded');
  @override Future<void> explicitlyReportPlayed(Event event) async => throw StateError('Real played transport is excluded');
  Future<void> showForwardPicker(BuildContext context, Event event) async => throw StateError('Real forward transport is excluded');
  static Future<void> closeFor(Client client) async { _instances.remove(client)?.dispose(); }
}
''',
    'lib/config/setting_keys.dart': '''class _Setting<T> { final T value; const _Setting(this.value); }
abstract final class AppSettings {
  static const showThumbnailsInTimeline = _Setting(true);
  static const autoplayImages = _Setting(false);
  static const renderHtml = _Setting(false);
  static Future<void> init({bool loadWebConfigFile = false}) async {}
}
''',
    'lib/config/app_config.dart': '''abstract final class AppConfig { static const double messageFontSize = 16; }
''',
    'lib/personal/transcript_panel.dart': '''import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
class TranscriptPanel extends StatelessWidget {
  final Event event;
  const TranscriptPanel({super.key, required this.event});
  @override Widget build(BuildContext context) => throw StateError('Transcription UI is excluded');
}
''',
    'lib/utils/platform_infos.dart': '''abstract final class PlatformInfos {
  static const isMobile = false, isMacOS = false, isWeb = false, isLinux = false;
}
''',
    'lib/utils/url_launcher.dart': '''import 'package:material_ui/material_ui.dart';
class UrlLauncher {
  UrlLauncher(BuildContext context, String url);
  Future<void> launchUrl() async => throw StateError('External navigation is excluded');
}
''',
    'lib/utils/event_checkbox_extension.dart': '''abstract final class EventCheckboxRoomExtension {
  static const relationshipType = 'im.fluffychat.checkboxes';
}
''',
    'lib/utils/matrix_sdk_extensions/matrix_file_extension.dart': '''import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
extension ExcludedFileOperations on MatrixFile {
  Future<void> save(BuildContext context) async => throw StateError('Native file export is excluded');
  Future<void> share(BuildContext context) async => throw StateError('Native file sharing is excluded');
}
''',
    'lib/widgets/future_loading_dialog.dart': '''import 'package:async/async.dart' as async;
import 'package:material_ui/material_ui.dart';
Future<async.Result<T>> showFutureLoadingDialog<T>({required BuildContext context,
  Future<T> Function()? future,
  Future<T> Function(void Function(double?))? futureWithProgress}) async =>
  throw StateError('Unrelated app download dialog is excluded');
// Same compatibility getters as production future_loading_dialog.dart.
extension DeprecatedApiAccessExtension<T> on async.Result<T> {
  T? get result => asValue?.value;
  Object? get error => asError?.error;
}
''',
    'lib/l10n/l10n.dart': '''import 'package:material_ui/material_ui.dart';
class L10n {
  static L10n of(BuildContext context) => L10n();
  String get user => 'fixture';
  String startedACall(String actor) => 'fixture';
  String userSentUnknownEvent(String actor, String type) => 'fixture';
  String redactedBy(String actor) => 'fixture';
  String redactedByBecause(String actor, String reason) => 'fixture';
}
''',
    'lib/pages/image_viewer/image_viewer.dart': '''import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
class ImageViewer extends StatelessWidget {
  const ImageViewer(Event event, {super.key, Timeline? timeline, required BuildContext outerContext});
  @override Widget build(BuildContext context) => throw StateError('Ordinary media viewer is excluded');
}
''',
    'lib/pages/chat/events/html_message.dart': '''import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
class HtmlMessage extends StatelessWidget {
  const HtmlMessage({super.key, required String html, required Color textColor,
    required Room room, required double fontSize, required TextStyle linkStyle,
    required void Function(dynamic) onOpen, required String eventId,
    required Object? checkboxCheckedEvents});
  @override Widget build(BuildContext context) => throw StateError('HTML UI is excluded');
}
''',
    'lib/pages/chat/events/map_bubble.dart': '''import 'package:material_ui/material_ui.dart';
class MapBubble extends StatelessWidget {
  const MapBubble({super.key, required VoidCallback onTap, required double latitude, required double longitude});
  @override Widget build(BuildContext context) => throw StateError('Location UI is excluded');
}
''',
}

# Peers are only constructor/type ports. Their build() must not silently pretend
# to verify ordinary video/audio/image/file/cute/poll behavior.
for name, declaration in {
    'video_player': '''class EventVideoPlayer extends StatelessWidget {
  const EventVideoPlayer(Event event, {super.key, Timeline? timeline, Color? textColor, Color? linkColor});''',
    'audio_player': '''class AudioPlayerWidget extends StatelessWidget {
  const AudioPlayerWidget(Event event, {super.key, required Color color, required Color linkColor, required double fontSize});''',
    'image_bubble': '''class ImageBubble extends StatelessWidget {
  const ImageBubble(Event event, {super.key, required double width, required double height, required BoxFit fit,
    required BorderRadius borderRadius, Timeline? timeline, Color? textColor, VoidCallback? onTap});''',
    'message_download_content': '''class MessageDownloadContent extends StatelessWidget {
  const MessageDownloadContent(Event event, {super.key, required Color textColor, required Color linkColor});''',
    'cute_events': '''class CuteContent extends StatelessWidget { const CuteContent(Event event, {super.key});''',
    'poll': '''class PollWidget extends StatelessWidget {
  const PollWidget({super.key, required Event event, required Timeline timeline, required Color textColor, required Color linkColor});''',
}.items():
    STUBS[f'lib/pages/chat/events/{name}.dart'] = (
        "import 'package:material_ui/material_ui.dart';\nimport 'package:matrix/matrix.dart';\n"
        + declaration + f"\n  @override Widget build(BuildContext context) => throw StateError('{name} peer UI is excluded');\n}}\n"
    )


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hosted_versions():
    result = {}
    lock = (ROOT / 'pubspec.lock').read_text()
    for match in re.finditer(r'^  ([a-zA-Z0-9_]+):\n(.*?)(?=^  [a-zA-Z0-9_]+:|^sdks:|\Z)', lock, re.M | re.S):
        name, block = match.groups()
        if re.search(r'^    source: hosted\s*$', block, re.M):
            version = re.search(r'^    version: ["\']?([^\s"\']+)', block, re.M)
            if version:
                result[name] = version.group(1)
    return result


def package_roots():
    path = ROOT / '.dart_tool/package_config.json'
    if not path.is_file():
        raise RuntimeError('Root package_config missing; coordinator must resolve the app lock first')
    result = {}
    for package in json.loads(path.read_text())['packages']:
        parsed = urlparse(urljoin(path.as_uri(), package['rootUri']))
        if parsed.scheme != 'file':
            raise RuntimeError('Non-filesystem package root is unsupported')
        result[package['name']] = Path(unquote(parsed.path)).resolve()
    return result


def dependencies(spec):
    section = re.search(r'^dependencies:\s*\n(.*?)(?=^[^\s#]|\Z)', spec, re.M | re.S)
    return re.findall(r'^  ([a-zA-Z0-9_]+):', section.group(1), re.M) if section else []


def dependency_closure(roots, versions):
    visited, selected = set(), set()
    queue = [*DIRECT, *VENDORED, 'flutter', 'flutter_test', 'flutter_lints']
    while queue:
        name = queue.pop()
        if name in visited:
            continue
        visited.add(name)
        if name in FORBIDDEN:
            raise RuntimeError(f'Unrelated app/build-hook dependency reached: {name}')
        package = roots.get(name)
        if package is None or not (package / 'pubspec.yaml').is_file():
            raise RuntimeError(f'Reachable locked package unavailable: {name}')
        if name in VENDORED and package != VENDORED[name].resolve():
            raise RuntimeError(f'{name} must resolve to the actual vendored checkout')
        spec = (package / 'pubspec.yaml').read_text()
        if name in versions:
            actual = re.search(r'^version:\s*["\']?([^\s"\']+)', spec, re.M)
            if actual is None or actual.group(1) != versions[name]:
                raise RuntimeError(f'App lock/package_config version mismatch: {name}')
            selected.add(name)
        queue.extend(dependencies(spec))
    return {name: versions[name] for name in sorted(selected)}


def checked_write(relative, content):
    target = HARNESS / relative
    cursor = target
    while cursor != ROOT:
        if cursor.is_symlink():
            raise RuntimeError(f'Refusing symlink in managed harness: {cursor}')
        cursor = cursor.parent
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


def vendor_snapshot():
    result = {}
    for name, root in VENDORED.items():
        for path in [root / 'pubspec.yaml', *sorted((root / 'lib').rglob('*.dart'))]:
            if path.is_symlink() or not path.is_file():
                raise RuntimeError(f'Vendored source missing/symlinked: {path}')
            result[str(path.relative_to(ROOT))] = digest(path)
    return result


def verify(snapshot):
    if digest(ROOT / 'pubspec.lock') != snapshot['app_lock_sha256']:
        raise RuntimeError('App lock changed during verification; regenerate/re-run harness')
    for relative, expected in snapshot['production_sources'].items():
        if digest(ROOT / relative) != expected or digest(HARNESS / relative) != expected:
            raise RuntimeError(f'Production/copied source changed: {relative}')
    for relative, expected in snapshot['vendored_sources'].items():
        if digest(ROOT / relative) != expected:
            raise RuntimeError(f'Vendored source changed: {relative}')
    for relative, expected in snapshot['stub_sources'].items():
        if digest(HARNESS / relative) != expected:
            raise RuntimeError(f'App/platform fixture port changed: {relative}')


def prepare():
    pinned = dependency_closure(package_roots(), hosted_versions())
    for name in [*DIRECT, 'flutter_lints']:
        if name not in pinned:
            raise RuntimeError(f'Locked hosted dependency absent: {name}')
    if HARNESS.is_symlink() or HARNESS.parent.is_symlink():
        raise RuntimeError('Refusing symlinked harness/build directory')
    if HARNESS.exists():
        marker = HARNESS / MARKER
        if marker.is_symlink() or not marker.is_file() or marker.read_text() != MARKER_CONTENT:
            raise RuntimeError('Existing player harness is not managed; no files overwritten')
    else:
        HARNESS.mkdir(parents=True)
        (HARNESS / MARKER).write_text(MARKER_CONTENT)
    snapshot = {
        'app_lock_sha256': digest(ROOT / 'pubspec.lock'),
        'production_sources': {}, 'vendored_sources': vendor_snapshot(),
        'stub_sources': {}, 'hosted_versions': pinned, 'tests': TESTS,
        'scope': 'Source-exact fixtures, app/platform/UI ports stubbed; no real account/native Android/Telegram acceptance',
    }
    for relative in SOURCES + TESTS:
        source = ROOT / relative
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f'Production source/test missing or symlinked: {relative}')
        checked_write(relative, source.read_bytes().decode('utf-8'))
        snapshot['production_sources'][relative] = digest(source)
    for relative, content in STUBS.items():
        checked_write(relative, '// FIXTURE PORT ONLY - excluded production app/platform/UI behavior.\n' + content)
        snapshot['stub_sources'][relative] = digest(HARNESS / relative)
    direct = ''.join(f'  {name}: "{pinned[name]}"\n' for name in DIRECT)
    overrides = ''.join(f'  {name}: "{version}"\n' for name, version in pinned.items())
    vendor = ''.join(f'  {name}:\n    path: {json.dumps(str(path.resolve()))}\n' for name, path in VENDORED.items())
    checked_write('pubspec.yaml', f'''name: fluffychat
publish_to: none
description: Source-exact round playback fixtures with explicit app/UI ports.
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
{direct}{vendor}dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: "{pinned['flutter_lints']}"
dependency_overrides:
{overrides}hooks:
  user_defines:
    sqlite3:
      source: sqlcipher
flutter:
  uses-material-design: true
''')
    checked_write('analysis_options.yaml', 'include: package:flutter_lints/flutter.yaml\nanalyzer:\n  errors:\n    todo: ignore\n')
    checked_write('PORTS.md', '''# Fixture boundary

All files in production_sources/SOURCE-MANIFEST.json are copied byte-for-byte.
Matrix/personal_core use their real vendored files, also SHA-snapshotted.
material_ui, video_player, just_audio, path_provider and transitive hosted
dependencies use the app's exact lock versions. Native SDK hooks remain enabled.

Stubbed app ports: PersonalPrivacy supplies an unlocked fixture surface;
TelegramRoundService supplies no reverse state and denies all receipts/forward;
AppSettings supplies static fixture configuration. No trusted sender, E2EE,
private journal, account recovery, incognito transport or bridge-state acceptance
is proven by these ports. Mini-player/renderer state guards and resource ownership
are real production code. Source-expiry tests supply explicit guarded source state.

Unrelated UI ports: ordinary audio/video/image/file/cute/poll/HTML/location/viewer,
transcript panel, l10n, checkbox metadata, URL launcher, native export/share and
generic download dialog. Their build()/external actions throw if exercised.
The dialog port retains production DeprecatedApiAccessExtension result/error
getter semantics; it does not replace the Result type or product export API.
They only let the actual MessageContent guard/routing compile; ordinary media
playback or those UI branches are not acceptance-tested here. Path-provider retry
uses the official plugin platform mock, not a real device path-provider channel.

No initialize()/native texture in mini lifecycle fixtures; native controller API
ownership is tested without a codec. Physical Android audio routes/focus, TalkBack,
real permissions, hardware playback, Keystore, runtime bridge and Telegram delivery
remain NOT RUN. Native SDK hook/build success is not runtime E2EE acceptance.
''')
    checked_write('SOURCE-MANIFEST.json', json.dumps(snapshot, indent=2) + '\n')
    verify(snapshot)
    return snapshot


def run(argv, environment):
    print('Running:', ' '.join(argv), flush=True)
    subprocess.run(['rtk', *argv], cwd=HARNESS, env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default=str(ROOT.parent / 'spikes/toolchains/flutter-3.47.4/bin/flutter'))
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--skip-analyze', action='store_true')
    args = parser.parse_args()
    expected = ROOT.parent / 'spikes/toolchains/flutter-3.47.4/bin/flutter'
    if Path(args.flutter).resolve() != expected.resolve():
        raise RuntimeError('Player verification must use the isolated Flutter 3.47.4 toolchain')
    snapshot = prepare()
    print(f'Prepared separate managed player harness: {HARNESS}', flush=True)
    if args.prepare_only:
        return
    environment = os.environ.copy()
    toolchains = ROOT.parent / 'spikes/toolchains'
    environment['CARGO_HOME'] = str(toolchains / 'cargo')
    environment['RUSTUP_HOME'] = str(toolchains / 'rustup')
    environment['PATH'] = os.pathsep.join([
        str(toolchains / 'cargo/bin'), str(toolchains / 'native-tools/bin'),
        environment.get('PATH', '/usr/bin:/bin'),
    ])
    verify(snapshot)
    run([args.flutter, 'pub', 'get', '--offline'], environment)
    run([args.flutter, 'test', '--no-pub', '--reporter', 'expanded', *TESTS], environment)
    if not args.skip_analyze:
        run([args.flutter, 'analyze', '--no-pub', 'lib', 'test'], environment)
    verify(snapshot)
    print('PASS source-exact round playback fixtures; real Android/Telegram/E2EE/native texture NOT RUN', flush=True)


if __name__ == '__main__':
    main()
