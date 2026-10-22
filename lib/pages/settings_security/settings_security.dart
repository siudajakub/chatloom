// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'settings_security_view.dart';

class SettingsSecurity extends StatefulWidget {
  const SettingsSecurity({super.key});

  @override
  SettingsSecurityController createState() => SettingsSecurityController();
}

class SettingsSecurityController extends State<SettingsSecurity> {
  bool privacyPending = false;
  String? privacyError;

  Future<void> setPrivacy(bool value, {AppSettings<bool?>? setting}) async {
    if (privacyPending) return;
    setState(() {
      privacyPending = true;
      privacyError = null;
    });
    try {
      if (setting == null) {
        await PersonalPrivacy.setIncognito(
          value,
          Matrix.of(context).widget.clients,
        );
      } else {
        await setting.setItem(value);
      }
    } catch (_) {
      if (mounted)
        setState(
          () => privacyError =
              'Could not finish updating privacy. The current device policy is shown; try again.',
        );
    } finally {
      notionSettingsRevision.value++;
      if (mounted) setState(() => privacyPending = false);
    }
  }

  Future<void> toggleBiometrics() async {
    AppLock.of(context).showLockScreen();

    final oldState = AppLock.of(context).useBiometrics;
    final actionStr = oldState
        ? L10n.of(context).disableBiometrics
        : L10n.of(context).enableBiometrics;
    final consent = await showOkCancelAlertDialog(
      context: context,
      title: actionStr,
      message: L10n.of(context).biometricsDescription,
      okLabel: actionStr,
      cancelLabel: L10n.of(context).cancel,
      isDestructive: true,
    );
    if (consent != OkCancelResult.ok) return;
    if (!mounted) return;

    if (!oldState) {
      // Every non-success of the prompt is a result, never an exception.
      final result = await AppLock.of(context).confirmBiometrics();
      if (!mounted) return;
      if (!result.unlocked) {
        final message = result.enableMessage;
        if (message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }
    }
    await AppLock.of(context).changeUseBiometrics(!oldState);
    setState(() {});
  }

  Future<void> disableAppLockAction() async {
    AppLock.of(context).showLockScreen();
    final consent = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).disableAppLock,
      message: L10n.of(context).disableAppLockAreYouSure,
      okLabel: L10n.of(context).disableAppLock,
      cancelLabel: L10n.of(context).cancel,
      isDestructive: true,
    );
    if (consent != OkCancelResult.ok) return;
    if (!mounted) return;
    await AppLock.of(context).changePincode(null);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> setAppLockAction() async {
    await AppLock.of(context).changeUseBiometrics(false);
    if (!mounted) return;
    final l10n = L10n.of(context);
    if (AppLock.of(context).isActive) {
      AppLock.of(context).showLockScreen();
    }
    final newLock = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.pleaseChooseAPasscode,
      message: l10n.pleaseEnter6Digits,
      cancelLabel: l10n.cancel,
      validator: (text) {
        if (text.length == 6 && int.tryParse(text)! >= 0) {
          return null;
        }
        return l10n.pleaseEnter6Digits;
      },
      keyboardType: TextInputType.number,
      obscureText: true,
      maxLines: 1,
      minLines: 1,
      maxLength: 6,
    );
    if (newLock != null) {
      if (!mounted) return;
      await AppLock.of(context).changePincode(newLock);
      setState(() {});
    }
  }

  Future<void> changeShareKeysWith(ShareKeysWith? shareKeysWith) async {
    if (shareKeysWith == null) return;
    AppSettings.shareKeysWith.setItem(shareKeysWith.name);
    Matrix.of(context).client.shareKeysWith = shareKeysWith;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => SettingsSecurityView(this);
}
