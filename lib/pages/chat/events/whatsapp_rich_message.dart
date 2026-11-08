// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// A presentation copy only: the stored event, type, source and media remain
/// intact. Other clients still receive the bridge's complete textual fallback.
Event whatsAppDisplayEvent(Event source, WhatsAppInteractiveContent message) {
  final content = Map<String, dynamic>.from(source.content)
    ..remove('pl.personal.chat.whatsapp.interactive')
    ..remove('format')
    ..remove('formatted_body');
  content['body'] = message.body;
  if (message.formattedBody case final String html) {
    content['format'] = 'org.matrix.custom.html';
    content['formatted_body'] = html;
  }
  return Event(
    room: source.room,
    eventId: source.eventId,
    type: source.type,
    senderId: source.senderId,
    originServerTs: source.originServerTs,
    content: content,
    unsigned: source.unsigned,
    stateKey: source.stateKey,
    redacts: source.redacts,
    status: source.status,
    originalSource: source.originalSource,
  );
}

class WhatsAppInteractiveMessage extends StatelessWidget {
  final Event event;
  final WhatsAppInteractiveContent message;
  final Widget Function(Event) contentBuilder;
  final Color textColor;
  final Color linkColor;
  final Color? backgroundColor;

  const WhatsAppInteractiveMessage({
    super.key,
    required this.event,
    required this.message,
    required this.contentBuilder,
    required this.textColor,
    required this.linkColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      contentBuilder(whatsAppDisplayEvent(event, message)),
      NotionWhatsAppActions(
        actions: [
          for (final action in message.actions)
            NotionMessageUrlAction(label: action.label, url: action.url),
        ],
        textColor: textColor,
        linkColor: linkColor,
        backgroundColor: backgroundColor,
        onOpen: (url) {
          // Revalidate at the boundary too; the general launcher supports
          // other URI schemes for unrelated application features.
          if (!event.redacted &&
              WhatsAppUrlAction.isValidUrl(url) &&
              message.actions.any((a) => a.url == url)) {
            unawaited(UrlLauncher(context, url).launchUrl());
          }
        },
        onCopy: (url) {
          if (!event.redacted &&
              WhatsAppUrlAction.isValidUrl(url) &&
              message.actions.any((a) => a.url == url)) {
            unawaited(Clipboard.setData(ClipboardData(text: url)));
          }
        },
      ),
    ],
  );
}

/// Matrix relations are fetched once per timeline/source, outside build. This
/// does not request WhatsApp history or send a vote/read/typing operation.
class WhatsAppPollMessage extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final WhatsAppPollSnapshot poll;
  final Color textColor;
  final Color linkColor;

  const WhatsAppPollMessage({
    super.key,
    required this.event,
    required this.timeline,
    required this.poll,
    required this.textColor,
    required this.linkColor,
  });

  @override
  State<WhatsAppPollMessage> createState() => _WhatsAppPollMessageState();
}

class _WhatsAppPollMessageState extends State<WhatsAppPollMessage> {
  int _generation = 0;
  bool _failed = false;
  bool _sourceRedacted = false;
  StreamSubscription<Event>? _subscription;

  @override
  void initState() {
    super.initState();
    _watch();
    _load();
  }

  @override
  void didUpdateWidget(WhatsAppPollMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.timeline, widget.timeline) ||
        !identical(oldWidget.event.room, widget.event.room) ||
        oldWidget.event.eventId != widget.event.eventId) {
      _failed = false;
      _sourceRedacted = false;
      unawaited(_subscription?.cancel());
      _watch();
      _load();
    }
  }

  void _watch() {
    _subscription = widget.event.room.client.onTimelineEvent.stream.listen((e) {
      if (!mounted || e.roomId != widget.event.roomId) return;
      if (e.type == EventTypes.Redaction) {
        if (e.redacts == widget.event.eventId) {
          setState(() => _sourceRedacted = true);
        } else if (widget
                .timeline
                .aggregatedEvents[widget.event.eventId]?[RelationshipTypes
                    .reference]
                ?.any((r) => r.eventId == e.redacts) ==
            true) {
          setState(() {});
        }
      } else if (e.type == PollEventContent.responseType &&
          e.relationshipEventId == widget.event.eventId) {
        // The SDK's own listener updates aggregation first. Rebuild even
        // when a parent has retained its list subtree for another reason.
        setState(() {});
      }
    });
  }

  void _load() {
    final generation = ++_generation;
    final event = widget.event;
    final timeline = widget.timeline;
    // A row can be mounted while its parent's timeline is being rebuilt.
    // Starting after the frame also avoids synchronous cached callbacks.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _generation ||
          event.redacted ||
          _sourceRedacted ||
          timeline.room.id != event.roomId ||
          !identical(timeline.room.client, event.room.client)) {
        return;
      }
      unawaited(() async {
        var failed = false;
        try {
          await timeline.fetchAggregatedEvents(
            event.eventId,
            RelationshipTypes.reference,
            throwOnError: true,
          );
        } catch (_) {
          // Keep available results. No raw event IDs or server error bodies
          // are added to application logs by this presentation adapter.
          failed = true;
        }
        if (mounted && generation == _generation) {
          setState(() => _failed = failed);
        }
      }());
    });
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    if (event.redacted || _sourceRedacted) return const SizedBox.shrink();
    final relations = widget
        .timeline
        .aggregatedEvents[event.eventId]?[RelationshipTypes.reference];
    final votes = <WhatsAppPollVote>[];
    for (final relation in relations ?? <Event>{}) {
      if (relation.roomId != event.roomId ||
          !identical(relation.room.client, event.room.client) ||
          relation.type != PollEventContent.responseType) {
        continue;
      }
      if (relation.redacted) {
        votes.add(
          WhatsAppPollVote(
            senderId: relation.senderId,
            eventId: relation.eventId,
            timestampMs: relation.originServerTs.millisecondsSinceEpoch,
            answerIds: const [],
            redacted: true,
          ),
        );
        continue;
      }
      final vote = WhatsAppPollVote.fromRelation(
        relation.toJson(),
        expectedPollEventId: event.eventId,
      );
      if (vote != null) votes.add(vote);
    }
    final bySender = widget.poll.votesBySender(votes);
    final own = bySender[event.room.client.userID] ?? const <String>{};
    final hasResults = bySender.values.any((answers) => answers.isNotEmpty);
    final polish = Localizations.maybeLocaleOf(context)?.languageCode == 'pl';
    final status = polish
        ? (_failed
              ? 'Głosuj w WhatsApp · Nie udało się pobrać części wyników'
              : hasResults
              ? 'Głosuj w WhatsApp · Wyniki z dostępnych głosów'
              : 'Głosuj w WhatsApp · Brak dostępnych głosów')
        : (_failed
              ? 'Vote in WhatsApp · Some results could not be loaded'
              : hasResults
              ? 'Vote in WhatsApp · Results from available votes'
              : 'Vote in WhatsApp · No votes available');
    return NotionReadOnlyPoll(
      question: widget.poll.question,
      options: [
        for (final option in widget.poll.options)
          NotionPollOption(
            id: option.id,
            label: option.label,
            selected: own.contains(option.id),
            votes: hasResults
                ? bySender.values.where((ids) => ids.contains(option.id)).length
                : null,
          ),
      ],
      status: status,
      textColor: widget.textColor,
      linkColor: widget.linkColor,
    );
  }
}
