// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/encryption/recovery_settings.dart';
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:chatloom/ui/notion/notion_motion.dart';
import 'package:chatloom/utils/file_selector.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import 'settings_account_cache.dart';
import 'settings_view.dart';

enum SettingsSurface { overview, account, recovery, advanced }

class Settings extends StatefulWidget {
  final SettingsSurface surface;
  const Settings({super.key, this.surface = SettingsSurface.overview});

  @override
  SettingsController createState() => SettingsController();
}

class SettingsController extends State<Settings> {
  Future<Profile>? profileFuture;
  bool profileUpdated = false;
  bool _refreshProfile = false;
  Client? _profileClient;
  int _accountRevision = 0;

  /// Last known profile of the active account, available on the first frame
  /// while [profileFuture] refreshes it.
  Profile? get cachedProfile {
    final client = _profileClient;
    return client == null ? null : SettingsAccountCache.of(client).profile;
  }

  bool _isCurrentClient(Client client, int revision) =>
      mounted &&
      revision == _accountRevision &&
      identical(_profileClient, client) &&
      identical(Matrix.of(context).client, client);

  void updateProfile() => setState(() {
    profileUpdated = true;
    _refreshProfile = true;
    profileFuture = null;
  });

  Future<void> setDisplaynameAction() async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    Profile? profile;
    try {
      profile = await profileFuture;
    } catch (_) {
      if (!_isCurrentClient(client, revision)) return;
    }
    if (!_isCurrentClient(client, revision)) return;
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.editDisplayname,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
      initialText: profile?.displayName ?? client.userID!.localpart,
    );
    if (input == null) return;
    if (!_isCurrentClient(client, revision)) return;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => client.setProfileField(client.userID!, 'displayname', {
        'displayname': input,
      }),
    );
    if (success.error == null && _isCurrentClient(client, revision)) {
      updateProfile();
    }
  }

  /// The recovery state right now: the cached value when known, else one
  /// short check (offline it stays unknown and the dialog warns).
  Future<LogoutRecovery> _recoveryForLogout(Client client, int revision) async {
    if (!client.encryptionEnabled) return LogoutRecovery.noEncryption;
    if (cryptoIdentityConnected == null) {
      try {
        await checkBootstrap(
          account: client,
          accountRevision: revision,
        ).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    return switch (cryptoIdentityConnected) {
      true => LogoutRecovery.connected,
      false => LogoutRecovery.notConnected,
      null => LogoutRecovery.unknown,
    };
  }

  Future<void> logoutAction() async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    final recovery = await _recoveryForLogout(client, revision);
    if (!mounted || !_isCurrentClient(client, revision)) return;
    final choice = await showLogoutConfirmDialog(context, recovery);
    if (!mounted || !_isCurrentClient(client, revision)) return;
    if (choice == LogoutChoice.setUpRecovery) {
      await firstRunBootstrapAction();
      return;
    }
    if (choice != LogoutChoice.logOut) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        if (recovery == LogoutRecovery.connected) {
          await _flushKeyBackup(client);
        }
        await client.logout();
      },
    );
    if (!mounted ||
        result.error != null ||
        !_isCurrentClient(client, revision)) {
      return;
    }
    context.go('/');
  }

  /// Uploads message keys that arrived since the last backup run, so the
  /// recovery key restores the newest messages too. Best effort: the SDK
  /// logs its own failures, and logging out is never blocked by it.
  Future<void> _flushKeyBackup(Client client) async {
    try {
      await client.encryption?.keyManager.uploadInboundGroupSessions().timeout(
        const Duration(seconds: 10),
      );
    } catch (_) {
      Logs().w('logout_key_backup_flush_failed');
    }
  }

  Future<void> setAvatarAction() async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    Profile? profile;
    try {
      profile = await profileFuture;
    } catch (_) {
      if (!_isCurrentClient(client, revision)) return;
    }
    if (!_isCurrentClient(client, revision)) return;
    final actions = [
      if (PlatformInfos.isMobile)
        AdaptiveModalAction(
          value: AvatarAction.camera,
          label: l10n.openCamera,
          isDefaultAction: true,
          icon: const Icon(Icons.camera_alt_outlined),
        ),
      AdaptiveModalAction(
        value: AvatarAction.file,
        label: l10n.openGallery,
        icon: const Icon(Icons.photo_outlined),
      ),
      if (profile?.avatarUrl != null)
        AdaptiveModalAction(
          value: AvatarAction.remove,
          label: l10n.removeYourAvatar,
          isDestructive: true,
          icon: const Icon(Icons.delete_outlined),
        ),
    ];
    final action = actions.length == 1
        ? actions.single.value
        : await showModalActionPopup<AvatarAction>(
            context: context,
            title: l10n.changeYourAvatar,
            cancelLabel: l10n.cancel,
            actions: actions,
          );
    if (action == null) return;
    if (!_isCurrentClient(client, revision)) return;
    if (action == AvatarAction.remove) {
      final success = await showFutureLoadingDialog(
        context: context,
        future: () => client.setAvatar(null),
      );
      if (success.error == null && _isCurrentClient(client, revision)) {
        updateProfile();
      }
      return;
    }
    MatrixFile file;
    if (PlatformInfos.isMobile) {
      final result = await ImagePicker().pickImage(
        source: action == AvatarAction.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        imageQuality: 50,
      );
      if (result == null || !_isCurrentClient(client, revision)) return;
      file = MatrixFile(bytes: await result.readAsBytes(), name: result.path);
    } else {
      if (!_isCurrentClient(client, revision)) return;
      final result = await selectFiles(context, type: FileType.image);
      final pickedFile = result.firstOrNull;
      if (pickedFile == null || !_isCurrentClient(client, revision)) return;
      file = MatrixFile(
        bytes: await pickedFile.readAsBytes(),
        name: pickedFile.name,
      );
    }
    if (!_isCurrentClient(client, revision)) return;
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => client.setAvatar(file),
    );
    if (success.error == null && _isCurrentClient(client, revision)) {
      updateProfile();
    }
  }

  Future<void> checkBootstrap({Client? account, int? accountRevision}) async {
    if (!mounted) return;
    final client = account ?? Matrix.of(context).client;
    final revision = accountRevision ?? _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    if (!client.encryptionEnabled) return;
    if (!client.isLogged()) return;
    try {
      await client.accountDataLoading;
      if (!_isCurrentClient(client, revision)) return;
      await client.userDeviceKeysLoading;
      if (!_isCurrentClient(client, revision)) return;
      if (client.prevBatch == null) {
        await client.onSync.stream.first;
        if (!_isCurrentClient(client, revision)) return;
      }

      final state = await client.getCryptoIdentityState();
      if (!_isCurrentClient(client, revision)) return;
      final connected = state.initialized && state.connected;
      SettingsAccountCache.of(client).rememberRecovery(connected);
      setState(() {
        cryptoIdentityConnected = connected;
        recoveryInitialized = state.initialized;
      });
    } catch (_) {
      if (_isCurrentClient(client, revision)) {
        SettingsAccountCache.of(client).rememberRecovery(null);
        setState(() {
          cryptoIdentityConnected = null;
          recoveryInitialized = null;
        });
      }
    }
  }

  bool? cryptoIdentityConnected;

  /// Whether the account has a recovery key at all; null until checked on
  /// this page (only [cryptoIdentityConnected] is cached).
  bool? recoveryInitialized;

  RecoveryStatus get recoveryStatus => recoveryStatusOf(
    connected: cryptoIdentityConnected,
    initialized: recoveryInitialized,
  );

  /// Checks a recovery key against the account's secret storage key. Local
  /// only: nothing is unlocked, cached or changed (`postUnlock: false`).
  Future<RecoveryUnlockFailure?> checkRecoveryKey(
    String keyOrPassphrase,
  ) async {
    final encryption = Matrix.of(context).client.encryption;
    if (encryption == null) return RecoveryUnlockFailure.other;
    try {
      await encryption.ssss.open().unlock(
        keyOrPassphrase: keyOrPassphrase,
        postUnlock: false,
      );
      return null;
    } catch (error) {
      return classifyRecoveryUnlockError(error);
    }
  }

  Future<void> verifyRecoveryKeyAction() =>
      showVerifyRecoveryKeyDialog(context, check: checkRecoveryKey);

  /// Guarded: confirm, then the unchanged reset flow of the recovery page.
  Future<void> resetRecoveryKeyAction() async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!await confirmRecoveryReset(context)) return;
    if (!mounted || !_isCurrentClient(client, revision)) return;
    await context.push('/backup?reset=true');
    if (_isCurrentClient(client, revision)) {
      await checkBootstrap(account: client, accountRevision: revision);
    }
  }

  /// The recovery key page: set up a key, or connect this device to it.
  /// When recovery is already connected, Settings offers verify and reset
  /// instead ([verifyRecoveryKeyAction], [resetRecoveryKeyAction]).
  Future<void> firstRunBootstrapAction([_]) async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    if (cryptoIdentityConnected == true) {
      await resetRecoveryKeyAction();
      return;
    }
    await context.push('/backup');
    if (_isCurrentClient(client, revision)) {
      await checkBootstrap(account: client, accountRevision: revision);
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    if (!identical(_profileClient, client)) {
      _profileClient = client;
      _accountRevision++;
      profileFuture = null;
      profileUpdated = false;
      _refreshProfile = false;
      final cache = SettingsAccountCache.of(client);
      // Show the last known recovery state at once; re-check it only when it
      // is stale, and only after the page finished sliding in.
      cryptoIdentityConnected = cache.recoveryConnected;
      recoveryInitialized = cache.recoveryConnected == true ? true : null;
      if (!cache.recoveryFresh) {
        final revision = _accountRevision;
        NotionMotion.afterRouteSettled(context, () {
          if (_isCurrentClient(client, revision)) {
            unawaited(
              checkBootstrap(account: client, accountRevision: revision),
            );
          }
        });
      }
    }
    profileFuture ??= SettingsAccountCache.of(
      client,
    ).loadProfile(force: _refreshProfile);
    _refreshProfile = false;
    return SettingsView(this);
  }
}

enum AvatarAction { camera, file, remove }
