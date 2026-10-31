// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show instagramRavenOf;

/// Device-local storage of one account's opened view-once media.
abstract interface class ViewOnceOpeningsStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

/// The account's encrypted private store (`PersonalClient.readLocalRecord`,
/// SQLCipher, `local:` namespace): never synced, never sent anywhere.
class PersonalViewOnceOpeningsStorage implements ViewOnceOpeningsStorage {
  PersonalViewOnceOpeningsStorage(this.personal);

  final PersonalClient personal;

  static const key = 'viewOnceOpened';

  /// Throws while the app has not opened the store yet;
  /// [ViewOnceOpenings.load] then tries again on the next open.
  @override
  Future<Map<String, dynamic>?> read() => personal.readLocalRecord(key);

  @override
  Future<void> write(Map<String, dynamic> value) =>
      personal.writeLocalRecord(key, value);
}

/// Instagram view-once ("raven") photos and videos J opened in ChatLoom
/// (J, 2026-10-31). The bridge stores the media like any other and never
/// tells Instagram it was opened; ChatLoom shows it behind "Tap to view"
/// until the first tap, then as ordinary media with a reminder that
/// Instagram still counts it as unopened. Opening it again is allowed any
/// number of times.
///
/// One app-wide registry, like [HiddenMessages]: per account a bounded,
/// insertion-ordered set of `roomId␀eventId` in that account's encrypted
/// private store. Device-local on purpose: nothing goes to the homeserver,
/// the private journal or the network. A change notifies listeners once.
class ViewOnceOpenings extends ChangeNotifier {
  ViewOnceOpenings({this.storageFor = defaultStorage});

  /// The registry the app uses.
  static final instance = ViewOnceOpenings();

  static ViewOnceOpeningsStorage? defaultStorage(Client client) =>
      client.userID == null
      ? null
      : PersonalViewOnceOpeningsStorage(PersonalClient.of(client));

  /// Opened items kept per account; the oldest falls out first.
  static const capacity = 5000;

  // Not final: tests swap the store of [instance].
  ViewOnceOpeningsStorage? Function(Client client) storageFor;

  final _accounts = Expando<_OpenedAccount>();

  static String _key(String roomId, String eventId) => '$roomId\u0000$eventId';

  /// View-once media not opened on this device yet: kept out of galleries,
  /// album grids and shared-media thumbnails until its own "Tap to view".
  static bool isSealed(Event event) =>
      instagramRavenOf(event.content).present && !instance.isOpened(event);

  /// Whether [event] was opened here. Starts loading the account's record
  /// on first use; false until it is loaded.
  bool isOpened(Event event) {
    final account = _account(event.room.client);
    if (account == null || account.keys.isEmpty) return false;
    return account.keys.contains(_key(event.room.id, event.eventId));
  }

  /// Starts loading [client]'s record (idempotent; retries a failed read).
  void load(Client client) {
    final existing = _accounts[client];
    if (existing != null) {
      existing.retry(this);
      return;
    }
    _account(client);
  }

  _OpenedAccount? _account(Client client) {
    final existing = _accounts[client];
    if (existing != null) return existing;
    if (client.userID == null) return null;
    final account = _accounts[client] = _OpenedAccount(storageFor(client));
    account.load(this);
    return account;
  }

  /// Records that [event] was opened here and persists it. Sends nothing.
  void markOpened(Event event) {
    final account = _account(event.room.client);
    if (account == null) return;
    final key = _key(event.room.id, event.eventId);
    if (account.keys.contains(key)) return;
    account.keys.add(key);
    while (account.keys.length > capacity) {
      account.keys.remove(account.keys.first);
    }
    _changed();
    account.persist();
  }

  void _changed() => notifyListeners();

  @visibleForTesting
  void debugReset(Client client) => _accounts[client] = null;
}

class _OpenedAccount {
  _OpenedAccount(this.storage);

  final ViewOnceOpeningsStorage? storage;

  // Insertion order = open order (oldest first).
  final keys = <String>{};
  bool _loaded = false;
  bool _loading = false;
  Future<void>? _writing;
  bool _dirty = false;

  void retry(ViewOnceOpenings registry) {
    if (!_loaded && !_loading) load(registry);
  }

  void load(ViewOnceOpenings registry) {
    final storage = this.storage;
    if (storage == null) {
      _loaded = true;
      return;
    }
    _loading = true;
    unawaited(() async {
      var ok = false;
      try {
        // After the current build pass.
        await Future<void>.microtask(() {});
        final stored = (await storage.read())?['keys'];
        if (stored is List) {
          // Items opened while loading stay the newest.
          final recent = keys.toList();
          keys
            ..clear()
            ..addAll(stored.whereType<String>())
            ..removeAll(recent)
            ..addAll(recent);
          while (keys.length > ViewOnceOpenings.capacity) {
            keys.remove(keys.first);
          }
        }
        ok = true;
      } catch (_) {
        // Store not open: this session's openings stay in memory, nothing
        // overwrites the stored record, the next load reads it again.
      }
      _loading = false;
      if (!ok) return;
      final hadPending = _dirty;
      _loaded = true;
      if (keys.isNotEmpty) registry._changed();
      if (hadPending) persist();
    }());
  }

  /// Writes the record, one write at a time.
  void persist() {
    final storage = this.storage;
    if (storage == null) return;
    if (!_loaded || _writing != null) {
      _dirty = true;
      return;
    }
    _writing = () async {
      do {
        _dirty = false;
        try {
          await storage.write({'v': 1, 'keys': keys.toList()});
        } catch (_) {
          // Kept in memory; the next opening tries again.
          break;
        }
      } while (_dirty);
      _writing = null;
    }();
  }
}
