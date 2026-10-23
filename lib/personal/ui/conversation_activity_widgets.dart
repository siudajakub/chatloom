// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/conversation_classification.dart';
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
  });

  final Client client;
  final Iterable<Room> rooms;
  final Widget Function(BuildContext, ConversationActivity) builder;
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

  void _create() => _activity =
      ConversationActivity(client: widget.client, rooms: widget.rooms, now: widget.now);

  @override
  void didUpdateWidget(ConversationActivityBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
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
    listenable: _activity,
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
  final users = entries.map((entry) => entry.user).toList();
  final first = users.first;
  final String text;
  if (AppConfig.hideTypingUsernames) {
    text = users.length == 1 &&
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
      .map((entry) => notionNetworkLabel(classifier.classify(entry.room).network))
      .toSet();
  return '$text · ${labels.join(', ')}';
}

/// Problems win over typing and actual, attributable presence. Silence never
/// becomes "offline", and a bridged puppet's Matrix presence is not remote
/// network presence (the model gates provenance).
class ConversationActivityStatus extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final connection = ConnectionStatusMonitor.of(client);
    final bridges = BridgeHealthMonitor.of(client);
    return ListenableBuilder(
      listenable: Listenable.merge([connection, bridges]),
      builder: (context, _) {
        var label = connection.value.label;
        label ??= rooms.map(bridges.problemFor).nonNulls.firstOrNull?.title;
        if (label == null && !connection.raw.offline) {
          final typing = conversationTypingText(
            context, activity, sourceLabels: sourceLabels,
          );
          if (typing.isNotEmpty) {
            label = typing;
          } else {
            final presences = activity.presences
              ..sort((a, b) {
                if (a.online != b.online) return a.online ? -1 : 1;
                return (b.lastActive ?? DateTime(0))
                    .compareTo(a.lastActive ?? DateTime(0));
              });
            final presence = presences.firstOrNull;
            if (presence != null) {
              label = presence.online
                  ? L10n.of(context).currentlyActive
                  : presence.lastActive == null
                  ? null
                  : L10n.of(context).lastActiveAgo(
                      presence.lastActive!.localizedTime(context),
                    );
              if (label != null && sourceLabels) {
                final network = ConversationClassifier([presence.room])
                    .classify(presence.room).network;
                label = '$label · ${notionNetworkLabel(network)}';
              }
            }
          }
        }
        return Semantics(
          liveRegion: true,
          child: NotionStatusLine(status: label ?? fallback),
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
