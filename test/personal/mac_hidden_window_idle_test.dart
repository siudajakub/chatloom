// SPDX-License-Identifier: AGPL-3.0-or-later
// Perf wave (2026-11-26, lane mac): a macOS window that is out of sight
// must not keep frames, video display links or readiness timers going.
// AppKit and the engine report visibility and lifecycle only on change, so
// the app asks once at startup and stops playback while the window is
// hidden even without a `hidden` lifecycle.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Matrix extends MatrixState {
  final Client active;
  _Matrix(this.active);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: AppSettings.store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MacDesktopWindow visibility', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(MacDesktopWindow.desktopChannel, null);
      MacDesktopWindow.visible.value = true;
    });

    test('the startup query applies a window launched out of sight', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(MacDesktopWindow.desktopChannel, (
        call,
      ) async {
        calls.add(call.method);
        return false;
      });
      await MacDesktopWindow.queryVisibility();
      expect(calls, ['visibility']);
      expect(MacDesktopWindow.visible.value, isFalse);
    });

    test('no native answer keeps the window visible', () async {
      messenger.setMockMethodCallHandler(MacDesktopWindow.desktopChannel, (
        call,
      ) async {
        throw PlatformException(code: 'unavailable');
      });
      await MacDesktopWindow.queryVisibility();
      expect(MacDesktopWindow.visible.value, isTrue);
      // Older native builds without the handler.
      messenger.setMockMethodCallHandler(MacDesktopWindow.desktopChannel, null);
      await MacDesktopWindow.queryVisibility();
      expect(MacDesktopWindow.visible.value, isTrue);
    });

    test('only a bool changes it', () {
      MacDesktopWindow.applyVisibility('false');
      MacDesktopWindow.applyVisibility(null);
      expect(MacDesktopWindow.visible.value, isTrue);
      MacDesktopWindow.applyVisibility(false);
      expect(MacDesktopWindow.visible.value, isFalse);
    });
  });

  group('stopWhileWindowHidden', () {
    testWidgets('stops videos once hidden past the grace, spares voice', (
      tester,
    ) async {
      final coordinator = RoundPlaybackCoordinator();
      final calls = <String>[];
      final voice = coordinator.register(
        pause: () async => calls.add('voice pause'),
        stop: () async => calls.add('voice stop'),
        retain: () async => calls.add('voice retain'),
        keepWhileHidden: true,
      );
      coordinator.register(
        pause: () async => calls.add('loop pause'),
        stop: () async => calls.add('loop stop'),
      );
      coordinator.register(
        pause: () async => calls.add('viewer pause'),
        stop: () async => calls.add('viewer stop'),
        retain: () async => calls.add('viewer retain'),
      );
      expect(await voice.acquireAudible(), isTrue);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final stop = coordinator.stopWhileWindowHidden(
        visible,
        lifecycle: () => AppLifecycleState.resumed,
      );
      addTearDown(stop);

      // A Mission Control flash: back before the grace ends.
      visible.value = false;
      await tester.pump(const Duration(seconds: 1));
      visible.value = true;
      await tester.pump(const Duration(seconds: 5));
      expect(calls, isEmpty);

      visible.value = false;
      await tester.pump(RoundPlaybackCoordinator.windowHiddenGrace);
      await tester.pump();
      expect(calls, ['loop stop', 'viewer retain']);
      expect(voice.isCurrent, isTrue, reason: 'MAC-04: voice keeps playing');
      expect(coordinator.suspended, isFalse);
    });

    testWidgets('leaves a hidden lifecycle to the app lock', (tester) async {
      final coordinator = RoundPlaybackCoordinator();
      final calls = <String>[];
      coordinator.register(
        pause: () async => calls.add('pause'),
        stop: () async => calls.add('stop'),
      );
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      final stop = coordinator.stopWhileWindowHidden(
        visible,
        lifecycle: () => AppLifecycleState.hidden,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(calls, isEmpty);
      stop();

      // A window launched hidden (no lifecycle yet) stops from the start.
      final stopNull = coordinator.stopWhileWindowHidden(
        visible,
        lifecycle: () => null,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(calls, ['stop']);
      stopNull();
    });

    testWidgets('stopping the watch cancels a pending stop', (tester) async {
      final coordinator = RoundPlaybackCoordinator();
      final calls = <String>[];
      coordinator.register(pause: () async {}, stop: () async => calls.add(''));
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      coordinator.stopWhileWindowHidden(visible, lifecycle: () => null)();
      await tester.pump(const Duration(seconds: 10));
      expect(calls, isEmpty);
    });
  });

  group('settings readiness refresh', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
    });

    Future<NotionSettingsScaffold Function()> pumpPage(
      WidgetTester tester, {
      required ValueNotifier<bool> tickers,
    }) async {
      final client = Client('hub-readiness-idle', database: _UnusedDatabase());
      final personal = PersonalClient.of(client);
      addTearDown(personal.dispose);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _Matrix(client),
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: tickers,
              builder: (context, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: PersonalSettingsPage(
                client: client,
                section: PersonalSettingsSection.sync,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return () => tester.widget<NotionSettingsScaffold>(
        find.byType(NotionSettingsScaffold),
      );
    }

    testWidgets('refreshes every 30 s only while the page is in front', (
      tester,
    ) async {
      final tickers = ValueNotifier(true);
      addTearDown(tickers.dispose);
      final scaffold = await pumpPage(tester, tickers: tickers);

      var before = scaffold();
      await tester.pump(const Duration(seconds: 31));
      expect(identical(scaffold(), before), isFalse, reason: 'refreshed');

      // Covered route, hidden window or inactive app (TickerMode off).
      tickers.value = false;
      await tester.pump();
      before = scaffold();
      await tester.pump(const Duration(seconds: 95));
      expect(identical(scaffold(), before), isTrue, reason: 'no refresh');

      // In front again: refreshed at once and every 30 s.
      tickers.value = true;
      await tester.pump();
      before = scaffold();
      await tester.pump(const Duration(seconds: 31));
      expect(identical(scaffold(), before), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
