// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_notifications/push_rule_extensions.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/matrix.dart';
import 'settings_notifications_view.dart';

class SettingsNotifications extends StatefulWidget {
  final bool registrationDetails;
  const SettingsNotifications({super.key, this.registrationDetails = false});

  @override
  SettingsNotificationsController createState() =>
      SettingsNotificationsController();
}

class SettingsNotificationsController extends State<SettingsNotifications> {
  bool isLoading = false;

  Future<void> onPusherTap(Pusher pusher) async {
    final account = Matrix.of(context).client;
    final revision = _accountRevision;
    final delete = await showModalActionPopup<bool>(
      context: context,
      title: pusher.deviceDisplayName,
      message: '${pusher.appDisplayName} (${pusher.appId})',
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          label: L10n.of(context).delete,
          isDestructive: true,
          value: true,
        ),
      ],
    );
    if (delete != true || !_current(account, revision)) return;

    final success = await showFutureLoadingDialog(
      context: context,
      future: () => account.deletePusher(
        PusherId(appId: pusher.appId, pushkey: pusher.pushkey),
      ),
    );

    if (success.error != null || !_current(account, revision)) return;

    setState(() {
      pusherFuture = null;
    });
  }

  Future<List<Pusher>?>? pusherFuture;
  Client? _account;
  int _accountRevision = 0;
  bool _current(Client account, int revision) =>
      mounted &&
      identical(_account, account) &&
      identical(Matrix.of(context).client, account) &&
      revision == _accountRevision;
  void retryPushers() => setState(() => pusherFuture = null);

  Future<void> togglePushRule(PushRuleKind kind, PushRule pushRule) async {
    final account = Matrix.of(context).client;
    final revision = _accountRevision;
    setState(() {
      isLoading = true;
    });
    try {
      final updateFromSync = account.onSync.stream
          .where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          )
          .first;
      await account.setPushRuleEnabled(
        kind,
        pushRule.ruleId,
        !pushRule.enabled,
      );
      await updateFromSync.timeout(const Duration(seconds: 15));
    } catch (e, s) {
      Logs().w('Unable to toggle push rule', e, s);
      if (!_current(account, revision)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    } finally {
      if (_current(account, revision)) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> editPushRule(PushRule rule, PushRuleKind kind) async {
    final account = Matrix.of(context).client;
    final revision = _accountRevision;
    final theme = Theme.of(context);
    final action = await showAdaptiveDialog<PushRuleDialogAction>(
      context: context,
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 256),
        child: AlertDialog.adaptive(
          title: Text(rule.getPushRuleName(L10n.of(context))),
          content: Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Material(
              borderRadius: BorderRadius.circular(AppConfig.borderRadius),
              color: theme.colorScheme.surfaceContainer,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  prettyJson(rule.toJson()),
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
              ),
            ),
          ),
          actions: [
            AdaptiveDialogAction(
              onPressed: Navigator.of(context).pop,
              child: Text(L10n.of(context).close),
            ),
            if (!rule.ruleId.startsWith('.m.'))
              AdaptiveDialogAction(
                onPressed: () =>
                    Navigator.of(context).pop(PushRuleDialogAction.delete),
                child: Text(
                  L10n.of(context).delete,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
    if (action == null || !_current(account, revision)) return;
    switch (action) {
      case PushRuleDialogAction.delete:
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).deletePushRuleCanNotBeUndone,
          okLabel: L10n.of(context).delete,
          isDestructive: true,
        );
        if (consent != OkCancelResult.ok || !_current(account, revision))
          return;
        setState(() {
          isLoading = true;
        });
        try {
          final updateFromSync = account.onSync.stream
              .where(
                (syncUpdate) =>
                    syncUpdate.accountData?.any(
                      (accountData) => accountData.type == 'm.push_rules',
                    ) ??
                    false,
              )
              .first;
          await account.deletePushRule(kind, rule.ruleId);
          await updateFromSync.timeout(const Duration(seconds: 15));
        } catch (e, s) {
          Logs().w('Unable to delete push rule', e, s);
          if (!_current(account, revision)) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
        } finally {
          if (_current(account, revision)) {
            setState(() {
              isLoading = false;
            });
          }
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = Matrix.of(context).client;
    if (!identical(_account, account)) {
      _account = account;
      _accountRevision++;
      pusherFuture = null;
      isLoading = false;
    }
    return SettingsNotificationsView(this);
  }
}

enum PushRuleDialogAction { delete }

String prettyJson(Map<String, Object?> json) {
  const decoder = JsonDecoder();
  const encoder = JsonEncoder.withIndent('    ');
  final object = decoder.convert(jsonEncode(json));
  return encoder.convert(object);
}
