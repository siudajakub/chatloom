// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/personal/message_notification.dart';
import 'package:fluffychat/personal/push_diagnostics.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/background_push.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Settings → Notifications → Notification diagnostics.
///
/// Everything here is computed on this device and shown as yes/no answers,
/// outcome names, counts and times. It never shows tokens, keys, account,
/// chat or message identifiers, names or message text, and "Copy
/// diagnostics" copies the same content-free summary.
class PushDiagnosticsPage extends StatefulWidget {
  const PushDiagnosticsPage({super.key});

  @override
  State<PushDiagnosticsPage> createState() => _PushDiagnosticsPageState();
}

class _DeviceChecks {
  final bool? permission;
  final String messagesChannel;
  final String remindersChannel;
  final bool? batteryUnrestricted;
  const _DeviceChecks({
    this.permission,
    this.messagesChannel = 'Unknown',
    this.remindersChannel = 'Unknown',
    this.batteryUnrestricted,
  });
}

String channelStateLabel(AndroidNotificationChannel? channel) {
  if (channel == null) return 'Not created yet';
  return switch (channel.importance) {
    Importance.none => 'Off',
    Importance.min || Importance.low => 'Silent',
    Importance.defaultImportance => 'On',
    Importance.high || Importance.max => 'On, pops up',
    _ => 'On',
  };
}

/// Whether a notification channel state means notifications for it will not
/// alert the user.
bool channelStateIsProblem(String state) => state == 'Off' || state == 'Silent';

/// Subtitle for rows in a problem state that open system settings.
const pushDiagnosticsFixHint = 'Tap to change in system settings';

/// One-line summary for the top of the diagnostics page. [problems] lists
/// failing checks as short phrases, most important first; `null` entries
/// are checks that passed or are unknown.
String pushDiagnosticsVerdict(Iterable<String?> problems) {
  final first = problems.whereType<String>().firstOrNull;
  return first == null ? 'Notifications look healthy' : 'Problem: $first';
}

String yesNo(bool? value) => switch (value) {
  true => 'Yes',
  false => 'No',
  null => 'Unknown',
};

class _PushDiagnosticsPageState extends State<PushDiagnosticsPage>
    with WidgetsBindingObserver {
  final _plugin = FlutterLocalNotificationsPlugin();
  _DeviceChecks _device = const _DeviceChecks();
  PushDiagnosticsSnapshot _snapshot = PushDiagnosticsSnapshot.empty;
  PushPusherCheck? _pusher;
  bool _pusherFailed = false;
  bool _testing = false;
  bool _loaded = false;
  String? _testResult;
  Client? _client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = Matrix.of(context).client;
    if (!identical(client, _client)) {
      _client = client;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from system settings (permission, channel, battery).
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final client = _client;
    final push = Matrix.of(context).backgroundPush;
    final snapshot = await PushDiagnostics.read();
    final device = await _deviceChecks();
    PushPusherCheck? pusher;
    var pusherFailed = false;
    if (push != null && client != null) {
      try {
        pusher = await push
            .checkPusher(client)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        pusherFailed = true;
      }
    }
    if (!mounted || !identical(client, _client)) return;
    setState(() {
      _snapshot = snapshot;
      _device = device;
      _pusher = pusher;
      _pusherFailed = pusherFailed;
      _loaded = true;
    });
  }

  Future<_DeviceChecks> _deviceChecks() async {
    if (!PlatformInfos.isAndroid) return const _DeviceChecks();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    bool? permission;
    var messages = 'Unknown';
    var reminders = 'Unknown';
    bool? battery;
    try {
      await PersonalNotificationChannels.ensure(_plugin);
      permission = await android?.areNotificationsEnabled();
      final channels = await android?.getNotificationChannels() ?? const [];
      AndroidNotificationChannel? find(String id) =>
          channels.where((channel) => channel.id == id).firstOrNull;
      messages = channelStateLabel(
        find(PersonalNotificationChannels.messagesId),
      );
      reminders = channelStateLabel(
        find(PersonalNotificationChannels.remindersId),
      );
    } catch (_) {}
    try {
      battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {}
    return _DeviceChecks(
      permission: permission,
      messagesChannel: messages,
      remindersChannel: reminders,
      batteryUnrestricted: battery,
    );
  }

  Map<String, String> _checks() {
    final push = Matrix.of(context).backgroundPush;
    final client = _client;
    final pusher = _pusher;
    return {
      'Platform': PlatformInfos.isAndroid ? 'Android' : 'Not Android',
      'Notifications allowed': yesNo(_device.permission),
      'Messages channel': _device.messagesChannel,
      'Reminders channel': _device.remindersChannel,
      'Battery optimization': switch (_device.batteryUnrestricted) {
        true => 'Not restricted',
        false => 'Restricted',
        null => 'Unknown',
      },
      'Firebase token present': yesNo(
        push == null ? null : push.fcmToken != null,
      ),
      if (push != null && client != null)
        'Registration': push.registrationDescription(client),
      'Pusher registered': _pusherFailed ? 'Unknown' : yesNo(pusher?.exists),
      if (pusher != null) ...{
        'Pusher uses this device': yesNo(pusher.tokenMatches),
        'Pusher gateway address matches': yesNo(pusher.urlMatches),
        'Pusher format is event_id_only': yesNo(pusher.formatEventIdOnly),
        'Pusher gateway key matches': yesNo(pusher.nonceMatches),
      },
    };
  }

  Future<void> _sendTest() async {
    final push = Matrix.of(context).backgroundPush;
    final client = _client;
    if (push == null || client == null || _testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    String result;
    try {
      final entry = await push
          .sendTestNotification(client)
          .timeout(const Duration(seconds: 45));
      result = entry == null
          ? 'No chat with a message from someone else was found.'
          : pushOutcomeLabel(entry.outcome);
    } catch (error) {
      result = 'Failed (${PushDiagnostics.errorType(error)})';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
    await _refresh();
  }

  Future<void> _copy() async {
    final text = PushDiagnostics.describe(_snapshot, checks: _checks());
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied (no message content)')),
    );
  }

  Future<void> _reset() async {
    await PushDiagnostics.reset();
    if (!mounted) return;
    setState(() => _testResult = null);
    await _refresh();
  }

  TextStyle _valueStyle(BuildContext context, bool problem) =>
      NotionType.footnote.copyWith(
        color: problem
            ? context.notion.colors.danger
            : context.notion.colors.textSecondary,
      );

  /// A result that fades through when a check finishes or changes.
  Widget _value(BuildContext context, String value, {bool problem = false}) =>
      NotionFadeThrough(
        alignment: AlignmentDirectional.centerEnd,
        child: Text(
          value,
          key: ValueKey((value, problem)),
          textAlign: TextAlign.end,
          style: _valueStyle(context, problem),
        ),
      );

  /// A counter that rolls up or down when new pushes arrive.
  Widget _count(BuildContext context, int value, {bool problem = false}) =>
      NotionAnimatedCount(count: value, style: _valueStyle(context, problem));

  Widget _check(String title, bool? ok, {String? subtitle}) => NotionListRow(
    title: title,
    subtitle: subtitle,
    trailing: _value(context, yesNo(ok), problem: ok == false),
  );

  Future<void> _openSystemNotificationSettings() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.openAppNotificationSettings();
    } catch (_) {}
  }

  /// Failing checks in display order; the first one names the verdict.
  List<String?> _problems(BackgroundPush? push) {
    final pusher = _pusher;
    return [
      if (_device.permission == false) 'Notifications are not allowed',
      if (channelStateIsProblem(_device.messagesChannel))
        'Messages channel is ${_device.messagesChannel.toLowerCase()}',
      if (channelStateIsProblem(_device.remindersChannel))
        'Reminders channel is ${_device.remindersChannel.toLowerCase()}',
      if (_device.batteryUnrestricted == false)
        'Battery optimization is restricted',
      if (push != null && push.fcmToken == null) 'No Firebase token',
      if (!_pusherFailed && pusher != null && !pusher.exists)
        'Pusher is not registered',
      if (pusher != null && pusher.exists) ...[
        if (pusher.tokenMatches == false) 'Pusher does not use this device',
        if (pusher.urlMatches == false) 'Gateway address does not match',
        if (pusher.formatEventIdOnly == false) 'Pusher format is wrong',
        if (pusher.nonceMatches == false) 'Gateway key does not match',
      ],
    ];
  }

  Widget _channelRow(String title, String state) {
    final problem = channelStateIsProblem(state);
    return NotionListRow(
      title: title,
      subtitle: problem ? pushDiagnosticsFixHint : null,
      trailing: _value(context, state, problem: problem),
      onTap: problem ? _openSystemNotificationSettings : null,
    );
  }

  String _time(DateTime? at) {
    if (at == null) return 'Never';
    final local = at.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortMonthDay(local)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  }

  @override
  Widget build(BuildContext context) {
    final push = Matrix.of(context).backgroundPush;
    final client = _client ?? Matrix.of(context).client;
    final pusher = _pusher;
    final snapshot = _snapshot;
    final last = snapshot.last;
    final failures =
        snapshot.count(PushOutcome.timeout) +
        snapshot.count(PushOutcome.fetchFailed) +
        snapshot.count(PushOutcome.error) +
        snapshot.count(PushOutcome.storageUnavailable) +
        snapshot.count(PushOutcome.noClient);
    final silenced = [
      PushOutcome.seen,
      PushOutcome.own,
      PushOutcome.pushRules,
      PushOutcome.activeRoom,
      PushOutcome.muted,
      PushOutcome.mentionsOnly,
      PushOutcome.ignored,
    ].fold<int>(0, (sum, outcome) => sum + snapshot.count(outcome));
    final typography = context.notion.typography;
    return NotionSettingsScaffold(
      title: 'Notification diagnostics',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Checks run on this device and show only yes/no answers, '
            'outcomes and counts. No message content, names, tokens or '
            'identifiers are shown or copied.',
            style: typography.footnoteMuted,
          ),
          if (PlatformInfos.isAndroid)
            Builder(
              builder: (context) {
                final verdict = _loaded
                    ? pushDiagnosticsVerdict(_problems(push))
                    : 'Checking this device…';
                final problem = verdict.startsWith('Problem:');
                return NotionFadeThrough(
                  child: NotionListRow(
                    key: ValueKey(('push-diagnostics-verdict', verdict)),
                    title: verdict,
                    trailing: _loaded
                        ? _value(
                            context,
                            problem ? 'Needs attention' : 'OK',
                            problem: problem,
                          )
                        : null,
                  ),
                );
              },
            ),
          const NotionSectionHeader(title: 'This device'),
          if (!PlatformInfos.isAndroid)
            const NotionListRow(
              title: 'Push notifications',
              subtitle: 'Background notifications are available on Android.',
            ),
          if (PlatformInfos.isAndroid) ...[
            NotionListRow(
              title: 'Notifications allowed',
              subtitle: _device.permission == false
                  ? pushDiagnosticsFixHint
                  : 'Open system notification settings',
              trailing: _value(
                context,
                yesNo(_device.permission),
                problem: _device.permission == false,
              ),
              onTap: _openSystemNotificationSettings,
            ),
            _channelRow('Messages channel', _device.messagesChannel),
            _channelRow('Reminders channel', _device.remindersChannel),
            BatteryOptimizationRow(
              unrestricted: _device.batteryUnrestricted,
              onChanged: _refresh,
              showIcon: false,
            ),
            _check(
              'Firebase token present',
              push == null ? null : push.fcmToken != null,
            ),
            if (push != null)
              ListenableBuilder(
                listenable: push.registrationChanges,
                builder: (context, _) => NotionListRow(
                  title: 'Registration',
                  subtitle: push.registrationDescription(client),
                ),
              ),
          ],
          const NotionSectionHeader(title: 'Account pusher'),
          if (_pusherFailed)
            NotionListRow(
              title: 'Could not check the pusher',
              subtitle: 'Check your connection, then tap to retry.',
              onTap: _refresh,
            )
          else ...[
            _check('Pusher registered', pusher?.exists),
            // The detailed checks open below once a pusher is found.
            NotionSizeReveal(
              visible: pusher != null && pusher.exists,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _check('Uses this device', pusher?.tokenMatches),
                  _check('Gateway address matches', pusher?.urlMatches),
                  _check('Format is event_id_only', pusher?.formatEventIdOnly),
                  _check('Gateway key matches', pusher?.nonceMatches),
                ],
              ),
            ),
          ],
          const NotionSectionHeader(title: 'Recent pushes'),
          NotionListRow(
            title: 'Last push received',
            subtitle: snapshot.lastKind == null
                ? null
                : pushKindLabel(snapshot.lastKind!),
            trailing: _value(context, _time(snapshot.lastReceivedAt)),
          ),
          if (last != null)
            NotionListRow(
              title: 'Last result',
              subtitle: [
                pushOutcomeLabel(last.outcome),
                ?last.errorType,
                if (last.elapsedMs != null) '${last.elapsedMs} ms',
              ].join(' · '),
              trailing: _value(context, _time(last.at)),
            ),
          NotionListRow(
            title: 'Received',
            trailing: _count(context, snapshot.count(PushOutcome.received)),
          ),
          NotionListRow(
            title: 'Shown',
            subtitle: 'Messages, generic alerts and reminders',
            trailing: _count(
              context,
              snapshot.count(PushOutcome.shown) +
                  snapshot.count(PushOutcome.shownFallback) +
                  snapshot.count(PushOutcome.reminderShown),
            ),
          ),
          NotionListRow(
            title: 'Silenced on purpose',
            subtitle: 'Read elsewhere, own, muted, open chat or rules',
            trailing: _count(context, silenced),
          ),
          NotionListRow(
            title: 'Failed',
            trailing: _count(context, failures, problem: failures > 0),
          ),
          for (final entry in snapshot.recent.take(10))
            NotionListRow(
              title: pushOutcomeLabel(entry.outcome),
              subtitle: [
                pushKindLabel(entry.kind),
                ?entry.errorType,
                if (entry.elapsedMs != null) '${entry.elapsedMs} ms',
              ].join(' · '),
              trailing: _value(context, _time(entry.at)),
            ),
          const NotionSectionHeader(title: 'Actions'),
          NotionSizeReveal(
            visible: _testResult != null,
            child: NotionListRow(title: 'Test result', subtitle: _testResult),
          ),
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Wrap(
              spacing: NotionSpace.xs,
              runSpacing: NotionSpace.xs,
              children: [
                NotionButton.primary(
                  label: 'Send test notification',
                  icon: Icons.notifications_active_outlined,
                  busy: _testing,
                  onPressed: push == null || !PlatformInfos.isAndroid
                      ? null
                      : _sendTest,
                ),
                NotionButton(
                  label: 'Copy diagnostics (no content)',
                  icon: Icons.copy_outlined,
                  onPressed: _copy,
                ),
                NotionButton.ghost(
                  label: 'Reset counters',
                  icon: Icons.restart_alt,
                  onPressed: _reset,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.md),
            child: Text(
              'The test runs the real notification path for the newest '
              'message from someone else, skipping only the "already read" '
              'and "chat open" checks. If messages from others never show '
              '"Last push received", the server is not reaching this device.',
              style: typography.footnoteMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Android battery optimization status with a shortcut to the system list.
class BatteryOptimizationRow extends StatelessWidget {
  final bool? unrestricted;
  final Future<void> Function()? onChanged;

  /// Diagnostics rows carry no icons; settings rows do.
  final bool showIcon;
  const BatteryOptimizationRow({
    super.key,
    required this.unrestricted,
    this.onChanged,
    this.showIcon = true,
  });

  @override
  Widget build(BuildContext context) => NotionListRow(
    leading: showIcon ? const Icon(Icons.battery_saver_outlined) : null,
    title: 'Battery optimization',
    subtitle: switch (unrestricted) {
      true => 'Not restricted. Notifications can arrive in the background.',
      false =>
        'Restricted. Android may delay notifications. Tap and choose '
            '"Don\'t optimize" or "Unrestricted" for Personal Chat.',
      null => 'Status unavailable.',
    },
    trailing: Text(
      switch (unrestricted) {
        true => 'OK',
        false => 'Restricted',
        null => 'Unknown',
      },
      style: NotionType.footnote.copyWith(
        color: unrestricted == false
            ? context.notion.colors.danger
            : context.notion.colors.textSecondary,
      ),
    ),
    onTap: () async {
      try {
        await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
      } catch (_) {}
      await onChanged?.call();
    },
  );
}

/// Loads the battery status for rows outside the diagnostics page.
class BatteryOptimizationStatus extends StatefulWidget {
  const BatteryOptimizationStatus({super.key});

  @override
  State<BatteryOptimizationStatus> createState() =>
      _BatteryOptimizationStatusState();
}

class _BatteryOptimizationStatusState extends State<BatteryOptimizationStatus>
    with WidgetsBindingObserver {
  bool? _unrestricted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    bool? value;
    try {
      value = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {}
    if (mounted) setState(() => _unrestricted = value);
  }

  @override
  Widget build(BuildContext context) =>
      BatteryOptimizationRow(unrestricted: _unrestricted, onChanged: _load);
}
