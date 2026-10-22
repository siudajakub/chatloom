// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

typedef CryptoIdentityState = ({
  bool connected,
  bool crossSigningEnabled,
  bool initialized,
  bool keyBackupEnabled,
});

/// The SDK and storage calls of the recovery page, in one place so tests can
/// replace them. Every method is the unchanged SDK flow; nothing here
/// implements cryptography.
class BootstrapCrypto {
  const BootstrapCrypto();

  Future<CryptoIdentityState> state(Client client) =>
      client.getCryptoIdentityState();

  /// Opens secret storage with [keyOrPassphrase] and self-signs this device.
  Future<void> restore(Client client, String keyOrPassphrase) =>
      client.restoreCryptoIdentity(keyOrPassphrase);

  /// Creates (or, when [connected], re-creates keeping the downloaded key
  /// backup) the crypto identity; returns the new recovery key.
  Future<String> setUp(
    Client client, {
    String? passphrase,
    required bool connected,
  }) async {
    if (connected) {
      Logs().i('Download the key backup...');
      await client.encryption!.keyManager.loadAllKeys();
    }
    Logs().i('Init crypto identity...');
    final recoveryKey = await client.initCryptoIdentity(passphrase: passphrase);
    if (connected) {
      Logs().i('Mark all megolm sessions as needing upload...');
      await client.database.markInboundGroupSessionsAsNeedingUpload();
    }
    return recoveryKey;
  }

  /// Own devices that can send this device the secrets after verification.
  Future<List<DeviceKeys>> verifiedDevices(Client client) async {
    await client.updateUserDeviceKeys();
    return client.userDeviceKeys[client.userID!]?.deviceKeys.values
            .where(
              (device) =>
                  device.hasValidSignatureChain(verifiedByTheirMasterKey: true),
            )
            .toList() ??
        [];
  }

  Future<KeyVerification> startVerification(Client client) =>
      client.userDeviceKeys[client.userID!]!.startVerification();

  Future<String?> readStoredKey(String key) =>
      personalSecureStorage.read(key: key);

  Future<void> writeStoredKey(String key, String? value) =>
      personalSecureStorage.write(key: key, value: value);

  Future<void> deleteStoredKey(String key) =>
      personalSecureStorage.delete(key: key);
}
