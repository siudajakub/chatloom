// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Phone lifecycle sync settings (2026-10-21).
void main() {
  test('background syncs for pushes never page history into limited chats', () {
    final client = Client('lifecycle', database: _Database())
      ..requestHistoryOnLimitedTimeline = true;
    ClientManager.applyMobileLifecycle(client, foreground: false);
    expect(
      client.requestHistoryOnLimitedTimeline,
      isFalse,
      reason: 'one request per limited chat would follow every push catch-up',
    );
    expect(client.syncErrorMaxTimeoutSec, foregroundSyncRetryCapSec);
    ClientManager.applyMobileLifecycle(client, foreground: true);
    expect(client.requestHistoryOnLimitedTimeline, isFalse);
    expect(client.syncErrorMaxTimeoutSec, foregroundSyncRetryCapSec);
    client.backgroundSync = false;
  });
}
