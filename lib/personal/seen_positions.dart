// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Device-local storage of one account's seen positions.
abstract interface class SeenPositionsStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

/// The account's encrypted private store (`PersonalClient.readLocalRecord`,
/// SQLCipher, `local:` namespace): never synced to the worker journal,
/// never sent anywhere.
class PersonalSeenPositionsStorage implements SeenPositionsStorage {
  PersonalSeenPositionsStorage(this.personal);

  final PersonalClient personal;

  static const key = 'seenPositions';

  /// Throws while the app has not opened the store yet (it never opens it
  /// itself); [SeenPositions.load] then tries again on the next open.
  @override
  Future<Map<String, dynamic>?> read() => personal.readLocalRecord(key);

  @override
  Future<void> write(Map<String, dynamic> value) =>
      personal.writeLocalRecord(key, value);
}

/// Where this device last showed each chat: the newest message on screen at
/// the bottom of the live conversation (what `PersonalPrivacy.observe`
/// sees). Incognito never moves the read marker, so `m.fully_read` stays
/// where it was and every reopen would land on the same stale position;
/// this record lets a chat open at what is new **to this device** instead.
///
/// A positioning hint only: nothing is sent (no receipt, no read marker, no
/// journal entry) and the inbox unread state does not read it. Per account
/// a bounded record (least recently seen chat falls out first) in that
/// account's encrypted private store; writes are coalesced.
class SeenPositions {
  SeenPositions({
    this.storageFor = defaultStorage,
    this.writeDelay = const Duration(seconds: 2),
  });

  /// The registry the app uses.
  static final instance = SeenPositions();

  static SeenPositionsStorage? defaultStorage(Client client) =>
      client.userID == null
      ? null
      : PersonalSeenPositionsStorage(PersonalClient.of(client));

  /// Chats remembered per account.
  static const capacity = 300;

  /// Storage of an account, or null to keep its positions in memory only.
  // Not final: tests swap the store of [instance].
  SeenPositionsStorage? Function(Client client) storageFor;

  /// A burst of new messages at the bottom is written once.
  final Duration writeDelay;

  final _accounts = Expando<_SeenAccount>();

  /// Starts loading [client]'s positions (idempotent; a failed read is
  /// tried again on the next call).
  void load(Client client) {
    final existing = _accounts[client];
    if (existing != null) {
      existing.retry();
      return;
    }
    _account(client);
  }

  _SeenAccount? _account(Client client) {
    final existing = _accounts[client];
    if (existing != null) return existing;
    if (client.userID == null) return null;
    final account = _accounts[client] = _SeenAccount(storageFor(client));
    account.load();
    return account;
  }

  /// [eventId] (sent at [originServerTs]) is the newest message on screen at
  /// the bottom of [room]'s live conversation. Recorded with the read marker
  /// it was seen against, so a marker moved later by another app wins.
  void record(Room room, String eventId, {DateTime? originServerTs}) {
    if (!eventId.startsWith(r'$')) return;
    final account = _account(room.client);
    if (account == null) return;
    final fullyRead = room.fullyRead;
    final current = account.rooms[room.id];
    if (current != null &&
        current.eventId == eventId &&
        current.fullyRead == fullyRead) {
      return;
    }
    account.rooms
      ..remove(room.id)
      ..[room.id] = _Seen(
        eventId,
        fullyRead,
        originServerTs?.millisecondsSinceEpoch ?? 0,
      );
    while (account.rooms.length > capacity) {
      account.rooms.remove(account.rooms.keys.first);
    }
    account.schedule(writeDelay);
  }

  /// The read marker [room] opens at, given the server's [marker]: empty
  /// when this device already showed its newest message, the seen message
  /// when it is newer than the read marker, otherwise [marker].
  String openMarker(Room room, String marker) {
    final seen = _accounts[room.client]?.rooms[room.id];
    // Read further in another app since: the server's marker is newer.
    if (seen == null || seen.fullyRead != room.fullyRead) return marker;
    final latest = room.lastEvent;
    if (latest == null) return marker;
    if (latest.eventId == seen.eventId ||
        seen.originServerTs > latest.originServerTs.millisecondsSinceEpoch) {
      return '';
    }
    return seen.eventId;
  }

  /// Writes [client]'s pending change now (the chat closes, the app goes to
  /// the background).
  void flush(Client client) => _accounts[client]?.flush();

  @visibleForTesting
  void debugReset(Client client) {
    _accounts[client]?.cancel();
    _accounts[client] = null;
  }
}

class _Seen {
  const _Seen(this.eventId, this.fullyRead, this.originServerTs);

  final String eventId;
  final String fullyRead;
  final int originServerTs;
}

class _SeenAccount {
  _SeenAccount(this.storage);

  final SeenPositionsStorage? storage;

  // Insertion order = least recently seen first.
  final rooms = <String, _Seen>{};
  bool _loaded = false;
  bool _loading = false;
  bool _dirty = false;
  Timer? _timer;
  Future<void>? _writing;

  void retry() {
    if (!_loaded && !_loading) load();
  }

  void load() {
    final storage = this.storage;
    if (storage == null) {
      _loaded = true;
      return;
    }
    _loading = true;
    unawaited(() async {
      var ok = false;
      try {
        final stored = (await storage.read())?['rooms'];
        if (stored is List) {
          // Positions seen while loading stay the newest.
          final recent = Map.of(rooms);
          rooms.clear();
          for (final entry in stored) {
            if (entry is! Map) continue;
            final (r, e, f, t) = (
              entry['r'],
              entry['e'],
              entry['f'],
              entry['t'],
            );
            if (r is! String || e is! String || f is! String || t is! int) {
              continue;
            }
            rooms
              ..remove(r)
              ..[r] = _Seen(e, f, t);
          }
          for (final entry in recent.entries) {
            rooms
              ..remove(entry.key)
              ..[entry.key] = entry.value;
          }
          while (rooms.length > SeenPositions.capacity) {
            rooms.remove(rooms.keys.first);
          }
        }
        ok = true;
      } catch (_) {
        // Storage not open or unavailable: positions of this session stay
        // in memory, the stored record is not overwritten, and the next
        // [SeenPositions.load] reads it again.
      }
      _loading = false;
      if (!ok) return;
      _loaded = true;
      if (_dirty) flush();
    }());
  }

  /// A write after [delay], unless one is already scheduled.
  void schedule(Duration delay) {
    if (storage == null) return;
    _dirty = true;
    if (!_loaded) return; // The load writes it afterwards.
    _timer ??= Timer(delay, flush);
  }

  /// Writes the record now, one write at a time; a change during a write is
  /// written right after it.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final storage = this.storage;
    if (storage == null || !_loaded || !_dirty || _writing != null) return;
    _writing = () async {
      do {
        _dirty = false;
        try {
          await storage.write({
            'v': 1,
            'rooms': [
              for (final MapEntry(key: room, value: seen) in rooms.entries)
                {
                  'r': room,
                  'e': seen.eventId,
                  'f': seen.fullyRead,
                  't': seen.originServerTs,
                },
            ],
          });
        } catch (_) {
          // Kept in memory; the next change or flush tries again.
          _dirty = true;
          break;
        }
      } while (_dirty);
      _writing = null;
    }();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
