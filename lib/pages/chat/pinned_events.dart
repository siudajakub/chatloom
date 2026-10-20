// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_list_tile.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class PinnedEvents extends StatelessWidget {
  final ChatController controller;

  const PinnedEvents(this.controller, {super.key});

  Future<void> _displayPinnedEventsDialog(BuildContext context) async {
    final l10n = L10n.of(context);
    final eventsResult = await showFutureLoadingDialog(
      context: context,
      future: () => Future.wait(
        controller.room.pinnedEventIds.map(
          (eventId) => controller.room.getEventById(eventId),
        ),
      ),
    );
    final events = eventsResult.result;
    if (events == null) return;
    if (!context.mounted) return;

    final eventId = events.length == 1
        ? events.single?.eventId
        : await showModalActionPopup<String>(
            context: context,
            title: l10n.pin,
            cancelLabel: l10n.cancel,
            actions: events
                .map(
                  (event) => AdaptiveModalAction(
                    value: event?.eventId ?? '',
                    icon: const Icon(Icons.push_pin_outlined),
                    label:
                        (event == null
                            ? null
                            : personalEventPreview(
                                event,
                                i18n: MatrixLocals(l10n),
                              )) ??
                        'UNKNOWN',
                  ),
                )
                .toList(),
          );

    if (eventId != null) controller.scrollToEventId(eventId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final pinnedEventIds = controller.room.pinnedEventIds;

    if (pinnedEventIds.isEmpty || controller.activeThreadId != null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<Event?>(
      future: controller.room.getEventById(pinnedEventIds.last),
      builder: (context, snapshot) {
        final event = snapshot.data;
        // A newly pinned message (or the loaded preview) fades through.
        return NotionFadeThrough(
          duration: NotionMotion.short,
          child: KeyedSubtree(
            key: ValueKey(event?.eventId),
            child: ChatAppBarListTile(
              title:
                  (event == null
                      ? null
                      : personalEventPreview(
                          event,
                          i18n: MatrixLocals(L10n.of(context)),
                        )) ??
                  L10n.of(context).loadingPleaseWait,
              leading: IconButton(
                splashRadius: 18,
                iconSize: 18,
                color: theme.colorScheme.onSurfaceVariant,
                icon: const Icon(Icons.push_pin),
                tooltip: L10n.of(context).unpin,
                onPressed:
                    controller.room.canSendEvent(EventTypes.RoomPinnedEvents)
                    ? () => controller.unpinEvent(event!.eventId)
                    : null,
              ),
              onTap: () => _displayPinnedEventsDialog(context),
            ),
          ),
        );
      },
    );
  }
}
