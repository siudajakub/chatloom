// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

void main() {
  group('classifyRecoveryUnlockError', () {
    test('only the SDK causes that reject the input are a wrong key', () {
      for (final cause in [
        'Inalid key',
        'Incorrect parity',
        'Incorrect prefix',
        'Incorrect length',
        'Tried to unlock with passphrase while key does not have a passphrase',
      ]) {
        expect(
          classifyRecoveryUnlockError(InvalidPassphraseException(cause)),
          RecoveryUnlockFailure.wrongKey,
          reason: cause,
        );
      }
      // Account state, not the key: never a reason to drop the saved key.
      for (final cause in [
        'Unknown Algorithm',
        'Key has no content!',
        'Nothing specified',
      ]) {
        expect(
          classifyRecoveryUnlockError(InvalidPassphraseException(cause)),
          RecoveryUnlockFailure.other,
          reason: cause,
        );
      }
    });

    test('connection failures and timeouts are offline', () {
      expect(
        classifyRecoveryUnlockError(const SocketException('offline')),
        RecoveryUnlockFailure.offline,
      );
      expect(
        classifyRecoveryUnlockError(http.ClientException('offline')),
        RecoveryUnlockFailure.offline,
      );
      expect(
        classifyRecoveryUnlockError(TimeoutException('slow')),
        RecoveryUnlockFailure.offline,
      );
      expect(
        classifyRecoveryUnlockError(Exception('Bootstrap error!')),
        RecoveryUnlockFailure.other,
      );
    });
  });

  group('shouldForgetStoredRecoveryKey', () {
    final wrong = InvalidPassphraseException('Inalid key');
    const saved = 'EsTx AAAA BBBB';

    test('offline never deletes the saved key', () {
      expect(
        shouldForgetStoredRecoveryKey(
          error: const SocketException('offline'),
          attempted: saved,
          stored: saved,
        ),
        isFalse,
      );
      expect(
        shouldForgetStoredRecoveryKey(
          error: TimeoutException('slow'),
          attempted: saved,
          stored: saved,
        ),
        isFalse,
      );
    });

    test('a server or account-state error never deletes it', () {
      expect(
        shouldForgetStoredRecoveryKey(
          error: MatrixException.fromJson({
            'errcode': 'M_UNKNOWN',
            'error': 'fixture',
          }),
          attempted: saved,
          stored: saved,
        ),
        isFalse,
      );
      expect(
        shouldForgetStoredRecoveryKey(
          error: InvalidPassphraseException('Key has no content!'),
          attempted: saved,
          stored: saved,
        ),
        isFalse,
      );
    });

    test('a wrong typed key never deletes a different saved key', () {
      expect(
        shouldForgetStoredRecoveryKey(
          error: wrong,
          attempted: 'EsTx CCCC',
          stored: saved,
        ),
        isFalse,
      );
    });

    test('only the saved key itself, definitively rejected, is forgotten', () {
      expect(
        shouldForgetStoredRecoveryKey(
          error: wrong,
          attempted: ' $saved ',
          stored: saved,
        ),
        isTrue,
      );
      expect(
        shouldForgetStoredRecoveryKey(
          error: wrong,
          attempted: saved,
          stored: null,
        ),
        isFalse,
      );
    });
  });

  test('error texts are sentences without exception text', () {
    for (final failure in RecoveryUnlockFailure.values) {
      final text = recoveryUnlockErrorText(failure, storedKeyKept: true);
      expect(text, isNot(contains('Exception')));
      expect(text, endsWith('.'));
    }
    expect(
      recoveryUnlockErrorText(
        RecoveryUnlockFailure.offline,
        storedKeyKept: true,
      ),
      contains('saved recovery key is kept'),
    );
    expect(
      recoveryUnlockErrorText(
        RecoveryUnlockFailure.wrongKey,
        storedKeyRemoved: true,
      ),
      contains('was removed'),
    );
  });

  group('waitForRecoverySecrets', () {
    test('gives up after maxTries instead of waiting forever', () async {
      var checks = 0;
      final connected = await waitForRecoverySecrets(
        maxTries: 3,
        interval: Duration.zero,
        connected: () async {
          checks++;
          return false;
        },
      );
      expect(connected, isFalse);
      expect(checks, 4);
    });

    test('returns as soon as the secrets arrive', () async {
      var checks = 0;
      final connected = await waitForRecoverySecrets(
        interval: Duration.zero,
        connected: () async => ++checks == 3,
      );
      expect(connected, isTrue);
      expect(checks, 3);
    });

    test('stops when the page is gone', () async {
      var checks = 0;
      final connected = await waitForRecoverySecrets(
        interval: Duration.zero,
        cancelled: () => checks >= 2,
        connected: () async {
          checks++;
          return false;
        },
      );
      expect(connected, isFalse);
      expect(checks, 2);
    });
  });
}
