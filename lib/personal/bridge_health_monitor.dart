// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/utils/macos_desktop.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:matrix/matrix.dart';

/// Reads a bridge's provisioning `whoami` (test seam). Null: this device
/// can't ask that bridge at all (no supported route); a thrown
/// [BridgeProvisioningException] is a failed request.
typedef BridgeWhoamiLoader =
    Future<BridgeWhoami?> Function(BridgeEndpoint bridge);

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

/// Live bridge health of one account:
///
/// 1. each login's current state from the bridge's provisioning
///    `GET /v3/whoami` (bbctl turns bridgev2's state notices off, so this is
///    the live source): asked when something starts listening, every
///    [BridgeHealthRules.liveInterval] while the app is in the foreground,
///    when a network page opens ([refresh]), and shortly after a delivery
///    failure; one request per bridge at a time, with backoff after failures
///    and never while the app is in the background;
/// 2. bridgev2 state notices (`fi.mau.bridge_state`) in the bridge bots'
///    management rooms, for bridges that send them: on attach the last
///    stored events of those rooms are read from the local database, later
///    notices arrive with sync;
/// 3. remote messages per network (heal a stale problem, prove recent
///    delivery);
/// 4. `com.beeper.message_send_status` failures.
///
/// Listens only while something shows the result (inbox, chat banner,
/// network pages). Nothing is logged except error types.
class BridgeHealthMonitor extends ChangeNotifier with WidgetsBindingObserver {
  BridgeHealthMonitor(
    this.client, {
    DateTime Function()? clock,
    BridgeWhoamiLoader? whoami,
    List<BridgeEndpoint> Function()? bridges,
    bool watchLifecycle = true,
    ValueListenable<bool>? windowVisible,
  }) : _clock = clock ?? DateTime.now,
       _whoami = whoami ?? _directoryWhoami(client),
       _bridges = bridges ?? (() => discoverBridges(client.rooms)),
       _watchLifecycle = watchLifecycle,
       _windowVisible =
           windowVisible ??
           (watchLifecycle && PlatformInfos.isMacOS
               ? MacDesktopWindow.visible
               : null);

  static final _byClient = Expando<BridgeHealthMonitor>('bridge health');

  static BridgeHealthMonitor of(Client client) =>
      _byClient[client] ??= BridgeHealthMonitor(client);

  @visibleForTesting
  static void debugOverride(Client client, BridgeHealthMonitor monitor) =>
      _byClient[client] = monitor;

  final Client client;
  final DateTime Function() _clock;
  final BridgeWhoamiLoader _whoami;
  final List<BridgeEndpoint> Function() _bridges;
  final bool _watchLifecycle;

  /// The macOS window's visibility: a covered or minimised window asks no
  /// bridge (BP-03).
  final ValueListenable<bool>? _windowVisible;
  AppLifecycleState? _lifecycle;

  /// Bridge bot user id → network.
  final _bots = <String, String>{};
  final _signals = <String, BridgeSignals>{};
  final _live = <String, _LiveRequests>{};
  Map<String, BridgeHealth> _health = const {};
  StreamSubscription<Event>? _events;
  int _generation = 0;
  bool _scanned = false;
  bool _foreground = true;
  bool _observing = false;
  bool _polling = false;
  Timer? _poll;
  Timer? _boundary;

  /// Every network with a known verdict (problems and healthy ones).
  Map<String, BridgeHealth> get health => _health;

  /// Networks with a problem, worst first.
  List<BridgeHealth> get problems =>
      _health.values.where((h) => h.state.isProblem).toList()..sort(
        (a, b) => b.state.severity != a.state.severity
            ? b.state.severity.compareTo(a.state.severity)
            : a.label.compareTo(b.label),
      );

  /// What this device saw of [network] (per-login notices and `whoami`
  /// states, last remote message, recent deliveries), for the Networks
  /// page's details. Read only; `null` when nothing was seen.
  BridgeSignals? signalsFor(String network) => _signals[network];

  /// The problem of [room]'s network, if any.
  BridgeHealth? problemFor(Room room) {
    final network = bridgeNetworkOfRoom(room);
    if (network == null) return null;
    final health = _health[network];
    return health != null && health.state.isProblem ? health : null;
  }

  /// The bridge bot's management room for [network], when this device knows
  /// one (the room `whoami` named, the room its last notice came from, else
  /// a DM with the bot).
  Room? managementRoom(String network) {
    final signals = _signals[network];
    for (final id in [
      signals?.liveManagementRoomId,
      signals?.managementRoomId,
    ]) {
      final room = id == null ? null : client.getRoomById(id);
      if (room != null && room.membership == Membership.join) return room;
    }
    for (final entry in _bots.entries) {
      if (entry.value != network) continue;
      for (final candidate in client.rooms) {
        if (_isManagementRoom(candidate, entry.key)) return candidate;
      }
    }
    return null;
  }

  /// Asks [network]'s bridge for its current state now (a network page
  /// opened, pull to refresh) unless an answer is under a minute old or a
  /// request is in flight; [force] skips the age check.
  Future<void> refresh(String network, {bool force = false}) async {
    final bridge = _bridgeFor(network);
    if (bridge == null) return;
    final live = _live.putIfAbsent(network, _LiveRequests.new);
    final at = _signals[network]?.liveAt;
    if (!force &&
        at != null &&
        _clock().difference(at) < const Duration(minutes: 1)) {
      return;
    }
    if (live.inFlight != null) return live.inFlight;
    await _fetch(bridge, _generation);
  }

  /// The user signed out of [network] from this device: it reads as signed
  /// out at once (no "Connected", no second "Sign out"), and the bridge is
  /// asked again shortly to confirm.
  void noteSignedOut(String network) {
    final signals = _signal(network)..signedOutAt = _clock();
    signals.live = const {};
    _evaluate(force: true);
    final live = _live.putIfAbsent(network, _LiveRequests.new);
    live.nextAt = _clock().add(const Duration(seconds: 15));
    _schedulePoll();
  }

  static BridgeWhoamiLoader _directoryWhoami(Client client) => (bridge) {
    final directory = BridgeDirectory.of(client);
    if (directory.api == null || !(directory.reaches?.call(bridge) ?? true)) {
      return Future.value();
    }
    return directory.refreshLogins(bridge);
  };

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
    if (_watchLifecycle && !_observing) {
      try {
        final binding = WidgetsBinding.instance;
        binding.addObserver(this);
        _observing = true;
        _lifecycle = binding.lifecycleState;
      } catch (_) {
        // No Flutter binding (plain unit tests): always in the foreground.
      }
    }
    _windowVisible?.addListener(_onForegroundChanged);
    _foreground = _isForeground;
    unawaited(_scan(generation));
  }

  void _detach() {
    _generation++;
    unawaited(_events?.cancel());
    _events = null;
    _poll?.cancel();
    _poll = null;
    _boundary?.cancel();
    _boundary = null;
    _polling = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _windowVisible?.removeListener(_onForegroundChanged);
  }

  /// Only an app the user is looking at polls (BP-03): `inactive` (another
  /// app focused on the Mac, the shade or split screen on Android) waits,
  /// and so does a hidden Mac window. Coming back asks due bridges at once.
  bool get _isForeground =>
      (_lifecycle == null || _lifecycle == AppLifecycleState.resumed) &&
      (_windowVisible?.value ?? true);

  /// Whether a `whoami` round is scheduled (tests).
  @visibleForTesting
  bool get debugPollScheduled => _poll != null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _onForegroundChanged();
  }

  void _onForegroundChanged() {
    final foreground = _isForeground;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      // Back in front: ages moved on while away, and due bridges are asked.
      _evaluate();
      _schedulePoll();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  BridgeEndpoint? _bridgeFor(String network) =>
      _bridges().where((bridge) => bridge.network == network).firstOrNull;

  /// Schedules the next `whoami` round at the earliest due bridge. One timer
  /// at most, only while listened to and in the foreground.
  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (!hasListeners || !_foreground || !_scanned || _polling) return;
    final now = _clock();
    DateTime? next;
    for (final bridge in _bridges()) {
      final due = _live[bridge.network]?.nextAt ?? now;
      if (next == null || due.isBefore(next)) next = due;
    }
    if (next == null) return;
    final wait = next.difference(now);
    final generation = _generation;
    _poll = Timer(wait.isNegative ? Duration.zero : wait, () {
      _poll = null;
      if (generation == _generation) unawaited(_pollDue(generation));
    });
  }

  /// Asks every due bridge, one after the other.
  Future<void> _pollDue(int generation) async {
    if (_polling) return;
    _polling = true;
    try {
      // One bridge per network (the first, as sign-out and search use).
      final seen = <String>{};
      for (final bridge in _bridges()) {
        if (!seen.add(bridge.network)) continue;
        if (generation != _generation || !_foreground) return;
        final due = _live[bridge.network]?.nextAt;
        if (due != null && due.isAfter(_clock())) continue;
        final inFlight = _live[bridge.network]?.inFlight;
        if (inFlight != null) {
          await inFlight;
        } else {
          await _fetch(bridge, generation);
        }
      }
    } finally {
      _polling = false;
      if (generation == _generation) _schedulePoll();
    }
  }

  /// One `whoami` of [bridge]; the answer replaces its live login states.
  Future<void> _fetch(BridgeEndpoint bridge, int generation) {
    final network = bridge.network;
    final live = _live.putIfAbsent(network, _LiveRequests.new);
    final running = live.inFlight;
    if (running != null) return running;
    final done = _fetchOnce(bridge, generation, live).whenComplete(() {
      live.inFlight = null;
    });
    live.inFlight = done;
    return done;
  }

  Future<void> _fetchOnce(
    BridgeEndpoint bridge,
    int generation,
    _LiveRequests live,
  ) async {
    final network = bridge.network;
    final signals = _signal(network)..liveChecking = true;
    _evaluate();
    try {
      final whoami = await _whoami(bridge).timeout(const Duration(seconds: 25));
      if (generation != _generation) return;
      final now = _clock();
      if (whoami == null) {
        signals.liveUnavailable = true;
        live
          ..failures = 0
          ..failingSince = null
          ..nextAt = now.add(BridgeHealthRules.unavailableRetry);
        return;
      }
      signals.setLive(
        [
          for (final login in whoami.logins)
            ?BridgeStateReport.fromLogin(
              network: network,
              loginId: login.id,
              loginName: login.name,
              state: login.stateDetails,
              fetchedAt: now,
            ),
        ],
        now,
        managementRoomId: whoami.managementRoom,
      );
      lastAnswerAt = now;
      live
        ..failures = 0
        ..failingSince = null
        ..answered = true
        ..nextAt = now.add(BridgeHealthRules.liveInterval);
    } on BridgeProvisioningException catch (error) {
      if (generation != _generation) return;
      logBackgroundError('bridge_status', error);
      final now = _clock();
      if (error.unreachable || error.unsupported || error.status == 200) {
        // No route for this bridge (or not a bridgev2 answer): unknown, and
        // asked again much later.
        signals.liveUnavailable = true;
        live
          ..failures = 0
          ..failingSince = null
          ..nextAt = now.add(BridgeHealthRules.unavailableRetry);
        return;
      }
      _failed(signals, live, now);
    } catch (error) {
      if (generation != _generation) return;
      logBackgroundError('bridge_status', error);
      _failed(signals, live, _clock());
    } finally {
      signals.liveChecking = false;
      if (generation == _generation) _evaluate();
    }
  }

  /// When any bridge last answered `whoami` (proof the route and the
  /// connection work while another bridge fails).
  @visibleForTesting
  DateTime? lastAnswerAt;

  void _failed(BridgeSignals signals, _LiveRequests live, DateTime now) {
    live.failures++;
    final since = live.failingSince ??= now;
    final backoff =
        BridgeHealthRules.retryBase * math.pow(2, live.failures - 1);
    live.nextAt = now.add(
      backoff > BridgeHealthRules.retryMax
          ? BridgeHealthRules.retryMax
          : backoff,
    );
    // A bridge that answered before, keeps failing for minutes while other
    // bridges answer: its process is down (the route itself works).
    final others = lastAnswerAt;
    if (live.answered &&
        live.failures >= BridgeHealthRules.unreachableFailures &&
        now.difference(since) >= BridgeHealthRules.transientDelay &&
        others != null &&
        others.isAfter(since)) {
      signals.unreachableSince ??= since;
    }
  }

  /// Asks [network]'s bridge again within [delay] (a delivery failed).
  void _refreshSoon(String network, Duration delay) {
    final live = _live.putIfAbsent(network, _LiveRequests.new);
    final at = _clock().add(delay);
    final due = live.nextAt;
    if (due != null && !due.isAfter(at)) return;
    live.nextAt = at;
    _schedulePoll();
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
    _schedulePoll();
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
      if (evaluate) {
        _evaluate();
        // A failure may mean the login dropped: ask the bridge soon.
        if (delivery.failed) _refreshSoon(network, const Duration(seconds: 20));
      }
      return;
    }
    if (!_isRemote(event)) return;
    final signals = _signals[network];
    // Only networks with something to heal need inbound times live.
    if (signals == null && evaluate) return;
    if (_signal(network).addInbound(at) && evaluate) {
      // A remote message heals a problem and proves an unknown network
      // works; an already healthy one stays as it is.
      final current = _health[network];
      if (current == null || current.state != BridgeHealthState.ok) {
        _evaluate();
      }
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

  void _evaluate({bool force = false}) {
    if (!_scanned && !force) return;
    final now = _clock();
    final next = <String, BridgeHealth>{
      for (final entry in _signals.entries)
        entry.key: evaluateBridgeHealth(entry.key, entry.value, now),
    };
    _scheduleBoundary(now);
    if (mapEquals(next, _health)) return;
    _health = next;
    notifyListeners();
  }

  /// One timer for the next moment a verdict changes by itself (a passing
  /// state reaches 3 minutes, an answer gets old), only while listened to.
  void _scheduleBoundary(DateTime now) {
    _boundary?.cancel();
    _boundary = null;
    if (!hasListeners) return;
    DateTime? next;
    for (final signals in _signals.values) {
      final at = nextBridgeHealthChange(signals, now);
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    if (next == null) return;
    final generation = _generation;
    _boundary = Timer(next.difference(now) + const Duration(seconds: 1), () {
      _boundary = null;
      if (generation == _generation) _evaluate();
    });
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

/// `whoami` bookkeeping of one network (monitor only, never shown).
class _LiveRequests {
  /// When the bridge is due to be asked again (null: now).
  DateTime? nextAt;
  Future<void>? inFlight;
  int failures = 0;
  DateTime? failingSince;

  /// The bridge answered at least once this session.
  bool answered = false;
}
