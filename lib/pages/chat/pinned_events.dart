// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/chat_app_bar_list_tile.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The pinned bar under the chat header (Telegram): it shows one pin; a tap
/// scrolls to it and steps to the next older one, wrapping around, while
/// the segments on the left show which one of up to four is shown.
/// Long-press lists all pins. Unpin is immediate with Undo.
class PinnedEvents extends StatefulWidget {
  final ChatController controller;

  const PinnedEvents(this.controller, {super.key});

  /// Most segments the position indicator draws (Telegram draws a window).
  static const maxSegments = 4;

  @override
  State<PinnedEvents> createState() => _PinnedEventsState();
}

class _PinnedEventsState extends State<PinnedEvents> {
  /// Index into the pins of the one shown; null = the newest.
  int? _index;
  List<String> _known = const [];

  /// One lookup per pinned event, never a new future per build.
  final _events = <String, Future<Event?>>{};

  ChatController get controller => widget.controller;

  Future<Event?> _event(String id) => _events[id] ??= controller.room
      .getEventById(id)
      .catchError((Object _) => null);

  void _sync(List<String> pins) {
    if (listEquals(pins, _known)) return;
    // A new pin is shown first (Telegram); otherwise keep the position.
    final added = pins.isNotEmpty && !_known.contains(pins.last);
    _known = List.of(pins);
    _events.removeWhere((id, _) => !pins.contains(id));
    if (added || _index == null || _index! >= pins.length) _index = null;
  }

  int _current(List<String> pins) => _index ?? pins.length - 1;

  void _tap(List<String> pins) {
    final index = _current(pins);
    controller.scrollToEventId(pins[index]);
    if (pins.length > 1) {
      setState(() => _index = index == 0 ? pins.length - 1 : index - 1);
    }
  }

  Future<void> _list(List<String> pins) async {
    final l10n = L10n.of(context);
    final events = await Future.wait(pins.reversed.map(_event));
    if (!mounted) return;
    final chosen = await showNotionSheet<String>(
      context: context,
      title: pins.length == 1
          ? 'Pinned message'
          : '${pins.length} pinned messages',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final event in events)
            if (event != null)
              NotionGlassMenuRow(
                leading: const Icon(Icons.push_pin_outlined),
                title: personalEventPreview(event, i18n: MatrixLocals(l10n)),
                onTap: () => Navigator.of(context).pop(event.eventId),
              ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final index = pins.indexOf(chosen);
    if (index >= 0) setState(() => _index = index);
    controller.scrollToEventId(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final pins = controller.pinnedEventIds;
    _sync(pins);

    if (pins.isEmpty || controller.activeThreadId != null) {
      return const SizedBox.shrink();
    }
    final index = _current(pins);
    final id = pins[index];
    return GestureDetector(
      onLongPress: () => _list(pins),
      child: FutureBuilder<Event?>(
        future: _event(id),
        builder: (context, snapshot) {
          final event = snapshot.data;
          // The pin shown (and its loaded preview) fades through.
          return NotionFadeThrough(
            duration: NotionMotion.short,
            child: KeyedSubtree(
              key: ValueKey((id, event?.eventId)),
              child: ChatAppBarListTile(
                title:
                    (event == null
                        ? null
                        : personalEventPreview(
                            event,
                            i18n: MatrixLocals(L10n.of(context)),
                          )) ??
                    L10n.of(context).loadingPleaseWait,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pins.length > 1)
                      _PinSegments(
                        count: pins.length,
                        index: index,
                        color: colors.accent,
                        track: colors.border,
                      ),
                    IconButton(
                      splashRadius: 18,
                      iconSize: 18,
                      color: colors.textSecondary,
                      icon: const Icon(Icons.push_pin),
                      tooltip: L10n.of(context).unpin,
                      onPressed:
                          controller.room.canChangeStateEvent(
                            EventTypes.RoomPinnedEvents,
                          )
                          ? () => controller.unpinEvent(id)
                          : null,
                    ),
                  ],
                ),
                onTap: () => _tap(pins),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Telegram's pinned position: a column of short segments, the shown pin's
/// one in the accent. More pins than [PinnedEvents.maxSegments] scroll the
/// window with the shown pin.
class _PinSegments extends StatelessWidget {
  final int count;
  final int index;
  final Color color;
  final Color track;
  const _PinSegments({
    required this.count,
    required this.index,
    required this.color,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    final shown = math.min(count, PinnedEvents.maxSegments);
    final first = (index - shown + 1).clamp(0, count - shown);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: NotionSpace.xs),
      child: SizedBox(
        width: NotionSpace.xxs - 1,
        height: ChatAppBarListTile.fixedHeight - NotionSpace.xs,
        child: Column(
          spacing: NotionSpace.xxs / 2,
          children: [
            for (var i = first; i < first + shown; i++)
              Expanded(
                child: AnimatedContainer(
                  duration: NotionMotion.of(context, NotionMotion.quick),
                  curve: NotionMotion.standard,
                  decoration: BoxDecoration(
                    color: i == index ? color : track,
                    borderRadius: NotionRadius.pillAll,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
