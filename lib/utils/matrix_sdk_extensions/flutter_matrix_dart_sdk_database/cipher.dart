// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/storage/cipher_policy.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';

const _passwordStorageKey = 'database_password';
final _cipherPolicy = CipherPolicy(const _SecureKeyVault());

/// A failure never creates a plaintext fallback or deletes an existing key.
Future<String> getDatabaseCipher({bool requireExisting = false}) =>
    getProtectedStorageCipher(
      _passwordStorageKey,
      requireExisting: requireExisting,
    );

Future<String> getProtectedStorageCipher(
  String key, {
  bool requireExisting = false,
}) => _cipherPolicy.load(key, requireExisting: requireExisting);

class _SecureKeyVault implements KeyVault {
  const _SecureKeyVault();

  @override
  Future<String?> read(String key) => personalSecureStorage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      personalSecureStorage.write(key: key, value: value);
}
