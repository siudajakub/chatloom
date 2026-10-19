// Offline: SharedPreferences mock only, no account or platform plugins.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/settings_chat/settings_media_view.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  setUp(() async {
    for (final setting in [
      AppSettings.audioRecordingNoiseSuppress,
      AppSettings.audioRecordingAutoGain,
      AppSettings.audioRecordingEchoCancel,
      AppSettings.personalVoiceIsolation,
      AppSettings.personalVoiceHighQuality,
      AppSettings.personalRoundHighQuality,
      AppSettings.personalRoundStabilization,
      AppSettings.personalRoundNoiseReduction,
      AppSettings.personalAutoDownloadVoiceRounds,
      AppSettings.personalAutoDownloadWifiOnly,
    ]) {
      await AppSettings.store.remove(setting.key);
    }
  });

  Future<void> mount(WidgetTester tester, {bool rounds = true}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsMediaPage(showRoundOptions: rounds),
      ),
    );
    // Let the sections' one-shot entrance settle (semantics of a section
    // are excluded while it is still fully transparent).
    await tester.pumpAndSettle();
  }

  NotionSettingsToggle toggle(WidgetTester tester, AppSettings<bool> setting) =>
      tester.widget<NotionSettingsToggle>(find.byKey(ValueKey(setting.key)));

  Future<void> tap(WidgetTester tester, AppSettings<bool> setting) async {
    await tester.tap(find.byKey(ValueKey(setting.key)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows defaults for every voice, round and download option', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Voice messages & round videos'), findsOneWidget);
    expect(
      find.text('Auto-download voice messages & round videos'),
      findsOneWidget,
    );
    expect(find.text('Play instantly, no waiting'), findsOneWidget);
    expect(
      find.text('Uses the call microphone mode; may sound like a phone call.'),
      findsOneWidget,
    );
    for (final section in [
      'Voice messages',
      'Round videos',
      'Media downloads',
    ]) {
      expect(find.text(section), findsOneWidget);
    }
    expect(toggle(tester, AppSettings.audioRecordingNoiseSuppress).value, true);
    expect(toggle(tester, AppSettings.audioRecordingAutoGain).value, true);
    expect(toggle(tester, AppSettings.audioRecordingEchoCancel).value, false);
    expect(toggle(tester, AppSettings.personalVoiceIsolation).value, false);
    expect(toggle(tester, AppSettings.personalVoiceHighQuality).value, false);
    expect(toggle(tester, AppSettings.personalRoundHighQuality).value, false);
    expect(toggle(tester, AppSettings.personalRoundStabilization).value, true);
    expect(toggle(tester, AppSettings.personalRoundNoiseReduction).value, true);
    expect(
      toggle(tester, AppSettings.personalAutoDownloadVoiceRounds).value,
      true,
    );
    expect(
      toggle(tester, AppSettings.personalAutoDownloadWifiOnly).value,
      false,
    );
  });

  testWidgets('toggles persist to AppSettings', (tester) async {
    await mount(tester);
    await tap(tester, AppSettings.personalVoiceHighQuality);
    expect(AppSettings.personalVoiceHighQuality.value, isTrue);
    await tap(tester, AppSettings.audioRecordingAutoGain);
    expect(AppSettings.audioRecordingAutoGain.value, isFalse);
    await tap(tester, AppSettings.personalRoundHighQuality);
    expect(AppSettings.personalRoundHighQuality.value, isTrue);
    await tap(tester, AppSettings.personalRoundStabilization);
    expect(AppSettings.personalRoundStabilization.value, isFalse);
    await tap(tester, AppSettings.personalAutoDownloadWifiOnly);
    expect(AppSettings.personalAutoDownloadWifiOnly.value, isTrue);
    expect(toggle(tester, AppSettings.personalVoiceHighQuality).value, isTrue);
  });

  testWidgets('voice isolation locks noise suppression and echo cancel on', (
    tester,
  ) async {
    await AppSettings.audioRecordingNoiseSuppress.setItem(false);
    await mount(tester);
    expect(
      toggle(tester, AppSettings.audioRecordingNoiseSuppress).value,
      false,
    );
    await tap(tester, AppSettings.personalVoiceIsolation);
    expect(AppSettings.personalVoiceIsolation.value, isTrue);
    final ns = toggle(tester, AppSettings.audioRecordingNoiseSuppress);
    final aec = toggle(tester, AppSettings.audioRecordingEchoCancel);
    expect(ns.value, isTrue);
    expect(ns.onChanged, isNull);
    expect(aec.value, isTrue);
    expect(aec.onChanged, isNull);
    // The stored individual preference is kept for when isolation is off.
    expect(AppSettings.audioRecordingNoiseSuppress.value, isFalse);
  });

  testWidgets('Wi-Fi only is disabled while auto-download is off', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, AppSettings.personalAutoDownloadVoiceRounds);
    expect(AppSettings.personalAutoDownloadVoiceRounds.value, isFalse);
    expect(
      toggle(tester, AppSettings.personalAutoDownloadWifiOnly).onChanged,
      isNull,
    );
    expect(find.text('Turn on auto-download first'), findsOneWidget);
  });

  testWidgets('round section is hidden where round capture is unavailable', (
    tester,
  ) async {
    await mount(tester, rounds: false);
    expect(find.text('Round videos'), findsNothing);
    expect(
      find.byKey(ValueKey(AppSettings.personalRoundHighQuality.key)),
      findsNothing,
    );
  });

  testWidgets('toggles expose switch semantics with English labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester);
    expect(
      tester.getSemantics(
        find.byKey(ValueKey(AppSettings.personalVoiceIsolation.key)),
      ),
      matchesSemantics(
        label: 'Strong noise reduction',
        hint: 'Voice isolation for noisy places. May sound narrower',
        hasToggledState: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });
}
