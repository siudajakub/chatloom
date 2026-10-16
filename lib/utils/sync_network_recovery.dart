// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:matrix/matrix.dart';

/// A network transition is a wake hint, never proof that the server is reachable.
Future<void> wakeSyncOnNetworkRecovery(
  Iterable<Client> clients,
  List<ConnectivityResult> networks,
) async {
  if (!networks.any((network) => network != ConnectivityResult.none)) return;
  await Future.wait([
    for (final client in clients)
      if (client.isLogged()) client.oneShotSync().catchError((Object _) {}),
  ]);
}
