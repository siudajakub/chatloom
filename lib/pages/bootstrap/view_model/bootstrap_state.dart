// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class BootstrapViewModelState {
  String? recoveryKey;
  bool isLoading = false;
  Object? unlockWithError;

  /// Why the last unlock failed; null after success or before any attempt.
  RecoveryUnlockFailure? unlockFailure;

  /// The last failure left the recovery key saved on this device in place.
  bool storedKeyKept = false;

  /// The last failure proved the saved recovery key wrong and removed it.
  bool storedKeyRemoved = false;

  /// The first check of the recovery state failed.
  bool loadFailed = false;

  /// The last attempt to create a recovery key failed (shown inline with
  /// "Try again").
  Object? setupError;
  ({
    bool connected,
    bool crossSigningEnabled,
    bool initialized,
    bool keyBackupEnabled,
  })?
  cryptoIdentityState;
  bool reset = false;
  KeyVerification? keyVerification;
  List<DeviceKeys>? connectedDevices;
  bool obscureText = true;
  bool waitingForSecrets = false;
  bool noSecretsreceived = false;

  bool newPassphraseEqualsRepeatPassphrase = false;
  bool newPassphraseLongEnough = false;
  bool newPassphraseUpperAndLowerCase = false;
  bool newPassphraseSpecialCharacters = false;
  bool newPassphraseNumbers = false;
  bool passphraseOrRecoveryKeyEntered = false;
  bool recoveryKeyDownloaded = false;
  bool recoveryKeyStoredInSecureStorage = false;
}
