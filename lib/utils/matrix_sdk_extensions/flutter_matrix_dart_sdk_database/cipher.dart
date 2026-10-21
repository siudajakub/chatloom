// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/personal/storage/cipher_policy.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  static const _options = IOSOptions(groupId: 'group.im.fluffychat.app');

  FlutterSecureStorage get _storage => const FlutterSecureStorage(
    iOptions: _options,
    mOptions: personalMacStorageOptions,
  );

  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key, iOptions: _options);
    if (value != null || !PlatformInfos.isIOS) return value;
    // Preserve the legacy key as well: migration is a copy, never deletion.
    final legacy = await personalSecureStorage.read(key: key);
    if (legacy != null) {
      await _storage.write(key: key, value: legacy, iOptions: _options);
    }
    return legacy;
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value, iOptions: _options);
}
