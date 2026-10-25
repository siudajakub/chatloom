// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/presence_status.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Owns activity only while a header, visible inbox row or footer is mounted.
/// Its notifications never rebuild the message list.
class ConversationActivityBuilder extends StatefulWidget {
  const ConversationActivityBuilder({
    super.key,
    required this.client,
    required this.rooms,
    required this.builder,
    this.now,
    this.headerPresence = false,
  });

  final Client client;
  final Iterable<Room> rooms;
  final Widget Function(BuildContext, ConversationActivity) builder;

  /// Chat headers: show received presence, bridged ghosts included, while
  /// [PresenceDisplay.enabled] is on, and none at all while it is off. Other
  /// surfaces keep the default (native Matrix members only).
  final bool headerPresence;

  /// Test clock for deterministic expiry; production uses the current time.
  final DateTime Function()? now;

  @override
  State<ConversationActivityBuilder> createState() =>
      _ConversationActivityBuilderState();
}

class _ConversationActivityBuilderState
    extends State<ConversationActivityBuilder> {
  late ConversationActivity _activity;

  @override
  void initState() {
    super.initState();
    _create();
  }

  void _create() => _activity = ConversationActivity(
    client: widget.client,
    rooms: widget.rooms,
    now: widget.now,
    presenceAllowed: widget.headerPresence
        ? (_) => PresenceDisplay.enabled.value
        : null,
  );

  @override
  void didUpdateWidget(ConversationActivityBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client) ||
        oldWidget.headerPresence != widget.headerPresence) {
      _activity.dispose();
      _create();
    } else {
      _activity.setRooms(widget.rooms);
    }
  }

  @override
  void dispose() {
    _activity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.headerPresence
        ? Listenable.merge([_activity, PresenceDisplay.enabled])
        : _activity,
    builder: (context, _) => widget.builder(context, _activity),
  );
}

String conversationTypingText(
  BuildContext context,
  ConversationActivity activity, {
  bool sourceLabels = false,
}) {
  final entries = activity.typing;
  if (entries.isEmpty) return '';
  final l10n = L10n.of(context);
  final users = conversationTypingUsers(activity);
  final first = users.first;
  final String text;
  if (AppConfig.hideTypingUsernames) {
    text =
        users.length == 1 &&
            activity.counterpartId(entries.first.room) == first.id
        ? l10n.isTyping
        : l10n.numUsersTyping(users.length);
  } else if (users.length == 1) {
    text = activity.counterpartId(entries.first.room) == first.id
        ? l10n.isTyping
        : l10n.userIsTyping(first.calcDisplayname());
  } else if (users.length == 2) {
    text = l10n.userAndUserAreTyping(
      first.calcDisplayname(),
      users.last.calcDisplayname(),
    );
  } else {
    text = l10n.userAndOthersAreTyping(
      first.calcDisplayname(),
      users.length - 1,
    );
  }
  if (!sourceLabels) return text;
  final classifier = ConversationClassifier(entries.map((entry) => entry.room));
  final labels = entries
      .map(
        (entry) => notionNetworkLabel(classifier.classify(entry.room).network),
      )
      .toSet();
  return '$text · ${labels.join(', ')}';
}

/// One Matrix identity can type in several merged sources simultaneously.
/// Keep source entries for attribution, but show that identity only once.
List<User> conversationTypingUsers(ConversationActivity activity) => {
  for (final entry in activity.typing) entry.user.id: entry.user,
}.values.toList();

/// Problems win over typing and actual, attributable presence. Silence never
/// becomes "offline"; which rooms may show presence is decided by the
/// activity model ([ConversationActivityBuilder.headerPresence]).
///
/// Presence reads Telegram style ("online", "last seen 5 min ago", "last seen
/// today at 14:03") and re-words itself while visible, without a sync.
class ConversationActivityStatus extends StatefulWidget {
  const ConversationActivityStatus({
    super.key,
    required this.client,
    required this.rooms,
    required this.activity,
    this.sourceLabels = false,
    this.fallback,
  });

  final Client client;
  final Iterable<Room> rooms;
  final ConversationActivity activity;
  final bool sourceLabels;

  /// The resting line while nothing is live (network or member count).
  final String? fallback;

  @override
  State<ConversationActivityStatus> createState() =>
      _ConversationActivityStatusState();
}

class _ConversationActivityStatusState
    extends State<ConversationActivityStatus> {
  Timer? _refresh;

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _schedule(DateTime? at) {
    _refresh?.cancel();
    _refresh = null;
    if (at == null) return;
    final delay = at.difference(widget.activity.now);
    _refresh = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (mounted) setState(() {});
    });
  }

  String? _presence(BuildContext context) {
    final presences = widget.activity.presences
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return (b.lastActive ?? DateTime(0)).compareTo(
          a.lastActive ?? DateTime(0),
        );
      });
    final presence = presences.firstOrNull;
    if (presence == null) return null;
    final label = presenceLabel(
      online: presence.online,
      lastActive: presence.lastActive,
      precision: presence.precision,
      now: widget.activity.now,
      use24h: DateTime.now().use24HourFormat(context),
    );
    _schedule(label?.refreshAt);
    if (label == null) return null;
    if (!widget.sourceLabels) return label.text;
    final network = ConversationClassifier([
      presence.room,
    ]).classify(presence.room).network;
    return '${label.text} · ${notionNetworkLabel(network)}';
  }

  @override
  Widget build(BuildContext context) {
    final connection = ConnectionStatusMonitor.of(widget.client);
    final bridges = BridgeHealthMonitor.of(widget.client);
    return ListenableBuilder(
      listenable: Listenable.merge([connection, bridges]),
      builder: (context, _) {
        var label = connection.value.label;
        label ??= widget.rooms
            .map(bridges.problemFor)
            .nonNulls
            .firstOrNull
            ?.title;
        if (label == null && !connection.raw.offline) {
          final typing = conversationTypingText(
            context,
            widget.activity,
            sourceLabels: widget.sourceLabels,
          );
          label = typing.isNotEmpty ? typing : _presence(context);
        }
        return Semantics(
          liveRegion: true,
          child: NotionStatusLine(status: label ?? widget.fallback),
        );
      },
    );
  }
}

/// Keeps the existing private/network avatar, adding a real online signal.
class ConversationActivityAvatar extends StatelessWidget {
  const ConversationActivityAvatar({
    super.key,
    required this.activity,
    required this.child,
  });

  final ConversationActivity activity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!activity.presences.any((presence) => presence.online)) return child;
    return Semantics(
      label: L10n.of(context).currentlyActive,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          PositionedDirectional(
            bottom: 0,
            end: 0,
            child: Container(
              key: const ValueKey('conversation-online-dot'),
              width: NotionSpace.sm,
              height: NotionSpace.sm,
              decoration: BoxDecoration(
                color: context.notion.colors.success,
                shape: BoxShape.circle,
                border: Border.all(
                  color: context.notion.colors.background,
                  width: NotionSpace.xxs / 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
