// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:personal_core/personal_core.dart';

/// Why a change still waits for the background service (Settings → Sync).
enum PendingChangeState {
  /// Private sync is not connected; the change is kept on this device.
  local,

  /// Not handed to the private journal yet.
  sending,

  /// In the journal; no fresh worker heartbeat, so it waits for the worker.
  workerOffline,

  /// In the journal; the running worker normally answers within seconds.
  waiting,

  /// The running worker has not answered it for minutes (see
  /// [PersonalClient.isUnconfirmed]).
  unconfirmed,
}

/// One entity's unconfirmed change, described without identifiers.
class PendingChange {
  final String entity;
  final String title;
  final PendingChangeState state;

  /// The newest command for [entity]; [resendable] ones can be sent again.
  final PersonalOperation operation;
  final bool resendable;

  const PendingChange({
    required this.entity,
    required this.title,
    required this.state,
    required this.operation,
    required this.resendable,
  });

  String get reason => switch (state) {
    PendingChangeState.local =>
      'Saved on this device · sent when private sync is connected',
    PendingChangeState.sending => 'Sending…',
    PendingChangeState.workerOffline =>
      'Background service is offline · applied when it is back',
    PendingChangeState.waiting => 'Waiting for the background service',
    PendingChangeState.unconfirmed =>
      'Not confirmed by the background service · send it again',
  };

  @override
  String toString() => 'PendingChange(${state.name}, redacted)';
}

/// A metadata entity changed on this device and elsewhere; both versions
/// are kept until the user chooses.
class SyncConflict {
  final String entity;
  final String title;
  final bool draft;

  /// Short descriptions of what differs: this device's version and the
  /// version saved by the other device (or the background service).
  final String local;
  final String other;

  const SyncConflict({
    required this.entity,
    required this.title,
    required this.draft,
    required this.local,
    required this.other,
  });

  @override
  String toString() => 'SyncConflict(redacted)';
}

/// What Settings → Sync shows about unconfirmed changes and conflicts.
class SyncChanges {
  final List<PendingChange> pending;
  final List<SyncConflict> conflicts;
  const SyncChanges(this.pending, this.conflicts);

  bool get isEmpty => pending.isEmpty && conflicts.isEmpty;

  /// Legacy chat tags are no longer edited anywhere; their leftovers never
  /// ask the user for anything.
  static bool hidden(String entity) =>
      entity.startsWith('label:') || entity.startsWith('labels:');

  static SyncChanges of(PersonalClient personal, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final newest = <String, PersonalOperation>{};
    for (final op in personal.pending.values) {
      if (hidden(op.entityId)) continue;
      final known = newest[op.entityId];
      if (known == null || op.createdAt.isAfter(known.createdAt)) {
        newest[op.entityId] = op;
      }
    }
    final online = personal.workerOnline;
    final pending = [
      for (final entry in newest.entries)
        () {
          final op = entry.value;
          final published = personal.publishedAt(op) != null;
          final unconfirmed = personal.isUnconfirmed(op, now: at);
          return PendingChange(
            entity: entry.key,
            title: syncEntityTitle(personal, entry.key, operation: op),
            state: !personal.ready
                ? PendingChangeState.local
                : !published
                ? PendingChangeState.sending
                : unconfirmed
                ? PendingChangeState.unconfirmed
                : online
                ? PendingChangeState.waiting
                : PendingChangeState.workerOffline,
            operation: op,
            resendable: personal.ready && unconfirmed,
          );
        }(),
    ]..sort((a, b) => a.title.compareTo(b.title));
    final conflicts = [
      for (final entry in personal.conflicts.entries)
        if (!hidden(entry.key))
          SyncConflict(
            entity: entry.key,
            title: syncEntityTitle(personal, entry.key),
            draft: entry.key.startsWith('draft:'),
            local: describeSyncValue(
              entry.key,
              personal.values[entry.key] ?? entry.value['proposedValue'],
              against: entry.value['existingValue'],
            ),
            other: describeSyncValue(
              entry.key,
              entry.value['existingValue'],
              against:
                  personal.values[entry.key] ?? entry.value['proposedValue'],
            ),
          ),
    ]..sort((a, b) => a.title.compareTo(b.title));
    return SyncChanges(pending, conflicts);
  }

  /// The subtitle of Settings › Advanced and of its Private sync row.
  static String settingsSummary(PersonalClient personal) {
    final changes = SyncChanges.of(personal);
    if (!personal.ready) {
      final kept = changes.pending.length;
      return kept == 0
          ? 'Private sync not connected'
          : kept == 1
          ? 'Private sync not connected · 1 change kept on this device'
          : 'Private sync not connected · $kept changes kept on this device';
    }
    if (changes.conflicts.isNotEmpty) {
      final count = changes.conflicts.length;
      return count == 1
          ? '1 setting changed on two devices · choose a version'
          : '$count settings changed on two devices · choose versions';
    }
    if (changes.pending.any(
      (change) => change.state == PendingChangeState.unconfirmed,
    )) {
      return 'Some changes are not confirmed · open to send them again';
    }
    if (changes.pending.isNotEmpty) {
      final count = changes.pending.length;
      return count == 1
          ? '1 change waiting for the background service'
          : '$count changes waiting for the background service';
    }
    return 'Private sync on';
  }
}

String _roomName(PersonalClient personal, String roomId) {
  final room = personal.client.getRoomById(roomId);
  if (room == null) return 'a chat';
  final name = room.getLocalizedDisplayname();
  return name.trim().isEmpty ? 'a chat' : name;
}

String _personName(PersonalClient personal, String groupId) {
  final value = personal.values['person:$groupId']?['name'];
  return value is String && value.trim().isNotEmpty
      ? value
      : 'a merged conversation';
}

/// `org:`, `nickname:`, `avatar:` and `draft:` entities name a chat
/// (`<roomId>`) or a merged person (`person:<groupId>`).
String _subject(PersonalClient personal, String id) => id.startsWith('person:')
    ? _personName(personal, id.substring('person:'.length))
    : _roomName(personal, id);

String _conversationOf(PersonalClient personal, Map<String, dynamic> payload) {
  Object? conversation = payload['conversation'];
  final source = payload['source'];
  final target = payload['target'];
  if (conversation == null && source is Map) {
    conversation = source['conversation'];
  }
  if (conversation == null && target is Map) {
    conversation = target['conversation'];
  }
  final room = conversation is Map ? conversation['roomId'] : null;
  return room is String ? ' · ${_roomName(personal, room)}' : '';
}

/// A human title for a synced entity (no identifiers).
String syncEntityTitle(
  PersonalClient personal,
  String entity, {
  PersonalOperation? operation,
}) {
  final kind = operation?.kind ?? '';
  if (kind.startsWith('transcript.')) {
    final payload = operation!.payload;
    final where = _conversationOf(
      personal,
      payload.containsKey('source')
          ? payload
          : personal.transcripts[entity]?.toJson().cast<String, dynamic>() ??
                const {},
    );
    return kind == 'transcript.cancel'
        ? 'Stop a transcription$where'
        : 'Transcription request$where';
  }
  if (kind.startsWith('schedule.')) {
    return 'Scheduled message${_conversationOf(personal, operation!.payload)}';
  }
  if (kind.startsWith('reminder.')) {
    return 'Reminder${_conversationOf(personal, operation!.payload)}';
  }
  if (kind == 'worker.pairing') return 'Background service pairing';
  if (entity == transcriptionPolicyEntity) return 'Transcription settings';
  for (final (prefix, label) in const [
    ('org:', 'Chat settings'),
    ('nickname:', 'Conversation name'),
    ('avatar:', 'Private photo'),
    ('draft:', 'Draft'),
  ]) {
    if (entity.startsWith(prefix)) {
      return '$label · ${_subject(personal, entity.substring(prefix.length))}';
    }
  }
  if (entity.startsWith('person:')) {
    return 'Merged conversation · '
        '${_personName(personal, entity.substring('person:'.length))}';
  }
  if (entity.startsWith('person-prefs:')) {
    return 'Merged conversation settings · '
        '${_personName(personal, entity.substring('person-prefs:'.length))}';
  }
  if (entity.startsWith('merge-dismissed:')) return 'Merge suggestion';
  if (entity.startsWith('network-policy:')) {
    return 'Network defaults · '
        '${notionNetworkLabel(entity.substring('network-policy:'.length))}';
  }
  if (entity.startsWith('draft-copy:')) return 'Saved draft copy';
  if (entity.startsWith('bookmark:')) return 'Bookmark';
  return 'Private setting';
}

const _fieldLabels = <String, String>{
  'auto': 'Automatic transcription',
  'outgoing': 'Your messages',
  'defaultLanguage': 'Default language',
  'maxSeconds': 'Maximum length',
  'dailyBudgetUsd': 'Daily limit',
  'kinds': 'Media',
  'networks': 'Networks',
  'chatOverrides': 'Chat exceptions',
  'name': 'Name',
  'nickname': 'Conversation name',
  'archived': 'Archived',
  'lowPriority': 'Low priority',
  'muted': 'Privately muted',
  'mutedUntil': 'Mute ends',
  'ignored': 'Ignored',
  'placement': 'Placement',
  'notificationMode': 'Notifications',
  'pinOrder': 'Pinned',
  'theme': 'Colors',
  'members': 'Chats',
  'defaultRoomId': 'Default chat',
  'routing': 'Send messages via',
  'nameRoomId': 'Name',
  'groupPlacement': 'Groups',
  'showInGroups': 'Show in Groups',
  'groupNotifications': 'Group notifications',
  'notifications': 'Notifications',
};

const _kindLabels = <String, String>{
  'voice': 'voice messages',
  'round': 'round videos',
  'video': 'videos',
  'audio': 'other audio',
  'reel': 'Instagram reels',
};

/// Keys that change on every save or say nothing to the user.
const _noise = {
  'updatedAt',
  'version',
  'enabledAt',
  'savedAt',
  'entityId',
  'revision',
  'labelIds',
  'archivedAt',
  'archiveSources',
  'avatarAsset',
  'id',
};

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  return value is List ? value.map(_ordered).toList() : value;
}

bool _sameJson(Object? a, Object? b) =>
    jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));

String _format(String key, Object? value) {
  if (value == null) return 'none';
  if (value is bool) return value ? 'on' : 'off';
  if (key == 'pinOrder') return 'yes';
  // Chat references never show their identifiers.
  if (key == 'defaultRoomId' || key == 'nameRoomId') return 'another chat';
  if (key == 'routing') {
    return value == 'fixed' ? 'always the default chat' : 'automatic';
  }
  if (key == 'maxSeconds' && value is int) {
    return value % 60 == 0 ? '${value ~/ 60} min' : '$value s';
  }
  if (key == 'dailyBudgetUsd' && value is num) {
    return '\$${value.toStringAsFixed(2)}';
  }
  if (key == 'defaultLanguage' && value is String) {
    return transcriptionLanguages[value] ?? 'Automatic';
  }
  if (key == 'members' && value is List) return '${value.length}';
  if (key == 'kinds' && value is Map) {
    final off = [
      for (final entry in value.entries)
        if (entry.value == false) _kindLabels[entry.key] ?? 'a kind',
    ];
    final on = [
      for (final entry in value.entries)
        if (entry.value == true && entry.key == 'reel') _kindLabels[entry.key]!,
    ];
    return [
      if (off.isNotEmpty) 'off for ${off.join(', ')}',
      if (on.isNotEmpty) 'automatic for ${on.join(', ')}',
    ].join(' · ').ifEmpty('defaults');
  }
  if (value is Map) return value.isEmpty ? 'none' : '${value.length} set';
  if (value is String) {
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return 'empty';
    return text.length > 48 ? '${text.substring(0, 47)}…' : text;
  }
  return '$value';
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// What [value] says where it differs from [against], in a few words.
String describeSyncValue(String entity, Object? value, {Object? against}) {
  if (value is! Map) {
    return entity.startsWith('draft:') ? 'No draft' : 'Removed';
  }
  if (entity.startsWith('draft:')) {
    final text = value['text'];
    return text is String && text.trim().isNotEmpty
        ? '“${_format('text', text)}”'
        : 'Empty draft';
  }
  final other = against is Map ? against : const {};
  final keys = <String>{
    ...value.keys.cast<String>(),
    ...other.keys.cast<String>(),
  }..removeAll(_noise);
  final parts = <String>[];
  for (final key in keys.toList()..sort()) {
    final mine = value[key];
    if (_sameJson(mine, other[key])) continue;
    parts.add('${_fieldLabels[key] ?? 'Other setting'}: ${_format(key, mine)}');
  }
  if (parts.isEmpty) return 'Same settings';
  return parts.length > 3
      ? '${parts.take(3).join(' · ')} · ${parts.length - 3} more'
      : parts.join(' · ');
}
