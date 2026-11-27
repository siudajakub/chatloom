// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/personal/storage/secret_vault.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../personal/media/private_directories_stub.dart'
    if (dart.library.ffi) '../personal/media/private_directories_native.dart'
    as native;

/// Private desktop distribution does not use Keychain Sharing or provisioning.
/// Use the macOS login Keychain supported by ad-hoc/Developer ID applications;
/// the plugin's iOS and Android options remain unchanged. Every caller must use
/// the same namespace, including app lock, session restore and database keys.
/// An unavailable Keychain still fails closed; this is not a file fallback.
const personalMacStorageOptions = MacOsOptions(
  accountName: AppConfig.appId,
  usesDataProtectionKeychain: false,
);

const personalSecureStorage = PersonalSecureStorage();

/// The app's secure storage. On macOS every value lives in one [SecretVault]
/// so the Keychain asks for the password once after an update instead of
/// once per item; other platforms use the plugin unchanged.
class PersonalSecureStorage extends FlutterSecureStorage {
  const PersonalSecureStorage() : super(mOptions: personalMacStorageOptions);

  static const _keychain = FlutterSecureStorage(
    mOptions: personalMacStorageOptions,
  );

  static SecretVault? _vault;

  /// Replaces the macOS vault (tests); null restores the default.
  @visibleForTesting
  static SecretVault? debugVault;

  /// The vault on macOS (or in tests), null where the plugin is used.
  static SecretVault? get macVault => _macVault;

  static SecretVault? get _macVault {
    final override = debugVault;
    if (override != null) return override;
    if (!PlatformInfos.isMacOS) return null;
    return _vault ??= SecretVault(
      file: _LazyVaultFile(),
      keychain: const _PluginKeychain(_keychain),
    );
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    final vault = _macVault;
    if (vault != null) return vault.read(key);
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    final vault = _macVault;
    if (vault != null) return vault.write(key, value);
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    final vault = _macVault;
    if (vault != null) return vault.delete(key);
    return super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final vault = _macVault;
    if (vault != null) return await vault.read(key) != null;
    return super.containsKey(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  /// The vault cannot list Keychain items it has not copied yet, so listing
  /// or wiping everything would miss them; no caller needs either.
  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_macVault != null) throw UnsupportedError('readAll');
    return super.readAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (_macVault != null) throw UnsupportedError('deleteAll');
    return super.deleteAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

class _PluginKeychain implements KeychainItems {
  final FlutterSecureStorage storage;
  const _PluginKeychain(this.storage);

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
}

/// `<Application Support>/secret_vault/vault.v1` in the app's sandbox, its
/// folder created owner-only on first use.
class _LazyVaultFile implements VaultFile {
  Future<File>? _file;

  Future<File> _resolve() => _file ??= () async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/secret_vault');
    if (!await directory.exists()) native.PrivateDirectories.create(directory);
    return File('${directory.path}/vault.v1');
  }();

  @override
  Future<bool> exists() async => (await _resolve()).exists();

  @override
  Future<Uint8List> readAsBytes() async => (await _resolve()).readAsBytes();

  @override
  Future<void> replace(Uint8List bytes) async =>
      replaceFileAtomically(await _resolve(), bytes);

  @override
  Future<T> exclusive<T>(Future<T> Function() action) async =>
      withFileLock(File('${(await _resolve()).path}.lock'), action);
}
