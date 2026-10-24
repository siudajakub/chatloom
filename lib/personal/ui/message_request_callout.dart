// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/ui/network_action_flows.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Above the composer of an unaccepted message request (FX-02; Instagram's
/// and Messenger's request screen): who is asking, on which network, and
/// Accept / Delete / Block where the bridge declares them. Until the request
/// is accepted ChatLoom sends no public read receipt (privacy.dart) and the
/// chat stays quiet (inbox_projection.dart). A reply accepts the request
/// too; the composer notice says so.
class MessageRequestCallout extends StatefulWidget {
  final Room room;
  const MessageRequestCallout({super.key, required this.room});

  @override
  State<MessageRequestCallout> createState() => _MessageRequestCalloutState();
}

class _MessageRequestCalloutState extends State<MessageRequestCallout> {
  StreamSubscription<Object?>? _state;

  /// Accepted here and not refused (yet): hidden at once.
  bool _accepted = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(MessageRequestCallout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.room, widget.room)) {
      _accepted = false;
      _listen();
    }
  }

  void _listen() {
    unawaited(_state?.cancel());
    final room = widget.room;
    var request = isMessageRequest(room);
    // Only a change of the request flag rebuilds the callout.
    _state = room.client.onRoomState.stream
        .where((update) => update.roomId == room.id)
        .listen((_) {
          final now = isMessageRequest(room);
          if (now == request || !mounted) return;
          request = now;
          setState(() {});
        }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_state?.cancel());
    super.dispose();
  }

  Future<void> _accept() async {
    setState(() {
      _accepted = true;
      _busy = true;
    });
    final accepted = await acceptMessageRequestFlow(context, widget.room);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!accepted) _accepted = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final features = NetworkChatFeatures.of(room);
    final visible =
        !_accepted &&
        room.membership == Membership.join &&
        features.messageRequest;
    return NotionSizeReveal(
      visible: visible,
      // The card stays while it collapses after Accept.
      child: features.messageRequest
          ? _card(context, room, features)
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _card(BuildContext context, Room room, NetworkChatFeatures features) {
    final tokens = context.notion;
    final name = room.getLocalizedDisplayname();
    final network = bridgedNetworkLabel(room) ?? 'the network';
    final direct = room.isDirectChatForDisplay;
    return Padding(
      key: const ValueKey('message-request-callout'),
      padding: const EdgeInsets.fromLTRB(
        NotionSpace.md,
        NotionSpace.xs,
        NotionSpace.md,
        NotionSpace.xxs,
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.colors.surface,
            borderRadius: NotionRadius.mdAll,
          ),
          child: Padding(
            padding: const EdgeInsets.all(NotionSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.mark_email_unread_outlined,
                      size: NotionSize.icon,
                      color: tokens.colors.textSecondary,
                    ),
                    const SizedBox(width: NotionSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            direct
                                ? 'Message request from $name on $network'
                                : 'Group request on $network',
                            style: tokens.typography.callout.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: NotionSpace.xxs / 2),
                          Text(
                            direct
                                ? '$name won’t see that you read this until '
                                      'you accept.'
                                : 'Nobody sees that you read this until you '
                                      'accept.',
                            style: tokens.typography.footnoteMuted,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NotionSpace.xs),
                Wrap(
                  spacing: NotionSpace.xs,
                  runSpacing: NotionSpace.xs,
                  children: [
                    if (features.acceptWithButton)
                      NotionButton.primary(
                        key: const ValueKey('message-request-accept'),
                        label: 'Accept',
                        busy: _busy,
                        onPressed: _accept,
                      ),
                    if (features.deleteChat)
                      NotionButton.ghost(
                        key: const ValueKey('message-request-delete'),
                        label: 'Delete',
                        onPressed: () {
                          final router = GoRouter.maybeOf(context);
                          unawaited(
                            deleteNetworkChatFlow(
                              context,
                              room,
                              name: name,
                              fromRequest: true,
                              onStarted: () => router?.go('/rooms'),
                            ),
                          );
                        },
                      ),
                    if (direct && features.blockUser)
                      NotionButton.ghost(
                        key: const ValueKey('message-request-block'),
                        label: 'Block',
                        onPressed: () => unawaited(
                          blockNetworkUserFlow(
                            context,
                            room,
                            name: name,
                            block: true,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
