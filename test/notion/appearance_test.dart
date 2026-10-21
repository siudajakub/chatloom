// SPDX-License-Identifier: AGPL-3.0-or-later
// Colour system (DESIGN.md "Colour system"): accent presets × intensities,
// contrast and the theme wiring. The Appearance page and live re-theming are
// covered in appearance_controller_test.dart (full app graph).
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _white = Color(0xFFFFFFFF);

Iterable<(NotionAppearance, Brightness)> _all() sync* {
  for (final brightness in Brightness.values) {
    for (final accent in NotionAccent.values) {
      for (final intensity in NotionIntensity.values) {
        yield (
          NotionAppearance(accent: accent, intensity: intensity),
          brightness,
        );
      }
    }
  }
}

NotionColors _base(Brightness b) =>
    b == Brightness.dark ? NotionColors.dark : NotionColors.light;

NotionPalette _palette(NotionAppearance a, Brightness b) =>
    NotionPalette.resolve(a, _base(b), b);

void main() {
  group('palette', () {
    test('every preset and intensity keeps text at WCAG AA', () {
      for (final (appearance, brightness) in _all()) {
        final p = _palette(appearance, brightness);
        final base = _base(brightness);
        final why = '$appearance $brightness';
        expect(
          NotionContrast.ratio(p.onBubble, p.bubble),
          greaterThanOrEqualTo(4.5),
          reason: 'bubble text $why',
        );
        for (final stop in p.bubbleGradient ?? const <Color>[]) {
          expect(
            NotionContrast.ratio(p.onBubble, stop),
            greaterThanOrEqualTo(4.5),
            reason: 'gradient stop $why',
          );
        }
        expect(
          NotionContrast.ratio(p.onAccentFill, p.accentFill),
          greaterThanOrEqualTo(4.5),
          reason: 'accent fill $why',
        );
        expect(
          NotionContrast.ratio(p.accent, base.background),
          greaterThanOrEqualTo(4.5),
          reason: 'accent on page $why',
        );
        expect(
          NotionContrast.ratio(p.onAccent, p.accent),
          greaterThanOrEqualTo(4.5),
          reason: 'on accent $why',
        );
        for (var i = 0; i < 40; i++) {
          final avatar = p.avatar('Person $i');
          expect(
            NotionContrast.ratio(avatar.foreground, avatar.background),
            greaterThanOrEqualTo(4.5),
            reason: 'avatar $i $why',
          );
        }
        for (final key in NotionPalette.networkBrands.keys) {
          final color = p.network(key);
          if (color == null) continue;
          expect(
            NotionContrast.ratio(color, base.background),
            greaterThanOrEqualTo(3),
            reason: 'network $key $why',
          );
        }
      }
    });

    test('muted graphite is exactly the original grey look', () {
      final dark = _palette(NotionAppearance.legacy, Brightness.dark);
      expect(dark.bubble, ConversationBubbleColors.dark.outgoing);
      expect(dark.onBubble, ConversationBubbleColors.dark.text);
      expect(dark.bubbleGradient, isNull);
      expect(dark.accent, NotionColors.dark.text);
      expect(dark.accentFill, NotionColors.dark.text);
      expect(dark.onAccentFill, NotionColors.dark.background);
      expect(dark.accentTint, NotionColors.dark.selected);
      expect(dark.avatar('Anna'), (
        background: NotionColors.dark.selected,
        foreground: NotionColors.dark.text,
      ));
      expect(dark.network('whatsapp'), isNull);
    });

    test('intensities differ the way the settings describe', () {
      const blue = NotionAccent.blue;
      NotionPalette at(NotionIntensity i) => _palette(
        NotionAppearance(accent: blue, intensity: i),
        Brightness.dark,
      );
      final muted = at(NotionIntensity.muted);
      final balanced = at(NotionIntensity.balanced);
      final vivid = at(NotionIntensity.vivid);
      // Muted keeps a grey bubble with grey text; the others are coloured
      // with white text, Vivid as a gradient.
      expect(muted.onBubble, ConversationBubbleColors.dark.text);
      expect(HSLColor.fromColor(muted.bubble).saturation, lessThan(.3));
      expect(balanced.onBubble, _white);
      expect(balanced.bubbleGradient, isNull);
      expect(HSLColor.fromColor(balanced.bubble).saturation, greaterThan(.5));
      expect(vivid.bubbleGradient, hasLength(2));
      expect(vivid.bubbleGradient!.first, isNot(vivid.bubbleGradient!.last));
      // Muted desaturates the accent.
      expect(
        HSLColor.fromColor(muted.accentFill).saturation,
        lessThan(HSLColor.fromColor(balanced.accentFill).saturation),
      );
      // Avatars: grey, tinted, saturated. Networks only in Vivid.
      expect(muted.avatar('Anna').background, NotionColors.dark.selected);
      expect(
        balanced.avatar('Anna').background,
        isNot(muted.avatar('Anna').background),
      );
      expect(vivid.avatar('Anna').foreground, _white);
      expect(balanced.network('whatsapp'), isNull);
      expect(vivid.network('whatsapp'), isNotNull);
    });

    test('avatar colours are stable per name and spread across hues', () {
      final p = _palette(
        const NotionAppearance(
          accent: NotionAccent.blue,
          intensity: NotionIntensity.vivid,
        ),
        Brightness.dark,
      );
      expect(p.avatar('Anna'), p.avatar('Anna'));
      final distinct = {
        for (var i = 0; i < 64; i++) p.avatar('Contact $i').background,
      };
      expect(distinct.length, greaterThan(4));
    });

    test('stored names parse with safe fallbacks', () {
      expect(NotionAccent.parse('pink'), NotionAccent.pink);
      expect(NotionAccent.parse('nope'), NotionAppearance.standard.accent);
      expect(NotionAccent.parse(null), NotionAccent.blue);
      expect(NotionIntensity.parse('vivid'), NotionIntensity.vivid);
      expect(NotionIntensity.parse(''), NotionIntensity.balanced);
    });

    test('old FluffyChat colours map to the closest preset', () {
      expect(NotionAccent.nearest(const Color(0xFF2196F3)), NotionAccent.blue);
      expect(NotionAccent.nearest(const Color(0xFF4CAF50)), NotionAccent.green);
      expect(NotionAccent.nearest(const Color(0xFFE91E63)), NotionAccent.pink);
      expect(
        NotionAccent.nearest(const Color(0xFF5625BA)),
        NotionAccent.violet,
      );
      expect(
        NotionAccent.nearest(const Color(0xFF808080)),
        NotionAccent.graphite,
      );
    });
  });

  group('theme', () {
    test('component themes and bubbles follow the palette', () {
      for (final (appearance, brightness) in _all()) {
        final theme = NotionTheme.build(brightness, appearance);
        final tokens = theme.extension<NotionTokens>()!;
        final p = tokens.palette;
        expect(p.appearance, appearance);
        expect(tokens.colors.accent, p.accent);
        expect(theme.colorScheme.primary, p.accent);
        expect(
          theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
          p.accentFill,
        );
        expect(theme.badgeTheme.backgroundColor, p.accentFill);
        expect(theme.textSelectionTheme.cursorColor, p.accent);
        final bubbles = theme.extension<ConversationBubbleColors>()!;
        expect(bubbles.outgoing, p.bubble);
        expect(bubbles.outgoingText, p.onBubble);
        expect(bubbles.outgoingGradient, p.bubbleGradient);
      }
    });

    test('the default is Messenger blue, balanced', () {
      final p = NotionTheme.build(
        Brightness.dark,
      ).extension<NotionTokens>()!.palette;
      expect(p.appearance, NotionAppearance.standard);
      expect(NotionAppearance.standard.accent, NotionAccent.blue);
      expect(NotionAppearance.standard.intensity, NotionIntensity.balanced);
    });
  });
}
