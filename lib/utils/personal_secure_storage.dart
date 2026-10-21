// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Private desktop distribution does not use Keychain Sharing or provisioning.
/// Use the macOS login Keychain supported by ad-hoc/Developer ID applications;
/// the plugin's iOS and Android options remain unchanged. Every caller must use
/// the same namespace, including app lock, session restore and database keys.
/// An unavailable Keychain still fails closed; this is not a file fallback.
const personalMacStorageOptions = MacOsOptions(
  usesDataProtectionKeychain: false,
);

const personalSecureStorage = FlutterSecureStorage(
  mOptions: personalMacStorageOptions,
);
