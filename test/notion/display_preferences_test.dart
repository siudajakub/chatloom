// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/ui/notion/notion_display_preferences.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('missing and corrupt settings preserve compact defaults', () {
    for (final raw in [null, '', '{', 'null', '[]', '42']) {
      expect(
        NotionDisplayPreferences.decode(raw),
        NotionDisplayPreferences.standard,
      );
    }
    expect(NotionDisplayPreferences.standard.inboxScale, .75);
    expect(NotionDisplayPreferences.standard.messageTextScale, 1);
    expect(NotionDisplayPreferences.standard.messageAvatars, isTrue);
  });

  test('untrusted stored values clamp geometry and reject invalid types', () {
    final value = NotionDisplayPreferences.fromJson({
      'inboxScale': 40,
      'messageTextScale': -20,
      'messageSpacing': double.nan,
      'bubbleWidth': 'wide',
      'bubbleRadius': 999,
      'inboxAvatars': 'false',
      'glassEnabled': false,
      'reduceMotion': true,
      'unknownFutureKey': true,
    });
    expect(value.inboxScale, 1);
    expect(value.messageTextScale, .85);
    expect(value.messageSpacing, 1);
    expect(value.bubbleWidth, .78);
    expect(value.bubbleRadius, 28);
    expect(value.inboxAvatars, isTrue);
    expect(value.glassEnabled, isFalse);
    expect(value.reduceMotion, isTrue);
  });

  test('all visual choices survive serialization', () {
    const value = NotionDisplayPreferences(
      inboxScale: .9,
      inboxAvatars: false,
      inboxPreviews: false,
      inboxNetworkBadges: false,
      inboxTimestamps: false,
      inboxUnreadHighlight: false,
      messageTextScale: 1.2,
      messageSpacing: 1.5,
      messageAvatars: false,
      bubbleWidth: .9,
      bubbleRadius: 26,
      reduceMotion: true,
      glassEnabled: false,
    );
    final restored = NotionDisplayPreferences.decode(value.encode());
    expect(restored, value);
    expect(restored.hashCode, value.hashCode);
    expect(restored.copyWith(inboxScale: .8).messageSpacing, 1.5);
    expect(restored.copyWith(bubbleRadius: -1).bubbleRadius, 6);
  });

  testWidgets('stored layout applies on first build and changes persist', (
    tester,
  ) async {
    const initial = NotionDisplayPreferences(
      inboxScale: .8,
      reduceMotion: true,
    );
    SharedPreferences.setMockInitialValues({
      AppSettings.appearanceDisplay.key: initial.encode(),
      AppSettings.appearanceAccent.key: 'teal',
    });
    final preferences = await SharedPreferences.getInstance();
    late ThemeController controller;
    final observed = <NotionDisplayPreferences>[];
    await tester.pumpWidget(
      ThemeBuilder(
        preferences: preferences,
        builder: (context, mode, appearance) {
          controller = ThemeController.of(context);
          observed.add(controller.displayPreferences);
          return const SizedBox();
        },
      ),
    );
    expect(observed.first, initial);
    final updated = initial.copyWith(inboxPreviews: false, bubbleWidth: .9);
    await controller.setDisplayPreferences(updated);
    await tester.pump();
    expect(observed.last, updated);
    expect(ThemeBuilder.readDisplayPreferences(preferences), updated);
    await controller.resetDisplayPreferences();
    await tester.pump();
    expect(observed.last, NotionDisplayPreferences.standard);
    expect(
      ThemeBuilder.readDisplayPreferences(preferences),
      NotionDisplayPreferences.standard,
    );
    expect(preferences.getString(AppSettings.appearanceAccent.key), 'teal');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ThemeBuilder(
        preferences: preferences,
        builder: (context, mode, appearance) {
          expect(
            ThemeController.of(context).displayPreferences,
            NotionDisplayPreferences.standard,
          );
          return const SizedBox();
        },
      ),
    );
  });
}
