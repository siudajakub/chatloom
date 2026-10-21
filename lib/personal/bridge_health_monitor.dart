// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

const _bridgeTypes = ['m.bridge', 'uk.half-shot.bridge', 'com.beeper.bridge'];

/// Canonical network of a bridged room, from its bridge info state; `null`
/// for native Matrix rooms.
String? bridgeNetworkOfRoom(Room room) {
  for (final type in _bridgeTypes) {
    final states = room.states[type];
    if (states == null) continue;
    for (final info in states.values) {
      final protocol = info.content['protocol'];
      if (protocol is! Map) continue;
      final network =
          canonicalNetwork(protocol['id']) ??
          canonicalNetwork(protocol['displayname']);
      if (network != null && network != 'matrix') return network;
    }
  }
  return null;
}

/// Live bridge health of one account, built only from events the client
/// already receives:
///
/// 1. bridgev2 state notices (`fi.mau.bridge_state`) in the bridge bots'
///    management rooms: on attach the last stored events of those rooms are
///    read from the local database, later notices arrive with sync;
/// 2. remote messages per network (heal a stale problem notice);
/// 3. `com.beeper.message_send_status` failures, and failures reported by
///    the app through [noteDelivery].
///
/// Listens only while something shows the result (inbox, chat banner); no
/// polling and no requests. Nothing is logged except error types.
class BridgeHealthMonitor extends ChangeNotifier {
  BridgeHealthMonitor(this.client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final _byClient = Expando<BridgeHealthMonitor>('bridge health');

  static BridgeHealthMonitor of(Client client) =>
      _byClient[client] ??= BridgeHealthMonitor(client);

  @visibleForTesting
  static void debugOverride(Client client, BridgeHealthMonitor monitor) =>
      _byClient[client] = monitor;

  final Client client;
  final DateTime Function() _clock;

  /// Bridge bot user id → network.
  final _bots = <String, String>{};
  final _signals = <String, BridgeSignals>{};
  Map<String, BridgeHealth> _health = const {};
  StreamSubscription<Event>? _events;
  int _generation = 0;
  bool _scanned = false;

  /// Every network with a known verdict (problems and healthy ones).
  Map<String, BridgeHealth> get health => _health;

  /// Networks with a problem, worst first.
  List<BridgeHealth> get problems =>
      _health.values.where((h) => h.state.isProblem).toList()..sort(
        (a, b) => b.state.severity != a.state.severity
            ? b.state.severity.compareTo(a.state.severity)
            : a.label.compareTo(b.label),
      );

  /// What this device saw of [network] (per-login notices, last remote
  /// message, recent deliveries), for the Networks page's details. Read
  /// only; `null` when nothing was seen.
  BridgeSignals? signalsFor(String network) => _signals[network];

  /// The problem of [room]'s network, if any.
  BridgeHealth? problemFor(Room room) {
    final network = bridgeNetworkOfRoom(room);
    if (network == null) return null;
    final health = _health[network];
    return health != null && health.state.isProblem ? health : null;
  }

  /// The bridge bot's management room for [network], when this device knows
  /// one (the room its last notice came from, else a DM with the bot).
  Room? managementRoom(String network) {
    final id = _signals[network]?.managementRoomId;
    final room = id == null ? null : client.getRoomById(id);
    if (room != null && room.membership == Membership.join) return room;
    for (final entry in _bots.entries) {
      if (entry.value != network) continue;
      for (final candidate in client.rooms) {
        if (_isManagementRoom(candidate, entry.key)) return candidate;
      }
    }
    return null;
  }

  /// A delivery outcome the app saw itself (e.g. the outbox gave up on a
  /// bridged message). Lane-independent hook; harmless when unused.
  void noteDelivery(Room room, {required bool failed, DateTime? at}) {
    final network = bridgeNetworkOfRoom(room);
    if (network == null) return;
    _signal(
      network,
    ).addDelivery(BridgeDelivery(at: at ?? _clock(), failed: failed));
    _evaluate();
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) _attach();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _detach();
  }

  void _attach() {
    final generation = ++_generation;
    _events = client.onTimelineEvent.stream.listen(
      _onEvent,
      onError: (Object _) {},
    );
    unawaited(_scan(generation));
  }

  void _detach() {
    _generation++;
    unawaited(_events?.cancel());
    _events = null;
  }

  BridgeSignals _signal(String network) =>
      _signals[network] ??= BridgeSignals();

  void _indexBots() {
    for (final room in client.rooms) {
      for (final type in _bridgeTypes) {
        final states = room.states[type];
        if (states == null) continue;
        for (final info in states.values) {
          final bot = info.content['bridgebot'];
          if (bot is! String || !bot.isValidMatrixIdStrict()) continue;
          final protocol = info.content['protocol'];
          final network = protocol is Map
              ? canonicalNetwork(protocol['id']) ??
                    canonicalNetwork(protocol['displayname'])
              : null;
          if (network != null && network != 'matrix') _bots[bot] = network;
        }
      }
    }
  }

  /// A management room: joined, at most the account and the bot.
  bool _isManagementRoom(Room room, String bot) {
    if (room.membership != Membership.join || room.isSpace) return false;
    final joined = room.summary.mJoinedMemberCount;
    if (joined != null && joined > 2) return false;
    if (room.directChatMatrixID == bot) return true;
    final heroes = room.summary.mHeroes ?? const <String>[];
    return heroes.isNotEmpty &&
        heroes.every((id) => id == bot || id == client.userID);
  }

  String? _botNetwork(String sender, Room room) {
    final known = _bots[sender];
    if (known != null) return known;
    final guessed = bridgeBotNetworkFromId(sender);
    if (guessed == null || !_isManagementRoom(room, sender)) return null;
    return guessed;
  }

  Future<void> _scan(int generation) async {
    try {
      await client.roomsLoading;
    } catch (_) {
      return;
    }
    if (generation != _generation) return;
    _bots.clear();
    _indexBots();
    final management = <Room>{};
    for (final room in client.rooms) {
      if (room.membership != Membership.join) continue;
      final last = room.lastEvent;
      if (last != null) _consume(last, evaluate: false);
      final partner = room.directChatMatrixID;
      final heroes = room.summary.mHeroes ?? const <String>[];
      for (final candidate in [?partner, ...heroes]) {
        if (_botNetwork(candidate, room) != null &&
            _isManagementRoom(room, candidate)) {
          management.add(room);
        }
      }
    }
    for (final room in management) {
      List<Event> events;
      try {
        events = await client.database.getEventList(room, limit: 30);
      } catch (error) {
        Logs().w('[Personal] Bridge status unavailable: ${error.runtimeType}');
        continue;
      }
      if (generation != _generation) return;
      for (final event in events) {
        _consume(event, evaluate: false);
      }
    }
    _scanned = true;
    _evaluate();
  }

  void _onEvent(Event event) {
    // New bridged rooms (and their bots) arrive with their state.
    if (event.content[bridgeStateNoticeKey] is Map &&
        !_bots.containsKey(event.senderId)) {
      _indexBots();
    }
    _consume(event, evaluate: true);
  }

  void _consume(Event event, {required bool evaluate}) {
    final room = event.room;
    final sender = event.senderId;
    final at = event.originServerTs;
    final notice = event.content[bridgeStateNoticeKey];
    if (notice is Map) {
      final network = _botNetwork(sender, room);
      if (network == null) return;
      final report = BridgeStateReport.parse(
        notice,
        network: network,
        fallback: at,
        roomId: room.id,
      );
      if (report != null && _signal(network).addReport(report) && evaluate) {
        _evaluate();
      }
      return;
    }
    final network = bridgeNetworkOfRoom(room);
    if (network == null) return;
    if (event.type == bridgeMessageStatusType) {
      if (!_bots.containsKey(sender)) return;
      final delivery = BridgeDelivery.parse(event.content, at);
      if (delivery == null) return;
      _signal(network).addDelivery(delivery);
      if (evaluate) _evaluate();
      return;
    }
    if (!_isRemote(event)) return;
    final signals = _signals[network];
    // Only networks with something to heal need inbound times live.
    if (signals == null && evaluate) return;
    if (_signal(network).addInbound(at) && evaluate) {
      final current = _health[network];
      if (current != null && current.state.isProblem) _evaluate();
    }
  }

  /// A message that came through the bridge from the remote network: from a
  /// ghost user, or the bridge's double puppet of this account.
  bool _isRemote(Event event) {
    if (event.stateKey != null) return false;
    const types = {
      EventTypes.Message,
      EventTypes.Encrypted,
      EventTypes.Sticker,
      EventTypes.Reaction,
    };
    if (!types.contains(event.type)) return false;
    final sender = event.senderId;
    if (_bots.containsKey(sender)) return false;
    if (sender != client.userID) return true;
    return event.content['fi.mau.double_puppet_source'] != null;
  }

  void _evaluate() {
    if (!_scanned) return;
    final now = _clock();
    final next = <String, BridgeHealth>{
      for (final entry in _signals.entries)
        entry.key: evaluateBridgeHealth(entry.key, entry.value, now),
    };
    if (mapEquals(next, _health)) return;
    _health = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
