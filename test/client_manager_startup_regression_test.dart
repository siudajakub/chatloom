// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/utils/client_manager.dart';
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
}
