// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/settings_notifications/push_rule_extensions.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/push_diagnostics_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:unifiedpush_ui/unifiedpush_ui.dart';

import '../../widgets/matrix.dart';
import 'settings_notifications.dart';

/// Opens this app's notification settings in Android (sound, vibration,
/// pop-up and channels), like Signal's "Sounds" and Telegram's
/// "Notifications and Sounds" hand-off.
Future<void> openSystemNotificationSettings() async {
  try {
    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.openAppNotificationSettings();
  } catch (_) {
    // The system screen is unavailable; nothing else to offer.
  }
}

class SettingsNotificationsView extends StatelessWidget {
  final SettingsNotificationsController controller;

  const SettingsNotificationsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfos.supportsSystemNotifications) {
      return NotionScaffold(
        title: 'Notifications',
        body: const NotionEmptyState(
          icon: Icons.notifications_off_outlined,
          title: 'System notifications are off',
          message:
              'Conversation reminders and scheduled messages are available in Tools.',
        ),
      );
    }
    // ChatLoom's own per-chat mute rules follow the chat's mute and are
    // changed there, not in this list (push_rule_mirror.dart).
    final allPushRules = Matrix.of(context).client.globalPushRules;
    final pushRules = allPushRules == null
        ? null
        : withoutChatLoomRules(allPushRules);
    final pushCategories = [
      if (pushRules?.override?.isNotEmpty ?? false)
        (rules: pushRules?.override ?? [], kind: PushRuleKind.override),
      if (pushRules?.content?.isNotEmpty ?? false)
        (rules: pushRules?.content ?? [], kind: PushRuleKind.content),
      if (pushRules?.sender?.isNotEmpty ?? false)
        (rules: pushRules?.sender ?? [], kind: PushRuleKind.sender),
      if (pushRules?.underride?.isNotEmpty ?? false)
        (rules: pushRules?.underride ?? [], kind: PushRuleKind.underride),
    ];
    final pushService = Matrix.of(context).backgroundPush;
    return NotionSettingsScaffold(
      showBack: !ChatLoomThemes.isColumnMode(context),
      title: controller.widget.registrationDetails
          ? 'Notification registration details'
          : controller.widget.serverRules
          ? 'Server notification rules'
          : 'Notifications',
      child: StreamBuilder(
        stream: Matrix.of(context).client.onSync.stream.where(
          (syncUpdate) =>
              syncUpdate.accountData?.any(
                (accountData) => accountData.type == 'm.push_rules',
              ) ??
              false,
        ),
        builder: (BuildContext context, _) {
          final theme = Theme.of(context);
          final lastReceivedPush =
              lastReceivedPushNotification[Matrix.of(
                context,
              ).client.clientName];
          return Column(
            children: [
              if (!controller.widget.registrationDetails &&
                  !controller.widget.serverRules) ...[
                SettingsSwitchListTile.adaptive(
                  title: 'Show sender and message preview',
                  subtitle:
                      'Decrypted on this device. Shown on the lock screen '
                      'unless Android hides sensitive content; hidden while '
                      'the app lock is on.',
                  setting: AppSettings.personalNotificationPreviews,
                ),
                if (kIsWeb)
                  SettingsSwitchListTile.adaptive(
                    title: L10n.of(context).playSoundOnNotification,
                    setting: AppSettings.webNotificationSound,
                  ),
                if (PlatformInfos.isAndroid)
                  NotionListRow(
                    key: const ValueKey('notifications-sound'),
                    leading: const Icon(Icons.volume_up_outlined),
                    title: 'Sound & vibration',
                    subtitle: 'Sound, vibration and pop-up in Android settings',
                    onTap: openSystemNotificationSettings,
                  ),
                NotionListRow(
                  leading: const Icon(Icons.hub_outlined),
                  title: 'Per network',
                  subtitle: 'Notifications for each network',
                  onTap: () => context.push('/rooms/settings/networks'),
                ),
                const NotionSectionHeader(title: 'Troubleshooting'),
                NotionListRow(
                  leading: const Icon(Icons.troubleshoot_outlined),
                  title: 'Troubleshoot notifications',
                  subtitle: 'Checks, recent pushes and a test notification',
                  onTap: () =>
                      context.push('/rooms/settings/notifications/diagnostics'),
                ),
                if (PlatformInfos.isAndroid) const BatteryOptimizationStatus(),
                // Manual gateway setup, registration details and the
                // server rules are in Settings › Advanced › Developer.
                const NotionSectionHeader(title: 'Advanced'),
                if (pushService != null)
                  ListenableBuilder(
                    listenable: pushService.registrationChanges,
                    builder: (context, _) => NotionListRow(
                      leading: const Icon(Icons.phonelink_setup_outlined),
                      title: 'Push setup',
                      subtitle: pushService.registrationDescription(
                        Matrix.of(context).client,
                      ),
                      onTap: () => context.push('/rooms/settings/push'),
                    ),
                  )
                else
                  NotionListRow(
                    leading: const Icon(Icons.phonelink_setup_outlined),
                    title: 'Push setup',
                    subtitle: 'Registration status is unavailable.',
                    onTap: () => context.push('/rooms/settings/push'),
                  ),
              ],
              if (controller.widget.serverRules) ...[
                const Padding(
                  padding: EdgeInsets.only(bottom: NotionSpace.xs),
                  child: Text(
                    'These rules are stored on your account and decide which '
                    'events notify every device. Per-chat settings are in '
                    'Networks.',
                  ),
                ),
                const NotionSectionHeader(title: 'Rules'),
                if (pushRules == null)
                  const NotionListRow(
                    title: 'Rules are not available yet',
                    subtitle:
                        'Reconnect to load account notification rules. '
                        'Device setup remains available.',
                  ),
                if (pushRules != null)
                  for (final category in pushCategories) ...[
                    NotionSectionHeader(
                      title: category.kind.localized(L10n.of(context)),
                      padding: const EdgeInsets.only(
                        top: NotionSpace.md,
                        bottom: NotionSpace.xxs,
                      ),
                    ),
                    for (final rule in category.rules)
                      ListTile(
                        title: Text(rule.getPushRuleName(L10n.of(context))),
                        subtitle: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: rule.getPushRuleDescription(
                                  L10n.of(context),
                                ),
                              ),
                              const TextSpan(text: ' '),
                              WidgetSpan(
                                child: InkWell(
                                  onTap: () => controller.editPushRule(
                                    rule,
                                    category.kind,
                                  ),
                                  child: Text(
                                    L10n.of(context).more,
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      decoration: TextDecoration.underline,
                                      decorationColor:
                                          theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        trailing: Switch.adaptive(
                          value: rule.enabled,
                          onChanged: controller.isLoading
                              ? null
                              : rule.ruleId != '.m.rule.master' &&
                                    Matrix.of(
                                      context,
                                    ).client.allPushNotificationsMuted
                              ? null
                              : (_) => controller.togglePushRule(
                                  category.kind,
                                  rule,
                                ),
                        ),
                      ),
                  ],
              ],
              if (controller.widget.registrationDetails) ...[
                if (kDebugMode && lastReceivedPush != null)
                  ListTile(
                    title: const Text('Last received push notification'),
                    subtitle: Text(lastReceivedPush.toIso8601String()),
                  ),
                if (pushService?.firebaseEnabled != true)
                  ListTile(
                    title: Text(L10n.of(context).buildDoesNotSupportFirebase),
                    leading: Icon(Icons.close, color: theme.colorScheme.error),
                  ),
                if (PlatformInfos.isAndroid)
                  FutureBuilder(
                    future: UnifiedPush.getDistributors(),
                    builder: (context, snapshot) {
                      final distributors = snapshot.data;
                      if (distributors == null || distributors.isEmpty) {
                        if (pushService?.firebaseEnabled == true &&
                            pushService?.fcmToken == null) {
                          return ListTile(
                            title: Text(
                              L10n.of(
                                context,
                              ).unableToRegisterDeviceForFirebase,
                            ),
                            leading: Icon(
                              Icons.close,
                              color: theme.colorScheme.error,
                            ),
                          );
                        }
                        return SizedBox.shrink();
                      }
                      return ListTile(
                        title: Text(L10n.of(context).unifiedPushDistributors),
                        leading: Icon(Icons.info_outlined),
                        subtitle: SelectableText(distributors.join(', ')),
                        trailing: distributors.length >= 2
                            ? IconButton(
                                onPressed: () => UnifiedPushUi(
                                  context: context,
                                  instances: ['default'],
                                  unifiedPushFunctions: UPFunctions(),
                                  showNoDistribDialog: false,
                                  onNoDistribDialogDismissed:
                                      () {}, // TODO: Implement me
                                ).registerAppWithDialog(),
                                icon: Icon(Icons.edit_outlined),
                                style: IconButton.styleFrom(
                                  backgroundColor:
                                      theme.colorScheme.primaryContainer,
                                  foregroundColor:
                                      theme.colorScheme.onPrimaryContainer,
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                NotionSectionHeader(title: L10n.of(context).devices),
                FutureBuilder<List<Pusher>?>(
                  key: ValueKey(Matrix.of(context).client),
                  future: controller.pusherFuture ??= Matrix.of(
                    context,
                  ).client.getPushers(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return NotionListRow(
                        title: 'Could not load registered devices',
                        subtitle: 'Check your connection and retry.',
                        onTap: controller.retryPushers,
                      );
                    }
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: NotionDelayedReveal(
                          placeholder: SizedBox(height: 4),
                          child: LinearProgressIndicator(),
                        ),
                      );
                    }
                    final pushers = snapshot.data ?? [];
                    if (pushers.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16.0),
                          child: Text(L10n.of(context).noOtherDevicesFound),
                        ),
                      );
                    }
                    return ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: pushers.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(pushers[i].appId),
                        subtitle: Text(pushers[i].data.url.toString()),
                        onTap: () => controller.onPusherTap(pushers[i]),
                      ),
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
