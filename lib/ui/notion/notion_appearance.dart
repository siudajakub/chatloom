// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_contrast.dart';
import 'notion_tokens.dart';

/// How much colour the interface shows (DESIGN.md "Colour system").
///
/// The accent hue comes from [NotionAccent]; the intensity decides where it
/// appears and how loud it is. Every combination keeps text in bubbles and
/// on filled controls at WCAG AA (4.5:1).
enum NotionIntensity {
  /// The calm Notion look: grey own bubbles with a hint of the accent, grey
  /// letter avatars, monochrome network marks, a desaturated accent.
  muted('Muted', 'Calm and grey, a hint of colour'),

  /// Messenger's default: solid accent own bubbles, accent badges, toggles
  /// and links, softly tinted letter avatars.
  balanced('Balanced', 'Coloured bubbles and accents'),

  /// Messenger at full volume: gradient own bubbles, saturated letter
  /// avatars, network marks in their brand colours, tinted selection.
  vivid('Vivid', 'Gradients, coloured avatars and networks');

  final String label;
  final String description;
  const NotionIntensity(this.label, this.description);

  static NotionIntensity parse(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => NotionAppearance.standard.intensity,
  );
}

/// The accent presets offered in Appearance. Hues are tuned seeds; the
/// palette derives every tone from them with contrast checks, so a preset
/// never produces unreadable text.
enum NotionAccent {
  /// Messenger blue (default); its gradient ends in Messenger violet.
  blue('Blue', Color(0xFF0A7CFF), Color(0xFFA033FF)),
  indigo('Indigo', Color(0xFF6366F1), Color(0xFFA855F7)),
  violet('Violet', Color(0xFF8B5CF6), Color(0xFFE0409F)),
  pink('Pink', Color(0xFFEC4899), Color(0xFFFF6A3D)),
  red('Red', Color(0xFFEF4444), Color(0xFFF97316)),
  orange('Orange', Color(0xFFF97316), Color(0xFFF43F5E)),
  amber('Amber', Color(0xFFF59E0B), Color(0xFFEF4444)),
  green('Green', Color(0xFF22C55E), Color(0xFF0FB5A6)),
  teal('Teal', Color(0xFF14B8A6), Color(0xFF0A7CFF)),
  cyan('Cyan', Color(0xFF06B6D4), Color(0xFF6366F1)),

  /// No hue: the original monochrome Notion look.
  graphite('Graphite', null, null);

  final String label;

  /// The hue; null for [graphite].
  final Color? seed;

  /// Where the Vivid bubble gradient ends.
  final Color? gradientEnd;
  const NotionAccent(this.label, this.seed, this.gradientEnd);

  static NotionAccent parse(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => NotionAppearance.standard.accent,
  );

  /// The preset closest in hue to a colour stored by the old FluffyChat
  /// colour picker (`primary_color`); greys map to [graphite].
  static NotionAccent nearest(Color color) {
    final hsl = HSLColor.fromColor(color);
    if (hsl.saturation < .15 || hsl.lightness < .08 || hsl.lightness > .95) {
      return graphite;
    }
    var best = blue;
    var bestDistance = double.infinity;
    for (final accent in values) {
      final seed = accent.seed;
      if (seed == null) continue;
      final delta = (HSLColor.fromColor(seed).hue - hsl.hue).abs() % 360;
      final distance = delta > 180 ? 360 - delta : delta;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = accent;
      }
    }
    return best;
  }
}

/// The user's colour preference: an accent preset (or a custom colour) and
/// an intensity.
@immutable
class NotionAppearance {
  final NotionAccent accent;
  final NotionIntensity intensity;

  /// A colour the user picked instead of a preset; it replaces [accent]'s
  /// hue. Contrast is computed from it like from a preset, so any pick
  /// stays readable.
  final Color? custom;
  const NotionAppearance({
    required this.accent,
    required this.intensity,
    this.custom,
  });

  /// What a new install shows: Messenger blue, balanced.
  static const standard = NotionAppearance(
    accent: NotionAccent.blue,
    intensity: NotionIntensity.balanced,
  );

  /// The pre-colour Notion dark v2 look (grey bubbles, neutral accent).
  static const legacy = NotionAppearance(
    accent: NotionAccent.graphite,
    intensity: NotionIntensity.muted,
  );

  /// The hue the palette derives from; null for monochrome (graphite).
  Color? get seed => custom ?? accent.seed;

  /// Where the Vivid gradient ends: a custom colour turns 40° around the
  /// colour wheel, like the presets' hand-picked ends.
  Color? get gradientEnd {
    final custom = this.custom;
    if (custom == null) return accent.gradientEnd;
    final hsl = HSLColor.fromColor(custom);
    return hsl.withHue((hsl.hue + 40) % 360).toColor();
  }

  NotionAppearance copyWith({
    NotionAccent? accent,
    NotionIntensity? intensity,
    Color? custom,
    bool clearCustom = false,
  }) => NotionAppearance(
    accent: accent ?? this.accent,
    intensity: intensity ?? this.intensity,
    custom: clearCustom ? null : custom ?? this.custom,
  );

  @override
  bool operator ==(Object other) =>
      other is NotionAppearance &&
      other.accent == accent &&
      other.intensity == intensity &&
      other.custom == custom;

  @override
  int get hashCode => Object.hash(accent, intensity, custom);

  @override
  String toString() =>
      'NotionAppearance(${accent.name}, ${intensity.name}'
      '${custom == null ? '' : ', custom ${custom!.toARGB32().toRadixString(16)}'})';
}

/// Background and initials of a letter avatar.
typedef NotionAvatarColors = ({Color background, Color foreground});

/// Every colour the accent and intensity produce, resolved once per theme
/// (`context.notion.palette`). Widgets read roles here instead of mixing
/// colours per build, so scrolling never recomputes contrast.
@immutable
class NotionPalette {
  final NotionAppearance appearance;
  final Brightness brightness;

  /// Accent as a foreground on the page: links, active icons, the typing
  /// line, cursor, slider and radio. At least 4.5:1 on the background.
  final Color accent;

  /// Text and icons on [accent] (rarely needed; prefer [accentFill]).
  final Color onAccent;

  /// Filled accent controls: unread badges, the send button, switch tracks,
  /// checkboxes, primary buttons. [onAccentFill] reads on it at 4.5:1.
  final Color accentFill;
  final Color onAccentFill;

  /// A soft accent background: selected tabs, chips and segments, own
  /// reactions, text selection. Opaque.
  final Color accentTint;

  /// Own message bubble: a solid representative colour (quotes, placeholders
  /// and selection blend from it) plus an optional gradient (Vivid).
  final Color bubble;
  final List<Color>? bubbleGradient;

  /// Text in own bubbles; 4.5:1 on [bubble] and on every gradient stop.
  final Color onBubble;

  final List<NotionAvatarColors> _avatars;
  final Map<String, Color> _networks;

  const NotionPalette._({
    required this.appearance,
    required this.brightness,
    required this.accent,
    required this.onAccent,
    required this.accentFill,
    required this.onAccentFill,
    required this.accentTint,
    required this.bubble,
    required this.bubbleGradient,
    required this.onBubble,
    required List<NotionAvatarColors> avatars,
    required Map<String, Color> networks,
  }) : _avatars = avatars,
       _networks = networks;

  /// White: the text colour on every chromatic fill.
  static const _white = Color(0xFFFFFFFF);

  /// Own bubble of the original grey look (`ConversationBubbleColors.dark`).
  static const legacyOutgoingDark = Color(0xFF414141);
  static const legacyBubbleTextDark = Color(0xFFEEEEEC);

  /// Letter-avatar hues (Telegram-like set), picked per name.
  static const avatarHues = <Color>[
    Color(0xFFE5484D),
    Color(0xFFF76B15),
    Color(0xFFD9A400),
    Color(0xFF30A46C),
    Color(0xFF12A594),
    Color(0xFF0090FF),
    Color(0xFF8E4EC6),
    Color(0xFFD6409F),
  ];

  /// Network brand colours, shown only in [NotionIntensity.vivid].
  static const networkBrands = <String, Color>{
    'messenger': Color(0xFF0A7CFF),
    'facebook': Color(0xFF0866FF),
    'instagram': Color(0xFFE1306C),
    'whatsapp': Color(0xFF25D366),
    'telegram': Color(0xFF2AABEE),
    'signal': Color(0xFF3A76F0),
    'slack': Color(0xFFE01E5A),
    'discord': Color(0xFF5865F2),
    'linkedin': Color(0xFF0A66C2),
    'twitter': Color(0xFF1D9BF0),
    'googlechat': Color(0xFF00AC47),
    'gmessages': Color(0xFF1A73E8),
    'sms': Color(0xFF34C759),
    'imessage': Color(0xFF34C759),
  };

  /// Resolves [appearance] against the base roles of one brightness.
  factory NotionPalette.resolve(
    NotionAppearance appearance,
    NotionColors base,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    final intensity = appearance.intensity;
    final legacyOutgoing = dark ? legacyOutgoingDark : base.selected;
    final legacyText = dark ? legacyBubbleTextDark : base.text;
    final seed = appearance.seed;

    final avatars = [
      for (final hue in avatarHues)
        switch (intensity) {
          NotionIntensity.muted => (
            background: base.selected,
            foreground: base.text,
          ),
          NotionIntensity.balanced => _tinted(hue, base, dark),
          NotionIntensity.vivid => (
            background: fillFor(hue, _white),
            foreground: _white,
          ),
        },
    ];
    final networks = intensity == NotionIntensity.vivid
        ? {
            for (final entry in networkBrands.entries)
              // Marks are graphics: 3:1 on the page (WCAG 1.4.11).
              entry.key: inkOn(entry.value, base.background, minimum: 3),
          }
        : const <String, Color>{};

    if (seed == null) {
      // Graphite: the monochrome Notion roles.
      final vivid = intensity == NotionIntensity.vivid;
      return NotionPalette._(
        appearance: appearance,
        brightness: brightness,
        accent: base.text,
        onAccent: base.background,
        accentFill: base.text,
        onAccentFill: base.background,
        accentTint: base.selected,
        bubble: vivid ? base.text : legacyOutgoing,
        bubbleGradient: null,
        onBubble: vivid ? base.background : legacyText,
        avatars: avatars,
        networks: networks,
      );
    }

    final hue = switch (intensity) {
      NotionIntensity.muted => _desaturate(seed, .45),
      NotionIntensity.balanced => seed,
      NotionIntensity.vivid => _saturate(seed, 1.1),
    };
    final accent = inkOn(hue, base.background);
    final accentFill = fillFor(hue, _white);
    final tintAlpha = switch (intensity) {
      NotionIntensity.muted => dark ? .16 : .12,
      NotionIntensity.balanced => dark ? .26 : .16,
      NotionIntensity.vivid => dark ? .34 : .22,
    };
    final accentTint = Color.alphaBlend(
      accentFill.withValues(alpha: tintAlpha),
      base.surface,
    );

    late final Color bubble;
    List<Color>? gradient;
    late final Color onBubble;
    switch (intensity) {
      case NotionIntensity.muted:
        // The grey bubble with a hint of the hue; text keeps its grey.
        bubble = Color.alphaBlend(
          seed.withValues(alpha: dark ? .16 : .14),
          legacyOutgoing,
        );
        onBubble = NotionContrast.readable(bubble, legacyText);
      case NotionIntensity.balanced:
        // Solid and a little deeper than the brightest readable tone.
        bubble = fillFor(_desaturate(seed, .85), _white, minimum: 5.2);
        onBubble = _white;
      case NotionIntensity.vivid:
        final start = fillFor(_saturate(seed, 1.1), _white);
        final end = fillFor(
          _saturate(appearance.gradientEnd ?? seed, 1.1),
          _white,
        );
        gradient = [start, end];
        // Inside the gradient the sRGB blend is darker than either stop, so
        // the midpoint is a safe solid stand-in.
        bubble = Color.lerp(start, end, .5)!;
        onBubble = _white;
    }

    return NotionPalette._(
      appearance: appearance,
      brightness: brightness,
      accent: accent,
      // The accent is tuned against the page, so the page colour reads on it.
      onAccent: base.background,
      accentFill: accentFill,
      onAccentFill: _white,
      accentTint: accentTint,
      bubble: bubble,
      bubbleGradient: gradient,
      onBubble: onBubble,
      avatars: avatars,
      networks: networks,
    );
  }

  /// The palette of the original grey look; used outside a theme.
  static final legacyDark = NotionPalette.resolve(
    NotionAppearance.legacy,
    NotionColors.dark,
    Brightness.dark,
  );
  static final legacyLight = NotionPalette.resolve(
    NotionAppearance.legacy,
    NotionColors.light,
    Brightness.light,
  );

  /// Letter avatar colours for [key] (a name or id); stable across runs.
  NotionAvatarColors avatar(String? key) {
    if (key == null || key.isEmpty) return _avatars.first;
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _avatars[hash % _avatars.length];
  }

  /// The brand colour of a network mark (`messenger`, `whatsapp`, ...) in
  /// Vivid; null means monochrome.
  Color? network(String? key) => key == null ? null : _networks[key];

  static NotionPalette lerp(NotionPalette a, NotionPalette b, double t) {
    Color l(Color x, Color y) => Color.lerp(x, y, t)!;
    final ga = a.bubbleGradient;
    final gb = b.bubbleGradient;
    return NotionPalette._(
      appearance: t < .5 ? a.appearance : b.appearance,
      brightness: t < .5 ? a.brightness : b.brightness,
      accent: l(a.accent, b.accent),
      onAccent: l(a.onAccent, b.onAccent),
      accentFill: l(a.accentFill, b.accentFill),
      onAccentFill: l(a.onAccentFill, b.onAccentFill),
      accentTint: l(a.accentTint, b.accentTint),
      bubble: l(a.bubble, b.bubble),
      bubbleGradient: ga != null && gb != null && ga.length == gb.length
          ? [for (var i = 0; i < ga.length; i++) l(ga[i], gb[i])]
          : (t < .5 ? ga : gb),
      onBubble: l(a.onBubble, b.onBubble),
      avatars: t < .5 ? a._avatars : b._avatars,
      networks: t < .5 ? a._networks : b._networks,
    );
  }

  /// [seed] with its lightness moved until [on] reads on it at [minimum]:
  /// darker under white text, lighter under dark text. Hue and saturation
  /// stay, so the result is the most vivid readable tone.
  static Color fillFor(
    Color seed,
    Color on, {
    double minimum = NotionContrast.minimum + .1,
  }) {
    var hsl = HSLColor.fromColor(seed.withValues(alpha: 1));
    final lighten = on.computeLuminance() < .5;
    for (var i = 0; i < 100; i++) {
      if (NotionContrast.ratio(on, hsl.toColor()) >= minimum) break;
      final next = hsl.lightness + (lighten ? .01 : -.01);
      if (next < 0 || next > 1) break;
      hsl = hsl.withLightness(next);
    }
    return hsl.toColor();
  }

  /// [seed] as a foreground on [background]: lightened on a dark page,
  /// darkened on a light one, until it reaches [minimum].
  static Color inkOn(
    Color seed,
    Color background, {
    double minimum = NotionContrast.minimum + .1,
  }) {
    var hsl = HSLColor.fromColor(seed.withValues(alpha: 1));
    final lighten = background.computeLuminance() < .5;
    for (var i = 0; i < 100; i++) {
      if (NotionContrast.ratio(hsl.toColor(), background) >= minimum) break;
      final next = hsl.lightness + (lighten ? .01 : -.01);
      if (next < 0 || next > 1) break;
      hsl = hsl.withLightness(next);
    }
    return hsl.toColor();
  }

  static NotionAvatarColors _tinted(Color hue, NotionColors base, bool dark) {
    final background = Color.alphaBlend(
      hue.withValues(alpha: dark ? .30 : .20),
      base.surface,
    );
    return (background: background, foreground: inkOn(hue, background));
  }

  static Color _desaturate(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation * factor).clamp(0.0, 1.0))
        .toColor();
  }

  static Color _saturate(Color color, double factor) =>
      _desaturate(color, factor);
}
