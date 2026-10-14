// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:fluffychat/pages/chat/events/message_content.dart';
import 'package:fluffychat/pages/chat/events/message_reactions.dart';
import 'package:fluffychat/pages/chat/events/reply_content.dart';
import 'package:fluffychat/pages/chat/notion_conversation.dart';
import 'package:fluffychat/personal/capabilities.dart';
import 'package:fluffychat/personal/immediate_outbox.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/media/immediate_media_outbox.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart'
    show personalDate, personalText, schedulePersonalAttachment;
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/scheduled_composer.dart';
import 'package:fluffychat/personal/round_video/round_capture_controller.dart';
import 'package:fluffychat/personal/round_video/round_outbox_panel.dart';
import 'package:fluffychat/personal/round_video/round_record_button.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';
import 'package:fluffychat/personal/round_video/telegram_room_binding.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_adapter.dart';
import 'package:fluffychat/personal/ui/notion_network_filter.dart'
    show notionNetworkLabel;
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:uuid/uuid.dart';

import 'merged_media_dialog.dart';

class SourceChatPage extends StatelessWidget {
  final SourceEventRef source;
  const SourceChatPage({super.key, required this.source});
  @override
  Widget build(BuildContext context) {
    final matrix = Matrix.of(context);
    final active = matrix.client;
    final correct = matrix.widget.clients
        .where((c) => c.userID == source.conversation.accountId)
        .firstOrNull;
    if (active.userID == source.conversation.accountId &&
        active.getRoomById(source.conversation.roomId) != null) {
      return ChatPage(
        roomId: source.conversation.roomId,
        eventId: source.eventId,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Source message')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The source conversation is unavailable in the current account.',
              ),
              if (correct != null &&
                  correct.getRoomById(source.conversation.roomId) != null)
                TextButton(
                  onPressed: () {
                    matrix.setActiveClient(correct);
                    context.go(
                      '/rooms/${source.conversation.roomId}?event=${Uri.encodeComponent(source.eventId)}',
                    );
                  },
                  child: const Text('Open in the source account'),
                ),
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MergedChatPage extends StatefulWidget {
  final PersonalClient personal;
  final PersonGroup group;
  const MergedChatPage({
    super.key,
    required this.personal,
    required this.group,
  });
  @override
  State<MergedChatPage> createState() => _MergedChatPageState();
}

class _MergedChatPageState extends State<MergedChatPage> {
  final timelines = <String, Timeline>{};
  final input = TextEditingController();
  final viewed = <String, Event>{};
  final rowKeys = <String, GlobalKey>{};
  final viewportKey = GlobalKey();
  final scroll = ScrollController();
  bool showLatest = false;
  ConversationRef? selectedNetwork;
  SendTarget? _draftTarget;
  MergedEvent<Object?>? _confirmedOutgoing;
  bool _needsNetworkChoice = false;
  String? _savedDraftText;
  bool _draftRestored = false;
  final unavailable = <String>{};
  Event? reply;
  bool loading = true, sending = false, paging = false;
  Timer? _draftTimer;
  String? problem;
  late final personal = widget.personal;
  @override
  void initState() {
    super.initState();
    personal.addListener(_personalChanged);
    scroll.addListener(() {
      final value = scroll.hasClients && scroll.offset > 120;
      if (mounted && value != showLatest) setState(() => showLatest = value);
    });
    _load();
  }

  void _personalChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!loading) setState(() => loading = true);
    unavailable.clear();
    problem = null;
    try {
      // Journal network synchronization must not block source conversations.
      unawaited(personal.load());
      try {
        await personal.loadLocal();
      } catch (_) {
        problem =
            'Private storage is unavailable. Conversation history remains accessible.';
      }
      try {
        await personal.client.roomsLoading?.timeout(
          const Duration(seconds: 15),
        );
      } on TimeoutException {
        // Cached rooms can still provide history; missing sources remain retryable.
      }
      if (!mounted) return;
      await Future.wait(
        widget.group.members.map((member) async {
          if (timelines.containsKey(member.roomId)) return;
          final room = personal.client.getRoomById(member.roomId);
          if (room == null || member.accountId != personal.client.userID) {
            unavailable.add(member.roomId);
            return;
          }
          try {
            final timeline = await room.getTimeline(onUpdate: _timelineChanged);
            if (!mounted) {
              timeline.cancelSubscriptions();
              return;
            }
            timelines[member.roomId] = timeline;
            setState(() {});
          } catch (_) {
            unavailable.add(member.roomId);
          }
        }),
      );
      if (!mounted) return;
      final draft = personal.values['draft:person:${widget.group.id}'];
      if (!_draftRestored && input.text.isEmpty && draft?['text'] is String) {
        input.text = draft!['text'] as String;
        final target = draft['target'];
        if (target is Map) {
          try {
            final restored = SendTarget.fromJson(
              Map<String, dynamic>.from(target),
            );
            if (widget.group.members.contains(restored.conversation)) {
              _draftTarget = restored;
              selectedNetwork = restored.conversation;
            } else {
              _needsNetworkChoice = true;
              problem =
                  'This draft belongs to a source outside this person. Choose a network before sending.';
            }
          } catch (_) {
            _needsNetworkChoice = true;
            problem =
                'The draft source could not be read. Choose a network before sending.';
          }
        } else if (input.text.isNotEmpty) {
          _needsNetworkChoice = true;
          problem =
              'This draft has no saved source. Choose a network before sending.';
        }
        _savedDraftText = input.text;
      }
      _draftRestored = true;
      if (unavailable.isNotEmpty) {
        problem =
            'Some sources are unavailable. History from available networks is shown.';
      }
    } catch (_) {
      problem =
          'A source could not be opened. The send network remains unchanged.';
    }
    if (mounted) setState(() => loading = false);
  }

  MergedTimelineBuffer<Event> get buffer {
    final result = MergedTimelineBuffer<Event>(widget.group.members);
    for (final member in widget.group.members) {
      final t = timelines[member.roomId];
      if (t == null) {
        result.addPage(member: member, events: const [], hasMore: false);
        continue;
      }
      result.addPage(
        member: member,
        events: t.events
            .where(
              (e) =>
                  {
                    EventTypes.Message,
                    EventTypes.Sticker,
                    EventTypes.Encrypted,
                    PollEventContent.startType,
                  }.contains(e.type) &&
                  e.relationshipType != RelationshipTypes.edit,
            )
            .map(
              (e) => MergedEvent(
                source: personal.source(e),
                timestamp: e.originServerTs,
                isOutgoing: e.senderId == personal.client.userID,
                value: e,
              ),
            ),
        hasMore: t.canRequestHistory,
        cursor: t.canRequestHistory
            ? t.events.lastOrNull?.eventId ?? 'initial'
            : null,
      );
    }
    return result;
  }

  SendTarget get target {
    if (reply == null && _draftTarget != null) return _draftTarget!;
    final events = buffer.events
        .where((event) => !event.isOutgoing || event.value.status.isSent)
        .toList();
    MergedEvent<Object?>? recent = events.lastOrNull;
    final confirmed = _confirmedOutgoing;
    if (confirmed != null &&
        (recent == null || confirmed.timestamp.isAfter(recent.timestamp))) {
      recent = confirmed;
    }
    final routed = MergedSendRouter.resolve(
      group: widget.group,
      now: DateTime.now(),
      recentEvent: recent,
      override: reply == null ? selectedNetwork : null,
      replyTo: reply == null ? null : personal.source(reply!),
    );
    return SendTarget(
      conversation: routed.conversation,
      readUpToEventId: viewed[routed.conversation.roomId]?.eventId,
    );
  }

  void _rememberAccepted(SendTarget target, String eventId, DateTime at) {
    if (!eventId.startsWith(r'$')) return;
    _confirmedOutgoing = MergedEvent<Object?>(
      source: SourceEventRef(
        conversation: target.conversation,
        eventId: eventId,
      ),
      timestamp: at,
      isOutgoing: true,
      value: null,
    );
  }

  /// Retain the rendered source-event anchor while pagination or incoming
  /// source events alter the merged sequence. Never jump a reader to the end.
  (GlobalKey, double)? _visibleAnchor() {
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
    (GlobalKey, double)? result;
    for (final key in rowKeys.values) {
      final row = key.currentContext?.findRenderObject();
      if (row is! RenderBox || !row.hasSize) continue;
      final rect = row.localToGlobal(Offset.zero) & row.size;
      if (!visible.overlaps(rect)) continue;
      if (result == null || rect.top < result.$2) result = (key, rect.top);
    }
    return result;
  }

  void _timelineChanged() {
    if (!mounted) return;
    final anchor = scroll.hasClients && scroll.offset > 80
        ? _visibleAnchor()
        : null;
    setState(() {});
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final row = anchor.$1.currentContext?.findRenderObject();
      if (row is! RenderBox || !row.hasSize) return;
      final after = row.localToGlobal(Offset.zero).dy;
      final restored = notionRestoredScrollOffset(
        scroll.offset,
        anchor.$2,
        after,
        reverse: true,
      );
      scroll.jumpTo(
        restored.clamp(
          scroll.position.minScrollExtent,
          scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  Future<void> _openVoiceSource() async {
    final frozen = target;
    final room = personal.client.getRoomById(frozen.conversation.roomId);
    if (room == null ||
        sending ||
        loading ||
        _needsNetworkChoice ||
        reply != null)
      return;
    if (!identical(Matrix.of(context).client, personal.client) ||
        personal.client.userID != frozen.conversation.accountId) {
      setState(
        () => problem =
            'The source account changed. Reopen this conversation before recording.',
      );
      return;
    }
    await _draft();
    if (!mounted) return;
    if (!identical(Matrix.of(context).client, personal.client) ||
        personal.client.userID != frozen.conversation.accountId ||
        target.conversation != frozen.conversation ||
        reply != null) {
      setState(
        () => problem =
            'The source changed. Your draft is preserved. Reopen the voice recorder.',
      );
      return;
    }
    // The ordinary source controller owns its real recorder and media send
    // flow. Opening it does not mutate this person's selected send target.
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ChatPage(roomId: room.id)),
    );
  }

  Future<void> _page() async {
    if (paging) return;
    setState(() => paging = true);
    try {
      await Future.wait(
        timelines.values
            .where((t) => t.canRequestHistory)
            .map((t) => t.requestHistory(historyCount: 50)),
      );
    } catch (_) {
      problem = 'Some older history could not be loaded. You can retry.';
    }
    if (mounted) setState(() => paging = false);
  }

  void _observe(Event event, GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !PersonalPrivacy.surfaceUnlocked ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final row = key.currentContext?.findRenderObject();
      final viewport = viewportKey.currentContext?.findRenderObject();
      if (row is! RenderBox ||
          viewport is! RenderBox ||
          !row.hasSize ||
          !viewport.hasSize) {
        return;
      }
      final rect = row.localToGlobal(Offset.zero) & row.size;
      final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
      if (!visible.overlaps(rect) || !event.eventId.startsWith(r'$')) return;
      final old = viewed[event.room.id];
      if (old == null || event.originServerTs.isAfter(old.originServerTs)) {
        viewed[event.room.id] = event;
        PersonalPrivacy.observe(event.room, event.eventId);
        if (PersonalPrivacy.policy.allowAutomaticRead) {
          unawaited(PersonalPrivacy.markRead(event.room, event.eventId));
        }
      }
    });
  }

  Future<void> _draft() async {
    if (_needsNetworkChoice) return;
    final text = input.text;
    final frozen = _draftTarget ??= target;
    try {
      await personal.savePersonalDraft(
        'draft:person:${widget.group.id}',
        frozen,
        text,
      );
      _savedDraftText = text;
    } catch (_) {
      problem = 'The draft was not synced. Your text remains in the editor.';
    }
  }

  Future<void> _send() async {
    if (sending || _needsNetworkChoice || input.text.trim().isEmpty) return;
    final frozen = target;
    final text = input.text;
    final replyAtSend = reply;
    _draftTimer?.cancel();
    final room = personal.client.getRoomById(frozen.conversation.roomId);
    if (room == null || !room.canSendDefaultMessages) {
      setState(
        () => problem =
            'The selected source is unavailable. Choose a network manually.',
      );
      return;
    }
    setState(() => sending = true);
    try {
      final result = await personal.sendImmediate(
        room,
        text,
        replyTo: replyAtSend,
      );
      if (result.state != ImmediateSendState.accepted) {
        problem =
            'Sending was not confirmed. Retrying retains the same attempt.';
      } else {
        if (result.eventId != null) {
          _rememberAccepted(frozen, result.eventId!, DateTime.now());
        }
        if (input.text == text) input.clear();
        if (reply == replyAtSend) reply = null;
        try {
          await _draft();
          await personal.completeImmediate(result.actionId);
        } catch (_) {
          problem =
              'Message accepted. Send state is retained until the draft is saved.';
        }
        if (input.text.isEmpty) _draftTarget = null;
      }
    } catch (_) {
      problem = 'Sending was not confirmed. Check the source before retrying.';
    }
    if (mounted) setState(() => sending = false);
  }

  Future<void> _allRead() async {
    var failed = false;
    for (final member in widget.group.members) {
      final room = personal.client.getRoomById(member.roomId);
      final id = room?.lastEvent?.eventId;
      if (room == null || id == null) {
        failed = true;
        continue;
      }
      try {
        await PersonalPrivacy.markRead(room, id, manual: true);
      } catch (_) {
        failed = true;
      }
    }
    if (mounted) {
      setState(
        () => problem = failed
            ? 'Some sources did not confirm the read marker.'
            : null,
      );
    }
  }

  Future<void> _schedule(bool attachment) async {
    if (sending || _needsNetworkChoice) return;
    final frozen = target;
    final text = input.text;
    final frozenReply = reply;
    if (!attachment && text.trim().isEmpty) return;
    setState(() => sending = true);
    try {
      final room = personal.client.getRoomById(frozen.conversation.roomId);
      if (room == null) throw StateError('The selected source is unavailable.');
      final composer = FrozenScheduledComposer.capture(
        room: room,
        target: frozen,
        reply: frozenReply,
        isCurrent: () => mounted &&
            identical(Matrix.of(context).client, personal.client),
      );
      bool sameComposerContext() => mounted &&
          identical(Matrix.of(context).client, personal.client) &&
          target.conversation == frozen.conversation &&
          identical(reply, frozenReply);
      if (attachment) {
        await schedulePersonalAttachment(
          context,
          personal,
          frozen,
          composeContext: composer,
        );
      } else {
        final due = await personalDate(context);
        if (due == null || !mounted) return;
        composer.validateCurrent();
        if (!due.isAfter(DateTime.now())) throw StateError('Invalid date');
        final id = const Uuid().v4();
        await personal.schedule(
          ScheduledSend(
            id: id,
            target: frozen,
            dueAt: due,
            content: composer.content({'msgtype': 'm.text', 'body': text}),
            transactionId: 'schedule-$id',
          ),
        );
        if (input.text == text && sameComposerContext()) {
          await personal.savePersonalDraft(
            'draft:person:${widget.group.id}',
            frozen,
            '',
          );
          if (input.text == text && sameComposerContext()) {
            input.clear();
            reply = null;
            _draftTarget = null;
          } else if (mounted) {
            await _draft();
          }
        }
      }
    } catch (_) {
      problem =
          'The message could not be scheduled in the selected source. Your draft is preserved.';
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _recordRound(RoundCaptureGestureController gesture, {bool silent = false}) async {
    if (sending || loading || _needsNetworkChoice) return;
    final frozen = target;
    final sourceRoom = personal.client.getRoomById(frozen.conversation.roomId);
    final sourceReply = reply;
    if (sourceRoom == null) return;
    setState(() => sending = true);
    try {
      final result = await TelegramRoundService.of(personal.client)
          .captureAndSend(
            context,
            sourceRoom,
            reply: sourceReply,
            readUpToEventId: frozen.readUpToEventId,
            gesture: gesture,
            silent: silent,
            stillCurrent: () =>
                mounted &&
                target.conversation == frozen.conversation &&
                identical(Matrix.of(context).client, personal.client),
          );
      if (!mounted || result == null) return;
      if (result.state == ImmediateMediaState.matrixAccepted &&
          result.eventId != null) {
        _rememberAccepted(frozen, result.eventId!, DateTime.now());
        if (identical(reply, sourceReply)) setState(() => reply = null);
      }
      setState(
        () => problem = result.state == ImmediateMediaState.matrixAccepted
            ? 'Matrix accepted the round video. Telegram delivery is unconfirmed.'
            : 'Recording preserved in its original source. Check the round video queue.',
      );
    } catch (_) {
      if (mounted)
        setState(
          () => problem =
              'Round videos require a trusted Telegram bridge, encryption and available storage.',
        );
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _attachMedia() async {
    if (sending || loading || _needsNetworkChoice) return;
    final frozen = target;
    final oldText = input.text;
    final sourceReply = reply;
    _draftTimer?.cancel();
    final key = 'draft:person:${widget.group.id}';
    var mediaAccepted = false;
    setState(() => sending = true);
    try {
      if (_savedDraftText != oldText &&
          (_savedDraftText != null || oldText.isNotEmpty)) {
        await personal.savePersonalDraft(key, frozen, oldText);
        _savedDraftText = oldText;
      }
      final current = personal.values[key];
      final baseline = current == null ? null : jsonDecode(jsonEncode(current));
      if (!mounted) return;
      final result = await showMergedMediaDialog(
        context,
        personal,
        frozen,
        replyTo: sourceReply,
        caption: oldText,
        onAccepted: (id, at) {
          if (mounted) _rememberAccepted(frozen, id, at);
        },
      );
      if (!mounted) return;
      mediaAccepted = result.accepted;
      // A later draft or a changed caption belongs to the user. Clear only the
      // exact captured text after all file sends were accepted.
      if (result.accepted &&
          result.caption == oldText.trim() &&
          input.text == oldText &&
          baseline is Map &&
          baseline['text'] == oldText &&
          const DeepCollectionEquality().equals(
            personal.values[key],
            baseline,
          ) &&
          !personal.conflicts.containsKey(key)) {
        await personal.savePersonalDraft(
          'draft:person:${widget.group.id}',
          frozen,
          '',
        );
        if (input.text == oldText) {
          input.clear();
          _savedDraftText = '';
          _draftTarget = null;
        } else {
          await personal.savePersonalDraft(
            'draft:person:${widget.group.id}',
            frozen,
            input.text,
          );
        }
      }
      if (result.accepted && reply == sourceReply) reply = null;
    } on PersonalCapabilityUnavailable catch (error) {
      problem = error.reason;
    } catch (_) {
      problem = mediaAccepted
          ? 'Attachments accepted. Your draft is retained until saving is confirmed.'
          : 'Attachments could not be prepared. Your draft is preserved.';
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _action(Event event, String action) async {
    try {
      final sourceRoom = personal.client.getRoomById(event.room.id);
      if (sourceRoom == null ||
          event.room.client != personal.client ||
          (event.redacted && action != 'source')) {
        throw StateError('Unavailable source');
      }
      if (action == 'reply') {
        if (!RoomCapabilities.forFeature(
          BridgeFeature.reply,
          sourceRoom,
          event: event,
        ).allowed) {
          throw StateError('Reply capability unverified');
        }
        setState(() {
          reply = event;
          _draftTarget = SendTarget(
            conversation: personal.ref(sourceRoom),
            readUpToEventId: viewed[sourceRoom.id]?.eventId,
          );
        });
        await _draft();
        return;
      }
      if (action == 'source') {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SourceChatPage(source: personal.source(event)),
          ),
        );
        return;
      }
      if (action == 'bookmark') {
        await personal.put('bookmark:${personal.transcriptId(event)}', {
          'source': personal.source(event).toJson(),
          'network': PersonalClient.networkOf(event.room),
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
      if (action == 'reaction') {
        if (!RoomCapabilities.forFeature(
          BridgeFeature.reaction,
          sourceRoom,
          event: event,
          reaction: '👍',
        ).allowed) {
          throw StateError('Reaction capability unverified');
        }
        await sourceRoom.sendReaction(event.eventId, '👍');
      }
      if (action == 'edit') {
        final timeline = timelines[sourceRoom.id];
        if (timeline == null ||
            !RoomCapabilities.forFeature(
              BridgeFeature.edit,
              sourceRoom,
              event: event,
              editCount: event
                  .aggregatedEvents(timeline, RelationshipTypes.edit)
                  .length,
            ).allowed) {
          throw StateError('Edit capability unverified');
        }
        if (!mounted) return;
        final text = await personalText(
          context,
          'Edit message',
          initial: event.getDisplayEvent(timeline).text,
        );
        if (text == null || text.trim().isEmpty) return;
        if (!RoomCapabilities.forFeature(
          BridgeFeature.edit,
          sourceRoom,
          event: event,
          editCount: event
              .aggregatedEvents(timeline, RelationshipTypes.edit)
              .length,
        ).allowed) {
          throw StateError('Source changed');
        }
        final sent = await personal.sendImmediate(
          sourceRoom,
          text,
          editEventId: event.eventId,
        );
        if (sent.state != ImmediateSendState.accepted) {
          throw StateError('Edit not confirmed');
        }
        await personal.completeImmediate(sent.actionId);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => problem = error is PersonalCapabilityUnavailable
              ? error.reason
              : 'The action was not confirmed in the source network.',
        );
      }
    }
  }

  @override
  void dispose() {
    if (_savedDraftText != input.text) {
      try {
        final frozen = _draftTarget ?? target;
        unawaited(
          personal
              .savePersonalDraft(
                'draft:person:${widget.group.id}',
                frozen,
                input.text,
              )
              .catchError((Object _) {}),
        );
      } catch (_) {}
    }
    for (final t in timelines.values) {
      t.cancelSubscriptions();
    }
    _draftTimer?.cancel();
    personal.removeListener(_personalChanged);
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = buffer.coveredEvents.reversed.toList();
    final channel = target.conversation;
    final theme = Theme.of(context);
    final displayName =
        InboxProjection(
          personal,
        ).metadataForEntity('person:${widget.group.id}').nickname ??
        widget.group.name;
    final avatarRoom = widget.group.members
        .map((member) => personal.client.getRoomById(member.roomId))
        .whereType<Room>()
        .firstOrNull;
    final enabled = !sending && !loading && !_needsNetworkChoice;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: NotionTokens.headerHeight,
        titleSpacing: 0,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        title: NotionCompactChatHeader(
          avatar: Avatar(
            client: personal.client,
            mxContent: avatarRoom?.avatar,
            name: displayName,
            size: 32,
          ),
          name: displayName,
          onDetails: () => showNotionMergedChatDetails(
            context,
            personal: personal,
            group: widget.group,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Conversation actions',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) => action == 'read'
                ? _allRead()
                : showNotionMergedChatDetails(
                    context,
                    personal: personal,
                    group: widget.group,
                  ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'details', child: Text('Chat details')),
              PopupMenuItem(
                value: 'read',
                child: Text('Mark all sources as read'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (problem != null)
            MaterialBanner(
              content: Text(problem!),
              actions: [
                if (unavailable.isNotEmpty || timelines.isEmpty)
                  TextButton(
                    onPressed: loading ? null : _load,
                    child: const Text('Retry loading'),
                  ),
                TextButton(
                  onPressed: () => setState(() => problem = null),
                  child: const Text('Close'),
                ),
              ],
            ),
          if (loading) const LinearProgressIndicator(),
          Expanded(
            child: Stack(
              children: [
                ListView.builder(
                  key: viewportKey,
                  controller: scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                  itemCount: events.length + 1,
                  findChildIndexCallback: (key) {
                    final source = rowKeys.entries
                        .where((entry) => entry.value == key)
                        .firstOrNull
                        ?.key;
                    if (source == null) return null;
                    final index = events.indexWhere(
                      (event) => event.source.key == source,
                    );
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    if (index == events.length)
                      return buffer.hasMore
                          ? TextButton(
                              onPressed: paging ? null : _page,
                              child: Text(
                                paging ? 'Loading…' : 'Older messages',
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                events.isEmpty && !loading
                                    ? 'No messages yet'
                                    : 'Available history loaded',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                    final merged = events[index];
                    final event = merged.value;
                    final timeline = timelines[event.room.id]!;
                    final display = event.getDisplayEvent(timeline);
                    final rendered = display.eventId == event.eventId
                        ? event
                        : Event.fromJson({
                            ...event.toJson(),
                            'type': display.type,
                            'content': display.content,
                          }, event.room);
                    final key = rowKeys.putIfAbsent(
                      merged.source.key,
                      GlobalKey.new,
                    );
                    _observe(event, key);
                    return FutureBuilder<User?>(
                      key: key,
                      future: event.fetchSenderUser(),
                      builder: (context, snapshot) {
                        final sender =
                            snapshot.data ?? event.senderFromMemoryOrFallback;
                        return NotionAuthoredMessageRow(
                          avatar: Avatar(
                            client: event.room.client,
                            mxContent: sender.avatarUrl,
                            name: sender.calcDisplayname(),
                            size: 36,
                          ),
                          author: merged.isOutgoing
                              ? 'You'
                              : sender.calcDisplayname(),
                          time: event.originServerTs.localizedTimeOfDay(
                            context,
                          ),
                          source:
                              'via ${notionNetworkLabel(PersonalClient.networkOf(event.room))}',
                          actions: PopupMenuButton<String>(
                            tooltip: 'Message actions',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 44),
                            iconSize: 18,
                            onSelected: (action) => _action(event, action),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'reply',
                                enabled: !event.redacted,
                                child: const Text('Reply in source network'),
                              ),
                              PopupMenuItem(
                                value: 'reaction',
                                enabled: !event.redacted,
                                child: const Text('React with thumbs up'),
                              ),
                              PopupMenuItem(
                                value: 'bookmark',
                                enabled: !event.redacted,
                                child: const Text('Bookmark'),
                              ),
                              const PopupMenuItem(
                                value: 'source',
                                child: Text('Open source · edit · delete'),
                              ),
                              if (merged.isOutgoing &&
                                  event.messageType == MessageTypes.Text &&
                                  !event.redacted)
                                PopupMenuItem(
                                  value: 'edit',
                                  enabled: RoomCapabilities.forFeature(
                                    BridgeFeature.edit,
                                    event.room,
                                    event: event,
                                    editCount: event
                                        .aggregatedEvents(
                                          timeline,
                                          RelationshipTypes.edit,
                                        )
                                        .length,
                                  ).allowed,
                                  child: const Text('Edit in source network'),
                                ),
                            ],
                          ),
                          body: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (event.inReplyToEventId(
                                    includingFallback: false,
                                  ) !=
                                  null)
                                FutureBuilder<Event?>(
                                  future: event.getReplyEvent(timeline),
                                  builder: (context, snapshot) {
                                    final original = snapshot.data;
                                    if (original == null)
                                      return const Text(
                                        'Loading reply…',
                                        style: TextStyle(fontSize: 12),
                                      );
                                    return InkWell(
                                      onTap: () => _action(original, 'source'),
                                      child: AbsorbPointer(
                                        child: ReplyContent(
                                          original,
                                          ownMessage: merged.isOutgoing,
                                          timeline: timeline,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              AbsorbPointer(
                                absorbing:
                                    event.type == PollEventContent.startType &&
                                    !RoomCapabilities.forFeature(
                                      BridgeFeature.poll,
                                      event.room,
                                      event: event,
                                    ).allowed,
                                child: MessageContent(
                                  rendered,
                                  timeline: timeline,
                                  textColor: theme.colorScheme.onSurface,
                                  linkColor: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(
                                    NotionTokens.radius,
                                  ),
                                  selected: false,
                                  bigEmojis: const {},
                                ),
                              ),
                              if (event.hasAggregatedEvents(
                                timeline,
                                RelationshipTypes.reaction,
                              ))
                                MessageReactions(event, timeline),
                              if (event.hasAggregatedEvents(
                                timeline,
                                RelationshipTypes.edit,
                              ))
                                Text(
                                  'Edited',
                                  style: NotionTokens.caption.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (event.status.isError)
                                Text(
                                  'Could not be sent · open source to retry',
                                  style: NotionTokens.caption.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              if (event.status == EventStatus.sending)
                                const Text(
                                  'Sending…',
                                  style: NotionTokens.caption,
                                ),
                              if (event.type == PollEventContent.startType &&
                                  !RoomCapabilities.forFeature(
                                    BridgeFeature.poll,
                                    event.room,
                                    event: event,
                                  ).allowed)
                                Text(
                                  RoomCapabilities.forFeature(
                                    BridgeFeature.poll,
                                    event.room,
                                    event: event,
                                  ).reason,
                                  style: NotionTokens.caption,
                                ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                if (showLatest)
                  Positioned(
                    right: 16,
                    bottom: 8,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                      ),
                      onPressed: () => scroll.animateTo(
                        0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                      ),
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      label: const Text('Latest messages'),
                    ),
                  ),
              ],
            ),
          ),
          if (reply != null)
            ListTile(
              dense: true,
              title: const Text('Reply in source network'),
              subtitle: Text(
                '${notionNetworkLabel(PersonalClient.networkOf(reply!.room))} · Cancel this reply to open the source voice recorder',
              ),
              trailing: NotionIconButton(
                icon: Icons.close,
                label: 'Cancel reply',
                onPressed: () => setState(() => reply = null),
              ),
            ),
          if (channel.network == 'telegram' &&
              personal.client.getRoomById(channel.roomId) != null)
            RoundOutboxPanel(
              room: personal.client.getRoomById(channel.roomId)!,
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: NotionComposer(
                input: TextField(
                  controller: input,
                  maxLines: 6,
                  minLines: 1,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Write a message…',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                  ),
                  onChanged: (_) {
                    setState(() => _draftTarget ??= target);
                    _draftTimer?.cancel();
                    _draftTimer = Timer(
                      const Duration(milliseconds: 500),
                      _draft,
                    );
                  },
                ),
                actions: [
                  NotionIconButton(
                    icon: Icons.attach_file_outlined,
                    label: 'Attach media or a file',
                    onPressed: enabled ? _attachMedia : null,
                  ),
                  NotionIconButton(
                    icon: Icons.mic_none_outlined,
                    label: reply == null
                        ? 'Record a voice message in source conversation'
                        : 'Cancel this reply before opening the source voice recorder',
                    onPressed: enabled && reply == null
                        ? _openVoiceSource
                        : null,
                  ),
                  if (channel.network == 'telegram')
                    RoundRecordButton(onRecord: _recordRound),
                  PopupMenuButton<String>(
                    tooltip: 'Send options',
                    enabled: enabled,
                    onSelected: (choice) {
                      if (choice == 'roundSilent') {
                        final gesture = RoundCaptureGestureController(held: true)..lock();
                        _recordRound(gesture, silent: true).whenComplete(gesture.dispose);
                      } else {
                        _schedule(choice == 'attachment');
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'text', child: Text('Schedule text')),
                      const PopupMenuItem(
                        value: 'attachment',
                        child: Text('Schedule an attachment'),
                      ),
                      if (PlatformInfos.isAndroid &&
                          personal.client.getRoomById(channel.roomId) != null &&
                          TelegramRoomBinding.of(personal.client.getRoomById(channel.roomId)!)
                              ?.capabilities(personal.client.getRoomById(channel.roomId)!)
                              .extension.operation('silent_send').allowed == true)
                        const PopupMenuItem(
                          value: 'roundSilent',
                          child: Text('Record a round video silently'),
                        ),
                    ],
                    icon: const Icon(Icons.schedule_outlined),
                  ),
                ],
                source: DropdownButtonHideUnderline(
                  child: DropdownButton<ConversationRef>(
                    isExpanded: true,
                    isDense: true,
                    hint: const Text('Choose a send network'),
                    value: _needsNetworkChoice ? null : channel,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onChanged: reply != null || sending
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              selectedNetwork = value;
                              _draftTarget = SendTarget(
                                conversation: value,
                                readUpToEventId: viewed[value.roomId]?.eventId,
                              );
                              _needsNetworkChoice = false;
                            });
                            _draft();
                          },
                    items: [
                      for (final member in widget.group.members)
                        DropdownMenuItem(
                          value: member,
                          child: Text(
                            '${notionNetworkLabel(member.network)} · ${personal.client.getRoomById(member.roomId)?.getLocalizedDisplayname() ?? 'Unavailable source'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                sendAction: NotionSendButton(
                  busy: sending,
                  onPressed:
                      !enabled ||
                          input.text.trim().isEmpty ||
                          personal.client
                                  .getRoomById(channel.roomId)
                                  ?.canSendDefaultMessages !=
                              true
                      ? null
                      : _send,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
