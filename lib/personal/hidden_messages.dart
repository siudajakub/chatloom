// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/pages/chat/message_deletion.dart'
    show bridgedNetworkLabel;
import 'package:chatloom/personal/personal_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Device-local storage of one account's hidden messages.
abstract interface class HiddenMessagesStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

/// The account's encrypted private store (`PersonalClient.readLocalRecord`,
/// SQLCipher, `local:` namespace): never synced to the worker journal,
/// never sent anywhere.
class PersonalHiddenMessagesStorage implements HiddenMessagesStorage {
  PersonalHiddenMessagesStorage(this.personal);

  final PersonalClient personal;

  static const key = 'hiddenMessages';

  /// Throws while the app has not opened the store yet (it never opens it
  /// itself); [HiddenMessages.load] then tries again on the next open.
  @override
  Future<Map<String, dynamic>?> read() => personal.readLocalRecord(key);

  @override
  Future<void> write(Map<String, dynamic> value) =>
      personal.writeLocalRecord(key, value);
}

/// "Remove for you" (Messenger) / "Delete for me" (Telegram), J 2026-10-24:
/// a message is hidden **in ChatLoom only**. Nothing is redacted, deleted or
/// sent: no Matrix request, no bridge event, no journal entry. Everyone
/// else, the network and J's other apps keep the message.
///
/// One app-wide registry (the timeline filters are static, like
/// [MessageDeletions]): per account a bounded, insertion-ordered set of
/// `roomId␀eventId`, persisted in that account's encrypted private store.
/// It is device-local on purpose: J's constraint is that hiding sends
/// nothing anywhere, and the private journal would be a write to the
/// homeserver.
///
/// Consumers: `isVisibleInGui` (ordinary chat), the merged chat rows, the
/// inbox preview and the on-device message search. A change notifies
/// listeners once; hosts refilter their rows on that, nothing per frame.
class HiddenMessages extends ChangeNotifier {
  HiddenMessages({this.storageFor = defaultStorage});

  /// The registry the app uses.
  static final instance = HiddenMessages();

  static HiddenMessagesStorage? defaultStorage(Client client) =>
      client.userID == null
      ? null
      : PersonalHiddenMessagesStorage(PersonalClient.of(client));

  /// Hidden messages kept per account; the oldest hide falls out first.
  static const capacity = 5000;

  /// Storage of an account, or null to keep its hides in memory only.
  // Not final: tests swap the store of [instance].
  HiddenMessagesStorage? Function(Client client) storageFor;

  final _accounts = Expando<_HiddenAccount>();

  /// Bumped on every change, for widget signatures.
  int get revision => _revision;
  int _revision = 0;

  static String _key(String roomId, String eventId) => '$roomId\u0000$eventId';

  /// Whether [event] is hidden for this account (app-wide registry).
  /// A set lookup; false while the account's hides are still loading.
  static bool hides(Event event) => instance.isHidden(event);

  bool isHidden(Event event) {
    final account = _accounts[event.room.client];
    if (account == null || account.keys.isEmpty) return false;
    return account.keys.contains(_key(event.room.id, event.eventId));
  }

  /// Whether [event] can be hidden: a sent message with a server ID.
  /// (A failed or sending own message has its own Delete.)
  static bool canHide(Event event) =>
      event.status.isSent && event.eventId.startsWith(r'$');

  /// Starts loading [client]'s hides (idempotent). Hosts call it when they
  /// open; the rows are refiltered when it finishes.
  void load(Client client) {
    final existing = _accounts[client];
    if (existing != null) {
      existing.retry(this);
      return;
    }
    _account(client);
  }

  _HiddenAccount? _account(Client client) {
    final existing = _accounts[client];
    if (existing != null) return existing;
    if (client.userID == null) return null;
    final account = _accounts[client] = _HiddenAccount(storageFor(client));
    account.load(this);
    return account;
  }

  /// Hides [event] here and persists it. Never touches the network.
  void hide(Event event) {
    final account = _account(event.room.client);
    if (account == null) return;
    final key = _key(event.room.id, event.eventId);
    account.keys
      ..remove(key)
      ..add(key);
    while (account.keys.length > capacity) {
      account.keys.remove(account.keys.first);
    }
    _changed();
    account.persist();
  }

  /// Shows [event] again (Undo).
  void unhide(Event event) =>
      _unhideKeys(event.room.client, [_key(event.room.id, event.eventId)]);

  /// Number of hidden messages of [rooms] (one account), for chat details.
  int countIn(Iterable<Room> rooms) {
    var count = 0;
    for (final room in rooms) {
      final account = _accounts[room.client];
      if (account == null) continue;
      final prefix = '${room.id}\u0000';
      count += account.keys.where((k) => k.startsWith(prefix)).length;
    }
    return count;
  }

  /// Shows every hidden message of [rooms] again; returns what was shown,
  /// for [restore] (Undo).
  List<(Client, String)> unhideAll(Iterable<Room> rooms) {
    final removed = <(Client, String)>[];
    for (final room in rooms) {
      final account = _accounts[room.client];
      if (account == null) continue;
      final prefix = '${room.id}\u0000';
      for (final key in account.keys.where((k) => k.startsWith(prefix))) {
        removed.add((room.client, key));
      }
    }
    final byClient = <Client, List<String>>{};
    for (final (client, key) in removed) {
      (byClient[client] ??= []).add(key);
    }
    byClient.forEach(_unhideKeys);
    return removed;
  }

  /// Hides again what [unhideAll] showed.
  void restore(List<(Client, String)> keys) {
    final touched = <_HiddenAccount>{};
    for (final (client, key) in keys) {
      final account = _account(client);
      if (account == null) continue;
      account.keys.add(key);
      touched.add(account);
    }
    if (touched.isEmpty) return;
    _changed();
    for (final account in touched) {
      account.persist();
    }
  }

  void _unhideKeys(Client client, List<String> keys) {
    final account = _account(client);
    if (account == null) return;
    var changed = false;
    for (final key in keys) {
      changed = account.keys.remove(key) || changed;
    }
    if (!changed) return;
    _changed();
    account.persist();
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  /// Hides [event] and confirms with an Undo snackbar that says what it
  /// means. [refresh] refilters the host's rows (safe after it is gone).
  static void hideWithUndo(
    BuildContext context,
    Event event, {
    VoidCallback? refresh,
    HiddenMessages? registry,
  }) {
    final hidden = registry ?? instance;
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The bubble shrinks away first when it is on screen (not under reduced
    // motion); otherwise it goes at once.
    final exit = ConversationMessageEntrance.leave([
      event.eventId,
      event.transactionId,
    ]);
    if (exit != null) {
      unawaited(exit.then((_) => _hideNow(hidden, event, refresh, messenger)));
    } else {
      _hideNow(hidden, event, refresh, messenger);
    }
  }

  static void _hideNow(
    HiddenMessages hidden,
    Event event,
    VoidCallback? refresh,
    ScaffoldMessengerState? messenger,
  ) {
    hidden.hide(event);
    refresh?.call();
    final network = bridgedNetworkLabel(event.room);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            network == null
                ? 'Removed for you. Others in the chat still see it.'
                : 'Removed for you. It stays in the chat on $network.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              hidden.unhide(event);
              refresh?.call();
            },
          ),
        ),
      );
  }

  @visibleForTesting
  void debugReset(Client client) => _accounts[client] = null;
}

class _HiddenAccount {
  _HiddenAccount(this.storage);

  final HiddenMessagesStorage? storage;

  // Insertion order = hide order (oldest first).
  final keys = <String>{};
  bool _loaded = false;
  bool _loading = false;
  Future<void>? _writing;
  bool _dirty = false;

  /// Loads again after a failed read (the store was not open yet).
  void retry(HiddenMessages registry) {
    if (!_loaded && !_loading) load(registry);
  }

  void load(HiddenMessages registry) {
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
        final value = await storage.read();
        final stored = value?['keys'];
        if (stored is List) {
          // Hides made while loading stay the newest.
          final recent = keys.toList();
          keys
            ..clear()
            ..addAll(stored.whereType<String>())
            ..removeAll(recent)
            ..addAll(recent);
          while (keys.length > HiddenMessages.capacity) {
            keys.remove(keys.first);
          }
        }
        ok = true;
      } catch (_) {
        // Storage not open or unavailable: hides of this session stay in
        // memory, nothing is written over the stored record, and the next
        // [HiddenMessages.load] reads it again.
      }
      _loading = false;
      if (!ok) return;
      final hadPending = _dirty;
      _loaded = true;
      if (keys.isNotEmpty) registry._changed();
      if (hadPending) persist();
    }());
  }

  /// Writes the account's record, one write at a time; a change during a
  /// write is written right after it.
  void persist() {
    final storage = this.storage;
    if (storage == null) return;
    if (!_loaded || _writing != null) {
      // The load (or the running write) writes it afterwards.
      _dirty = true;
      return;
    }
    _writing = () async {
      do {
        _dirty = false;
        try {
          await storage.write({'v': 1, 'keys': keys.toList()});
        } catch (_) {
          // Kept in memory; the next change tries again.
          break;
        }
      } while (_dirty);
      _writing = null;
    }();
  }
}
