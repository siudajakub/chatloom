// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/pages/bootstrap/view_model/bootstrap_crypto.dart';
import 'package:chatloom/pages/bootstrap/view_model/bootstrap_view_model.dart';
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected fixture database access');
}

class _Client extends Client {
  _Client() : super('bootstrap fixture', database: _NoDatabase());
  @override
  String get userID => '@fixture:example.invalid';
}

const _disconnected = (
  connected: false,
  crossSigningEnabled: true,
  initialized: true,
  keyBackupEnabled: true,
);
const _connected = (
  connected: true,
  crossSigningEnabled: true,
  initialized: true,
  keyBackupEnabled: true,
);
const _fresh = (
  connected: false,
  crossSigningEnabled: false,
  initialized: false,
  keyBackupEnabled: false,
);

/// Fictional SDK and keystore: no network, no keys, no device storage.
class _Crypto extends BootstrapCrypto {
  _Crypto({this.states = const [], this.restoreError, this.stored});

  /// Answers of successive `state` calls; the last one repeats.
  List<Object> states;
  Object? restoreError;
  String? stored;
  Object? setUpError;
  int restores = 0;
  int setUps = 0;
  final setUpPassphrases = <String?>[];
  int stateCalls = 0;

  @override
  Future<CryptoIdentityState> state(Client client) async {
    final answer =
        states[stateCalls < states.length ? stateCalls : states.length - 1];
    stateCalls++;
    if (answer is CryptoIdentityState) return answer;
    throw answer;
  }

  @override
  Future<void> restore(Client client, String keyOrPassphrase) async {
    restores++;
    final error = restoreError;
    if (error != null) throw error;
  }

  @override
  Future<String> setUp(
    Client client, {
    String? passphrase,
    required bool connected,
  }) async {
    setUps++;
    setUpPassphrases.add(passphrase);
    final error = setUpError;
    if (error != null) throw error;
    return 'fictional recovery key';
  }

  @override
  Future<List<DeviceKeys>> verifiedDevices(Client client) async => const [];

  @override
  Future<String?> readStoredKey(String key) async => stored;

  @override
  Future<void> writeStoredKey(String key, String? value) async =>
      stored = value;

  @override
  Future<void> deleteStoredKey(String key) async => stored = null;
}

Future<BootstrapViewModel> _open(_Crypto crypto) async {
  final model = BootstrapViewModel(
    client: _Client(),
    reset: false,
    crypto: crypto,
    secretsPollInterval: Duration.zero,
  );
  // Let `_init` read the state and prefill the saved key.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return model;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const saved = 'EsTx fict iona lkey';

  group('recovery unlock (CC-06)', () {
    test('offline keeps the saved recovery key and offers a retry', () async {
      final crypto = _Crypto(
        states: [_disconnected],
        stored: saved,
        restoreError: const SocketException('offline'),
      );
      final model = await _open(crypto);
      addTearDown(model.dispose);
      expect(model.enterPassphraseOrRecovController.text, saved);

      await model.unlock();

      expect(crypto.stored, saved);
      expect(model.value.unlockFailure, RecoveryUnlockFailure.offline);
      expect(model.value.storedKeyKept, isTrue);
      expect(model.value.isLoading, isFalse);
      expect(model.unlockErrorText, contains('saved recovery key is kept'));
      expect(model.unlockErrorText, isNot(contains('Socket')));

      // Back online: the same saved key unlocks.
      crypto
        ..restoreError = null
        ..states = [_connected];
      await model.unlock();
      expect(crypto.restores, 2);
      expect(model.value.unlockFailure, isNull);
      expect(model.value.cryptoIdentityState?.connected, isTrue);
      expect(crypto.stored, saved);
    });

    test('a timeout or server error keeps the saved key too', () async {
      for (final error in <Object>[
        TimeoutException('slow'),
        MatrixException.fromJson({'errcode': 'M_UNKNOWN', 'error': 'x'}),
        Exception('Bootstrap error!'),
      ]) {
        final crypto = _Crypto(
          states: [_disconnected],
          stored: saved,
          restoreError: error,
        );
        final model = await _open(crypto);
        await model.unlock();
        expect(crypto.stored, saved, reason: '$error');
        expect(model.value.storedKeyKept, isTrue);
        model.dispose();
      }
    });

    test(
      'the saved key, definitively rejected, is removed and said so',
      () async {
        final crypto = _Crypto(
          states: [_disconnected],
          stored: saved,
          restoreError: InvalidPassphraseException('Inalid key'),
        );
        final model = await _open(crypto);
        addTearDown(model.dispose);
        await model.unlock();
        expect(crypto.stored, isNull);
        expect(model.value.unlockFailure, RecoveryUnlockFailure.wrongKey);
        expect(model.unlockErrorText, contains('was removed'));
      },
    );

    test('a wrong key typed over the saved one keeps the saved key', () async {
      final crypto = _Crypto(
        states: [_disconnected],
        stored: saved,
        restoreError: InvalidPassphraseException('Inalid key'),
      );
      final model = await _open(crypto);
      addTearDown(model.dispose);
      model.enterPassphraseOrRecovController.text = 'EsTx typo';
      await model.unlock();
      expect(crypto.stored, saved);
      expect(model.value.unlockFailure, RecoveryUnlockFailure.wrongKey);
      expect(model.unlockErrorText, isNot(contains('removed')));
    });

    test(
      'a restore that succeeds stays successful when the re-check fails',
      () async {
        final crypto = _Crypto(
          states: [_disconnected, const SocketException('offline')],
          stored: saved,
        );
        final model = await _open(crypto);
        addTearDown(model.dispose);
        await model.unlock();
        expect(model.value.unlockFailure, isNull);
        expect(model.value.cryptoIdentityState?.connected, isTrue);
        expect(crypto.stored, saved);
      },
    );
  });

  group('waiting for keys from another device (CC-13)', () {
    test('ends with "no keys" instead of waiting forever', () async {
      final crypto = _Crypto(states: [_disconnected]);
      final model = await _open(crypto);
      addTearDown(model.dispose);
      var notified = 0;
      model.addListener(() => notified++);

      await model.awaitSecretsAfterVerification();

      expect(model.value.waitingForSecrets, isFalse);
      expect(model.value.noSecretsreceived, isTrue);
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('finishes as soon as the secrets arrive', () async {
      final crypto = _Crypto(
        states: [_disconnected, _disconnected, _disconnected, _connected],
      );
      final model = await _open(crypto);
      addTearDown(model.dispose);
      await model.awaitSecretsAfterVerification();
      expect(model.value.noSecretsreceived, isFalse);
      expect(model.value.waitingForSecrets, isFalse);
      expect(model.value.cryptoIdentityState?.connected, isTrue);
    });

    test('a closed page stops waiting without notifying', () async {
      final crypto = _Crypto(states: [_disconnected]);
      final model = await _open(crypto);
      final waiting = model.awaitSecretsAfterVerification();
      model.dispose();
      await waiting; // No "used after being disposed" assertion.
    });
  });

  group('setting up a recovery key (CS-14)', () {
    test(
      'a failure is one inline error, and "Try again" repeats the choice',
      () async {
        final crypto = _Crypto(states: [_fresh])
          ..setUpError = const SocketException('offline');
        final model = await _open(crypto);
        addTearDown(model.dispose);

        await model.setOrSkipPassphrase(null);
        expect(model.value.setupError, isA<SocketException>());
        expect(model.value.isLoading, isFalse);
        expect(model.value.recoveryKey, isNull);

        crypto.setUpError = null;
        await model.retrySetup();
        expect(crypto.setUpPassphrases, [null, null]);
        expect(model.value.setupError, isNull);
        expect(model.value.recoveryKey, 'fictional recovery key');
      },
    );
  });

  test(
    'a failed first check offers "Try again" instead of a spinner',
    () async {
      final crypto = _Crypto(
        states: [const SocketException('offline'), _disconnected],
      );
      final model = await _open(crypto);
      addTearDown(model.dispose);
      expect(model.value.loadFailed, isTrue);
      expect(model.value.cryptoIdentityState, isNull);

      await model.retryLoad();
      expect(model.value.loadFailed, isFalse);
      expect(model.value.cryptoIdentityState?.initialized, isTrue);
    },
  );
}
