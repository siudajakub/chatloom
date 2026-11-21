// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('new display options round-trip and preserve old defaults', () {
    final old = NotionDisplayPreferences.decode('{"wallpaperPreset":"ocean"}');
    expect(old.wallpaperPreset, NotionWallpaperPreset.ocean);
    expect(old.bubbleFinish, NotionBubbleFinish.automatic);
    expect(old.accountWallpaperEnabled, isTrue);

    final changed = old.copyWith(
      bubbleFinish: NotionBubbleFinish.gradient,
      accountWallpaperEnabled: false,
    );
    expect(changed, isNot(old));
    final restored = NotionDisplayPreferences.decode(changed.encode());
    expect(restored, changed);
    expect(restored.hashCode, changed.hashCode);
    expect(
      restored.copyWith(bubbleRadius: 20).accountWallpaperEnabled,
      isFalse,
    );
    expect(
      restored.copyWith(bubbleRadius: 20).bubbleFinish,
      changed.bubbleFinish,
    );
  });

  test('explicit finishes keep message text clear over glass', () {
    const customSeeds = [
      Color(0xFF000000),
      Color(0xFFFFFFFF),
      Color(0xFFE1CA1B),
      Color(0xFF287F17),
      Color(0xFFDB13AE),
    ];
    const extremes = [Color(0xFFFFFFFF), Color(0xFF000000)];

    for (final brightness in Brightness.values) {
      final base = brightness == Brightness.dark
          ? NotionColors.dark
          : NotionColors.light;
      for (final intensity in NotionIntensity.values) {
        final appearances = [
          for (final accent in NotionAccent.values)
            NotionAppearance(accent: accent, intensity: intensity),
          for (final seed in customSeeds)
            NotionAppearance(
              accent: NotionAccent.blue,
              intensity: intensity,
              custom: seed,
            ),
        ];
        for (final appearance in appearances) {
          final palette = NotionPalette.resolve(appearance, base, brightness);
          expect(
            palette.bubbleGradientFor(NotionBubbleFinish.automatic),
            palette.bubbleGradient,
          );
          expect(palette.bubbleGradientFor(NotionBubbleFinish.solid), isNull);
          for (final finish in [
            NotionBubbleFinish.sheen,
            NotionBubbleFinish.gradient,
          ]) {
            final stops = palette.bubbleGradientFor(finish)!;
            expect(stops, hasLength(2));
            for (var step = 0; step <= 10; step++) {
              final fill = Color.lerp(stops.first, stops.last, step / 10)!;
              for (final wallpaper in extremes) {
                final composite = Color.alphaBlend(
                  fill.withValues(alpha: NotionBubble.fillOpacity),
                  wallpaper,
                );
                expect(
                  NotionContrast.ratio(palette.onBubble, composite),
                  greaterThanOrEqualTo(NotionContrast.minimum),
                  reason: '$appearance $brightness $finish at step $step',
                );
              }
            }
          }
        }
      }
    }
  });

  testWidgets('finish applies to outgoing app bubbles only', (tester) async {
    const custom = Color(0xFFEED99D);
    const outgoingKey = ValueKey('outgoing');
    const incomingKey = ValueKey('incoming');
    const customKey = ValueKey('custom');

    Future<void> mount(NotionBubbleFinish finish) => tester.pumpWidget(
      Builder(
        builder: (context) => MaterialApp(
          theme: ChatLoomThemes.buildTheme(
            context,
            Brightness.dark,
            NotionAppearance.standard,
            NotionDisplayPreferences(bubbleFinish: finish),
          ),
          home: const Scaffold(
            body: Column(
              children: [
                ConversationBubble(
                  key: outgoingKey,
                  body: Text('Outgoing'),
                  outgoing: true,
                ),
                ConversationBubble(
                  key: incomingKey,
                  body: Text('Incoming'),
                  outgoing: false,
                ),
                ConversationBubble(
                  key: customKey,
                  body: Text('Custom'),
                  outgoing: true,
                  backgroundColor: custom,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    BoxDecoration fill(Key key) => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(Container),
          ),
        )
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((box) => box.color != null || box.gradient != null);

    await mount(NotionBubbleFinish.gradient);
    expect(
      (fill(outgoingKey).gradient! as LinearGradient).begin,
      AlignmentDirectional.topStart,
    );
    expect(fill(incomingKey).gradient, isNull);
    expect(fill(customKey).gradient, isNull);
    expect(fill(customKey).color, custom);

    await mount(NotionBubbleFinish.solid);
    await tester.pumpAndSettle();
    expect(fill(outgoingKey).gradient, isNull);
    expect(fill(outgoingKey).color, isNotNull);
  });
}
