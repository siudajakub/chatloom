// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/ui/notion/notion_motion.dart';
import 'package:fluffychat/utils/file_selector.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import 'settings_account_cache.dart';
import 'settings_view.dart';

enum SettingsSurface { overview, account, recovery, about }

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

  /// Per-account cache of settings values (management link, capabilities).
  SettingsAccountCache get accountCache =>
      SettingsAccountCache.of(_profileClient ?? Matrix.of(context).client);

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

  Future<void> logoutAction() async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    final consent = await showOkCancelAlertDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.areYouSureYouWantToLogout,
      message: l10n.noBackupWarning,
      isDestructive: cryptoIdentityConnected == false,
      okLabel: l10n.logout,
      cancelLabel: l10n.cancel,
    );
    if (consent != OkCancelResult.ok) return;
    if (!_isCurrentClient(client, revision)) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: client.logout,
    );
    if (result.error != null || !_isCurrentClient(client, revision)) return;
    context.go('/');
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
      setState(() => cryptoIdentityConnected = connected);
    } catch (_) {
      if (_isCurrentClient(client, revision)) {
        SettingsAccountCache.of(client).rememberRecovery(null);
        setState(() => cryptoIdentityConnected = null);
      }
    }
  }

  bool? cryptoIdentityConnected;

  Future<void> firstRunBootstrapAction([_]) async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    if (cryptoIdentityConnected == true) {
      final action = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).chatBackup,
        message: L10n.of(context).onlineKeyBackupEnabled,
        okLabel: L10n.of(context).resetRecoveryKey,
        cancelLabel: L10n.of(context).close,
        isDestructive: true,
      );
      if (action != OkCancelResult.ok) return;
      if (!_isCurrentClient(client, revision)) return;
      await context.push('/backup?reset=true');
      if (_isCurrentClient(client, revision)) {
        await checkBootstrap(account: client, accountRevision: revision);
      }
      return;
    }
    if (!_isCurrentClient(client, revision)) return;
    await context.push('/backup');
    if (_isCurrentClient(client, revision)) {
      await checkBootstrap(account: client, accountRevision: revision);
    }
  }

  Future<void> deleteAccountAction() async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    final l10n = L10n.of(context);
    final consent = await showOkCancelAlertDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.warning,
      message: l10n.deactivateAccountWarning,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (consent != OkCancelResult.ok || !_isCurrentClient(client, revision))
      return;
    final owner = client.userID!;
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.confirmMatrixId,
      validator: (text) => text == owner ? null : l10n.supposedMxid(owner),
      isDestructive: true,
      okLabel: l10n.delete,
      cancelLabel: l10n.cancel,
    );
    if (input != owner || !_isCurrentClient(client, revision)) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => client.uiaRequestBackground<IdServerUnbindResult?>(
        (auth) => _isCurrentClient(client, revision)
            ? client.deactivateAccount(auth: auth, erase: true)
            : throw StateError('The active account changed.'),
      ),
    );
    if (result.isError || !_isCurrentClient(client, revision)) return;
    await showFutureLoadingDialog(context: context, future: client.logout);
    if (_isCurrentClient(client, revision)) context.go('/');
  }

  Future<void> dehydrateAction() async {
    final client = Matrix.of(context).client;
    final revision = _accountRevision;
    if (!_isCurrentClient(client, revision)) return;
    final l10n = L10n.of(context);
    final consent = await showOkCancelAlertDialog(
      context: context,
      title: l10n.dehydrate,
      message: l10n.dehydrateWarning,
      isDestructive: true,
      okLabel: l10n.ok,
      cancelLabel: l10n.cancel,
    );
    if (consent != OkCancelResult.ok || !_isCurrentClient(client, revision))
      return;
    final response = await showFutureLoadingDialog(
      context: context,
      future: client.exportDump,
    );
    final export = response.result;
    if (export == null || !_isCurrentClient(client, revision)) return;
    final date = DateTime.now().toIso8601String().substring(0, 10);
    await MatrixFile(
      bytes: Uint8List.fromList(utf8.encode(export)),
      name: 'personal-chat-export-$date.fluffybackup',
    ).save(context);
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
