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

  /// The last sync failed (offline notice in the inbox).
  bool get offline =>
      this == ConnectionPhase.waitingForNetwork ||
      this == ConnectionPhase.connecting;
}

/// Raw phase from the latest sync status. The SDK spends a healthy long poll
/// in `waitingForResponse`, so only a failed attempt (until the next one
/// finishes), response processing and the very first sync of a new login
/// count as not online.
ConnectionPhase rawConnectionPhase({
  required SyncStatus? status,
  required bool failed,
  required bool noNetwork,
  required bool firstSync,
}) {
  if (status == SyncStatus.processing || status == SyncStatus.cleaningUp) {
    return ConnectionPhase.updating;
  }
  if (failed) {
    return noNetwork
        ? ConnectionPhase.waitingForNetwork
        : ConnectionPhase.connecting;
  }
  if (firstSync && status != null) return ConnectionPhase.updating;
  return ConnectionPhase.online;
}

/// Debounced connection phase of one client.
///
/// A problem shows only after it lasted [offlineGrace] (a failed sync is
/// retried after 3 s, so one blip stays invisible) or [updatingGrace]
/// (ordinary syncs process in well under a second); recovery shows at once.
/// While something is shown, a change to another problem shows at once too.
///
/// Listens to the sync status only while it has listeners, piggybacking on
/// the SDK's own sync loop: no polling, nothing runs in the background. The
/// grace timer is the only timer and exists only during a problem.
class ConnectionStatusMonitor extends ChangeNotifier
    implements ValueListenable<ConnectionPhase> {
  ConnectionStatusMonitor({
    required Stream<SyncStatusUpdate> Function() statuses,
    required SyncStatusUpdate? Function() current,
    required bool Function() firstSync,
    Future<bool> Function()? hasNetwork,
    this.offlineGrace = const Duration(seconds: 4),
    this.updatingGrace = const Duration(seconds: 2),
  }) : _statuses = statuses,
       _current = current,
       _firstSync = firstSync,
       _hasNetwork = hasNetwork ?? _deviceHasNetwork;

  factory ConnectionStatusMonitor.forClient(Client client) =>
      ConnectionStatusMonitor(
        statuses: () => client.onSyncStatus.stream,
        current: () => client.onSyncStatus.value,
        firstSync: () => client.prevBatch == null,
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
  final Duration offlineGrace;
  final Duration updatingGrace;

  StreamSubscription<SyncStatusUpdate>? _subscription;
  Timer? _grace;
  SyncStatus? _status;
  bool _failed = false;
  bool _noNetwork = false;
  int _probe = 0;
  ConnectionPhase _raw = ConnectionPhase.online;
  ConnectionPhase _value = ConnectionPhase.online;

  /// What the UI shows (debounced).
  @override
  ConnectionPhase get value => _value;

  /// Undebounced phase; tests and diagnostics.
  ConnectionPhase get raw => _raw;

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
    final current = _current();
    _status = current?.status;
    _failed = current?.status == SyncStatus.error;
    _subscription = _statuses().listen(_onStatus, onError: (Object _) {});
    if (_failed) unawaited(_checkNetwork());
    _update();
  }

  void _detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _grace?.cancel();
    _grace = null;
    _probe++;
  }

  void _onStatus(SyncStatusUpdate update) {
    final status = update.status;
    if (status == _status &&
        status != SyncStatus.error &&
        status != SyncStatus.finished) {
      return;
    }
    _status = status;
    if (status == SyncStatus.error) {
      final wasFailed = _failed;
      _failed = true;
      if (!wasFailed) unawaited(_checkNetwork());
    } else if (status == SyncStatus.finished) {
      _failed = false;
      _noNetwork = false;
    }
    _update();
  }

  /// One connectivity check per outage (not polled): "Waiting for network"
  /// only when the device reports no network at all.
  Future<void> _checkNetwork() async {
    final probe = ++_probe;
    bool network;
    try {
      network = await _hasNetwork();
    } catch (_) {
      network = true;
    }
    if (probe != _probe || !_failed) return;
    if (_noNetwork == !network) return;
    _noNetwork = !network;
    _update();
  }

  void _update() {
    _raw = rawConnectionPhase(
      status: _status,
      failed: _failed,
      noNetwork: _noNetwork,
      firstSync: _firstSync(),
    );
    if (_raw == ConnectionPhase.online) {
      _grace?.cancel();
      _grace = null;
      _set(ConnectionPhase.online);
      return;
    }
    if (_value != ConnectionPhase.online) {
      _set(_raw);
      return;
    }
    _grace ??= Timer(
      _raw == ConnectionPhase.updating ? updatingGrace : offlineGrace,
      () {
        _grace = null;
        if (_raw != ConnectionPhase.online) _set(_raw);
      },
    );
  }

  void _set(ConnectionPhase phase) {
    if (_value == phase) return;
    _value = phase;
    notifyListeners();
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
