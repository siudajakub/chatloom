// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/storage/storage_failure.dart';
import 'package:chatloom/utils/client_manager.dart';
import 'package:chatloom/utils/init_with_restore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient implements Client {
  @override
  final String clientName;
  bool loggedIn = false;
  _FakeClient(this.clientName);

  @override
  bool isLogged() => loggedIn;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if ({
      #roomsLoading,
      #accountDataLoading,
      #userDeviceKeysLoading,
    }.contains(invocation.memberName)) {
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

class _BackgroundClient extends _FakeClient {
  _BackgroundClient(super.clientName);
  @override
  bool backgroundSync = true;
  @override
  PresenceType? syncPresence;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> savedAccounts(List<String> names) async {
    SharedPreferences.setMockInitialValues({
      ClientManager.clientNamespace: names,
    });
    return SharedPreferences.getInstance();
  }

  test(
    'background restore disables every sync loop before initialization',
    () async {
      final store = await savedAccounts(['healthy', 'slow']);
      final slow = Completer<void>();
      final initialized = <_BackgroundClient>[];
      final startup = ClientStartup(
        store: store,
        backgroundSync: false,
        clientFactory: (name, _) async => _BackgroundClient(name),
        initializeClient: (client, _) async {
          final background = client as _BackgroundClient;
          expect(background.backgroundSync, isFalse);
          expect(background.syncPresence, PresenceType.offline);
          initialized.add(background);
          if (client.clientName == 'slow') await slow.future;
          background.loggedIn = true;
        },
      );
      addTearDown(startup.dispose);
      final restoring = startup.restore();
      await Future<void>.delayed(Duration.zero);
      expect(initialized.length, 2);
      expect(startup.busy, isTrue);
      expect(initialized.every((client) => !client.backgroundSync), isTrue);
      slow.complete();
      await restoring;
      expect(startup.clients.length, 2);
    },
  );

  test(
    'failed account initialization preserves the recoverable namespace',
    () async {
      final store = await savedAccounts(['healthy', 'failed', 'logged-out']);
      final initialized = <String>[];
      final clients = await ClientManager.getClients(
        store: store,
        clientFactory: (name, _) async => _FakeClient(name),
        initializeClient: (client, _) async {
          initialized.add(client.clientName);
          if (client.clientName == 'failed') {
            throw StateError('synthetic failure');
          }
          (client as _FakeClient).loggedIn = client.clientName == 'healthy';
        },
      );
      expect(initialized, unorderedEquals(['healthy', 'failed', 'logged-out']));
      expect(clients.map((c) => c.clientName), ['healthy', 'failed']);
      expect(store.getStringList(ClientManager.clientNamespace), [
        'healthy',
        'failed',
      ]);

      // The next launch retries the preserved account rather than forgetting it.
      final retried = <String>[];
      final restored = await ClientManager.getClients(
        store: store,
        clientFactory: (name, _) async => _FakeClient(name),
        initializeClient: (client, _) async {
          retried.add(client.clientName);
          (client as _FakeClient).loggedIn = true;
        },
      );
      expect(retried, unorderedEquals(['healthy', 'failed']));
      expect(restored.every((c) => c.isLogged()), isTrue);
    },
  );

  test(
    'uninitialized clients are retained without interpreting them as logouts',
    () async {
      final store = await savedAccounts(['first', 'second']);
      final clients = await ClientManager.getClients(
        store: store,
        initialize: false,
        clientFactory: (name, _) async => _FakeClient(name),
        initializeClient: (_, _) async => fail('Initialization was disabled'),
      );
      expect(clients.map((c) => c.clientName), ['first', 'second']);
      expect(store.getStringList(ClientManager.clientNamespace), [
        'first',
        'second',
      ]);
    },
  );

  test('a single logged-out account remains available for login', () async {
    final store = await savedAccounts(['only']);
    final clients = await ClientManager.getClients(
      store: store,
      clientFactory: (name, _) async => _FakeClient(name),
      initializeClient: (_, _) async {},
    );
    expect(clients.single.clientName, 'only');
    expect(store.getStringList(ClientManager.clientNamespace), ['only']);
  });
  for (final corrupt in <Object>[42, 'not-a-list', false]) {
    test(
      'invalid registry type is preserved without creating a client: ${corrupt.runtimeType}',
      () async {
        SharedPreferences.setMockInitialValues({
          ClientManager.clientNamespace: corrupt,
        });
        final store = await SharedPreferences.getInstance();
        final startup = ClientStartup(
          store: store,
          clientFactory: (_, _) async {
            fail('A corrupt registry must not create an apparent new account');
          },
        );
        addTearDown(startup.dispose);
        await startup.restore();
        expect(startup.registryFailure?.code, 'account_registry_invalid');
        expect(startup.clients, isEmpty);
        expect(store.get(ClientManager.clientNamespace), corrupt);
      },
    );
  }

  test(
    'single restore failure stays outside login and explicit retry reuses session',
    () async {
      final store = await savedAccounts(['saved']);
      final client = _FakeClient('saved');
      var attempts = 0;
      var created = 0;
      final startup = ClientStartup(
        store: store,
        clientFactory: (_, _) async {
          created++;
          return client;
        },
        initializeClient: (_, _) async {
          if (++attempts == 1) {
            throw const StorageFailure(StorageFailureCode.keyUnavailable);
          }
          client.loggedIn = true;
        },
      );
      addTearDown(startup.dispose);
      await startup.restore();
      expect(startup.clients, isEmpty);
      expect(startup.failedCount, 1);
      expect(store.getStringList(ClientManager.clientNamespace), ['saved']);
      await startup.restore();
      expect(startup.clients, [client]);
      expect(startup.hasFailures, isFalse);
      expect(created, 1);
    },
  );

  test(
    'failed account factory does not block a healthy account or recreate it on retry',
    () async {
      final store = await savedAccounts(['bad', 'healthy']);
      final calls = <String, int>{};
      var recover = false;
      final startup = ClientStartup(
        store: store,
        clientFactory: (name, _) async {
          calls[name] = (calls[name] ?? 0) + 1;
          if (name == 'bad' && !recover) {
            throw const StorageFailure(StorageFailureCode.databaseUnavailable);
          }
          return _FakeClient(name)..loggedIn = true;
        },
        initializeClient: (_, _) async {},
      );
      addTearDown(startup.dispose);
      await startup.restore();
      final healthy = startup.clients.single;
      expect(healthy.clientName, 'healthy');
      expect(startup.failedCount, 1);
      expect(store.getStringList(ClientManager.clientNamespace), [
        'bad',
        'healthy',
      ]);
      recover = true;
      await startup.restore();
      expect(startup.clients.first, same(healthy));
      expect(startup.clients.map((c) => c.clientName), ['healthy', 'bad']);
      expect(calls, {'bad': 2, 'healthy': 1});
    },
  );

  test(
    'registry retry rereads the corrected saved list without resetting it',
    () async {
      SharedPreferences.setMockInitialValues({
        ClientManager.clientNamespace: 7,
      });
      final store = await SharedPreferences.getInstance();
      final startup = ClientStartup(
        store: store,
        clientFactory: (name, _) async => _FakeClient(name)..loggedIn = true,
        initializeClient: (_, _) async {},
      );
      addTearDown(startup.dispose);
      await startup.restore();
      expect(startup.registryFailure, isNotNull);
      await store.setStringList(ClientManager.clientNamespace, ['restored']);
      await startup.restore();
      expect(startup.clients.single.clientName, 'restored');
      expect(startup.hasFailures, isFalse);
    },
  );

  test(
    'overlapping retries coalesce and dispose rejects late account publication',
    () async {
      final store = await savedAccounts(['saved']);
      final gate = Completer<void>();
      var attempts = 0;
      final startup = ClientStartup(
        store: store,
        clientFactory: (name, _) async => _FakeClient(name)..loggedIn = true,
        initializeClient: (_, _) async {
          attempts++;
          await gate.future;
        },
      );
      final first = startup.restore();
      final second = startup.restore();
      expect(second, same(first));
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      startup.dispose();
      gate.complete();
      await first;
      expect(startup.clients, isEmpty);
      expect(store.getStringList(ClientManager.clientNamespace), ['saved']);
    },
  );

  test(
    'ordinary startup init failure never attempts backup-based session recovery',
    () async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings.init(loadWebConfigFile: false);
      final client = _FailingInitClient();
      await expectLater(client.initWithRestore(), throwsStateError);
      expect(client.initializations, 1);
      expect(client.initArguments?[#preserveSessionOnInitFailure], isTrue);
      expect(client.initArguments?[#waitUntilLoadCompletedLoaded], isTrue);
      expect(client.initArguments?[#waitForFirstSync], isFalse);
      // Interface noSuchMethod forwarding includes omitted optional arguments
      // with their default values. No replacement session may be supplied.
      for (final field in [
        #newToken,
        #newRefreshToken,
        #newTokenExpiresAt,
        #newHomeserver,
        #newUserID,
        #newDeviceID,
        #newDeviceName,
        #newOlmAccount,
        #newOidcClientId,
      ]) {
        expect(client.initArguments?[field], isNull, reason: '$field');
      }
    },
  );
}

class _FailingInitClient extends _FakeClient {
  _FailingInitClient() : super('saved');
  int initializations = 0;
  Map<Symbol, dynamic>? initArguments;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #init) {
      initializations++;
      initArguments = invocation.namedArguments;
      return Future<void>.error(
        StateError('synthetic existing database failure'),
      );
    }
    return super.noSuchMethod(invocation);
  }
}
