// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 8 customization: the new local display preferences, the custom
// accent, quick reactions, and the app-wide effects they have.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(
  Widget child, {
  NotionDisplayPreferences display = NotionDisplayPreferences.standard,
  NotionAppearance appearance = NotionAppearance.standard,
  MediaQueryData media = const MediaQueryData(),
}) {
  final theme = NotionTheme.build(
    Brightness.dark,
    appearance,
    display.trueBlack,
  );
  return MediaQuery(
    data: media,
    child: MaterialApp(
      theme: theme.copyWith(extensions: [...theme.extensions.values, display]),
      builder: (context, child) => NotionDisplayScope(child: child!),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  group('NotionDisplayPreferences (wave 8 fields)', () {
    test('defaults keep the current look', () {
      const d = NotionDisplayPreferences.standard;
      expect(d.trueBlack, isFalse);
      expect(d.uiTextScale, 1);
      expect(d.clockFormat, NotionClockFormat.system);
      expect(d.messageTimestamps, NotionTimestampMode.grouped);
      expect(d.deliveryTicks, isTrue);
      expect(d.senderNames, isTrue);
      expect(d.jumboEmoji, NotionJumboEmoji.large);
      expect(d.jumboEmoji.factor, 5);
      expect(d.inboxPreviewLines, 1);
      expect(d.haptics, isTrue);
      expect(d.wallpaperPreset, NotionWallpaperPreset.none);
      // Settings stored before wave 8 decode to the same defaults.
      expect(
        NotionDisplayPreferences.decode(
          '{"inboxScale": .8}',
        ).copyWith(inboxScale: .75),
        NotionDisplayPreferences.standard,
      );
    });

    test('new choices survive serialization', () {
      const value = NotionDisplayPreferences(
        trueBlack: true,
        uiTextScale: 1.2,
        clockFormat: NotionClockFormat.h24,
        messageTimestamps: NotionTimestampMode.every,
        deliveryTicks: false,
        senderNames: false,
        jumboEmoji: NotionJumboEmoji.off,
        inboxPreviewLines: 2,
        haptics: false,
        wallpaperPreset: NotionWallpaperPreset.ocean,
        wallpaperStrength: .3,
      );
      final restored = NotionDisplayPreferences.decode(value.encode());
      expect(restored, value);
      expect(restored.hashCode, value.hashCode);
      expect(
        restored.copyWith(haptics: true).wallpaperPreset,
        NotionWallpaperPreset.ocean,
      );
    });

    test('unknown names and out-of-range numbers fall back or clamp', () {
      final value = NotionDisplayPreferences.fromJson({
        'clockFormat': 'h36',
        'messageTimestamps': 3,
        'jumboEmoji': null,
        'wallpaperPreset': 'mars',
        'uiTextScale': 9,
        'inboxPreviewLines': 7,
        'wallpaperStrength': -1,
        'trueBlack': 'yes',
      });
      expect(value.clockFormat, NotionClockFormat.system);
      expect(value.messageTimestamps, NotionTimestampMode.grouped);
      expect(value.jumboEmoji, NotionJumboEmoji.large);
      expect(value.wallpaperPreset, NotionWallpaperPreset.none);
      expect(value.uiTextScale, 1.3);
      expect(value.inboxPreviewLines, 2);
      expect(value.wallpaperStrength, .15);
      expect(value.trueBlack, isFalse);
    });

    test('message time visibility follows the mode', () {
      const grouped = NotionDisplayPreferences.standard;
      expect(grouped.showsTime(last: true), isTrue);
      expect(grouped.showsTime(last: false), isFalse);
      const every = NotionDisplayPreferences(
        messageTimestamps: NotionTimestampMode.every,
      );
      expect(every.showsTime(last: false), isTrue);
      const hidden = NotionDisplayPreferences(
        messageTimestamps: NotionTimestampMode.hidden,
      );
      expect(hidden.showsTime(last: true), isFalse);
    });
  });

  group('Custom accent', () {
    test('parses, formats and stores alongside the preset', () async {
      expect(
        ThemeBuilder.parseCustomAccent('#12ab9F'),
        const Color(0xFF12AB9F),
      );
      expect(ThemeBuilder.parseCustomAccent('12AB9F'), const Color(0xFF12AB9F));
      for (final bad in [null, '', '#12345', 'red', '#GGGGGG']) {
        expect(ThemeBuilder.parseCustomAccent(bad), isNull);
      }
      expect(
        ThemeBuilder.formatCustomAccent(const Color(0xFF0A7CFF)),
        '#0A7CFF',
      );
      expect(ThemeBuilder.formatCustomAccent(null), '');

      SharedPreferences.setMockInitialValues({
        AppSettings.appearanceAccent.key: 'teal',
        AppSettings.appearanceCustomAccent.key: '#B4237A',
      });
      final stored = ThemeBuilder.readAppearance(
        await SharedPreferences.getInstance(),
      );
      expect(stored.accent, NotionAccent.teal);
      expect(stored.custom, const Color(0xFFB4237A));
      expect(stored.seed, const Color(0xFFB4237A));
      expect(stored.copyWith(clearCustom: true).seed, NotionAccent.teal.seed);
    });

    test('any custom hue keeps readable bubbles in both themes', () {
      for (var hue = 0; hue < 360; hue += 30) {
        for (final lightness in [.2, .5, .85]) {
          final color = HSLColor.fromAHSL(
            1,
            hue.toDouble(),
            .9,
            lightness,
          ).toColor();
          for (final intensity in NotionIntensity.values) {
            for (final (base, brightness) in [
              (NotionColors.dark, Brightness.dark),
              (NotionColors.light, Brightness.light),
              (NotionColors.black, Brightness.dark),
            ]) {
              final palette = NotionPalette.resolve(
                NotionAppearance(
                  accent: NotionAccent.blue,
                  intensity: intensity,
                  custom: color,
                ),
                base,
                brightness,
              );
              for (final fill in [palette.bubble, ...?palette.bubbleGradient]) {
                expect(
                  NotionContrast.ratio(palette.onBubble, fill),
                  greaterThanOrEqualTo(4.5),
                  reason: 'hue $hue l $lightness ${intensity.name}',
                );
              }
            }
          }
        }
      }
    });
  });

  group('Quick reactions', () {
    test('parse falls back to the defaults on damaged values', () {
      expect(
        ConversationMessageActions.parseQuickReactions(''),
        NotionReactions.defaults,
      );
      for (final bad in ['{', '"x"', '[]', '[1, 2]', '[""]']) {
        expect(
          ConversationMessageActions.parseQuickReactions(bad),
          NotionReactions.defaults,
          reason: bad,
        );
      }
      expect(
        ConversationMessageActions.parseQuickReactions(
          '["🔥", "🔥", "🙏", "👀", "🎉", "💯", "😎", "🤝"]',
        ),
        ['🔥', '🙏', '👀', '🎉', '💯', '😎'],
      );
    });

    test('saving the defaults clears the stored value', () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
      await ConversationMessageActions.saveQuickReactions(['🔥', '🙏', '👀']);
      expect(ConversationMessageActions.preferredReactions(), [
        '🔥',
        '🙏',
        '👀',
      ]);
      await ConversationMessageActions.saveQuickReactions(
        NotionReactions.defaults,
      );
      expect(AppSettings.quickReactions.value, '');
      expect(
        ConversationMessageActions.preferredReactions(),
        NotionReactions.defaults,
      );
    });
  });

  test('inbox swipe choices parse with per-side fallbacks', () {
    expect(
      InboxSwipeChoice.parse('pin', InboxSwipeChoice.archive),
      InboxSwipeChoice.pin,
    );
    expect(
      InboxSwipeChoice.parse('bogus', InboxSwipeChoice.read),
      InboxSwipeChoice.read,
    );
  });

  group('Effects', () {
    testWidgets('clock format overrides the device in every time', (
      tester,
    ) async {
      final time = DateTime(2026, 10, 25, 15, 4);
      late String shown;
      Widget probe() => Builder(
        builder: (context) {
          shown = time.localizedTimeOfDay(context);
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        _host(
          probe(),
          display: const NotionDisplayPreferences(
            clockFormat: NotionClockFormat.h24,
          ),
        ),
      );
      expect(shown, '15:04');
      await tester.pumpWidget(
        _host(
          probe(),
          display: const NotionDisplayPreferences(
            clockFormat: NotionClockFormat.h12,
          ),
          media: const MediaQueryData(alwaysUse24HourFormat: true),
        ),
      );
      // The theme (and its extensions) animates to the new value.
      await tester.pumpAndSettle();
      expect(shown, '3:04 PM');
    });

    testWidgets('interface text size multiplies the system scale', (
      tester,
    ) async {
      late double scale;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              scale = MediaQuery.textScalerOf(context).scale(10);
              return const SizedBox();
            },
          ),
          display: const NotionDisplayPreferences(uiTextScale: 1.2),
          media: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        ),
      );
      expect(scale, closeTo(18, .001));
    });

    testWidgets('pure black darkens the page only in the dark theme', (
      tester,
    ) async {
      late Color page;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              page = context.notion.colors.background;
              return const SizedBox();
            },
          ),
          display: const NotionDisplayPreferences(trueBlack: true),
        ),
      );
      expect(page, NotionColors.black.background);
      expect(
        NotionTheme.build(
          Brightness.light,
          NotionAppearance.standard,
          true,
        ).extension<NotionTokens>()!.colors.background,
        NotionColors.light.background,
      );
    });

    testWidgets('two-line previews let the inbox preview wrap', (tester) async {
      Widget row() => SizedBox(
        width: 320,
        child: NotionInboxRow(
          avatar: const SizedBox(),
          name: 'Anna',
          preview:
              'A preview long enough to need a second line in a '
              'narrow chat list row, and then some more words',
          onTap: () {},
        ),
      );
      Text preview(WidgetTester tester) =>
          tester.widget<Text>(find.textContaining('A preview long enough'));
      await tester.pumpWidget(_host(row()));
      expect(preview(tester).maxLines, 1);
      await tester.pumpWidget(
        _host(
          row(),
          display: const NotionDisplayPreferences(inboxPreviewLines: 2),
        ),
      );
      await tester.pumpAndSettle();
      expect(preview(tester).maxLines, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('preset wallpapers paint a static gradient', (tester) async {
      await tester.pumpWidget(
        _host(
          const Stack(
            children: [
              NotionPresetWallpaper(
                preset: NotionWallpaperPreset.sunset,
                strength: .4,
              ),
            ],
          ),
        ),
      );
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(NotionPresetWallpaper),
          matching: find.byType(DecoratedBox),
        ),
      );
      final gradient = (box.decoration as BoxDecoration).gradient!;
      expect(gradient.colors, hasLength(3));
      expect(gradient.colors.first.a, closeTo(.4, .01));
      await tester.pumpWidget(
        _host(
          const Stack(
            children: [
              NotionPresetWallpaper(
                preset: NotionWallpaperPreset.none,
                strength: .4,
              ),
            ],
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(NotionPresetWallpaper),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
    });

    testWidgets('haptics follow the stored preference', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppSettings.appearanceDisplay.key: const NotionDisplayPreferences(
          haptics: false,
        ).encode(),
      });
      final preferences = await SharedPreferences.getInstance();
      late ThemeController controller;
      await tester.pumpWidget(
        ThemeBuilder(
          preferences: preferences,
          builder: (context, mode, appearance) {
            controller = ThemeController.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(NotionHaptics.enabled, isFalse);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') calls.add('vibrate');
          return null;
        },
      );
      NotionHaptics.send();
      expect(calls, isEmpty);
      await controller.resetDisplayPreferences();
      expect(NotionHaptics.enabled, isTrue);
      NotionHaptics.send();
      await tester.pump();
      expect(calls, ['vibrate']);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  });
}
