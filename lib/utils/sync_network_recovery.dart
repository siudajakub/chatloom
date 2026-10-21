// SPDX-License-Identifier: AGPL-3.0-or-later
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
      if (client.isLogged())
        (client.prevBatch == null
                ? client.oneShotSync()
                : client.restartSync(timeout: Duration.zero))
            .catchError((Object _) {}),
  ]);
}

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
}
