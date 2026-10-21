// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/network_sign_out.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/sync_changes.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart'
    show canEditChatPreferences, privateNotificationLabel;
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart'
    show NotionNetworkGlyph;
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/sync_changes_section.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

// Settings → Networks (wave 4, J: "network management should be nicer and
// simpler, you get lost in those options").
//
// One list of networks, each with its logo, name, account (when the bridge
// reported it) and one status pill. A tap opens the network: its status
// with the one action that fixes it, where its groups appear, its
// notifications, and everything technical behind "Advanced". The rules are
// the same private `network-policy:<network>` metadata the old "Networks &
// chat rules" page edited; nothing is written to Matrix or the bridges. The
// one exception is "Sign out of <network>" (confirmed, J 2026-10-21), which
// sends the bridge's `logout` command to its bot (`network_sign_out.dart`).

/// The one status a network shows in the list.
enum NetworkStatus {
  /// No problem reported (or messages flow).
  connected,

  /// Works, but something needs a look: reconnecting, the phone app is
  /// needed, or messages are not being delivered.
  attention,

  /// Messages do not arrive: signed out, disconnected, bridge not running.
  disconnected,

  /// Nothing known about a bridge (native Matrix, an unknown bridge, or the
  /// first scan has not finished): no pill.
  unknown,
}

NetworkStatus networkStatusOf(BridgeHealth? health) => switch (health?.state) {
  null => NetworkStatus.unknown,
  BridgeHealthState.ok || BridgeHealthState.unknown => NetworkStatus.connected,
  BridgeHealthState.degraded => NetworkStatus.attention,
  BridgeHealthState.disconnected ||
  BridgeHealthState.loggedOut => NetworkStatus.disconnected,
};

String? networkStatusLabel(NetworkStatus status) => switch (status) {
  NetworkStatus.connected => 'Connected',
  NetworkStatus.attention => 'Needs attention',
  NetworkStatus.disconnected => 'Disconnected',
  NetworkStatus.unknown => null,
};

NotionStatusTone networkStatusTone(NetworkStatus status) => switch (status) {
  NetworkStatus.connected => NotionStatusTone.success,
  NetworkStatus.attention => NotionStatusTone.warning,
  NetworkStatus.disconnected => NotionStatusTone.danger,
  NetworkStatus.unknown => NotionStatusTone.neutral,
};

String networkChatCount(int chats) => switch (chats) {
  0 => 'No chats yet',
  1 => '1 chat',
  _ => '$chats chats',
};

/// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago".
String networkAgo(DateTime at, DateTime now) {
  final age = now.difference(at);
  if (age.isNegative || age < const Duration(minutes: 1)) return 'just now';
  if (age < const Duration(hours: 1)) return '${age.inMinutes} min ago';
  if (age < const Duration(days: 1)) return '${age.inHours} h ago';
  return age.inDays == 1 ? 'yesterday' : '${age.inDays} days ago';
}

/// Human state of one bridge login report (Advanced).
String bridgeReportLabel(BridgeStateReport report) => switch (report.state) {
  BridgeHealthState.ok || BridgeHealthState.unknown => 'Connected',
  BridgeHealthState.degraded =>
    report.userAction == 'OPEN_NATIVE' ? 'Needs the phone app' : 'Connecting',
  BridgeHealthState.disconnected =>
    report.stateEvent == 'BRIDGE_UNREACHABLE'
        ? 'Bridge isn’t running'
        : 'Disconnected',
  BridgeHealthState.loggedOut =>
    report.stateEvent == 'UNCONFIGURED' ? 'Not signed in' : 'Signed out',
};

/// Everything the list and the detail show about one network.
@immutable
class NetworkSummary {
  const NetworkSummary({
    required this.network,
    this.health,
    this.chats = 0,
    this.groups = 0,
    this.accounts = const [],
  });

  final String network;
  final BridgeHealth? health;
  final int chats;
  final int groups;

  /// Signed-in account names the bridge reported (`remote_name`).
  final List<String> accounts;

  String get label => notionNetworkLabel(network);
  NetworkStatus get status => networkStatusOf(health);
  bool get hasProblem => health?.state.isProblem ?? false;

  /// One line under the name: the problem, else the account and chats.
  String get subtitle {
    final health = this.health;
    if (health != null && health.state.isProblem) {
      return health.summary.isEmpty ? health.title : health.summary;
    }
    final count = networkChatCount(chats);
    return accounts.isEmpty ? count : '${accounts.join(', ')} · $count';
  }

  /// All networks of the account: from its chats, from saved rules and from
  /// bridge status (a signed-out bridge without chats still shows). Problems
  /// first, then by name.
  static List<NetworkSummary> collect(
    PersonalClient personal,
    BridgeHealthMonitor monitor,
  ) {
    final rooms = personal.client.rooms;
    final classifier = ConversationClassifier(rooms);
    final chats = <String, int>{};
    final groups = <String, int>{};
    for (final room in rooms) {
      if (room.isSpace || PersonalPrivacy.isJournal(room)) continue;
      final kind = classifier.classify(room);
      if (kind.technical) continue;
      chats.putIfAbsent(kind.network, () => 0);
      groups.putIfAbsent(kind.network, () => 0);
      if (room.membership != Membership.join) continue;
      chats[kind.network] = chats[kind.network]! + 1;
      if (kind.isGroup) groups[kind.network] = groups[kind.network]! + 1;
    }
    final networks = {
      ...chats.keys,
      for (final key in personal.values.keys)
        if (key.startsWith('network-policy:'))
          key.substring('network-policy:'.length),
      ...monitor.health.keys,
    };
    final result = [
      for (final network in networks)
        NetworkSummary(
          network: network,
          health: monitor.health[network],
          chats: chats[network] ?? 0,
          groups: groups[network] ?? 0,
          accounts: _accounts(monitor, network),
        ),
    ];
    result.sort((a, b) {
      final severity = (b.health?.state.severity ?? 0).compareTo(
        a.health?.state.severity ?? 0,
      );
      return severity != 0 ? severity : a.label.compareTo(b.label);
    });
    return result;
  }

  static List<String> _accounts(BridgeHealthMonitor monitor, String network) =>
      {
        for (final report
            in monitor.signalsFor(network)?.reports.values ??
                const <BridgeStateReport>[])
          ?report.remoteName,
      }.toList()..sort();
}

/// Rebuilds when the account's rooms are added or removed (chat counts),
/// not on every sync.
mixin _RoomCountRefresh<T extends StatefulWidget> on State<T> {
  PersonalClient get personal;
  StreamSubscription<SyncUpdate>? _roomSync;
  int _roomCount = 0;

  void listenToRooms() {
    _roomCount = personal.client.rooms.length;
    _roomSync = personal.client.onSync.stream.listen((_) {
      final count = personal.client.rooms.length;
      if (count == _roomCount || !mounted) return;
      setState(() => _roomCount = count);
    });
  }

  @override
  void dispose() {
    unawaited(_roomSync?.cancel());
    super.dispose();
  }
}

/// Settings → Networks: one row per network.
class NetworksPage extends StatefulWidget {
  const NetworksPage({
    super.key,
    required this.personal,
    this.monitor,
    this.onOpen,
  });

  final PersonalClient personal;

  /// Test seam; defaults to the client's shared monitor.
  final BridgeHealthMonitor? monitor;

  /// Opens one network; defaults to `/rooms/settings/networks/<network>`.
  final ValueChanged<String>? onOpen;

  @override
  State<NetworksPage> createState() => _NetworksPageState();
}

class _NetworksPageState extends State<NetworksPage>
    with _RoomCountRefresh<NetworksPage> {
  @override
  PersonalClient get personal => widget.personal;
  BridgeHealthMonitor get _monitor =>
      widget.monitor ?? BridgeHealthMonitor.of(personal.client);

  @override
  void initState() {
    super.initState();
    PersonalPageLoad.request(context, personal);
    listenToRooms();
  }

  void _open(String network) {
    final open = widget.onOpen;
    if (open != null) return open(network);
    context.push('/rooms/settings/networks/${Uri.encodeComponent(network)}');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([personal, _monitor]),
    builder: (context, _) {
      final networks = NetworkSummary.collect(personal, _monitor);
      final notice = _PrivateSyncNotice.of(context, personal);
      return NotionScaffold(
        title: 'Networks',
        onBack: ChatLoomThemes.isColumnMode(context)
            ? null
            : () => Navigator.maybePop(context),
        children: [
          NotionStaggeredColumn(
            children: [
              ?notice,
              if (networks.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: NotionSpace.xxl),
                  child: NotionEmptyState(
                    icon: Icons.hub_outlined,
                    title: 'No networks yet',
                    message:
                        'Networks appear here once your chats have synced.',
                  ),
                )
              else ...[
                for (final summary in networks)
                  NetworkRow(
                    key: ValueKey('network-${summary.network}'),
                    summary: summary,
                    onTap: () => _open(summary.network),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: NotionSpace.md),
                  child: Text(
                    'Tap a network to fix its connection, choose where its '
                    'groups appear and how it notifies you.',
                    style: context.notion.typography.footnoteMuted,
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    },
  );
}

/// The network logo in a round tile.
class NetworkLogo extends StatelessWidget {
  const NetworkLogo({
    super.key,
    required this.network,
    this.size = NotionSize.avatar,
  });

  final String network;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.notion.colors.surface,
        shape: BoxShape.circle,
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: NotionNetworkGlyph(
            network: network == 'other' ? null : network,
            size: size * .55,
          ),
        ),
      ),
    ),
  );
}

/// One network in the list: logo, name, one line, status pill, chevron.
class NetworkRow extends StatelessWidget {
  const NetworkRow({super.key, required this.summary, required this.onTap});

  final NetworkSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final typography = context.notion.typography;
    final status = networkStatusLabel(summary.status);
    final pill = status == null
        ? null
        : NotionStatusPill(
            label: status,
            tone: networkStatusTone(summary.status),
          );
    return Semantics(
      button: true,
      label: [summary.label, ?status, summary.subtitle].join(', '),
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressRow,
        child: InkWell(
          onTap: onTap,
          borderRadius: NotionRadius.rowAll,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: NotionSize.rowMinHeight + NotionSpace.sm,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Large text on a phone: the pill moves under the name so
                  // the name keeps its width.
                  final stacked =
                      MediaQuery.textScalerOf(context).scale(16) > 22 &&
                      constraints.maxWidth < 480;
                  return Row(
                    children: [
                      NetworkLogo(network: summary.network),
                      const SizedBox(width: NotionSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(summary.label, style: typography.body),
                            Text(
                              summary.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: typography.footnoteMuted,
                            ),
                            if (stacked && pill != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: NotionSpace.xxs,
                                ),
                                child: pill,
                              ),
                          ],
                        ),
                      ),
                      if (!stacked && pill != null) ...[
                        const SizedBox(width: NotionSpace.xs),
                        pill,
                      ],
                      const SizedBox(width: NotionSpace.xxs),
                      Icon(
                        Icons.chevron_right,
                        size: NotionSize.iconMd,
                        color: context.notion.colors.textSecondary,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Why rules cannot be changed right now (web, switched account, private
/// sync off), with the one action that helps. Status still shows.
abstract final class _PrivateSyncNotice {
  static Widget? of(BuildContext context, PersonalClient personal) {
    if (kIsWeb) {
      return const _Notice(
        NotionCallout(
          icon: Icons.lock_outline,
          title: 'Change these on your phone or Mac',
          message:
              'Network rules are encrypted. Edit them in the Android or '
              'macOS app.',
        ),
      );
    }
    if (!identical(Matrix.of(context).client, personal.client)) {
      return const _Notice(
        NotionCallout(
          icon: Icons.swap_horiz,
          title: 'You switched accounts',
          message: 'Go back and open Networks again.',
        ),
      );
    }
    if (!personal.ready) {
      return _Notice(
        NotionCallout(
          icon: Icons.sync_disabled_outlined,
          title: 'Private sync is off',
          message:
              'Turn it on to choose where chats appear and how networks '
              'notify you. Connection status still shows.',
          actionLabel: 'Set up',
          onAction: () => context.push('/rooms/settings/sync'),
        ),
      );
    }
    return null;
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.callout);
  final NotionCallout callout;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NotionSpace.md),
    child: callout,
  );
}

/// One network: status and fix, where its groups appear, notifications,
/// and diagnostics behind "Advanced".
class NetworkDetailPage extends StatefulWidget {
  const NetworkDetailPage({
    super.key,
    required this.personal,
    required this.network,
    this.monitor,
    this.onOpenChat,
    this.clock,
    this.signOut,
  });

  final PersonalClient personal;
  final String network;

  /// Test seams.
  final BridgeHealthMonitor? monitor;
  final ValueChanged<Room>? onOpenChat;
  final DateTime Function()? clock;

  /// Sends the bridge's sign-out command for a network (default
  /// [NetworkSignOut.signOut]).
  final Future<void> Function(String network)? signOut;

  @override
  State<NetworkDetailPage> createState() => _NetworkDetailPageState();
}

class _NetworkDetailPageState extends State<NetworkDetailPage>
    with _RoomCountRefresh<NetworkDetailPage> {
  bool _saving = false;
  bool _advanced = false;
  String? _error;

  /// Sign-out progress: null (offered), false (sending), true (sent).
  bool? _signedOut;

  @override
  PersonalClient get personal => widget.personal;
  String get _network => widget.network;
  String get _key => 'network-policy:$_network';
  BridgeHealthMonitor get _monitor =>
      widget.monitor ?? BridgeHealthMonitor.of(personal.client);
  bool get _active => identical(Matrix.of(context).client, personal.client);
  bool get _canEdit =>
      _active && !_saving && canEditChatPreferences(personal, _key);

  @override
  void initState() {
    super.initState();
    PersonalPageLoad.request(context, personal);
    listenToRooms();
  }

  NetworkPreferences get _policy =>
      NetworkPreferences.fromJson(personal.values[_key] ?? {}, _network);

  /// Saves at once (the private replica queues it locally); only a failure
  /// is shown.
  Future<void> _update(Map<String, dynamic> patch) async {
    if (!_canEdit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await personal.put(_key, {
        ...?personal.values[_key],
        ..._policy.toJson(),
        ...patch,
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t save this change. Check private sync and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runSync(Future<void> Function() action) async {
    if (!_active) return;
    setState(() => _error = null);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t save this choice. Check private sync and try again.',
        );
      }
    }
  }

  /// Telegram/Messenger "Log out": confirm, then act at once. The command
  /// leaves in the background; only a failure is reported.
  Future<void> _confirmSignOut(String label) async {
    final confirmed = await showNotionConfirmDialog(
      context: context,
      title: 'Sign out of $label?',
      message:
          'Chats from this network will stop syncing until you sign in again.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _signOut(label);
  }

  Future<void> _signOut(String label) async {
    if (!_active) return;
    setState(() => _signedOut = false);
    try {
      final signOut =
          widget.signOut ??
          NetworkSignOut(client: personal.client, monitor: _monitor).signOut;
      await signOut(_network);
      if (mounted) setState(() => _signedOut = true);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() => _signedOut = null);
      await ErrorReporter.action(
        context,
        message: 'Sign out of $label',
        onRetry: () => _signOut(label),
      ).onErrorCallback(error, stack);
    }
  }

  void _openChat(Room room) {
    final open = widget.onOpenChat;
    if (open != null) return open(room);
    context.push('/rooms/${room.id}');
  }

  Future<T?> _pick<T>({
    required String title,
    required T selected,
    required List<(T, String, String?)> choices,
  }) => showNotionSheet<T>(
    context: context,
    title: title,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (value, label, detail) in choices)
          Semantics(
            selected: value == selected,
            child: NotionListRow(
              title: label,
              subtitle: detail,
              trailing: value == selected
                  ? const Icon(Icons.check, size: NotionSize.icon)
                  : const SizedBox(width: NotionSize.icon),
              onTap: () => Navigator.of(context).pop(value),
            ),
          ),
      ],
    ),
  );

  static const _placements = <(ChatPlacement, String, String?)>[
    (ChatPlacement.inbox, 'Main list', 'Together with your other chats'),
    (ChatPlacement.groups, 'Groups', 'In the Groups view of the network menu'),
    (
      ChatPlacement.ignored,
      'Ignored',
      'Out of sight in Ignored, with no notifications',
    ),
  ];

  static String _placementLabel(ChatPlacement placement) =>
      _placements.firstWhere((choice) => choice.$1 == placement).$2;

  List<(String, String, String?)> _notificationChoices(String inherit) => [
    ('inherit', inherit, null),
    for (final mode in PersonalNotificationMode.values)
      (mode.name, privateNotificationLabel(mode), null),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([personal, _monitor]),
    builder: (context, _) {
      final summary =
          NetworkSummary.collect(
            personal,
            _monitor,
          ).where((s) => s.network == _network).firstOrNull ??
          NetworkSummary(network: _network);
      final notice = _PrivateSyncNotice.of(context, personal);
      return NotionScaffold(
        title: summary.label,
        onBack: () => Navigator.maybePop(context),
        children: [
          NotionStaggeredColumn(
            children: [
              _header(context, summary),
              _status(context, summary),
              ?_signOutAction(context, summary),
              ?notice,
              NotionSizeReveal(
                visible: _error != null,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: NotionSpace.sm),
                  child: NotionFadeThrough(
                    child: NotionCallout(
                      key: ValueKey(_error),
                      icon: Icons.error_outline,
                      tone: NotionCalloutTone.danger,
                      title: _error ?? '',
                      onDismiss: () => setState(() => _error = null),
                    ),
                  ),
                ),
              ),
              ..._rules(context, summary),
              _advancedSection(context, summary),
            ],
          ),
        ],
      );
    },
  );

  Widget _header(BuildContext context, NetworkSummary summary) {
    final typography = context.notion.typography;
    final status = networkStatusLabel(summary.status);
    return Padding(
      padding: const EdgeInsets.only(
        top: NotionSpace.md,
        bottom: NotionSpace.lg,
      ),
      child: Column(
        children: [
          NetworkLogo(network: _network, size: NotionSize.avatarLg + 16),
          const SizedBox(height: NotionSpace.sm),
          Semantics(
            header: true,
            child: Text(
              summary.label,
              style: typography.heading,
              textAlign: TextAlign.center,
            ),
          ),
          if (summary.accounts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xxs),
              child: Text(
                summary.accounts.join(', '),
                style: typography.footnoteMuted,
                textAlign: TextAlign.center,
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: NotionSpace.xs),
              child: NotionStatusPill(
                label: status,
                tone: networkStatusTone(summary.status),
              ),
            ),
        ],
      ),
    );
  }

  /// The problem in words with the one action that fixes it, or a quiet
  /// line when all is well.
  Widget _status(BuildContext context, NetworkSummary summary) {
    final health = summary.health;
    final now = (widget.clock ?? DateTime.now)();
    final bridgeChat = _monitor.managementRoom(_network);
    if (health != null && health.state.isProblem) {
      final signIn = health.state == BridgeHealthState.loggedOut;
      return Padding(
        padding: const EdgeInsets.only(bottom: NotionSpace.md),
        child: NotionCallout(
          key: ValueKey(health.signature),
          icon: switch (health.state) {
            BridgeHealthState.loggedOut => Icons.link_off,
            BridgeHealthState.disconnected => Icons.sync_problem_outlined,
            _ => Icons.warning_amber_outlined,
          },
          tone: health.state == BridgeHealthState.degraded
              ? NotionCalloutTone.warning
              : NotionCalloutTone.danger,
          title: health.title,
          message: health.describe(now),
          actionLabel: bridgeChat == null
              ? null
              : signIn
              ? 'Sign in'
              : 'Open bridge chat',
          onAction: bridgeChat == null ? null : () => _openChat(bridgeChat),
        ),
      );
    }
    final text = switch (summary.status) {
      NetworkStatus.connected => 'Working normally.',
      _ when _network == 'matrix' =>
        'Matrix chats connect directly, without a bridge.',
      _ => 'No problems reported.',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: NotionSpace.xs),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.notion.typography.calloutMuted,
      ),
    );
  }

  /// "Sign out of WhatsApp" and the like: only for a connected bridge whose
  /// chat this device knows; after the tap, one quiet line instead of the
  /// button.
  Widget? _signOutAction(BuildContext context, NetworkSummary summary) {
    final state = _signedOut;
    if (state == null &&
        (!_active ||
            _network == 'matrix' ||
            summary.status != NetworkStatus.connected ||
            _monitor.managementRoom(_network) == null)) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: NotionSpace.md),
      child: Center(
        child: NotionFadeThrough(
          child: state == null
              ? NotionButton.destructive(
                  key: const ValueKey('network-sign-out'),
                  label: 'Sign out of ${summary.label}',
                  icon: Icons.logout,
                  onPressed: () => _confirmSignOut(summary.label),
                )
              : Text(
                  state
                      ? 'Signed out of ${summary.label}. Sign in again from '
                            'the bridge chat.'
                      : 'Signing out of ${summary.label}…',
                  key: ValueKey(('network-sign-out-state', state)),
                  textAlign: TextAlign.center,
                  style: context.notion.typography.calloutMuted,
                ),
        ),
      ),
    );
  }

  List<Widget> _rules(BuildContext context, NetworkSummary summary) {
    final policy = _policy;
    final enabled = _canEdit;
    return [
      const NotionSectionHeader(title: 'Where chats appear'),
      NotionListRow(
        key: const ValueKey('network-groups-placement'),
        leading: const Icon(Icons.group_outlined),
        title: 'Groups',
        subtitle: _placementLabel(policy.groupPlacement),
        onTap: enabled
            ? () async {
                final value = await _pick<ChatPlacement>(
                  title: 'Show ${summary.label} groups in',
                  selected: policy.groupPlacement,
                  choices: _placements,
                );
                if (value != null && value != policy.groupPlacement) {
                  await _update({'groupPlacement': value.name});
                }
              }
            : null,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: NotionSpace.xxs),
        child: Text(
          'One-to-one chats always stay in the main list.',
          style: context.notion.typography.captionMuted,
        ),
      ),
      const NotionSectionHeader(title: 'Notifications'),
      NotionListRow(
        key: const ValueKey('network-notifications'),
        leading: const Icon(Icons.notifications_none_outlined),
        title: 'All chats',
        subtitle: policy.notifications == null
            ? 'Default'
            : privateNotificationLabel(policy.notifications!),
        onTap: enabled
            ? () async {
                final value = await _pick<String>(
                  title: '${summary.label} notifications',
                  selected: policy.notifications?.name ?? 'inherit',
                  choices: _notificationChoices('Default'),
                );
                if (value == null) return;
                await _update({
                  'notifications': value == 'inherit' ? null : value,
                });
              }
            : null,
      ),
      NotionListRow(
        key: const ValueKey('network-group-notifications'),
        leading: const Icon(Icons.forum_outlined),
        title: 'Groups',
        subtitle: policy.groupNotifications == null
            ? 'Same as all chats'
            : privateNotificationLabel(policy.groupNotifications!),
        onTap: enabled
            ? () async {
                final value = await _pick<String>(
                  title: '${summary.label} group notifications',
                  selected: policy.groupNotifications?.name ?? 'inherit',
                  choices: _notificationChoices('Same as all chats'),
                );
                if (value == null) return;
                await _update({
                  'groupNotifications': value == 'inherit' ? null : value,
                });
              }
            : null,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: NotionSpace.xs),
        child: Text(
          'Applies to current and future chats. A chat’s own setting wins.',
          style: context.notion.typography.captionMuted,
        ),
      ),
      ..._syncState(),
    ];
  }

  /// An unconfirmed change can be sent again, a conflict is resolved right
  /// here; both appear only when they exist.
  List<Widget> _syncState() {
    final changes = SyncChanges.of(personal);
    final pending = changes.pending
        .where((change) => change.entity == _key)
        .firstOrNull;
    final conflict = changes.conflicts
        .where((change) => change.entity == _key)
        .firstOrNull;
    return [
      NotionSizeReveal(
        visible: pending != null,
        child: pending == null
            ? const SizedBox.shrink()
            : SyncPendingRow(
                personal: personal,
                change: pending,
                run: _runSync,
                title: 'Your latest change',
              ),
      ),
      NotionSizeReveal(
        visible: conflict != null,
        child: conflict == null
            ? const SizedBox.shrink()
            : SyncConflictTile(
                personal: personal,
                conflict: conflict,
                run: _runSync,
                title: 'Changed on another device too',
              ),
      ),
    ];
  }

  Widget _advancedSection(BuildContext context, NetworkSummary summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: NotionSpace.md),
        NotionListRow(
          key: const ValueKey('network-advanced'),
          title: 'Advanced',
          subtitle: 'Connection details and the bridge chat',
          trailing: AnimatedRotation(
            turns: _advanced ? .5 : 0,
            duration: NotionMotion.of(context, NotionMotion.quick),
            curve: NotionMotion.standard,
            child: const Icon(Icons.expand_more, size: NotionSize.iconMd),
          ),
          onTap: () => setState(() => _advanced = !_advanced),
        ),
        NotionSizeReveal(
          visible: _advanced,
          child: _advanced
              ? _diagnostics(context, summary)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _diagnostics(BuildContext context, NetworkSummary summary) {
    final now = (widget.clock ?? DateTime.now)();
    final signals = _monitor.signalsFor(_network);
    final reports = signals?.reports.values.toList() ?? const [];
    final inbound = signals?.lastInbound;
    final failures =
        signals?.deliveries
            .where(
              (delivery) =>
                  delivery.failed &&
                  now.difference(delivery.at) <=
                      BridgeHealthRules.failureWindow,
            )
            .length ??
        0;
    final bridgeChat = _monitor.managementRoom(_network);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reports.isEmpty)
          const NotionListRow(
            title: 'Bridge status',
            subtitle: 'The bridge hasn’t reported a problem on this device.',
          )
        else
          for (final (index, report) in reports.indexed)
            NotionListRow(
              title:
                  report.remoteName ??
                  (reports.length == 1 ? 'Account' : 'Account ${index + 1}'),
              subtitle:
                  '${bridgeReportLabel(report)} · reported '
                  '${networkAgo(report.at, now)}',
            ),
        NotionListRow(
          title: 'Last message received',
          subtitle: inbound == null
              ? 'None seen on this device yet'
              : networkAgo(inbound, now),
        ),
        NotionListRow(
          title: 'Failed deliveries',
          subtitle: failures == 0
              ? 'None in the last 30 minutes'
              : '$failures in the last 30 minutes',
        ),
        NotionListRow(
          title: 'Chats',
          subtitle: summary.groups == 0
              ? networkChatCount(summary.chats)
              : '${networkChatCount(summary.chats)} · ${summary.groups} '
                    '${summary.groups == 1 ? 'group' : 'groups'}',
        ),
        if (bridgeChat != null)
          NotionListRow(
            key: const ValueKey('network-bridge-chat'),
            leading: const Icon(Icons.terminal_outlined),
            title: 'Open bridge chat',
            subtitle: 'Sign in, sign out and other bridge commands',
            onTap: () => _openChat(bridgeChat),
          ),
        Padding(
          padding: const EdgeInsets.only(top: NotionSpace.sm),
          child: Text(
            'Network rules are private to ChatLoom and sync between your '
            'devices. Other Beeper and Matrix apps are unchanged.',
            style: context.notion.typography.captionMuted,
          ),
        ),
      ],
    );
  }
}
