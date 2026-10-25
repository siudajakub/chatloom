// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline preferences: these controls do not need a Matrix account.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/settings_chat/settings_chat.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
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
      AppSettings.autoplayImages,
      AppSettings.renderHtml,
      AppSettings.hideUnknownEvents,
      AppSettings.messagePreviewMaxLines,
      AppSettings.emojiSuggestionLocale,
      AppSettings.displayChatDetailsColumn,
    ]) {
      await AppSettings.store.remove(setting.key);
    }
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: const SettingsChat(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('message display choices save without developer options', (
    tester,
  ) async {
    await mount(tester);
    expect(AppSettings.personalDeveloperOptions.value, isFalse);
    for (final setting in [
      AppSettings.autoplayImages,
      AppSettings.renderHtml,
      AppSettings.hideUnknownEvents,
    ]) {
      final row = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsSwitchListTile && widget.setting == setting,
      );
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(setting.value, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('long message picker preserves a custom stored limit', (
    tester,
  ) async {
    await AppSettings.messagePreviewMaxLines.setItem(37);
    await mount(tester);
    expect(find.text('37 lines'), findsOneWidget);
    final row = find.byKey(const Key('settings_message_preview_lines'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    for (final label in [
      'Unlimited',
      '10 lines',
      '25 lines',
      '50 lines',
      '100 lines',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Unlimited'));
    await tester.pumpAndSettle();
    expect(AppSettings.messagePreviewMaxLines.value, 0);
    expect(find.text('Unlimited'), findsOneWidget);
    expect(find.text('37 lines'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'emoji language keeps custom values until a supported choice is saved',
    (tester) async {
      await AppSettings.emojiSuggestionLocale.setItem('custom-locale');
      await mount(tester);
      expect(find.text('custom-locale'), findsOneWidget);
      final row = find.byKey(const Key('settings_emoji_suggestion_language'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Follow app language'), findsOneWidget);
      await tester.ensureVisible(find.text('日本語'));
      await tester.tap(find.text('日本語'));
      await tester.pumpAndSettle();
      expect(AppSettings.emojiSuggestionLocale.value, 'ja');
      expect(find.text('日本語'), findsOneWidget);
      expect(find.text('custom-locale'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop details preference is saved for subsequently opened chats',
    (tester) async {
      await mount(tester);
      final row = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsSwitchListTile &&
            widget.setting == AppSettings.displayChatDetailsColumn,
      );
      expect(row, findsOneWidget);
      expect(AppSettings.displayChatDetailsColumn.value, isFalse);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(AppSettings.displayChatDetailsColumn.value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
