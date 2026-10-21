// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/automatic_push.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/push_delivery_stages.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/push_rule_check.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
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
  PushGatewayProbe? _probe;
  AccountPushRulesSummary _rules = AccountPushRulesSummary.notLoaded;
  bool _pusherFailed = false;
  bool _testing = false;
  bool _reregistering = false;
  bool _loaded = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  String? _testResult;
  String? _reregisterResult;
  Client? _client;
  BackgroundPush? _push;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final matrix = Matrix.of(context);
    final push = matrix.backgroundPush;
    if (!identical(push, _push)) {
      _push?.registrationChanges.removeListener(_registrationChanged);
      _push = push;
      push?.registrationChanges.addListener(_registrationChanged);
    }
    final client = matrix.client;
    if (!identical(client, _client)) {
      _client = client;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _push?.registrationChanges.removeListener(_registrationChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from system settings (permission, channel, battery).
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  /// A registration step finished somewhere (also outside this page).
  void _registrationChanged() {
    if (mounted && !_reregistering) unawaited(_refresh());
  }

  /// One refresh at a time; a request while one runs schedules one more.
  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        await _load();
      } while (_refreshAgain && mounted);
    } finally {
      _refreshing = false;
    }
  }

  /// The account's pushers, or a failed read; never throws.
  static Future<(PushPusherCheck?, bool)> _checkPusher(
    BackgroundPush? push,
    Client? client,
  ) async {
    if (push == null || client == null) return (null, false);
    try {
      return (
        await push.checkPusher(client).timeout(const Duration(seconds: 10)),
        false,
      );
    } catch (_) {
      return (null, true);
    }
  }

  Future<void> _load() async {
    final client = _client;
    final push = _push;
    // Network checks run while the local ones are read.
    final pusherCheck = _checkPusher(push, client);
    final probe = push != null && PlatformInfos.isAndroid
        ? push.probeGateway()
        : Future<PushGatewayProbe?>.value();
    final snapshot = await PushDiagnostics.read();
    final device = await _deviceChecks();
    final (pusher, pusherFailed) = await pusherCheck;
    final reach = await probe;
    if (!mounted || !identical(client, _client)) return;
    setState(() {
      _snapshot = snapshot;
      _device = device;
      _pusher = pusher;
      _pusherFailed = pusherFailed;
      _probe = reach;
      _rules = client == null
          ? AccountPushRulesSummary.notLoaded
          : AccountPushRulesSummary.of(client);
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

  PushStageFacts _facts() {
    final push = _push;
    final client = _client;
    final pusher = _pusher;
    final tokenRecord = _snapshot.setup[PushSetupStep.token];
    // A failure remembered from an earlier process counts until this
    // process has asked Firebase itself.
    final tokenFailure =
        push?.tokenFailure ??
        (push?.fcmToken == null && tokenRecord != null && !tokenRecord.ok
            ? tokenRecord.detail
            : null);
    return PushStageFacts(
      firebase: push != null && push.firebaseEnabled && !push.upAction,
      automatic: usesAutomaticPush(
        AppSettings.pushNotificationsGatewayUrl.value,
      ),
      firebaseConfigured:
          push?.firebaseConfigured ??
          (tokenFailure == firebaseNotConfiguredDetail ? false : null),
      tokenFailure: tokenFailure,
      tokenPresent: push?.fcmToken != null,
      permission: _device.permission,
      messagesChannel: _device.messagesChannel,
      phase: push == null || client == null
          ? PushRegistrationPhase.unknown
          : push.registrationPhase(client),
      probe: _probe,
      pusherChecked: pusher != null,
      pusherCheckFailed: _pusherFailed,
      pusherExists: pusher?.exists ?? false,
      pusherTokenKnown: pusher?.tokenKnown ?? false,
      pusherTokenMatches: pusher?.tokenMatches ?? false,
      pusherUrlMatches: pusher?.urlMatches ?? false,
      pusherNonceMatches: pusher?.nonceMatches ?? false,
      snapshot: _snapshot,
    );
  }

  List<PushStage> _stages() => pushDeliveryStages(_facts(), time: _time);

  Map<String, String> _checks() {
    final push = _push;
    final client = _client;
    final pusher = _pusher;
    final stages = _stages();
    final rules = _rules;
    return {
      'Platform': PlatformInfos.isAndroid ? 'Android' : 'Not Android',
      for (var i = 0; i < stages.length; i++)
        'Step ${i + 1} ${stages[i].title}':
            '${pushStageStateLabel(stages[i].state)}: ${stages[i].detail}',
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
      'Gateway reachable from phone': switch (_probe?.reachability) {
        PushGatewayReachability.online => 'Yes',
        PushGatewayReachability.unexpected =>
          'Unexpected HTTP ${_probe!.status}',
        PushGatewayReachability.unreachable => 'No',
        null => 'Unknown',
      },
      'Pusher registered': _pusherFailed ? 'Unknown' : yesNo(pusher?.exists),
      if (pusher != null) ...{
        'Pusher uses this device': pusher.tokenKnown
            ? yesNo(pusher.tokenMatches)
            : 'Unknown',
        'Pusher gateway address matches': yesNo(pusher.urlMatches),
        'Pusher format is event_id_only': yesNo(pusher.formatEventIdOnly),
        'Pusher gateway key matches': yesNo(pusher.nonceMatches),
      },
      'Account rules synced': yesNo(rules.loaded),
      if (rules.loaded) ...{
        'Account Do Not Disturb': rules.doNotDisturb ? 'On' : 'Off',
        'Account rule direct chats': accountRuleStateLabel(rules.oneToOne),
        'Account rule group chats': accountRuleStateLabel(rules.groups),
        'Account rule encrypted direct chats': accountRuleStateLabel(
          rules.encryptedOneToOne,
        ),
        'Account rule encrypted groups': accountRuleStateLabel(
          rules.encryptedGroups,
        ),
        'Account rules with unknown conditions': yesNo(rules.unknownConditions),
      },
    };
  }

  Future<void> _sendTest() async {
    final push = _push;
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

  /// Token, gateway registration and account pusher again, in one tap.
  Future<void> _reregister() async {
    final push = _push;
    final client = _client;
    if (push == null || client == null || _reregistering) return;
    setState(() {
      _reregistering = true;
      _reregisterResult = null;
    });
    try {
      await push.reregister(context).timeout(const Duration(seconds: 90));
    } catch (_) {
      // The steps below show where it stopped.
    }
    if (!mounted) return;
    setState(() {
      _reregistering = false;
      _reregisterResult = push.registrationDescription(client);
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
  List<String?> _problems(List<PushStage> stages) => [
    ...stageProblems(stages),
    if (channelStateIsProblem(_device.remindersChannel))
      'Reminders channel is ${_device.remindersChannel.toLowerCase()}',
    if (_rules.loaded && _rules.doNotDisturb) 'Account Do Not Disturb is on',
    if (_rules.loaded && _ruleSilent(_rules.oneToOne))
      'Account rules silence direct chats',
    if (_device.batteryUnrestricted == false)
      'Battery optimization is restricted',
  ];

  static bool _ruleSilent(AccountRuleState state) =>
      state == AccountRuleState.off || state == AccountRuleState.silent;

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

  Widget _stageRow(int index, PushStage stage, {VoidCallback? onTap}) {
    final colors = context.notion.colors;
    final (icon, color) = switch (stage.state) {
      PushStageState.ok => (Icons.check_circle_outline, colors.success),
      PushStageState.problem => (Icons.error_outline, colors.danger),
      PushStageState.waiting => (Icons.schedule, colors.textSecondary),
      PushStageState.unknown => (Icons.help_outline, colors.textTertiary),
    };
    return NotionListRow(
      key: ValueKey(('push-stage', index)),
      leading: NotionFadeThrough(
        child: Icon(
          icon,
          key: ValueKey((index, stage.state)),
          size: NotionSize.icon,
          color: color,
        ),
      ),
      title: '${index + 1}. ${stage.title}',
      subtitle: stage.detail,
      trailing: _value(
        context,
        pushStageStateLabel(stage.state),
        problem: stage.problem,
      ),
      onTap: onTap,
    );
  }

  Widget _ruleRow(String title, AccountRuleState state, {bool alert = false}) =>
      NotionListRow(
        title: title,
        trailing: _value(
          context,
          accountRuleStateLabel(state),
          problem: alert && _ruleSilent(state),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final push = _push;
    final client = _client ?? Matrix.of(context).client;
    final pusher = _pusher;
    final snapshot = _snapshot;
    final last = snapshot.last;
    final stages = _stages();
    final rules = _rules;
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
    final android = PlatformInfos.isAndroid;
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
          if (android)
            Builder(
              builder: (context) {
                final verdict = _loaded
                    ? pushDiagnosticsVerdict(_problems(stages))
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
          if (android) ...[
            const NotionSectionHeader(title: 'Delivery path'),
            for (var i = 0; i < stages.length; i++)
              _stageRow(
                i,
                stages[i],
                onTap: i == 1 ? _openSystemNotificationSettings : null,
              ),
            NotionSizeReveal(
              visible: _reregisterResult != null,
              child: NotionListRow(
                title: 'Re-register result',
                subtitle: _reregisterResult,
              ),
            ),
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
                    label: 'Re-register this device',
                    icon: Icons.sync,
                    busy: _reregistering,
                    onPressed: push == null || _reregistering
                        ? null
                        : _reregister,
                  ),
                  NotionButton(
                    label: 'Send test notification',
                    icon: Icons.notifications_active_outlined,
                    busy: _testing,
                    onPressed: push == null ? null : _sendTest,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: Text(
                'Re-register asks for a new token, registers it with the '
                'gateway and saves the pusher on your account again. The '
                'test runs the real notification path for the newest message '
                'from someone else, skipping only the "already read" and '
                '"chat open" checks.',
                style: typography.footnoteMuted,
              ),
            ),
          ],
          const NotionSectionHeader(title: 'This device'),
          if (!android)
            const NotionListRow(
              title: 'Push notifications',
              subtitle: 'Background notifications are available on Android.',
            ),
          if (android) ...[
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
                  if (pusher == null || pusher.tokenKnown)
                    _check('Uses this device', pusher?.tokenMatches)
                  else
                    NotionListRow(
                      title: 'Uses this device',
                      trailing: _value(context, 'Unknown'),
                    ),
                  _check('Gateway address matches', pusher?.urlMatches),
                  _check('Gateway key matches', pusher?.nonceMatches),
                  // Informational: Beeper's homeserver does not forward the
                  // format and the gateway accepts that.
                  NotionListRow(
                    title: 'Format is event_id_only',
                    subtitle:
                        'Informational; the gateway never forwards '
                        'message content either way.',
                    trailing: _value(context, yesNo(pusher?.formatEventIdOnly)),
                  ),
                ],
              ),
            ),
          ],
          const NotionSectionHeader(title: 'Account notification rules'),
          if (!rules.loaded)
            const NotionListRow(
              title: 'Not synced to this device yet',
              subtitle:
                  'Until they are, the server’s decision to notify is used.',
            )
          else ...[
            NotionListRow(
              title: 'Do Not Disturb (account)',
              subtitle: 'Silences every notification on all devices.',
              trailing: _value(
                context,
                rules.doNotDisturb ? 'On' : 'Off',
                problem: rules.doNotDisturb,
              ),
            ),
            _ruleRow('Direct chats', rules.oneToOne, alert: true),
            _ruleRow('Group chats', rules.groups),
            _ruleRow('Encrypted direct chats', rules.encryptedOneToOne),
            _ruleRow('Encrypted group chats', rules.encryptedGroups),
            if (rules.unknownConditions)
              const NotionListRow(
                title: 'Some rules can’t be evaluated on this phone',
                subtitle: 'For those, the server’s decision to notify is used.',
              ),
            NotionListRow(
              title: 'Change account notification rules',
              subtitle: 'Settings → Notifications',
              onTap: () => context.push('/rooms/settings/notifications'),
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
          Padding(
            padding: const EdgeInsets.only(top: NotionSpace.xs),
            child: Wrap(
              spacing: NotionSpace.xs,
              runSpacing: NotionSpace.xs,
              children: [
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
              'If messages from others never show "Last push received", the '
              'server is not reaching this device.',
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
            '"Don\'t optimize" or "Unrestricted" for ChatLoom.',
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
