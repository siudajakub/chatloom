// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/chat_list/chat_thread_preview.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/kept_messages.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Bounded reads from the already-open account database. Do not open a
/// Timeline/Chat here: those own read receipts, history requests and playback.
Future<({List<Event> events, bool failed, bool hasMore})> loadThreadPreview(
  List<Room> sources, {
  int limit = 40,
}) async {
  final events = <(String, String), Event>{};
  var failed = false;
  var hasMore = false;
  for (final room in sources) {
    try {
      final saved = await room.client.database.getEventList(room, limit: limit);
      hasMore |= saved.length >= limit;
      for (final event in saved) {
        events[(room.id, event.eventId)] = event;
      }
    } catch (_) {
      failed = true;
    }
    // The newest sync may not have reached the local database yet.
    if (room.lastEvent case final event?) {
      events[(room.id, event.eventId)] = event;
    }
  }
  return (events: events.values.toList(), failed: failed, hasMore: hasMore);
}

/// The same visibility rules as the conversation; fresh filtering also keeps
/// a deletion/"Remove for you" from exposing old text in an open preview.
List<Event> visibleThreadPreviewEvents(Iterable<Event> events) {
  final visible = events.toList().filterByVisibleInGui()
    ..removeWhere((event) => event.isCollapsedState)
    ..sort((a, b) {
      final time = a.originServerTs.compareTo(b.originServerTs);
      if (time != 0) return time;
      final room = a.room.id.compareTo(b.room.id);
      return room != 0 ? room : a.eventId.compareTo(b.eventId);
    });
  return visible;
}

String _previewSender(Event event) {
  final name = event.room
      .getState(EventTypes.RoomMember, event.senderId)
      ?.content['displayname'];
  return name is String && name.trim().isNotEmpty ? name : event.senderId;
}

String _previewText(Event event) {
  // The full deleted-label helper may request missing administrator profiles.
  // A peek uses a neutral placeholder instead of triggering those requests.
  if (isDeletedForDisplay(event) && KeptMessages.of(event) == null) {
    final redaction = event.redactedBecause;
    if (redaction != null && isDisappearingRedaction(redaction)) {
      return 'Message disappeared';
    }
    if (redaction == null ||
        OwnSenderResolver.of(
          event.room.client,
        ).isOwnSender(redaction.senderId, roomId: event.room.id)) {
      return 'You deleted this message';
    }
    return 'Message deleted';
  }
  if (event.type == EventTypes.Encrypted) return 'Encrypted message';
  return personalPreviewLabel(event);
}

class RoomThreadPreview extends StatefulWidget {
  final List<Room> sources;
  final bool Function() isCurrent;
  final Listenable changes;
  final String Function(Room) sourceLabel;

  const RoomThreadPreview({
    super.key,
    required this.sources,
    required this.isCurrent,
    required this.changes,
    required this.sourceLabel,
  });

  @override
  State<RoomThreadPreview> createState() => _RoomThreadPreviewState();
}

class _RoomThreadPreviewState extends State<RoomThreadPreview> {
  List<Event> _events = [];
  bool _loading = true;
  bool _failed = false;
  bool _hasMore = false;
  bool _loadingOlder = false;
  int _limit = 40;
  int _generation = 0;
  final _subscriptions = <StreamSubscription>[];
  late final Listenable _changes;

  @override
  void initState() {
    super.initState();
    _changes = Listenable.merge([
      widget.changes,
      HiddenMessages.instance,
      KeptMessages.instance,
      MessageDeletions.changes,
    ])..addListener(_changed);
    for (final client in widget.sources.map((room) => room.client).toSet()) {
      _subscriptions.add(client.onSync.stream.listen((_) => _load()));
      _subscriptions.add(
        client.onLoginStateChanged.stream.listen((_) => _changed()),
      );
    }
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final result = await loadThreadPreview(widget.sources, limit: _limit);
    if (!mounted || generation != _generation) return;
    setState(() {
      _events = widget.isCurrent() ? result.events : [];
      _failed = result.failed;
      _hasMore = result.hasMore || result.failed;
      _loading = false;
      _loadingOlder = false;
    });
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore || !widget.isCurrent()) return;
    setState(() {
      _loadingOlder = true;
      _limit += 40;
    });
    await _load();
  }

  @override
  void dispose() {
    _generation++;
    _changes.removeListener(_changed);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent()) {
      return const ChatThreadPreview(messages: [], failed: true);
    }
    final events = visibleThreadPreviewEvents(_events);
    return ChatThreadPreview(
      loading: _loading,
      failed: _failed,
      loadingOlder: _loadingOlder,
      onLoadOlder: _hasMore ? _loadOlder : null,
      messages: [
        for (final event in events)
          ChatThreadPreviewMessage(
            text: _previewText(event),
            sender: OwnSenderResolver.of(event.room.client).isOwnEvent(event)
                ? 'You'
                : _previewSender(event),
            timestamp: event.originServerTs.toLocal(),
            outgoing: OwnSenderResolver.of(event.room.client).isOwnEvent(event),
            source: widget.sources.length > 1
                ? widget.sourceLabel(event.room)
                : null,
          ),
      ],
    );
  }
}
