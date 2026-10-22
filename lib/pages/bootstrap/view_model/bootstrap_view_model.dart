// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/utils/localized_exception_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'bootstrap_crypto.dart';
import 'bootstrap_state.dart';

class BootstrapViewModel extends ValueNotifier<BootstrapViewModelState> {
  final Client client;
  final bool reset;

  final TextEditingController enterPassphraseOrRecovController =
      TextEditingController();
  final TextEditingController newPassphraseController = TextEditingController();
  final TextEditingController repeatPassphraseController =
      TextEditingController();
  final ScrollController devicesScrollController = ScrollController();

  final BootstrapCrypto crypto;

  /// Pause between checks while waiting for another device's secrets.
  final Duration secretsPollInterval;

  bool _disposed = false;

  /// The last setup attempt skipped the passphrase ("Try again" repeats it).
  bool _setupSkippedPassphrase = false;

  BootstrapViewModel({
    required this.client,
    required this.reset,
    this.crypto = const BootstrapCrypto(),
    @visibleForTesting this.secretsPollInterval = const Duration(seconds: 1),
  }) : super(BootstrapViewModelState()..reset = reset) {
    newPassphraseController.addListener(_checkCanCreatePassphrase);
    repeatPassphraseController.addListener(_checkCanCreatePassphrase);
    enterPassphraseOrRecovController.addListener(
      _passphraseOrRecoveryKeyEntered,
    );
    _init();
  }

  /// The first state check failed (offline, server): "Try again" instead of
  /// an endless spinner.
  Future<void> retryLoad() {
    value.loadFailed = false;
    notifyListeners();
    return _init();
  }

  @override
  void notifyListeners() {
    // The page can close while the SDK is still answering.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelKeyVerification();
    enterPassphraseOrRecovController.dispose();
    newPassphraseController.dispose();
    repeatPassphraseController.dispose();
    devicesScrollController.dispose();
    super.dispose();
  }

  void _checkCanCreatePassphrase([_]) {
    final passphrase = newPassphraseController.text;
    value.newPassphraseEqualsRepeatPassphrase =
        passphrase.isNotEmpty && passphrase == repeatPassphraseController.text;
    value.newPassphraseLongEnough = passphrase.length >= 12;
    value.newPassphraseUpperAndLowerCase =
        passphrase.contains(RegExp(r'[A-Z]')) &&
        passphrase.contains(RegExp(r'[a-z]'));
    value.newPassphraseSpecialCharacters = passphrase.contains(
      RegExp(r'[!@#$%^&*(),.?":{}|<>]'),
    );
    value.newPassphraseNumbers = passphrase.contains(RegExp(r'\d'));
    notifyListeners();
  }

  Future<void> retryKeyVerification() async {
    value.noSecretsreceived = false;
    value.keyVerification = await crypto.startVerification(client);
    value.keyVerification?.onUpdate = _onKeyVerificationUpdate;
    notifyListeners();
  }

  Future<void> _init() async {
    final CryptoIdentityState state;
    try {
      state = await crypto.state(client);
    } catch (e, s) {
      logBackgroundError('bootstrap_state', e, s);
      value.loadFailed = true;
      notifyListeners();
      return;
    }
    if (_disposed) return;
    value.cryptoIdentityState = state;
    if (state.initialized) {
      if (state.connected) return notifyListeners();

      List<DeviceKeys> devices;
      try {
        devices = await crypto.verifiedDevices(client);
      } catch (e, s) {
        // The recovery key still works without the device list.
        logBackgroundError('bootstrap_devices', e, s);
        devices = const [];
      }
      value.connectedDevices = devices;
      if (_disposed) return;
      if (devices.isNotEmpty) {
        // Started on its own: if the request cannot be sent, the recovery
        // key below still works and "Try again" sends it later.
        try {
          value.keyVerification = await crypto.startVerification(client);
          value.keyVerification?.onUpdate = _onKeyVerificationUpdate;
        } catch (e, s) {
          logBackgroundError('bootstrap_verification', e, s);
        }
      }
      if (supportsSecureStorage) {
        try {
          final keyFromSecureStorage = await crypto.readStoredKey(
            _secureStorageKey,
          );
          if (keyFromSecureStorage != null) {
            enterPassphraseOrRecovController.text = keyFromSecureStorage;
          }
        } catch (e, s) {
          Logs().e('Unable to read key from secure storage', e, s);
        }
      }
    }
    notifyListeners();
  }

  void _passphraseOrRecoveryKeyEntered() {
    final passphraseOrRecoveryKeyEntered =
        enterPassphraseOrRecovController.text.isNotEmpty;
    if (value.passphraseOrRecoveryKeyEntered !=
        passphraseOrRecoveryKeyEntered) {
      value.passphraseOrRecoveryKeyEntered = passphraseOrRecoveryKeyEntered;
      notifyListeners();
    }
  }

  Future<void> _onKeyVerificationUpdate() async {
    if (value.keyVerification?.state == KeyVerificationState.done) {
      await awaitSecretsAfterVerification();
      return;
    }
    notifyListeners();
  }

  /// The other device verified this one: wait for it to send the secrets.
  /// When none arrive in time the page shows "No keys transmitted" with
  /// "Try again" instead of waiting forever.
  @visibleForTesting
  Future<void> awaitSecretsAfterVerification() async {
    value.waitingForSecrets = true;
    value.noSecretsreceived = false;
    notifyListeners();
    final connected = await waitForRecoverySecrets(
      interval: secretsPollInterval,
      cancelled: () => _disposed,
      connected: () async {
        try {
          value.cryptoIdentityState = await crypto.state(client);
        } catch (e, s) {
          logBackgroundError('bootstrap_secrets', e, s);
        }
        return value.cryptoIdentityState?.connected == true;
      },
    );
    value.waitingForSecrets = false;
    value.noSecretsreceived = !connected;
    notifyListeners();
  }

  Future<void> setOrSkipPassphrase(String? passphrase) async {
    _setupSkippedPassphrase = passphrase == null;
    value.isLoading = true;
    value.setupError = null;
    notifyListeners();
    try {
      final state = await crypto.state(client);
      value.recoveryKey = await crypto.setUp(
        client,
        passphrase: passphrase,
        connected: state.connected,
      );
    } catch (e) {
      // One inline error with "Try again" on the page (no dialog, no
      // snackbar); only a fixed diagnostic code is logged.
      final code = PersonalDiagnostic.from(e, PersonalFailurePhase.action).code;
      Logs().w('recovery_setup_failed $code');
      value.setupError = e;
      value.isLoading = false;
    }
    notifyListeners();
  }

  /// Repeats the failed setup with the same choice (passphrase or skip).
  Future<void> retrySetup() => setOrSkipPassphrase(
    _setupSkippedPassphrase ? null : newPassphraseController.text,
  );

  void _cancelKeyVerification() {
    final keyVerification = value.keyVerification;
    if (keyVerification != null &&
        keyVerification.state != KeyVerificationState.done &&
        keyVerification.state != KeyVerificationState.error) {
      // `m.user`, not the SDK default `m.unknown`: this request went to every
      // own device, which showed "Error m.unknown: m.unknown" on cancel.
      unawaited(
        keyVerification
            .cancel('m.user')
            .then(
              (_) {},
              onError: (Object e, StackTrace s) =>
                  logBackgroundError('verification_cancel', e, s),
            ),
      );
    }
  }

  bool get supportsSecureStorage =>
      PlatformInfos.isMobile || PlatformInfos.isDesktop;

  Future<void> unlock() async {
    final key = enterPassphraseOrRecovController.text.trim();
    if (key.isEmpty) return;

    _cancelKeyVerification();

    value.unlockWithError = null;
    value.unlockFailure = null;
    value.storedKeyKept = false;
    value.storedKeyRemoved = false;
    value.isLoading = true;
    notifyListeners();
    try {
      await crypto.restore(client, key);
    } catch (e) {
      await _unlockFailed(e, key);
      return;
    }
    final before = value.cryptoIdentityState;
    try {
      value.cryptoIdentityState = await crypto.state(client);
    } catch (e, s) {
      // Restored: the secrets are on this device even if the re-check
      // cannot reach the server.
      logBackgroundError('bootstrap_state', e, s);
      value.cryptoIdentityState = (
        connected: true,
        crossSigningEnabled: before?.crossSigningEnabled ?? true,
        initialized: true,
        keyBackupEnabled: before?.keyBackupEnabled ?? true,
      );
    }
    value.isLoading = false;
    notifyListeners();
  }

  Future<void> _unlockFailed(Object e, String key) async {
    final failure = classifyRecoveryUnlockError(e);
    final code = PersonalDiagnostic.from(e, PersonalFailurePhase.action).code;
    Logs().w('recovery_unlock_failed ${failure.name} $code');
    // The saved key goes only when it was the key tried and the SDK
    // definitively rejected it. Offline, timeouts and server errors keep
    // it (it may be the only copy), and so does a different typed key.
    var storedKeyKept = false;
    var storedKeyRemoved = false;
    if (supportsSecureStorage) {
      try {
        final stored = await crypto.readStoredKey(_secureStorageKey);
        if (shouldForgetStoredRecoveryKey(
          error: e,
          attempted: key,
          stored: stored,
        )) {
          await crypto.deleteStoredKey(_secureStorageKey);
          storedKeyRemoved = true;
        } else {
          storedKeyKept = stored != null;
        }
      } catch (_) {
        Logs().w('recovery_key_storage_unavailable');
      }
    }
    value.isLoading = false;
    value.unlockWithError = e;
    value.unlockFailure = failure;
    value.storedKeyKept = storedKeyKept;
    value.storedKeyRemoved = storedKeyRemoved;
    notifyListeners();
  }

  /// The sentence under the field for the last failed unlock.
  String? get unlockErrorText {
    final failure = value.unlockFailure;
    if (failure == null) return null;
    return recoveryUnlockErrorText(
      failure,
      storedKeyKept: value.storedKeyKept,
      storedKeyRemoved: value.storedKeyRemoved,
    );
  }

  void goToRoomsPageAfterSuccess(BuildContext context) {
    for (final room in client.rooms) {
      final lastEvent = room.lastEvent;
      if (lastEvent == null ||
          lastEvent.messageType != MessageTypes.BadEncrypted ||
          lastEvent.content['can_request_session'] != true) {
        continue;
      }
      final sessionId = lastEvent.content.tryGet<String>('session_id');
      final senderKey = lastEvent.content.tryGet<String>('sender_key');
      if (sessionId != null && senderKey != null) {
        client.encryption?.keyManager.maybeAutoRequest(
          room.id,
          sessionId,
          senderKey,
        );
      }
    }
    context.go('/rooms');
  }

  void toggleObscureText() {
    value.obscureText = !value.obscureText;
    notifyListeners();
  }

  void startResetAccount() {
    value.reset = true;
    notifyListeners();
  }

  String get _secureStorageKey => 'ssss_recovery_key_${client.userID}';

  Future<void> openRecoveryKeyFile(BuildContext context) async {
    final result = await FilePicker.pickFile(
      allowedExtensions: ['txt'],
      type: FileType.custom,
    );
    final file = result?.xFile;
    if (file == null) return;
    try {
      final key = await file.readAsString();
      enterPassphraseOrRecovController.text = key;
    } catch (e, s) {
      Logs().d('Unable to read recovery key file', e, s);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    }
    if (context.mounted) await unlock();
  }

  Future<void> toggleRecoveryKeyDownloaded(
    bool? downloaded,
    BuildContext context,
  ) async {
    final path = await FilePicker.saveFile(
      fileName: 'ChatLoom-Recovery-Key-${DateTime.now().toIso8601String()}.txt',
      bytes: Uint8List.fromList(value.recoveryKey!.codeUnits),
    );
    if (path == null) return;
    value.recoveryKeyDownloaded = downloaded == true;
    notifyListeners();
  }

  Future<void> toggleRecoveryKeyStoredInSecureStorage(bool? stored) async {
    if (stored == true) {
      await crypto.writeStoredKey(_secureStorageKey, value.recoveryKey);
    } else {
      await crypto.deleteStoredKey(_secureStorageKey);
    }
    value.recoveryKeyStoredInSecureStorage = stored == true;
    notifyListeners();
  }
}
