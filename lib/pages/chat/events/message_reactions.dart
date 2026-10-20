// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class MessageReactions extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final bool strict;

  const MessageReactions(
    this.event,
    this.timeline, {
    super.key,
    this.strict = false,
  });

  /// A reaction younger than this when its chip first appears is treated as
  /// just added (it pops); older ones are history and appear still.
  static const Duration freshWindow = Duration(seconds: 4);

  @override
  State<MessageReactions> createState() => _MessageReactionsState();
}

class _MessageReactionsState extends State<MessageReactions> {
  /// Chips present when this row was first built. Later chips are new
  /// reactions and pop in; the first set pops only when it is fresh (the
  /// first reaction on a visible message), never for scrolled-in history.
  Set<String>? _initial;

  Event get event => widget.event;
  Timeline get timeline => widget.timeline;
  bool get strict => widget.strict;

  @override
  void didUpdateWidget(MessageReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId) _initial = null;
  }

  @override
  Widget build(BuildContext context) {
    final allReactionEvents = event.aggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    );
    final reactionMap = <String, _ReactionEntry>{};
    final client = Matrix.of(context).client;

    for (final e in allReactionEvents) {
      final key = e.content
          .tryGetMap<String, Object?>('m.relates_to')
          ?.tryGet<String>('key');
      if (key != null) {
        if (!reactionMap.containsKey(key)) {
          reactionMap[key] = _ReactionEntry(
            key: key,
            count: 0,
            reacted: false,
            reactors: [],
          );
        }
        reactionMap[key]!.count++;
        reactionMap[key]!.reactors!.add(e.senderFromMemoryOrFallback);
        reactionMap[key]!.reacted |= e.senderId == e.room.client.userID;
        final sent = e.originServerTs;
        final latest = reactionMap[key]!.latest;
        if (latest == null || sent.isAfter(latest)) {
          reactionMap[key]!.latest = sent;
        }
      }
    }

    final reactionList = reactionMap.values.toList();
    final now = DateTime.now();
    final initial = _initial ??= {
      for (final r in reactionList)
        if (r.latest == null ||
            now.difference(r.latest!) > MessageReactions.freshWindow)
          r.key,
    };
    reactionList.sort((a, b) => b.count - a.count > 0 ? 1 : -1);
    final ownMessage = event.senderId == event.room.client.userID;
    final manager = ConversationMessageActions.coordinator(event);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ConversationMessageActions.reconcile(event, timeline);
    });
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) => Wrap(
        spacing: 4.0,
        runSpacing: 4.0,
        alignment: ownMessage ? WrapAlignment.end : WrapAlignment.start,
        children: [
          ...reactionList.map(
            (r) => _Reaction(
              key: ValueKey(r.key),
              popIn: !initial.contains(r.key),
              reactionKey: r.key,
              count: r.count,
              reacted: r.reacted,
              pending:
                  manager.unresolved(
                    ConversationMessageActions.key(event, r.key),
                  ) ||
                  manager.unresolved(
                    ConversationMessageActions.key(event, r.key, removal: true),
                  ),
              onTap: () => ConversationMessageActions.react(
                context,
                event,
                timeline,
                r.key,
                toggle: true,
                strict: strict,
              ),
              onLongPress: () async => await _AdaptableReactorsDialog(
                client: client,
                reactionEntry: r,
              ).show(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _Reaction extends StatelessWidget {
  final String reactionKey;
  final int count;
  final bool? reacted;
  final bool pending;
  final bool popIn;
  final void Function()? onTap;
  final void Function()? onLongPress;

  const _Reaction({
    super.key,
    this.popIn = false,
    required this.reactionKey,
    required this.count,
    required this.reacted,
    this.pending = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget content;
    if (reactionKey.startsWith('mxc://')) {
      content = MxcImage(
        uri: Uri.parse(reactionKey),
        width: 20,
        height: 20,
        animated: false,
        isThumbnail: false,
      );
    } else {
      var renderKey = Characters(reactionKey);
      if (renderKey.length > 10) {
        renderKey = renderKey.getRange(0, 9) + Characters('…');
      }
      content = Text(renderKey.toString(), style: TextStyle(fontSize: 14));
    }
    final reduced = NotionMotion.reduced(context);
    return Semantics(
      label:
          '$reactionKey, $count reactions${pending ? ', waiting for source confirmation' : ''}',
      // A new chip springs in; a changed count or own toggle pulses it.
      child: NotionPop(
        playOnMount: popIn,
        trigger: (count, reacted),
        child: NotionPressable(
          scale: NotionMotion.pressIcon,
          bounce: true,
          child: AnimatedOpacity(
            opacity: pending ? .55 : 1,
            duration: reduced ? Duration.zero : NotionMotion.short,
            curve: NotionMotion.standard,
            child: Badge(
              isLabelVisible: count > 1,
              label: NotionAnimatedCount(count: count),
              textStyle: TextStyle(fontSize: 10),
              textColor: theme.colorScheme.onPrimary,
              backgroundColor: theme.colorScheme.primary.withAlpha(200),
              child: InkWell(
                onTap: () => onTap != null ? onTap!() : null,
                onLongPress: () => onLongPress != null ? onLongPress!() : null,
                borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    border: Border.all(
                      color: reacted == true
                          ? theme.colorScheme.secondary
                          : theme.colorScheme.secondaryContainer,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(
                      AppConfig.borderRadius / 2,
                    ),
                  ),
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionEntry {
  String key;
  int count;
  bool reacted;
  List<User>? reactors;

  /// Newest reaction with this key, for the "just added" pop.
  DateTime? latest;

  _ReactionEntry({
    required this.key,
    required this.count,
    required this.reacted,
    this.reactors,
  });
}

class _AdaptableReactorsDialog extends StatelessWidget {
  final Client? client;
  final _ReactionEntry? reactionEntry;

  const _AdaptableReactorsDialog({this.client, this.reactionEntry});

  Future<bool?> show(BuildContext context) => showNotionCustomDialog(
    context: context,
    builder: (context) => this,
    barrierDismissible: true,
    useRootNavigator: false,
  );

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      child: Wrap(
        spacing: 8.0,
        runSpacing: 4.0,
        alignment: WrapAlignment.center,
        children: <Widget>[
          for (final reactor in reactionEntry!.reactors!)
            Chip(
              avatar: Avatar(
                mxContent: reactor.avatarUrl,
                name: reactor.displayName,
                client: client,
                presenceUserId: reactor.stateKey,
              ),
              label: Text(reactor.displayName!),
            ),
        ],
      ),
    );

    final title = Center(child: Text(reactionEntry!.key));

    return AlertDialog(title: title, content: body);
  }
}
