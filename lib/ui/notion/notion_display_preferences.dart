// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

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

  static NotionDisplayPreferences of(BuildContext context) =>
      Theme.of(context).extension<NotionDisplayPreferences>() ?? standard;

  factory NotionDisplayPreferences.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
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
          glassEnabled == other.glassEnabled;

  @override
  int get hashCode => Object.hash(
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
  );
}
