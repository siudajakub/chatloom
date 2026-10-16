// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/storage/storage_failure.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DelayedClient implements Client {
  @override
  final String clientName;
  @override
  final Future<void> roomsLoading;
  _DelayedClient(this.clientName, this.roomsLoading);
  @override
  bool isLogged() => true;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if ({
      #accountDataLoading,
      #userDeviceKeysLoading,
    }.contains(invocation.memberName)) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'delayed required loader failure stays out of login while healthy account remains usable',
    () async {
      SharedPreferences.setMockInitialValues({
        ClientManager.clientNamespace: ['broken', 'healthy'],
      });
      final store = await SharedPreferences.getInstance();
      final gate = Completer<void>();
      final startup = ClientStartup(
        store: store,
        clientFactory: (name, _) async => _DelayedClient(
          name,
          name == 'broken' ? gate.future : Future<void>.value(),
        ),
        initializeClient: (_, _) async {},
      );
      addTearDown(startup.dispose);
      final restoring = startup.restore();
      await Future<void>.delayed(Duration.zero);
      expect(startup.clients.map((c) => c.clientName), ['healthy']);
      gate.completeError(
        const StorageFailure(StorageFailureCode.databaseUnavailable),
      );
      await restoring;
      expect(startup.clients.map((c) => c.clientName), ['healthy']);
      expect(startup.failedCount, 1);
      expect(store.getStringList(ClientManager.clientNamespace), [
        'broken',
        'healthy',
      ]);
    },
  );
}
