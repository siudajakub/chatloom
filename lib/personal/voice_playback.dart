// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'round_video/round_playback_coordinator.dart';
import 'round_video/round_playback_queue.dart';

/// Voice notes: the remembered speed, the session's played notes and the
/// Telegram-style continuation into the next voice notes of a chat.
abstract final class VoicePlayback {
  /// The speed chip cycle (Telegram's 1×, 1.5×, 2× plus 1.25× and 0.5×).
  static const speeds = [1.0, 1.25, 1.5, 2.0, 0.5];

  /// A stored speed outside the cycle falls back to 1×.
  static double validSpeed(double? value) =>
      value != null && speeds.contains(value) ? value : 1.0;

  static double nextSpeed(double current) =>
      speeds[(speeds.indexOf(current) + 1) % speeds.length];

  /// Mounted voice rows that can play a continuation in place, by exact
  /// source. Holds no media and grants no audio.
  static final targets = RoundContinuationTargets();

  /// A recorded voice note (MSC3245), not an attached audio file: only
  /// voice notes continue into each other, like Telegram.
  static bool isVoice(Event event) =>
      event.type == EventTypes.Message &&
      !event.redacted &&
      event.messageType == MessageTypes.Audio &&
      event.content.containsKey('org.matrix.msc3245.voice');
}

/// Device-local, private storage of the played voice notes of one account
/// (`PersonalClient` encrypted store). Never synced, never sent: playing a
/// note sends no receipt either.
abstract interface class VoicePlayedStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

/// Voice notes played on this device, bounded. No bridge reports a verified
/// played state for voice notes, so this is what "unplayed" means for
/// continuation and for the unplayed dot (Telegram). With [storageFor] the
/// set survives restarts; notes older than the account's first load count
/// as played, so an update does not mark the whole history unplayed.
class VoicePlayedNotes extends ChangeNotifier {
  VoicePlayedNotes({this.storageFor});

  static const capacity = 1000;

  /// Storage of an account, or null to keep it in memory only.
  final VoicePlayedStorage? Function(Client client)? storageFor;

  // A set literal keeps insertion order (oldest first).
  final _keys = <(Client, String, String)>{};
  final _accounts = <Client, _PlayedAccount>{};

  static (Client, String, String) _key(Event event) =>
      (event.room.client, event.room.id, event.eventId);

  bool contains(Event event) => _keys.contains(_key(event));

  void add(Event event) {
    final key = _key(event);
    final added = !_keys.contains(key);
    _keys
      ..remove(key)
      ..add(key);
    while (_keys.length > capacity) {
      _keys.remove(_keys.first);
    }
    if (!added) return;
    notifyListeners();
    _account(event.room.client)?.persist(this);
  }

  /// True for an incoming, sent voice note not played on this device; false
  /// otherwise and while the account's played notes are still loading (so a
  /// played note never flashes a dot).
  bool unplayed(Event event) {
    if (!VoicePlayback.isVoice(event) ||
        event.senderId == event.room.client.userID ||
        !event.status.isSent ||
        contains(event)) {
      return false;
    }
    final client = event.room.client;
    if (storageFor == null) return true;
    final account = _account(client);
    final since = account?.since;
    if (account == null || since == null) return false;
    return !event.originServerTs.isBefore(since);
  }

  _PlayedAccount? _account(Client client) {
    final storageFor = this.storageFor;
    if (storageFor == null) return null;
    final existing = _accounts[client];
    if (existing != null) return existing;
    final storage = storageFor(client);
    if (storage == null) return null;
    final account = _accounts[client] = _PlayedAccount(client, storage);
    account.load(this);
    return account;
  }

  /// Sources of [client] in play order, for its storage record.
  List<List<String>> _sourcesOf(Client client) => [
    for (final key in _keys)
      if (identical(key.$1, client)) [key.$2, key.$3],
  ];

  void _changed() => notifyListeners();

  void clear() => _keys.clear();

  int get length => _keys.length;
}

class _PlayedAccount {
  _PlayedAccount(this.client, this.storage);

  final Client client;
  final VoicePlayedStorage storage;

  /// Notes sent before this moment count as played; null while loading.
  DateTime? since;
  Future<void>? _writing;
  bool _dirty = false;

  void load(VoicePlayedNotes notes) {
    unawaited(() async {
      DateTime? stored;
      var record = false;
      try {
        // After the current build pass, which opens the private store for
        // the rows it builds.
        await Future<void>.microtask(() {});
        final value = await storage.read();
        record = value != null;
        final raw = value?['since'];
        stored = raw is String ? DateTime.tryParse(raw) : null;
        final sources = value?['notes'];
        if (sources is List) {
          final loaded = <(Client, String, String)>{
            for (final source in sources)
              if (source is List &&
                  source.length == 2 &&
                  source[0] is String &&
                  source[1] is String)
                (client, source[0] as String, source[1] as String),
          };
          // Notes played while loading stay the newest.
          final played = notes._keys.toList();
          notes._keys
            ..clear()
            ..addAll(loaded)
            ..removeAll(played)
            ..addAll(played);
          while (notes._keys.length > VoicePlayedNotes.capacity) {
            notes._keys.remove(notes._keys.first);
          }
        }
      } catch (_) {
        // Storage unavailable: this session starts the window now.
      }
      since = stored ?? DateTime.now();
      notes._changed();
      if (!record || stored == null) persist(notes);
    }());
  }

  /// Writes the account's record, one write at a time; a change during a
  /// write is written right after it.
  void persist(VoicePlayedNotes notes) {
    if (since == null) return; // The load writes once it finished.
    if (_writing != null) {
      _dirty = true;
      return;
    }
    _writing = () async {
      do {
        _dirty = false;
        try {
          await storage.write({
            'since': since!.toUtc().toIso8601String(),
            'notes': notes._sourcesOf(client),
          });
        } catch (_) {
          // Kept in memory; the next play tries again.
          break;
        }
      } while (_dirty);
      _writing = null;
    }();
  }
}

/// Source references only: building a queue never downloads, decrypts,
/// sends a receipt or consults another account, room or thread.
abstract final class VoicePlaybackQueue {
  /// The voice notes to play after [source] ended, in timeline order: the
  /// run of voice notes right after it, up to the first other message
  /// (Telegram stops at a gap). With [unplayedOnly] (the note was an
  /// unplayed incoming one) own and [played] notes are skipped, not treated
  /// as a gap. Time-limited, protected, unsent and redacted notes never
  /// autoplay, nor does anything in a chat with a disappearing timer.
  static List<Event> after(
    Event source,
    Iterable<Event> history, {
    required bool unplayedOnly,
    required bool Function(Event event) played,
  }) {
    final room = source.room;
    if (!VoicePlayback.isVoice(source) ||
        disappearingTimerLimits(
          room.getState(beeperDisappearingTimerKey)?.content,
        )) {
      return const [];
    }
    Object? thread(Event event) {
      final relation = event.content['m.relates_to'];
      return relation is Map && relation['rel_type'] == RelationshipTypes.thread
          ? relation['event_id']
          : null;
    }

    final sourceThread = thread(source);
    final messages =
        history
            .where(
              (event) =>
                  identical(event.room.client, room.client) &&
                  event.room.id == room.id &&
                  _isMessage(event) &&
                  thread(event) == sourceThread,
            )
            .toList()
          ..sort((a, b) {
            final time = a.originServerTs.compareTo(b.originServerTs);
            return time != 0 ? time : a.eventId.compareTo(b.eventId);
          });
    final index = messages.indexWhere((e) => e.eventId == source.eventId);
    if (index < 0) return const [];
    final own = room.client.userID;
    final seen = <String>{source.eventId};
    final queue = <Event>[];
    for (final event in messages.skip(index + 1)) {
      if (!seen.add(event.eventId)) continue;
      if (!VoicePlayback.isVoice(event)) break;
      if (!event.status.isSent ||
          !event.eventId.startsWith(r'$') ||
          !RoundMediaPolicy.fromContent(event.content).canPersist) {
        continue;
      }
      if (unplayedOnly && (event.senderId == own || played(event))) continue;
      queue.add(event);
    }
    return List.unmodifiable(queue);
  }

  /// A message bubble the reader sees between two notes. Reactions, edits,
  /// state events and deleted messages are not a gap.
  static bool _isMessage(Event event) =>
      !event.redacted &&
      event.relationshipType != RelationshipTypes.edit &&
      (event.type == EventTypes.Message ||
          event.type == EventTypes.Sticker ||
          event.type == EventTypes.Encrypted ||
          event.type == PollEventContent.startType);
}

/// Walks a voice continuation after a note ended, like
/// `RoundMiniPlayerController.continueQueue`: a note with a mounted row
/// plays there; the first note without one plays detached together with
/// the rest ([detached], which then owns and ends [token]). An explicit play,
/// lock, background or account switch ends [token] and with it the walk.
/// Continuation is audible but sends nothing. Never throws.
abstract final class VoiceContinuation {
  static Future<void> run(
    List<Event> queue, {
    required RoundContinuationToken token,
    required double speed,
    required bool Function() allowed,
    required Future<void> Function(List<Event> queue) detached,
    RoundContinuationTargets? targets,
  }) async {
    final rows = targets ?? VoicePlayback.targets;
    var handedOff = false;
    try {
      final claim = token.claim();
      final pending = List<Event>.of(queue);
      while (pending.isNotEmpty) {
        if (!token.active || !allowed()) return;
        final event = pending.removeAt(0);
        final rest = List<Event>.unmodifiable(pending);
        final target = rows.targetFor(event);
        if (target == null) {
          handedOff = true;
          await detached([event, ...rest]);
          return;
        }
        final result = await target.startContinuation(
          rest,
          token: token,
          speed: speed,
          enlarge: false,
        );
        switch (result) {
          case RoundStartResult.started:
            return;
          case RoundStartResult.failed:
            continue;
          case RoundStartResult.aborted:
            if (!token.active || !allowed()) return;
            if (!token.isClaimedBy(claim)) {
              handedOff = true;
              return;
            }
            // The row was recycled while preparing: play it detached.
            if (rows.targetFor(event) == null) {
              handedOff = true;
              await detached([event, ...rest]);
              return;
            }
            continue;
        }
      }
    } catch (_) {
      // A failed hand-off still ends the token below.
      handedOff = false;
    } finally {
      if (!handedOff) token.end();
    }
  }
}
