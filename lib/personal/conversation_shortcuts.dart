// SPDX-License-Identifier: AGPL-3.0-or-later

/// Android dynamic conversation shortcuts for the most recent chats
/// (features FT-21, partial): long-press the launcher icon to open a chat.
///
/// Privacy: a shortcut carries only the inbox entity (room id or merged
/// person key, never shown) and the name the inbox shows (private nickname
/// first), never message text or an avatar. None exist while the app lock is
/// set or notification previews are off (the launcher would show names the
/// lock hides); they are removed then and on sign-out.
library;

import 'dart:async';

import 'package:chatloom/personal/inbox_projection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:matrix/matrix.dart';

/// Prefix of a conversation shortcut's action string.
const conversationShortcutPrefix = 'chatloom-chat:';

/// One shortcut: [entity] is `InboxProjection.entityFor` of its row.
@immutable
class ConversationShortcut {
  const ConversationShortcut({required this.entity, required this.label});

  final String entity;
  final String label;

  String get action => '$conversationShortcutPrefix$entity';

  @override
  bool operator ==(Object other) =>
      other is ConversationShortcut &&
      other.entity == entity &&
      other.label == label;

  @override
  int get hashCode => Object.hash(entity, label);
}

/// The inbox entity of a shortcut action, or null for any other action.
String? conversationShortcutEntity(String action) {
  if (!action.startsWith(conversationShortcutPrefix)) return null;
  final entity = action.substring(conversationShortcutPrefix.length);
  return entity.isEmpty ? null : entity;
}

/// The [limit] newest joined chats of the main list (pinned first, as the
/// inbox orders them), one per merged person.
List<ConversationShortcut> topConversationShortcuts(
  InboxProjection projection,
  InboxIndex index, {
  int limit = 4,
}) {
  final result = <ConversationShortcut>[];
  for (final room in projection.select(index)) {
    if (result.length >= limit) break;
    if (room.membership != Membership.join) continue;
    final label = projection.displayName(room).trim();
    if (label.isEmpty) continue;
    result.add(
      ConversationShortcut(entity: projection.entityFor(room), label: label),
    );
  }
  return result;
}

/// Publishes shortcuts at most every [minInterval] and only when they
/// changed; removing them (privacy) is immediate.
class ConversationShortcutPublisher {
  ConversationShortcutPublisher({
    Future<void> Function(List<ConversationShortcut> shortcuts)? publish,
    Future<void> Function()? clear,
    DateTime Function()? now,
    this.minInterval = const Duration(minutes: 5),
  }) : _publish = publish ?? _publishAndroid,
       _clear = clear ?? _clearAndroid,
       _now = now ?? DateTime.now;

  final Future<void> Function(List<ConversationShortcut>) _publish;
  final Future<void> Function() _clear;
  final DateTime Function() _now;
  final Duration minInterval;

  List<ConversationShortcut>? _published;
  DateTime? _publishedAt;
  bool _cleared = false;

  /// Offers the current top chats. [allowed] false removes every shortcut.
  /// Platform calls are fire-and-forget.
  void offer(List<ConversationShortcut> shortcuts, {required bool allowed}) {
    if (!allowed || shortcuts.isEmpty) {
      if (_cleared) return;
      _cleared = true;
      _published = null;
      _publishedAt = null;
      // The plugin never answers these two calls: never await them.
      unawaited(_clear().catchError((Object _) {}));
      return;
    }
    if (_published != null && listEquals(_published, shortcuts)) return;
    final at = _publishedAt;
    final now = _now();
    if (at != null && now.difference(at) < minInterval) return;
    _published = List.unmodifiable(shortcuts);
    _publishedAt = now;
    _cleared = false;
    unawaited(_publish(shortcuts).catchError((Object _) {}));
  }

  static Future<void> _publishAndroid(List<ConversationShortcut> shortcuts) =>
      FlutterShortcuts().setShortcutItems(
        shortcutItems: [
          for (final shortcut in shortcuts)
            ShortcutItem(
              id: shortcut.entity,
              action: shortcut.action,
              shortLabel: shortcut.label,
              conversationShortcut: true,
              // The app icon, never an avatar (privacy). The plugin needs
              // one: a person shortcut without an icon fails natively.
              icon: 'ic_launcher',
              shortcutIconAsset: ShortcutIconAsset.androidAsset,
            ),
        ],
      );

  static Future<void> _clearAndroid() =>
      FlutterShortcuts().clearShortcutItems();
}

/// Removes every conversation shortcut now (sign-out). Fire-and-forget.
void clearConversationShortcuts() => unawaited(
  FlutterShortcuts().clearShortcutItems().catchError((Object _) {}),
);
