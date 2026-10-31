// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// What the header says about the Matrix connection, as in Telegram.
enum ConnectionPhase { online, waitingForNetwork, connecting, updating }

extension ConnectionPhaseLabel on ConnectionPhase {
  /// Header text, `null` while online.
  String? get label => switch (this) {
    ConnectionPhase.online => null,
    ConnectionPhase.waitingForNetwork => 'Waiting for network…',
    ConnectionPhase.connecting => 'Connecting…',
    ConnectionPhase.updating => 'Updating…',
  };

  /// Syncing keeps failing (with evidence, see [ConnectionStatusMonitor]).
  bool get offline =>
      this == ConnectionPhase.waitingForNetwork ||
      this == ConnectionPhase.connecting;

  /// A request is on its way: the header line may show a small spinner.
  bool get busy =>
      this == ConnectionPhase.connecting || this == ConnectionPhase.updating;
}

/// Raw phase from the latest sync status. The SDK spends a healthy long poll
/// in `waitingForResponse`, so only [failing] (evidence of a lasting
/// problem), response processing, a catch-up after the app came back and
/// the very first sync of a new login count as not online.
ConnectionPhase rawConnectionPhase({
  required SyncStatus? status,
  required bool failing,
  required bool noNetwork,
  required bool firstSync,
  bool catchingUp = false,
}) {
  // An answer is being processed: the connection works.
  if (status == SyncStatus.processing || status == SyncStatus.cleaningUp) {
    return ConnectionPhase.updating;
  }
  if (failing) {
    return noNetwork
        ? ConnectionPhase.waitingForNetwork
        : ConnectionPhase.connecting;
  }
  if (catchingUp) return ConnectionPhase.updating;
  if (firstSync && status != null) return ConnectionPhase.updating;
  return ConnectionPhase.online;
}

/// Debounced connection phase of one client.
///
/// "Offline" needs evidence, never a single failed request: [failuresToShow]
/// consecutive failed syncs while the app is on screen (the SDK retries
/// after 3 s), or a retry after a failure that has not answered for
/// [stallAfter] (the app's clients retry with a request the server answers
/// at once, `Client.quickSyncRetry`, so silence means it cannot get
/// through; a long-poll never stalls). "Waiting for network…" also needs
/// the device to report no network, checked again on each failure (an app
/// the system kept off the network in the background reads as "none" until
/// it is back).
///
/// Visibility is debounced: a problem shows [offlineGrace] after its
/// evidence, "Updating…" after [updatingGrace] (ordinary syncs and a resume
/// catch-up on a working connection finish well within it); recovery shows
/// at once, and while something is shown a change to another phase shows at
/// once too. A problem shown for [lastingAfter] becomes [lasting]: only then
/// does the inbox add its notice with a Retry button.
///
/// The app tells the monitor when it leaves the screen ([background]) and
/// comes back ([resumed]): errors in between are what the background does to
/// a stopped sync loop (Android cuts a background app's network, a frozen
/// long-poll times out) and never count, and the stale state is dropped on
/// return instead of waiting for the next successful sync.
///
/// Listens to the sync status only while it has listeners, piggybacking on
/// the SDK's own sync loop: no polling, nothing runs in the background. Its
/// timers exist only during a problem or a catch-up, and are cancelled when
/// it ends, when the app leaves the screen and without listeners.
class ConnectionStatusMonitor extends ChangeNotifier
    implements ValueListenable<ConnectionPhase> {
  ConnectionStatusMonitor({
    required Stream<SyncStatusUpdate> Function() statuses,
    required SyncStatusUpdate? Function() current,
    required bool Function() firstSync,
    Future<bool> Function()? hasNetwork,
    bool Function()? quickRequest,
    this.offlineGrace = const Duration(seconds: 1),
    this.updatingGrace = const Duration(milliseconds: 1500),
    this.stallAfter = const Duration(seconds: 8),
    this.lastingAfter = const Duration(seconds: 30),
    this.failuresToShow = 2,
  }) : _statuses = statuses,
       _current = current,
       _firstSync = firstSync,
       _hasNetwork = hasNetwork ?? _deviceHasNetwork,
       _quickRequest = quickRequest ?? _always;

  factory ConnectionStatusMonitor.forClient(Client client) =>
      ConnectionStatusMonitor(
        statuses: () => client.onSyncStatus.stream,
        current: () => client.onSyncStatus.value,
        firstSync: () => client.prevBatch == null,
        quickRequest: () => client.syncRequestTimeout == Duration.zero,
      );

  static final _byClient = Expando<ConnectionStatusMonitor>(
    'connection status',
  );

  /// The shared monitor of [client] (inbox header, chat headers, notices).
  static ConnectionStatusMonitor of(Client client) =>
      _byClient[client] ??= ConnectionStatusMonitor.forClient(client);

  @visibleForTesting
  static void debugOverride(Client client, ConnectionStatusMonitor monitor) =>
      _byClient[client] = monitor;

  final Stream<SyncStatusUpdate> Function() _statuses;
  final SyncStatusUpdate? Function() _current;
  final bool Function() _firstSync;
  final Future<bool> Function() _hasNetwork;

  /// Whether the request waiting now asked for an immediate answer; only
  /// such a request can stall (a healthy long-poll waits up to 30 s).
  final bool Function() _quickRequest;
  static bool _always() => true;
  final Duration offlineGrace;
  final Duration updatingGrace;
  final Duration stallAfter;
  final Duration lastingAfter;
  final int failuresToShow;

  StreamSubscription<SyncStatusUpdate>? _subscription;
  Timer? _grace;
  Timer? _stall;
  Timer? _lastingTimer;
  SyncStatus? _status;
  bool _foreground = true;
  int _failures = 0;
  bool _stalled = false;
  bool _noNetwork = false;
  bool _catchingUp = false;
  bool _lasting = false;
  int _probe = 0;
  ConnectionPhase _raw = ConnectionPhase.online;
  ConnectionPhase _value = ConnectionPhase.online;

  /// What the UI shows (debounced).
  @override
  ConnectionPhase get value => _value;

  /// Undebounced phase; tests and diagnostics.
  ConnectionPhase get raw => _raw;

  /// The shown problem ([ConnectionPhaseLabel.offline]) has lasted
  /// [lastingAfter] on screen: worth a notice with an action.
  bool get lasting => _lasting;

  /// Whether the app is on screen (see [background] and [resumed]).
  bool get foreground => _foreground;

  bool get _failing =>
      _failures >= failuresToShow || (_stalled && _failures > 0);

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

  /// The app left the screen and its sync loop stops (mobile). Nothing is
  /// shown or measured until [resumed]; errors meanwhile do not count.
  void background() {
    _foreground = false;
    _reset();
    _update();
  }

  /// The app is back on screen. [catchingUp]: it just started a sync that
  /// brings the chats up to date, shown as "Updating…" only if it takes
  /// longer than [updatingGrace]; a failure of it alone is not "offline".
  void resumed({bool catchingUp = false}) {
    _foreground = true;
    _reset();
    _catchingUp = catchingUp && hasListeners;
    _update();
  }

  /// The catch-up of [resumed] ended without failing (the caller does not
  /// call this after a failed one, which stays "Updating…" until the retry
  /// decides). Its success clears the state anyway ([SyncStatus.finished]);
  /// this covers a catch-up that ended without any status (skipped while
  /// the client initialises), so "Updating…" never outlives it.
  void caughtUp() {
    if (!_catchingUp || _failures > 0) return;
    _catchingUp = false;
    _update();
  }

  void _reset() {
    _failures = 0;
    _stalled = false;
    _noNetwork = false;
    _catchingUp = false;
    _probe++;
    _stall?.cancel();
    _stall = null;
  }

  void _attach() {
    final current = _current();
    _status = current?.status;
    // Listeners come and go (a builder with a new merged listenable re-adds
    // its listener): the failures counted so far stand while the latest
    // status is still a failure. One from before anyone listened is one
    // failure, no evidence; anything else since means a new attempt.
    if (!_foreground || _status != SyncStatus.error) {
      _failures = 0;
      _stalled = false;
      _noNetwork = false;
    } else if (_failures == 0) {
      _failures = 1;
    }
    _subscription = _statuses().listen(_onStatus, onError: (Object _) {});
    if (_failures > 0) unawaited(_checkNetwork());
    _update();
  }

  void _detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _catchingUp = false;
    _probe++;
    _stall?.cancel();
    _stall = null;
    _grace?.cancel();
    _grace = null;
    _lastingTimer?.cancel();
    _lastingTimer = null;
    _lasting = false;
  }

  void _onStatus(SyncStatusUpdate update) {
    final status = update.status;
    if (status == _status &&
        status != SyncStatus.error &&
        status != SyncStatus.finished) {
      return;
    }
    _status = status;
    _stall?.cancel();
    _stall = null;
    switch (status) {
      case SyncStatus.error:
        // A request that hung and then failed is one failure.
        _stalled = false;
        // The background stops the loop and cuts its network: no evidence.
        if (!_foreground) break;
        _failures++;
        unawaited(_checkNetwork());
      case SyncStatus.waitingForResponse:
        // A retry after a failure asks for an answer at once; silence for
        // [stallAfter] means the server cannot be reached.
        if (_foreground && _failures > 0 && _quickRequest()) {
          _stall = Timer(stallAfter, _onStall);
        }
      case SyncStatus.processing || SyncStatus.cleaningUp:
        // The server answered: whatever failed before, it is reachable.
        _failures = 0;
        _stalled = false;
        _noNetwork = false;
        _probe++;
      case SyncStatus.finished:
        _reset();
    }
    _update();
  }

  void _onStall() {
    _stall = null;
    if (!_foreground || _failures == 0) return;
    _stalled = true;
    unawaited(_checkNetwork());
    _update();
  }

  /// One connectivity check per failed attempt on screen (not polled; the
  /// SDK spaces attempts by at least 3 s): "Waiting for network…" only when
  /// the device reports no network at all.
  Future<void> _checkNetwork() async {
    final probe = ++_probe;
    bool network;
    try {
      network = await _hasNetwork();
    } catch (_) {
      network = true;
    }
    if (probe != _probe || !_foreground || _failures == 0) return;
    if (_noNetwork == !network) return;
    _noNetwork = !network;
    _update();
  }

  void _update() {
    _raw = _foreground
        ? rawConnectionPhase(
            status: _status,
            failing: _failing,
            noNetwork: _noNetwork,
            firstSync: _firstSync(),
            catchingUp: _catchingUp,
          )
        : ConnectionPhase.online;
    if (_raw == ConnectionPhase.online) {
      _grace?.cancel();
      _grace = null;
      _set(ConnectionPhase.online);
      return;
    }
    if (_value != ConnectionPhase.online) {
      _grace?.cancel();
      _grace = null;
      _set(_raw);
      return;
    }
    final grace = _raw == ConnectionPhase.updating
        ? updatingGrace
        : offlineGrace;
    if (grace == Duration.zero) {
      _set(_raw);
      return;
    }
    _grace ??= Timer(grace, () {
      _grace = null;
      if (_raw != ConnectionPhase.online) _set(_raw);
    });
  }

  void _set(ConnectionPhase phase) {
    final lasting = _updateLasting(phase);
    if (_value == phase && !lasting) return;
    _value = phase;
    notifyListeners();
  }

  /// Starts or ends the [lastingAfter] clock of a shown problem; true when
  /// [lasting] changed.
  bool _updateLasting(ConnectionPhase phase) {
    if (phase.offline) {
      if (_lasting) return false;
      _lastingTimer ??= Timer(lastingAfter, () {
        _lastingTimer = null;
        if (!_value.offline || _lasting) return;
        _lasting = true;
        notifyListeners();
      });
      return false;
    }
    _lastingTimer?.cancel();
    _lastingTimer = null;
    if (!_lasting) return false;
    _lasting = false;
    return true;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  static Future<bool> _deviceHasNetwork() async {
    final networks = await Connectivity().checkConnectivity().timeout(
      const Duration(seconds: 2),
    );
    return networks.any((network) => network != ConnectivityResult.none);
  }
}
