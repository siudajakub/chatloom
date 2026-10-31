// SPDX-License-Identifier: AGPL-3.0-or-later

/// "Keep deleted messages" (J, 2026-10-31): a device-local copy of a message
/// taken the moment its deletion syncs, before the SDK wipes the content
/// ([Client.onBeforeRedaction], vendored SDK).
///
/// - Off by default (Settings → Chats). While on: messages other people
///   delete (default on), the user's own deletions (default off), view-once
///   and disappearing messages (default off, an explicit opt-in).
/// - Never kept: ChatLoom's own tidy-up deletions
///   ([MessageDeletions.isCleanup]), reactions, edits, state, messages this
///   device could not decrypt, and messages that were not synced before
///   they were deleted (there is nothing left to copy).
/// - Stored per account in the encrypted device store (SQLCipher,
///   `PersonalClient.writeLocalRecord`, `local:kept:`), one record per
///   message: never synced to the worker journal or the homeserver, never
///   logged, `toString` is redacted. Bounded to 5000 messages and 180 days
///   ([KeptMessages.defaultCapacity], [KeptMessages.defaultMaxAge]); "Clear
///   kept messages" and signing out delete them.
/// - Media keep their attachment reference only: a file that is still in
///   the local cache can be shown, nothing is downloaded after deletion.
///
/// Stable API:
/// ```dart
/// KeptMessages.instance.attach(client, onKept: notify); // hook + load
/// KeptMessages.of(event);   // the kept copy of a redacted event, or null
/// KeptMessages.instance.clear(client);  // "Clear kept messages"
/// KeptMessages.instance.forget(client, personal); // sign-out
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart'
    show RoundMediaPolicy, beeperDisappearingTimerKey, disappearingTimerLimits;

/// Which deletions are kept (Settings → Chats → Keep deleted messages).
@immutable
class KeepDeletedOptions {
  final bool enabled;
  final bool byOthers;
  final bool own;
  final bool disappearing;

  const KeepDeletedOptions({
    this.enabled = false,
    this.byOthers = true,
    this.own = false,
    this.disappearing = false,
  });

  static const off = KeepDeletedOptions();

  factory KeepDeletedOptions.fromSettings() => KeepDeletedOptions(
    enabled: AppSettings.keepDeletedMessages.value,
    byOthers: AppSettings.keepDeletedByOthers.value,
    own: AppSettings.keepDeletedOwn.value,
    disappearing: AppSettings.keepDeletedDisappearing.value,
  );
}

/// A deleted message as it was just before its deletion synced.
@immutable
class KeptMessage {
  final String roomId;
  final String eventId;
  final String senderId;
  final String type;

  /// The content, with the author's newest edit applied.
  final Map<String, Object?> content;
  final DateTime sentAt;

  /// When it was deleted: the redaction's server time.
  final DateTime deletedAt;
  final String deletedBy;
  final DeletedKind kind;
  final bool edited;

  const KeptMessage({
    required this.roomId,
    required this.eventId,
    required this.senderId,
    required this.type,
    required this.content,
    required this.sentAt,
    required this.deletedAt,
    required this.deletedBy,
    required this.kind,
    this.edited = false,
  });

  static const _version = 1;

  Map<String, Object?> toJson() => {
    'v': _version,
    'room': roomId,
    'event': eventId,
    'sender': senderId,
    'type': type,
    'content': content,
    'sent': sentAt.millisecondsSinceEpoch,
    'deleted': deletedAt.millisecondsSinceEpoch,
    'by': deletedBy,
    'kind': kind.name,
    if (edited) 'edited': true,
  };

  /// Null for a record this version cannot read.
  static KeptMessage? fromJson(Map<String, dynamic> json) {
    try {
      if (json['v'] != _version) return null;
      final content = json['content'];
      return KeptMessage(
        roomId: json['room'] as String,
        eventId: json['event'] as String,
        senderId: json['sender'] as String,
        type: json['type'] as String,
        content: content is Map
            ? Map<String, Object?>.from(content)
            : <String, Object?>{},
        sentAt: DateTime.fromMillisecondsSinceEpoch(json['sent'] as int),
        deletedAt: DateTime.fromMillisecondsSinceEpoch(json['deleted'] as int),
        deletedBy: json['by'] as String,
        kind: DeletedKind.values.byName(json['kind'] as String),
        edited: json['edited'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// The message as a (not redacted) event of [room], for previews and the
  /// kept bubble. The content is a copy: nothing can strip the kept one.
  Event toEvent(Room room) => Event(
    room: room,
    eventId: eventId,
    senderId: senderId,
    type: type,
    originServerTs: sentAt,
    content: jsonDecode(jsonEncode(content)) as Map<String, dynamic>,
  );

  /// Message content never reaches logs or crash reports.
  @override
  String toString() => 'KeptMessage(protected)';
}

/// Device-local storage of one account's kept messages.
abstract interface class KeptMessagesStorage {
  Future<Map<String, Map<String, dynamic>>> readAll();
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> delete(String key);
}

/// The account's encrypted device store (SQLCipher, `local:kept:`).
class PersonalKeptMessagesStorage implements KeptMessagesStorage {
  PersonalKeptMessagesStorage(this.personal);

  final PersonalClient personal;

  static const prefix = 'kept:';

  /// Waits for the app to open the store (as notifications do).
  @override
  Future<Map<String, Map<String, dynamic>>> readAll() async {
    await personal.loadLocal();
    return personal.readLocalRecords(prefix);
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) =>
      personal.writeLocalRecord('$prefix$key', value);

  @override
  Future<void> delete(String key) => personal.deleteLocalRecord('$prefix$key');
}

typedef KeptMessageListener = void Function(Room room, KeptMessage kept);

class KeptMessages extends ChangeNotifier {
  KeptMessages({
    this.storageFor = defaultStorage,
    this.optionsFor = KeepDeletedOptions.fromSettings,
    this.capacity = defaultCapacity,
    this.maxAge = defaultMaxAge,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The registry the app uses.
  static final instance = KeptMessages();

  static KeptMessagesStorage? defaultStorage(Client client) =>
      client.userID == null
      ? null
      : PersonalKeptMessagesStorage(PersonalClient.of(client));

  /// Kept messages per account; the oldest deletion falls out first.
  static const defaultCapacity = 5000;

  /// Kept messages older than this (by deletion time) are dropped.
  static const defaultMaxAge = Duration(days: 180);

  final int capacity;
  final Duration maxAge;

  /// Longest wait for the store while a sync holds a deletion.
  static const captureTimeout = Duration(seconds: 5);

  // Not final: tests swap them on [instance].
  KeptMessagesStorage? Function(Client client) storageFor;
  KeepDeletedOptions Function() optionsFor;
  final DateTime Function() _now;

  final _accounts = Expando<_KeptAccount>();

  /// Bumped on every change, for widget signatures.
  int get revision => _revision;
  int _revision = 0;

  static String _key(String roomId, String eventId) => '$roomId|$eventId';

  /// The kept copy of [event] while keeping is on, else null. A set lookup.
  static KeptMessage? of(Event event) => instance.lookUp(event);

  KeptMessage? lookUp(Event event) {
    if (!event.redacted) return null;
    final account = _accounts[event.room.client];
    if (account == null || account.entries.isEmpty) return null;
    if (!optionsFor().enabled) return null;
    return account.entries[_key(event.room.id, event.eventId)];
  }

  /// Number of kept messages of [client] (loaded so far).
  int countFor(Client client) => _accounts[client]?.entries.length ?? 0;

  /// Registers [client]: loads its kept messages and installs the SDK hook
  /// while keeping is on ([refreshHooks]). [onKept] hears every message
  /// kept from somebody else's deletion (the deletion notification).
  void attach(Client client, {KeptMessageListener? onKept}) {
    _account(client);
    _listeners[client] = onKept;
    _clients.add(client);
    _installHook(client);
  }

  final _listeners = Expando<KeptMessageListener>();
  final _clients = <Client>{};

  /// Installs or removes the SDK hook of every registered client after the
  /// setting changed. Off, the SDK reads nothing and waits for nothing.
  void refreshHooks() {
    for (final client in _clients) {
      _installHook(client);
    }
    _changed();
  }

  void _installHook(Client client) {
    client.onBeforeRedaction = optionsFor().enabled
        ? (capture) => this
              .capture(capture)
              .timeout(captureTimeout, onTimeout: () {})
              .catchError((Object _) {})
        : null;
  }

  /// Starts loading [client]'s kept messages (idempotent); retries a load
  /// that failed because the store was not open yet.
  void load(Client client) {
    final account = _account(client);
    if (account != null && !account.loaded && !account.loading) {
      account.ready = _load(account);
    }
  }

  /// What [capture] would keep, or null (pure: no store, no listener).
  KeptMessage? keepable(RedactionCapture capture, KeepDeletedOptions options) {
    if (!options.enabled) return null;
    final original = capture.original;
    final redaction = capture.redaction;
    final room = capture.room;
    if (!const {
      EventTypes.Message,
      EventTypes.Sticker,
    }.contains(original.type)) {
      return null;
    }
    if (original.redacted ||
        original.messageType == MessageTypes.BadEncrypted ||
        const {
          RelationshipTypes.edit,
          RelationshipTypes.reaction,
        }.contains(original.relationshipType)) {
      return null;
    }
    // ChatLoom's own tidy-up (an undelivered message, a reverted edit).
    if (MessageDeletions.isCleanup(original) ||
        MessageDeletions.isQuiet(room, redaction.eventId)) {
      return null;
    }
    final info = deletionOfRedaction(redaction, authorId: original.senderId);
    final disappearing =
        info.kind == DeletedKind.disappeared ||
        _limited(original.content) ||
        _limited(capture.latestEdit?.content ?? const {});
    if (disappearing) {
      if (!options.disappearing) return null;
    } else if (info.kind == DeletedKind.own) {
      if (!options.own) return null;
    } else if (!options.byOthers) {
      return null;
    }
    final edit = capture.latestEdit?.content['m.new_content'];
    final content = edit is Map
        ? Map<String, Object?>.from(edit)
        : Map<String, Object?>.from(original.content);
    content.remove('m.new_content');
    content.remove('m.relates_to');
    return KeptMessage(
      roomId: room.id,
      eventId: original.eventId,
      senderId: original.senderId,
      type: original.type,
      content: jsonDecode(jsonEncode(content)) as Map<String, Object?>,
      sentAt: original.originServerTs,
      deletedAt: redaction.originServerTs,
      deletedBy: redaction.senderId,
      kind: disappearing ? DeletedKind.disappeared : info.kind,
      edited: edit is Map,
    );
  }

  /// View-once, timed, protected or disappearing content.
  static bool _limited(Map<String, Object?> content) =>
      content['com.beeper.view_limited'] != null ||
      disappearingTimerLimits(content[beeperDisappearingTimerKey]) ||
      !RoundMediaPolicy.fromContent(content).canPersist;

  /// The SDK hook: keeps [capture] when the options say so. The sync waits
  /// for this (bounded by [captureTimeout] in [attach]).
  Future<void> capture(RedactionCapture capture) async {
    final kept = keepable(capture, optionsFor());
    if (kept == null) return;
    final client = capture.room.client;
    load(client);
    final account = _account(client);
    if (account == null) return;
    await account.ready;
    final key = _key(kept.roomId, kept.eventId);
    if (account.entries.containsKey(key)) return;
    account.entries[key] = kept;
    _prune(account);
    _changed();
    try {
      await account.storage?.write(key, kept.toJson());
    } catch (_) {
      // Kept for this session only; the store is unavailable.
    }
    if (kept.kind != DeletedKind.own && kept.kind != DeletedKind.disappeared) {
      _listeners[client]?.call(capture.room, kept);
    }
  }

  /// "Clear kept messages": deletes every kept message of [client].
  Future<void> clear(Client client) async {
    final account = _account(client);
    if (account == null) return;
    await account.ready;
    final keys = account.entries.keys.toList();
    account.entries.clear();
    _changed();
    for (final key in keys) {
      try {
        await account.storage?.delete(key);
      } catch (_) {}
    }
  }

  /// Sign-out: forgets [client]'s kept messages here and deletes them from
  /// the device store while it is still open (before [PersonalClient.dispose]).
  Future<void> forget(Client client, PersonalClient? personal) async {
    _accounts[client] = null;
    _listeners[client] = null;
    _clients.remove(client);
    client.onBeforeRedaction = null;
    _changed();
    if (personal == null) return;
    try {
      await personal.purgeLocalRecordsOnSignOut(
        PersonalKeptMessagesStorage.prefix,
      );
    } catch (_) {}
  }

  _KeptAccount? _account(Client client) {
    final existing = _accounts[client];
    if (existing != null) return existing;
    if (client.userID == null) return null;
    final account = _accounts[client] = _KeptAccount(storageFor(client));
    account.ready = _load(account);
    return account;
  }

  Future<void> _load(_KeptAccount account) async {
    final storage = account.storage;
    if (storage == null) {
      account.loaded = true;
      return;
    }
    Map<String, Map<String, dynamic>> stored;
    account.loading = true;
    try {
      stored = await storage.readAll();
    } catch (_) {
      return;
    } finally {
      account.loading = false;
    }
    account.loaded = true;
    final loaded = <String, KeptMessage>{};
    final unreadable = <String>[];
    for (final entry in stored.entries) {
      final kept = KeptMessage.fromJson(entry.value);
      if (kept == null) {
        unreadable.add(entry.key);
      } else {
        loaded[entry.key] = kept;
      }
    }
    // Oldest deletion first, then anything captured while loading.
    final sorted = loaded.entries.toList()
      ..sort((a, b) => a.value.deletedAt.compareTo(b.value.deletedAt));
    final live = Map.of(account.entries);
    account.entries
      ..clear()
      ..addEntries(sorted)
      ..addAll(live);
    final dropped = _prune(account, persist: false)..addAll(unreadable);
    if (account.entries.isNotEmpty) _changed();
    for (final key in dropped) {
      try {
        await storage.delete(key);
      } catch (_) {}
    }
  }

  /// Drops kept messages past [maxAge] and beyond [capacity] (oldest
  /// first); returns their keys (deleted from the store unless [persist] is
  /// false, when the caller does it).
  List<String> _prune(_KeptAccount account, {bool persist = true}) {
    final cutoff = _now().subtract(maxAge);
    final dropped = [
      for (final entry in account.entries.entries)
        if (entry.value.deletedAt.isBefore(cutoff)) entry.key,
    ];
    dropped.forEach(account.entries.remove);
    while (account.entries.length > capacity) {
      final oldest = account.entries.keys.first;
      account.entries.remove(oldest);
      dropped.add(oldest);
    }
    if (persist) {
      for (final key in dropped) {
        unawaited(account.storage?.delete(key).catchError((Object _) {}));
      }
    }
    return dropped;
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset(Client client) {
    _accounts[client] = null;
    _listeners[client] = null;
    _clients.remove(client);
    client.onBeforeRedaction = null;
  }

  @visibleForTesting
  Future<void> debugReady(Client client) =>
      _account(client)?.ready ?? Future.value();
}

class _KeptAccount {
  _KeptAccount(this.storage);

  final KeptMessagesStorage? storage;

  /// Insertion order = deletion order (oldest first).
  final entries = <String, KeptMessage>{};
  Future<void> ready = Future.value();
  bool loaded = false;
  bool loading = false;
}
