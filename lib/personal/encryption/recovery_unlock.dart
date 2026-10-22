// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:matrix/encryption.dart' show InvalidPassphraseException;
import 'package:matrix/matrix.dart' show SyncConnectionException;

/// Why unlocking with a recovery key or passphrase failed.
enum RecoveryUnlockFailure {
  /// The key or passphrase definitively does not open this account's secret
  /// storage.
  wrongKey,

  /// No connection or the server did not answer: the key was not checked.
  offline,

  /// Anything else (server error, account state still loading): the key was
  /// not proven wrong.
  other,
}

/// The causes of [InvalidPassphraseException] (vendored SDK `ssss.dart`)
/// that mean "this is not the key": a malformed recovery key, a key whose MAC
/// does not match the stored key, or a passphrase for a key without one.
/// Other causes ("Unknown Algorithm", "Key has no content!", missing
/// passphrase info) describe the account state, not the input.
const _wrongKeyCauses = {
  'Inalid key', // sic, the SDK's spelling
  'Invalid key',
  'Incorrect parity',
  'Incorrect prefix',
  'Incorrect length',
  'Tried to unlock with passphrase while key does not have a passphrase',
};

RecoveryUnlockFailure classifyRecoveryUnlockError(Object error) {
  if (error is InvalidPassphraseException) {
    return _wrongKeyCauses.contains(error.cause)
        ? RecoveryUnlockFailure.wrongKey
        : RecoveryUnlockFailure.other;
  }
  if (error is TimeoutException ||
      error is SyncConnectionException ||
      isPersonalNetworkFailure(error)) {
    return RecoveryUnlockFailure.offline;
  }
  return RecoveryUnlockFailure.other;
}

/// Whether a failed unlock may remove the recovery key the person saved in
/// this device's secure storage. Only when the saved key itself was tried
/// and definitively rejected: offline, timeouts, server errors and a typo in
/// a key typed over the saved one never delete it.
bool shouldForgetStoredRecoveryKey({
  required Object error,
  required String attempted,
  required String? stored,
}) =>
    stored != null &&
    stored.trim() == attempted.trim() &&
    classifyRecoveryUnlockError(error) == RecoveryUnlockFailure.wrongKey;

/// The sentence under the recovery key field.
String recoveryUnlockErrorText(
  RecoveryUnlockFailure failure, {
  bool storedKeyKept = false,
  bool storedKeyRemoved = false,
}) {
  final kept = storedKeyKept ? ' Your saved recovery key is kept.' : '';
  final removed = storedKeyRemoved
      ? ' The outdated copy saved on this device was removed.'
      : '';
  return switch (failure) {
    RecoveryUnlockFailure.wrongKey =>
      'This recovery key or passphrase doesn’t match your account.$removed '
          'Check it and try again.',
    RecoveryUnlockFailure.offline =>
      'No connection, so the recovery key couldn’t be checked.$kept '
          'Try again when you’re online.',
    RecoveryUnlockFailure.other =>
      'Couldn’t unlock with this recovery key right now.$kept Try again.',
  };
}

/// After a verification with another device: waits up to [maxTries] checks
/// for the other device to send the secrets. Returns true once [connected]
/// reports them, false when they never came (the page then offers "Try
/// again") or when [cancelled] (the page went away).
Future<bool> waitForRecoverySecrets({
  required Future<bool> Function() connected,
  int maxTries = 10,
  Duration interval = const Duration(seconds: 1),
  bool Function()? cancelled,
}) async {
  for (var tries = 0; ; tries++) {
    if (cancelled?.call() ?? false) return false;
    if (await connected()) return true;
    if (tries >= maxTries) return false;
    await Future<void>.delayed(interval);
  }
}
