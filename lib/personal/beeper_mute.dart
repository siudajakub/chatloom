// SPDX-License-Identifier: AGPL-3.0-or-later

/// Beeper's own room mute: `com.beeper.mute` room account data.
///
/// On Beeper the homeserver mutes a room through this account data rather
/// than a push rule, and bridges write it too (bridgev2 `MuteRoom`). bbctl's
/// Slack template sets `mute_channels_by_default: true`, so every Slack
/// channel the bridge created arrived muted for good: no push and no
/// notification count, so the inbox never showed it unread, while the SDK's
/// [Room.pushRuleState] still said "All messages".
///
/// ChatLoom therefore:
///
/// * shows the mute as the chat's account rule ([accountPushRuleState]) and
///   keeps such a chat unread from its read marker (`personalRoomUnread`);
/// * lifts the bridge's default mute of a Slack chat once
///   ([BeeperMuteRelease]). A released room carries
///   [beeperMuteReleasedType], so a mute the user sets later in another
///   Beeper client stays;
/// * clears the mute when the user picks a notifying account rule here
///   ([setAccountPushRuleState]).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/personal/conversation_classification.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

const beeperMuteType = 'com.beeper.mute';

/// Marks a room whose Beeper mute ChatLoom lifted (reverse DNS of the app).
const beeperMuteReleasedType = 'pl.personal.chat.beeper_mute_released';

/// Networks whose bridge mutes new chats by default and whose chats the user
/// wants to alert (J, 2026-11-02: every Slack message notifies).
const beeperMuteReleaseNetworks = {'slack'};

num? _mutedUntil(Room room) {
  final until = room.roomAccountData[beeperMuteType]?.content['muted_until'];
  return until is num ? until : null;
}

/// Whether the room's Beeper mute is in force: `muted_until` -1 is for good,
/// a positive value is its end in Unix milliseconds, 0 or none is unmuted.
bool beeperMuted(Room room, {DateTime? now}) {
  final until = _mutedUntil(room);
  if (until == null || until == 0) return false;
  return until < 0 || until > (now ?? DateTime.now()).millisecondsSinceEpoch;
}

/// The account rule the homeserver applies: [Room.pushRuleState], made
/// "Muted" by an active Beeper mute.
PushRuleState accountPushRuleState(Room room) =>
    beeperMuted(room) ? PushRuleState.dontNotify : room.pushRuleState;

Future<void> clearBeeperMute(Room room) => room.client.setAccountDataPerRoom(
  room.client.userID!,
  room.id,
  beeperMuteType,
  {'muted_until': 0},
);

/// Sets the account rule; a notifying choice also lifts the Beeper mute.
Future<void> setAccountPushRuleState(Room room, PushRuleState state) async {
  if (state != PushRuleState.dontNotify && beeperMuted(room)) {
    await clearBeeperMute(room);
  }
  await room.setPushRuleState(state);
}

/// Joined chats of [beeperMuteReleaseNetworks] that are muted for good by
/// Beeper and were never released before. Timed mutes are the user's.
List<Room> beeperMuteReleaseCandidates(
  Client client, {
  Set<String> pending = const {},
}) {
  ConversationClassifier? classifier;
  return [
    for (final room in client.rooms)
      if (room.membership == Membership.join &&
          !room.isSpace &&
          !pending.contains(room.id) &&
          (_mutedUntil(room) ?? 0) < 0 &&
          room.roomAccountData[beeperMuteReleasedType] == null &&
          beeperMuteReleaseNetworks.contains(
            (classifier ??= ConversationClassifier(
              client.rooms,
            )).classify(room).network,
          ))
        room,
  ];
}

/// Lifts the bridges' default mutes, a bounded number per pass, with
/// exponential backoff after an error.
class BeeperMuteRelease {
  final Client client;
  final Duration debounce;
  final Duration spacing;
  final int maxPerPass;
  final Duration backoffBase;
  final Duration backoffMax;

  BeeperMuteRelease(
    this.client, {
    this.debounce = const Duration(seconds: 3),
    this.spacing = const Duration(milliseconds: 250),
    this.maxPerPass = 25,
    this.backoffBase = const Duration(seconds: 30),
    this.backoffMax = const Duration(minutes: 30),
  });

  // Rooms released by this device that sync has not shown yet.
  final _pending = <String>{};
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  int _failures = 0;

  @visibleForTesting
  Set<String> get pending => _pending;

  void schedule([Duration? delay]) {
    if (_disposed || _running) return;
    _timer?.cancel();
    _timer = Timer(delay ?? debounce, () => unawaited(run()));
  }

  /// One pass. Returns the number of rooms released.
  Future<int> run() async {
    if (_disposed || _running || !client.isLogged()) return 0;
    _pending.removeWhere((id) {
      final room = client.getRoomById(id);
      return room == null ||
          room.roomAccountData[beeperMuteReleasedType] != null;
    });
    final rooms = beeperMuteReleaseCandidates(client, pending: _pending);
    if (rooms.isEmpty) return 0;
    _running = true;
    var released = 0;
    Duration? retry;
    try {
      for (final room in rooms.take(maxPerPass)) {
        if (_disposed) break;
        if (released > 0) await Future<void>.delayed(spacing);
        _pending.add(room.id);
        // The mute goes first: a missing marker only lets a later mute be
        // lifted once more, a marker without the release would keep it.
        await clearBeeperMute(room);
        await client.setAccountDataPerRoom(
          client.userID!,
          room.id,
          beeperMuteReleasedType,
          {'released_at': DateTime.now().millisecondsSinceEpoch},
        );
        released++;
      }
      _failures = 0;
    } catch (e, s) {
      _failures++;
      var wait = backoffBase * math.pow(2, math.min(_failures - 1, 10));
      if (wait > backoffMax) wait = backoffMax;
      if (e is MatrixException) {
        final after = e.retryAfterMs;
        if (after != null && Duration(milliseconds: after) > wait) {
          wait = Duration(milliseconds: after);
        }
      }
      Logs().w(
        'Beeper mute release: write failed, retry in ${wait.inSeconds} s',
        e is MatrixException ? e.errcode : e.runtimeType,
        s,
      );
      // The failed room is tried again, also when its mute was lifted.
      _pending.removeAll(rooms.skip(released).map((room) => room.id));
      retry = wait;
    } finally {
      _running = false;
    }
    if (retry != null) {
      schedule(retry);
    } else if (rooms.length > maxPerPass) {
      schedule();
    }
    return released;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  static final _attached = <Client, _Attached>{};

  /// Starts releasing for [client] (idempotent): after the first sync and
  /// whenever a sync brings a Beeper mute (a new bridged chat).
  static void startFor(Client client) {
    if (kIsWeb || _attached.containsKey(client)) return;
    var first = true;
    final attached = _Attached(BeeperMuteRelease(client));
    attached.sync = client.onSync.stream
        .where((update) => first || _bringsBeeperMute(update))
        .listen((_) {
          first = false;
          attached.release.schedule();
        });
    _attached[client] = attached;
  }

  /// Stops releasing for [client] (logout).
  static void stopFor(Client client) => _attached.remove(client)?.dispose();
}

bool _bringsBeeperMute(SyncUpdate update) {
  for (final room in update.rooms?.join?.values ?? <JoinedRoomUpdate>[]) {
    if (room.accountData?.any((e) => e.type == beeperMuteType) ?? false) {
      return true;
    }
  }
  return false;
}

class _Attached {
  final BeeperMuteRelease release;
  StreamSubscription<SyncUpdate>? sync;
  _Attached(this.release);
  void dispose() {
    release.dispose();
    unawaited(sync?.cancel());
  }
}
