// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:matrix/matrix.dart';

/// Longest automatic retry delay while the app is open on a phone. The SDK
/// otherwise backs off up to the 60 s set in `ClientManager`, so a server or
/// captive-portal outage hid new messages for up to a minute after it ended.
/// Network transitions bypass the delay entirely.
const foregroundSyncRetryCapSec = 20;

/// Restarts the sync of every logged-in client after a network transition.
///
/// A transition is a wake hint, never proof that the server is reachable.
/// The long-poll that was waiting on the previous network's socket would
/// only fail after its 30 s + 10 s response timeout and then wait out the
/// retry backoff; it is dropped instead (its late answer is never processed)
/// and a zero-timeout sync starts at once. The initial sync is never dropped.
Future<void> wakeSyncOnNetworkRecovery(
  Iterable<Client> clients,
  List<ConnectivityResult> networks,
) async {
  if (!networks.any((network) => network != ConnectivityResult.none)) return;
  await Future.wait([
    for (final client in clients)
      if (client.isLogged()) syncNow(client),
  ]);
}

/// Syncs [client] at once and completes when that sync is done (a failure is
/// reported on `onSyncStatus`, never thrown). A long-poll still waiting for
/// its answer, perhaps on a socket that no longer works, is dropped and the
/// retry backoff is skipped; the server answers at once (`timeout=0`). The
/// initial sync is joined, never thrown away. For explicit retries and wake
/// hints (network transitions, the app coming back on screen).
///
/// [responseTimeout]: how long the answer may take (the SDK default is 10 s
/// for `timeout=0`); a catch-up after a long absence passes a long-poll's
/// budget so a large backlog on a slow network is not cut off and fetched
/// twice.
Future<void> syncNow(Client client, {Duration? responseTimeout}) =>
    (client.prevBatch == null
            ? client.oneShotSync()
            : client.restartSync(
                timeout: Duration.zero,
                responseTimeout: responseTimeout,
              ))
        .catchError((Object _) {});

/// Turns the platform connectivity stream into sync restarts.
///
/// The platform reports the current networks when the watcher starts and
/// repeats an unchanged list whenever capabilities (signal, validation)
/// change; only a change of the reported networks is a transition. Nothing
/// is restarted while [foreground] is false: background delivery belongs to
/// push, and no sync may run behind the user's back (battery and privacy).
class SyncNetworkRecovery {
  final bool Function() foreground;
  List<ConnectivityResult>? _last;

  SyncNetworkRecovery({required this.foreground});

  Future<void> onNetworksChanged(
    Iterable<Client> clients,
    List<ConnectivityResult> networks,
  ) async {
    final previous = _last;
    _last = List.unmodifiable(networks);
    if (previous == null) return;
    if (const UnorderedIterableEquality<ConnectivityResult>().equals(
      previous,
      networks,
    )) {
      return;
    }
    if (!foreground()) return;
    await wakeSyncOnNetworkRecovery(clients, networks);
  }

  /// Forgets the last reported networks: the next report is a new baseline,
  /// not a transition (the watcher starts again after the app came back,
  /// whose own catch-up already syncs).
  void reset() => _last = null;
}

/// The platform's network watcher, subscribed only while [active] (2026-11-26).
///
/// A phone's sync loop is off in the background and [SyncNetworkRecovery]
/// ignores every report there, yet the subscription kept Android's default
/// network callback registered: each capability change of the current
/// network (signal, bandwidth estimate, validation) still reached the app
/// while it was away, through the platform channel into Dart, for nothing.
/// Cancelling the last listener unregisters that callback; starting again
/// calls [onStart] first, and the platform then reports the current networks
/// at once.
class NetworkWatch {
  NetworkWatch({
    required Stream<List<ConnectivityResult>> Function() changes,
    required this.onNetworks,
    this.onStart,
    this.onError,
  }) : _changes = changes;

  final Stream<List<ConnectivityResult>> Function() _changes;
  final void Function(List<ConnectivityResult> networks) onNetworks;
  final void Function()? onStart;
  final void Function()? onError;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _disposed = false;

  /// Whether the watcher is subscribed.
  bool get active => _subscription != null;

  set active(bool active) {
    if (_disposed || active == this.active) return;
    if (!active) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      return;
    }
    onStart?.call();
    try {
      _subscription = _changes().listen(
        onNetworks,
        onError: (Object _, StackTrace _) => onError?.call(),
      );
    } catch (_) {
      onError?.call();
    }
  }

  void dispose() {
    active = false;
    _disposed = true;
  }
}
