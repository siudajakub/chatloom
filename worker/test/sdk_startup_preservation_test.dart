// SPDX-License-Identifier: AGPL-3.0-or-later
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import '../../lib/personal/storage/storage_failure.dart';
import 'package:test/test.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  bool failAccount = true;
  Completer<List<Room>>? delayedRooms;
  int clears = 0;
  int deletes = 0;
  int accountReads = 0;
  final preserved = {'history': 'synthetic', 'keys': 'synthetic'};
  @override
  Future<Map<String, dynamic>?> getClient(String name) async {
    accountReads++;
    if (failAccount) {
      throw const StorageFailure(StorageFailureCode.databaseUnavailable);
    }
    return null; // A genuine logged-out account, after the injected fault clears.
  }

  @override
  Future<void> clear() async {
    clears++;
    preserved.clear();
  }

  @override
  Future<void> delete() async {
    deletes++;
    preserved.clear();
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #insertClient:
        return Future<int>.value(1);
      case #getUserDeviceKeys:
        return Future<Map<String, DeviceKeysList>>.value({});
      case #getRoomList:
        return delayedRooms?.future ?? Future<List<Room>>.value([]);
      case #getAccountData:
        return Future<Map<String, BasicEvent>>.value({});
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  for (final state in [null, LoginState.loggedIn, LoginState.softLoggedOut]) {
    test(
      'startup preservation preconditions precede database mutation: $state',
      () async {
        final database = _Database();
        final client = Client('sdk-precondition-synthetic', database: database);
        addTearDown(client.dispose);
        if (state != null) client.onLoginStateChanged.add(state);
        await expectLater(
          client.init(
            preserveSessionOnInitFailure: true,
            // With no previous state, the normal first-sync default is forbidden.
            waitForFirstSync: state == null,
          ),
          throwsA(isA<Exception>()),
        );
        expect(database.accountReads, 0);
        expect(database.clears, 0);
        expect(database.deletes, 0);
        expect(database.preserved.length, 2);
        expect(client.onLoginStateChanged.value, state);
      },
    );
  }

  test(
    'startup preservation requires all local loaders before database access',
    () async {
      final database = _Database();
      final client = Client(
        'sdk-local-precondition-synthetic',
        database: database,
      );
      addTearDown(client.dispose);
      await expectLater(
        client.init(
          preserveSessionOnInitFailure: true,
          waitForFirstSync: false,
          waitUntilLoadCompletedLoaded: false,
        ),
        throwsA(isA<Exception>()),
      );
      expect(database.accountReads, 0);
      expect(database.clears, 0);
    },
  );

  test('ordinary SDK init callers retain legacy failure cleanup', () async {
    final database = _Database();
    final client = Client('sdk-legacy-synthetic', database: database);
    addTearDown(client.dispose);
    final sub = client.onLoginStateChanged.stream.listen(
      (_) {},
      onError: (Object _) {},
    );
    addTearDown(sub.cancel);
    await expectLater(
      client.init(waitForFirstSync: false),
      throwsA(isA<Exception>()),
    );
    expect(database.clears, 1);
    expect(client.isLogged(), isFalse);
  });

  test(
    'real SDK init failure never clears/deletes storage or emits a logout',
    () async {
      final database = _Database();
      final client = Client('sdk-startup-synthetic', database: database);
      addTearDown(client.dispose);
      final states = <LoginState>[];
      final clears = <SessionClearReason>[];
      final loginSub = client.onLoginStateChanged.stream.listen(
        states.add,
        onError: (Object _) {},
      );
      final clearSub = client.onSessionCleared.stream.listen(clears.add);
      addTearDown(loginSub.cancel);
      addTearDown(clearSub.cancel);
      await expectLater(
        client.init(
          waitForFirstSync: false,
          preserveSessionOnInitFailure: true,
        ),
        throwsA(isA<Exception>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(database.clears, 0);
      expect(database.deletes, 0);
      expect(database.preserved.length, 2);
      expect(states, isNot(contains(LoginState.loggedOut)));
      expect(clears, isEmpty);
      // A retry reopens the same intact database; its genuine logged-out result
      // is distinct from the earlier initialization failure.
      database.failAccount = false;
      await client.init(
        waitForFirstSync: false,
        preserveSessionOnInitFailure: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(states, contains(LoginState.loggedOut));
      expect(database.preserved.length, 2);
    },
  );

  test(
    'real SDK delayed local loader failure preserves data before startup result',
    () async {
      final database = _Database()..failAccount = false;
      final gate = database.delayedRooms = Completer<List<Room>>();
      final client = Client('sdk-delayed-synthetic', database: database);
      addTearDown(client.dispose);
      final loginSub = client.onLoginStateChanged.stream.listen(
        (_) {},
        onError: (Object _) {},
      );
      addTearDown(loginSub.cancel);
      final init = client.init(
        newToken: 'synthetic-token',
        newHomeserver: Uri.parse('https://synthetic.invalid'),
        newUserID: '@synthetic:example.org',
        newDeviceID: 'SYNTHETIC',
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
        preserveSessionOnInitFailure: true,
      );
      final assertion = expectLater(init, throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);
      expect(client.onLoginStateChanged.value, isNot(LoginState.loggedIn));
      gate.completeError(
        const StorageFailure(StorageFailureCode.databaseUnavailable),
      );
      await assertion;
      expect(database.clears, 0);
      expect(database.deletes, 0);
      expect(database.preserved.length, 2);
      expect(client.onLoginStateChanged.value, isNot(LoginState.loggedIn));
    },
  );
}
