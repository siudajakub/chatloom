// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'notion_message_text_scaler.dart';
import 'notion_wallpapers.dart';

export 'notion_wallpapers.dart' show NotionWallpaperPreset;

/// Clock style of every time the app shows. [system] follows the device
/// setting (and the language on desktop).
enum NotionClockFormat {
  system('Automatic'),
  h12('12-hour'),
  h24('24-hour');

  final String label;
  const NotionClockFormat(this.label);
}

/// Which messages show their time under the bubble.
enum NotionTimestampMode {
  /// The last message of each group (default, Messenger).
  grouped('Last in each group'),

  /// Every message (WhatsApp, Telegram).
  every('Every message'),

  /// None; the time stays in the message menu and details.
  hidden('Hidden');

  final String label;
  const NotionTimestampMode(this.label);
}

/// Size of a message that contains only emoji.
enum NotionJumboEmoji {
  off('Normal size', 1),
  medium('Large', 3),
  large('Extra large', 5);

  final String label;

  /// Multiplier of the message font size.
  final double factor;
  const NotionJumboEmoji(this.label, this.factor);
}

/// Local visual preferences. They never change account or privacy policies.
@immutable
class NotionDisplayPreferences
    extends ThemeExtension<NotionDisplayPreferences> {
  const NotionDisplayPreferences({
    this.inboxScale = .75,
    this.inboxAvatars = true,
    this.inboxPreviews = true,
    this.inboxNetworkBadges = true,
    this.inboxTimestamps = true,
    this.inboxUnreadHighlight = true,
    this.messageTextScale = 1,
    this.messageSpacing = 1,
    this.messageAvatars = true,
    this.bubbleWidth = .78,
    this.bubbleRadius = 18,
    this.reduceMotion = false,
    this.glassEnabled = true,
    this.trueBlack = false,
    this.uiTextScale = 1,
    this.clockFormat = NotionClockFormat.system,
    this.messageTimestamps = NotionTimestampMode.grouped,
    this.deliveryTicks = true,
    this.senderNames = true,
    this.jumboEmoji = NotionJumboEmoji.large,
    this.inboxPreviewLines = 1,
    this.haptics = true,
    this.wallpaperPreset = NotionWallpaperPreset.none,
    this.wallpaperStrength = .5,
  });

  static const standard = NotionDisplayPreferences();

  final double inboxScale;
  final bool inboxAvatars;
  final bool inboxPreviews;
  final bool inboxNetworkBadges;
  final bool inboxTimestamps;
  final bool inboxUnreadHighlight;
  final double messageTextScale;
  final double messageSpacing;
  final bool messageAvatars;
  final double bubbleWidth;
  final double bubbleRadius;
  final bool reduceMotion;
  final bool glassEnabled;

  final bool trueBlack;
  final double uiTextScale;
  final NotionClockFormat clockFormat;
  final NotionTimestampMode messageTimestamps;
  final bool deliveryTicks;
  final bool senderNames;
  final NotionJumboEmoji jumboEmoji;
  final int inboxPreviewLines;
  final bool haptics;
  final NotionWallpaperPreset wallpaperPreset;
  final double wallpaperStrength;

  static NotionDisplayPreferences of(BuildContext context) =>
      Theme.of(context).extension<NotionDisplayPreferences>() ?? standard;

  /// The 24-hour choice, or null to follow the device.
  bool? get use24HourClock => switch (clockFormat) {
    NotionClockFormat.system => null,
    NotionClockFormat.h12 => false,
    NotionClockFormat.h24 => true,
  };

  /// Whether a message in [last] position of its group shows its time.
  bool showsTime({required bool last}) => switch (messageTimestamps) {
    NotionTimestampMode.grouped => last,
    NotionTimestampMode.every => true,
    NotionTimestampMode.hidden => false,
  };

  factory NotionDisplayPreferences.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    T choice<T extends Enum>(List<T> values, String key, T fallback) {
      final value = json[key];
      return values.firstWhere(
        (option) => option.name == value,
        orElse: () => fallback,
      );
    }

    return NotionDisplayPreferences(
      inboxScale: number('inboxScale', .75, .65, 1),
      inboxAvatars: flag('inboxAvatars', true),
      inboxPreviews: flag('inboxPreviews', true),
      inboxNetworkBadges: flag('inboxNetworkBadges', true),
      inboxTimestamps: flag('inboxTimestamps', true),
      inboxUnreadHighlight: flag('inboxUnreadHighlight', true),
      messageTextScale: number('messageTextScale', 1, .85, 1.4),
      messageSpacing: number('messageSpacing', 1, .75, 1.5),
      messageAvatars: flag('messageAvatars', true),
      bubbleWidth: number('bubbleWidth', .78, .6, .95),
      bubbleRadius: number('bubbleRadius', 18, 6, 28),
      reduceMotion: flag('reduceMotion', false),
      glassEnabled: flag('glassEnabled', true),
      trueBlack: flag('trueBlack', false),
      uiTextScale: number('uiTextScale', 1, .85, 1.3),
      clockFormat: choice(
        NotionClockFormat.values,
        'clockFormat',
        NotionClockFormat.system,
      ),
      messageTimestamps: choice(
        NotionTimestampMode.values,
        'messageTimestamps',
        NotionTimestampMode.grouped,
      ),
      deliveryTicks: flag('deliveryTicks', true),
      senderNames: flag('senderNames', true),
      jumboEmoji: choice(
        NotionJumboEmoji.values,
        'jumboEmoji',
        NotionJumboEmoji.large,
      ),
      inboxPreviewLines: number('inboxPreviewLines', 1, 1, 2).round(),
      haptics: flag('haptics', true),
      wallpaperPreset: choice(
        NotionWallpaperPreset.values,
        'wallpaperPreset',
        NotionWallpaperPreset.none,
      ),
      wallpaperStrength: number('wallpaperStrength', .5, .15, 1),
    );
  }

  static NotionDisplayPreferences decode(String? value) {
    if (value == null) return standard;
    try {
      final json = jsonDecode(value);
      return json is Map<String, dynamic>
          ? NotionDisplayPreferences.fromJson(json)
          : standard;
    } on FormatException {
      return standard;
    }
  }

  Map<String, dynamic> toJson() => {
    'inboxScale': inboxScale,
    'inboxAvatars': inboxAvatars,
    'inboxPreviews': inboxPreviews,
    'inboxNetworkBadges': inboxNetworkBadges,
    'inboxTimestamps': inboxTimestamps,
    'inboxUnreadHighlight': inboxUnreadHighlight,
    'messageTextScale': messageTextScale,
    'messageSpacing': messageSpacing,
    'messageAvatars': messageAvatars,
    'bubbleWidth': bubbleWidth,
    'bubbleRadius': bubbleRadius,
    'reduceMotion': reduceMotion,
    'glassEnabled': glassEnabled,
    'trueBlack': trueBlack,
    'uiTextScale': uiTextScale,
    'clockFormat': clockFormat.name,
    'messageTimestamps': messageTimestamps.name,
    'deliveryTicks': deliveryTicks,
    'senderNames': senderNames,
    'jumboEmoji': jumboEmoji.name,
    'inboxPreviewLines': inboxPreviewLines,
    'haptics': haptics,
    'wallpaperPreset': wallpaperPreset.name,
    'wallpaperStrength': wallpaperStrength,
  };

  String encode() => jsonEncode(toJson());

  @override
  NotionDisplayPreferences copyWith({
    double? inboxScale,
    bool? inboxAvatars,
    bool? inboxPreviews,
    bool? inboxNetworkBadges,
    bool? inboxTimestamps,
    bool? inboxUnreadHighlight,
    double? messageTextScale,
    double? messageSpacing,
    bool? messageAvatars,
    double? bubbleWidth,
    double? bubbleRadius,
    bool? reduceMotion,
    bool? glassEnabled,
    bool? trueBlack,
    double? uiTextScale,
    NotionClockFormat? clockFormat,
    NotionTimestampMode? messageTimestamps,
    bool? deliveryTicks,
    bool? senderNames,
    NotionJumboEmoji? jumboEmoji,
    int? inboxPreviewLines,
    bool? haptics,
    NotionWallpaperPreset? wallpaperPreset,
    double? wallpaperStrength,
  }) => NotionDisplayPreferences.fromJson({
    'inboxScale': inboxScale ?? this.inboxScale,
    'inboxAvatars': inboxAvatars ?? this.inboxAvatars,
    'inboxPreviews': inboxPreviews ?? this.inboxPreviews,
    'inboxNetworkBadges': inboxNetworkBadges ?? this.inboxNetworkBadges,
    'inboxTimestamps': inboxTimestamps ?? this.inboxTimestamps,
    'inboxUnreadHighlight': inboxUnreadHighlight ?? this.inboxUnreadHighlight,
    'messageTextScale': messageTextScale ?? this.messageTextScale,
    'messageSpacing': messageSpacing ?? this.messageSpacing,
    'messageAvatars': messageAvatars ?? this.messageAvatars,
    'bubbleWidth': bubbleWidth ?? this.bubbleWidth,
    'bubbleRadius': bubbleRadius ?? this.bubbleRadius,
    'reduceMotion': reduceMotion ?? this.reduceMotion,
    'glassEnabled': glassEnabled ?? this.glassEnabled,
    'trueBlack': trueBlack ?? this.trueBlack,
    'uiTextScale': uiTextScale ?? this.uiTextScale,
    'clockFormat': (clockFormat ?? this.clockFormat).name,
    'messageTimestamps': (messageTimestamps ?? this.messageTimestamps).name,
    'deliveryTicks': deliveryTicks ?? this.deliveryTicks,
    'senderNames': senderNames ?? this.senderNames,
    'jumboEmoji': (jumboEmoji ?? this.jumboEmoji).name,
    'inboxPreviewLines': inboxPreviewLines ?? this.inboxPreviewLines,
    'haptics': haptics ?? this.haptics,
    'wallpaperPreset': (wallpaperPreset ?? this.wallpaperPreset).name,
    'wallpaperStrength': wallpaperStrength ?? this.wallpaperStrength,
  });

  // Layout settings switch atomically: intermediate geometry during a
  // theme transition would make rows and bubbles jump on every frame.
  @override
  NotionDisplayPreferences lerp(
    covariant NotionDisplayPreferences? other,
    double t,
  ) => other == null || t < .5 ? this : other;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotionDisplayPreferences &&
          inboxScale == other.inboxScale &&
          inboxAvatars == other.inboxAvatars &&
          inboxPreviews == other.inboxPreviews &&
          inboxNetworkBadges == other.inboxNetworkBadges &&
          inboxTimestamps == other.inboxTimestamps &&
          inboxUnreadHighlight == other.inboxUnreadHighlight &&
          messageTextScale == other.messageTextScale &&
          messageSpacing == other.messageSpacing &&
          messageAvatars == other.messageAvatars &&
          bubbleWidth == other.bubbleWidth &&
          bubbleRadius == other.bubbleRadius &&
          reduceMotion == other.reduceMotion &&
          glassEnabled == other.glassEnabled &&
          trueBlack == other.trueBlack &&
          uiTextScale == other.uiTextScale &&
          clockFormat == other.clockFormat &&
          messageTimestamps == other.messageTimestamps &&
          deliveryTicks == other.deliveryTicks &&
          senderNames == other.senderNames &&
          jumboEmoji == other.jumboEmoji &&
          inboxPreviewLines == other.inboxPreviewLines &&
          haptics == other.haptics &&
          wallpaperPreset == other.wallpaperPreset &&
          wallpaperStrength == other.wallpaperStrength;

  @override
  int get hashCode => Object.hashAll([
    inboxScale,
    inboxAvatars,
    inboxPreviews,
    inboxNetworkBadges,
    inboxTimestamps,
    inboxUnreadHighlight,
    messageTextScale,
    messageSpacing,
    messageAvatars,
    bubbleWidth,
    bubbleRadius,
    reduceMotion,
    glassEnabled,
    trueBlack,
    uiTextScale,
    clockFormat,
    messageTimestamps,
    deliveryTicks,
    senderNames,
    jumboEmoji,
    inboxPreviewLines,
    haptics,
    wallpaperPreset,
    wallpaperStrength,
  ]);
}

/// Applies the app-wide parts of [NotionDisplayPreferences] below a
/// `MaterialApp` (its `builder`): interface text size on top of the system
/// text scale, and the clock format. Haptics are switched in
/// `ThemeController`, since they have no context.
class NotionDisplayScope extends StatelessWidget {
  const NotionDisplayScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final display = NotionDisplayPreferences.of(context);
    final clock = display.use24HourClock;
    if (display.uiTextScale == 1 && clock == null) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: display.uiTextScale == 1
            ? media.textScaler
            : NotionMessageTextScaler(media.textScaler, display.uiTextScale),
        alwaysUse24HourFormat: clock ?? media.alwaysUse24HourFormat,
      ),
      child: child,
    );
  }
}
