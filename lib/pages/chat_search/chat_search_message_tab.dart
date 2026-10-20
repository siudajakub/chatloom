// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_search/search_footer.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatSearchMessageTab extends StatelessWidget {
  final String searchQuery;
  final Room room;
  final List<Event> events;
  final void Function() onStartSearch;
  final bool endReached, isLoading;
  final DateTime? searchedUntil;

  const ChatSearchMessageTab({
    required this.searchQuery,
    required this.room,
    required this.onStartSearch,
    required this.events,
    required this.searchedUntil,
    required this.endReached,
    required this.isLoading,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Idle hint → loading skeleton → results fade through; each new search
    // passes through loading, so its first screenful rises in again.
    return NotionFadeThrough(
      child: events.isEmpty && searchQuery.isEmpty
          ? KeyedSubtree(key: const ValueKey('idle'), child: _idle(context))
          : events.isEmpty && isLoading
          ? NotionSkeleton(
              key: const ValueKey('loading'),
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: NotionSpace.md),
                children: [
                  for (var i = 0; i < 6; i++) const NotionSkeletonRow(),
                ],
              ),
            )
          : KeyedSubtree(
              key: const ValueKey('results'),
              child: _results(context, theme),
            ),
    );
  }

  Widget _idle(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const NotionPop(child: Icon(Icons.search_outlined, size: 64)),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Text(
          L10n.of(context).searchIn(
            room.getLocalizedDisplayname(MatrixLocals(L10n.of(context))),
          ),
          textAlign: TextAlign.center,
        ),
      ),
    ],
  );

  Widget _results(BuildContext context, ThemeData theme) {
    final own = OwnSenderResolver.of(room.client);
    return SelectionArea(
      child: NotionEntranceScope(
        child: ListView.separated(
          itemCount: events.length + 1,
          separatorBuilder: (context, _) =>
              Divider(color: theme.dividerColor, height: 1),
          itemBuilder: (context, i) {
            if (i == events.length) {
              return SearchFooter(
                searchedUntil: searchedUntil,
                endReached: endReached,
                isLoading: isLoading,
                onStartSearch: onStartSearch,
              );
            }
            final event = events[i];
            final sender = event.senderFromMemoryOrFallback;
            // Own bridge ghosts (messages sent from the native app) are "You".
            final displayname = own.isOwnEvent(event)
                ? 'You'
                : sender.calcDisplayname(i18n: MatrixLocals(L10n.of(context)));
            return NotionEntrance(
              playKey: event.eventId,
              rise: NotionMotion.riseList,
              child: _MessageSearchResultListTile(
                sender: sender,
                displayname: displayname,
                event: event,
                room: room,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MessageSearchResultListTile extends StatelessWidget {
  const _MessageSearchResultListTile({
    required this.sender,
    required this.displayname,
    required this.event,
    required this.room,
  });

  final User sender;
  final String displayname;
  final Event event;
  final Room room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      title: Row(
        children: [
          Avatar(
            client: room.client,
            mxContent: sender.avatarUrl,
            name: displayname,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(displayname),
          Expanded(
            child: Text(
              ' | ${event.originServerTs.localizedTimeShort(context)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      subtitle: Linkify(
        textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
        options: const LinkifyOptions(humanize: false),
        style: TextStyle(color: theme.colorScheme.onSurface),
        linkStyle: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
        ),
        onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
        // Text keeps its line breaks; media gets the short English label.
        text:
            event.type == EventTypes.Message &&
                const {
                  MessageTypes.Text,
                  MessageTypes.Notice,
                }.contains(event.messageType)
            ? event
                  .calcLocalizedBodyFallback(
                    plaintextBody: true,
                    removeMarkdown: true,
                    MatrixLocals(L10n.of(context)),
                  )
                  .trim()
            : personalPreviewLabel(event, i18n: MatrixLocals(L10n.of(context))),
        maxLines: 7,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.chevron_right_outlined),
        onPressed: () => context.go(
          '/${Uri(pathSegments: ['rooms', room.id], queryParameters: {'event': event.eventId})}',
        ),
      ),
    );
  }
}
