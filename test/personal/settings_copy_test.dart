// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 settings-copy lane: developer options, the configuration editor's
// guarded reset (CS-01), default-on toggles (CC-09) and the short
// background-service status (CS-04). Offline: SharedPreferences mock only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/config_viewer.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _registryKey = 'im.fluffychat.store.clients';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('developer options', () {
    test('off by default; the switch is stored and notifies', () async {
      await AppSettings.store.remove(AppSettings.personalDeveloperOptions.key);
      expect(DeveloperOptions.enabled, isFalse);
      var notified = 0;
      void listener() => notified++;
      DeveloperOptions.changes.addListener(listener);
      addTearDown(() => DeveloperOptions.changes.removeListener(listener));
      await DeveloperOptions.setEnabled(true);
      expect(DeveloperOptions.enabled, isTrue);
      expect(DeveloperOptions.changes.value, isTrue);
      expect(notified, 1);
      await DeveloperOptions.setEnabled(false);
      expect(DeveloperOptions.enabled, isFalse);
    });
  });

  group('configuration editor (CS-01)', () {
    test('rejects text that is not a number', () {
      expect(configValueError(AppSettings.textMessageMaxLength, 'abc'), isNotNull);
      expect(configValueError(AppSettings.textMessageMaxLength, ' 42 '), isNull);
      expect(
        configValueError(AppSettings.personalVoicePlaybackSpeed, '1,5'),
        isNotNull,
      );
      expect(
        configValueError(AppSettings.personalVoicePlaybackSpeed, '1.5'),
        isNull,
      );
      expect(configValueError(AppSettings.applicationName, 'anything'), isNull);
    });

    testWidgets('Reset asks first and keeps the account registry', (
      tester,
    ) async {
      await AppSettings.store.setString(_registryKey, 'registry');
      await AppSettings.personalIncognito.setItem(false);
      await AppSettings.pushNotificationsGatewayUrl.setItem(
        'https://gateway.example.invalid/notify',
      );
      await tester.pumpWidget(const MaterialApp(home: ConfigViewer()));
      await tester.pumpAndSettle();

      // Cancel: nothing changes.
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('Reset all app settings?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(AppSettings.personalIncognito.value, isFalse);

      // Confirm: preferences return to defaults, the rest is kept.
      await tester.tap(find.text('Reset').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NotionButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(AppSettings.personalIncognito.value, isTrue);
      expect(AppSettings.store.getString(_registryKey), 'registry');
      expect(
        AppSettings.pushNotificationsGatewayUrl.value,
        'https://gateway.example.invalid/notify',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a default-on toggle shows on before it is written (CC-09)', (
    tester,
  ) async {
    await AppSettings.store.remove(AppSettings.personalNotificationPreviews.key);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSwitchListTile.adaptive(
            title: 'Show sender and message preview',
            setting: AppSettings.personalNotificationPreviews,
          ),
        ),
      ),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(AppSettings.personalNotificationPreviews.value, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  group('background service status (CS-04)', () {
    final now = DateTime(2026, 10, 21, 15);
    WorkerReadiness beat({
      Duration age = const Duration(minutes: 1),
      bool healthy = true,
      String? transcription = 'ready',
      int? pending,
    }) => WorkerReadiness(
      receivedAt: now.subtract(age),
      healthy: healthy,
      verified: true,
      transcription: transcription,
      pending: pending,
    );

    test('a fresh healthy heartbeat is Ready in one short line', () {
      final status = beat().status(now);
      expect(status.label, 'Ready');
      expect(status.health, WorkerHealth.ok);
      expect(status.line, 'Running normally');
      expect(beat(pending: 3).status(now).line, '3 tasks waiting');
      expect(beat(pending: 1).status(now).line, '1 task waiting');
    });

    test('a stale heartbeat says when it was last seen', () {
      final status = beat(age: const Duration(minutes: 58)).status(now);
      expect(status.label, 'Offline');
      expect(status.health, WorkerHealth.offline);
      expect(status.line, startsWith('Last seen at '));
      final older = beat(age: const Duration(days: 2)).status(now);
      expect(older.line, startsWith('Last seen 19 Oct at '));
    });

    test('a reported problem needs attention', () {
      expect(beat(healthy: false).status(now).health, WorkerHealth.attention);
    });

    test('transcription status names a missing or blocked setup', () {
      expect(beat().transcriptionStatus(now).label, 'Ready');
      expect(
        beat(transcription: 'not_configured').transcriptionStatus(now).label,
        'Not set up',
      );
      expect(
        beat(
          transcription: 'blocked_codec_sandbox',
        ).transcriptionStatus(now).label,
        'Needs update',
      );
      expect(beat(transcription: null).transcriptionStatus(now).label, 'Unknown');
      // Offline wins over the last reported transcription state.
      expect(
        beat(age: const Duration(hours: 1)).transcriptionStatus(now).label,
        'Offline',
      );
    });

    test('details avoid internal words like worker and heartbeat', () {
      for (final text in [
        beat().describe(now),
        beat(age: const Duration(hours: 1)).describe(now),
        beat(transcription: 'not_configured', pending: 2).describe(now),
      ]) {
        expect(text.toLowerCase(), isNot(contains('worker')));
        expect(text.toLowerCase(), isNot(contains('heartbeat')));
      }
    });
  });
}
