// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show personalConversationAvatar;
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// One row of the forward sheet: a conversation of the inbox (a merged
/// person is one row), with the source rooms it can send through, best
/// first.
class ForwardTarget {
  final String entityId;
  final String name;
  final Room representative;
  final PersonGroup? group;

  /// Rooms the message can go to, in order: for a person the network the
  /// merged chat would send through now, then the others by recency.
  final List<Room> rooms;
  final Set<String> networks;
  final bool isGroup;
  final DateTime? lastActivity;

  const ForwardTarget({
    required this.entityId,
    required this.name,
    required this.representative,
    required this.rooms,
    required this.networks,
    this.group,
    this.isGroup = false,
    this.lastActivity,
  });

  bool matches(String query) {
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    final searchable = [
      name,
      for (final network in networks) notionNetworkLabel(network),
    ].join(' ').toLowerCase();
    return terms.every(searchable.contains);
  }

  @override
  String toString() => 'ForwardTarget(redacted)';
}

/// The conversations a message can be forwarded to, most recent first:
/// the inbox's records (private names, merged persons as one), without the
/// private journal, technical and ignored chats, spaces, or chats nobody
/// can send to. [accepts] narrows the source rooms (round forwards).
List<ForwardTarget> forwardTargets(
  PersonalClient personal, {
  bool Function(Room room)? accepts,
}) {
  final client = personal.client;
  final projection = InboxProjection.snapshot(personal);
  final index = projection.buildIndex(client.rooms);
  final own = OwnSenderResolver.of(client);
  bool sendable(Room room) =>
      room.membership == Membership.join &&
      !room.isSpace &&
      !PersonalPrivacy.isJournal(room) &&
      room.canSendDefaultMessages &&
      (accepts?.call(room) ?? true);
  final targets = <ForwardTarget>[];
  for (final record in index.records) {
    if (record.technical ||
        record.metadata.ignored ||
        record.placement == ChatPlacement.ignored) {
      continue;
    }
    final representative = client.getRoomById(record.representativeRoomId);
    if (representative == null) continue;
    final group = record.entityId.startsWith('person:')
        ? projection.groupById(record.entityId.substring('person:'.length))
        : null;
    final sources = group == null
        ? [representative]
        : [
            for (final member in group.members)
              ?client.getRoomById(member.roomId),
          ];
    final rooms = sources.where(sendable).toList()
      ..sort(
        (a, b) => (b.lastEvent?.originServerTs ?? DateTime(0)).compareTo(
          a.lastEvent?.originServerTs ?? DateTime(0),
        ),
      );
    if (rooms.isEmpty) continue;
    if (group != null) {
      final routed = _routedRoom(group, rooms, own);
      if (routed != null) {
        rooms
          ..remove(routed)
          ..insert(0, routed);
      }
    }
    targets.add(
      ForwardTarget(
        entityId: record.entityId,
        name: record.displayName,
        representative: representative,
        group: group,
        rooms: rooms,
        networks: record.networks,
        isGroup: record.isGroup,
        lastActivity: record.lastActivity,
      ),
    );
  }
  targets.sort((a, b) {
    final time = (b.lastActivity ?? DateTime(0)).compareTo(
      a.lastActivity ?? DateTime(0),
    );
    return time != 0 ? time : a.entityId.compareTo(b.entityId);
  });
  return targets;
}

/// The source the merged chat would send a new message through now (the
/// same rule as its composer: the latest network, the default after a
/// while), when that room can take it.
Room? _routedRoom(PersonGroup group, List<Room> rooms, OwnSenderResolver own) {
  Event? latest;
  for (final room in rooms) {
    final event = room.lastEvent;
    if (event == null || !event.eventId.startsWith(r'$')) continue;
    if (latest == null || event.originServerTs.isAfter(latest.originServerTs)) {
      latest = event;
    }
  }
  try {
    final routed = MergedSendRouter.resolve(
      group: group,
      now: DateTime.now(),
      recentEvent: latest == null
          ? null
          : MergedEvent(
              source: SourceEventRef(
                conversation: group.members.firstWhere(
                  (m) => m.roomId == latest!.room.id,
                ),
                eventId: latest.eventId,
              ),
              timestamp: latest.originServerTs,
              isOutgoing: own.isOwnEvent(latest),
              value: latest,
            ),
    );
    return rooms.where((r) => r.id == routed.conversation.roomId).firstOrNull;
  } catch (_) {
    return null;
  }
}

/// [content] as a new message: no reply, thread or edit relation and no
/// reply fallback; media keeps its `url`/`file` keys.
Map<String, Object?> forwardableContent(Map<String, Object?> content) {
  final copy = content.copy();
  final relation = copy.remove('m.relates_to');
  copy.remove('m.new_content');
  final wasReply = relation is Map && relation['m.in_reply_to'] != null;
  if (wasReply) {
    final body = copy['body'];
    if (body is String && body.startsWith('> ')) {
      final lines = body.split('\n');
      final start = lines.indexWhere((line) => !line.startsWith('>'));
      if (start > 0) {
        copy['body'] = lines.skip(start).join('\n').trimLeft();
      }
    }
    final formatted = copy['formatted_body'];
    if (formatted is String) {
      copy['formatted_body'] = formatted.replaceAll(
        RegExp(r'<mx-reply>.*</mx-reply>', dotAll: true),
        '',
      );
    }
  }
  return copy;
}

/// Why [room] cannot take [items], in the network's words, or null.
String? forwardUnavailableReason(Room room, List<ShareItem> items) {
  for (final item in items) {
    if (item is! ContentShareItem) continue;
    final content = item.value;
    final info = content['info'];
    final mime = info is Map ? info['mimetype'] : null;
    final feature = switch (content['msgtype']) {
      MessageTypes.Image => BridgeFeature.image,
      MessageTypes.Video => BridgeFeature.video,
      MessageTypes.Audio =>
        content.containsKey('org.matrix.msc3245.voice')
            ? BridgeFeature.voice
            : BridgeFeature.audio,
      MessageTypes.File => BridgeFeature.upload,
      MessageTypes.Location => BridgeFeature.location,
      _ => null,
    };
    if (feature == null) continue;
    final result = RoomCapabilities.forFeature(
      feature,
      room,
      media: mime is String
          ? BridgeMediaRequest(
              mimeType: mime,
              sizeBytes: info is Map ? info['size'] as int? : null,
              width: info is Map ? info['w'] as int? : null,
              height: info is Map ? info['h'] as int? : null,
            )
          : null,
    );
    if (result.status == CapabilityStatus.unavailable) {
      return result.reason.isEmpty
          ? 'This network does not accept this message.'
          : result.reason;
    }
  }
  return null;
}

/// Forward or share [items] (Telegram's share sheet): the inbox's chats,
/// recents first, search, several recipients, sent in place with progress
/// per chat, a short confirmation, and the user stays where they are.
/// Files (from another app) need the send dialog of the chosen chat: then
/// one chat is picked and opened with them.
Future<void> showForwardSheet(
  BuildContext context, {
  required List<ShareItem> items,
  String? title,
}) async {
  final client = Matrix.of(context).client;
  final personal = PersonalClient.of(client);
  final files = items.any((item) => item is FileShareItem);
  final router = GoRouter.of(context);
  final chosen = await showNotionSheet<ForwardTarget>(
    context: context,
    title: title ?? (files ? 'Share' : 'Forward'),
    builder: (context) => ForwardSheet(
      personal: personal,
      multiple: !files,
      unavailableReason: (room) => forwardUnavailableReason(room, items),
      send: files ? null : (context, room) => _sendItems(context, room, items),
      actionLabel: files ? 'Open chat' : null,
    ),
  );
  if (chosen == null) return;
  final room = chosen.rooms.first;
  final group = chosen.group;
  router.go(
    group == null
        ? '/rooms/${room.id}'
        : personSourceChatLocation(group.id, room.id),
    extra: items,
  );
}

/// Per room and item, the transaction of the last attempt: Try again sends
/// the same transaction, so a retry never delivers twice.
final _attempts = Expando<Map<Object, String>>();

/// Test seam: what the sheet's Send does for [room].
@visibleForTesting
Future<String?> debugSendForwardItems(
  BuildContext context,
  Room room,
  List<ShareItem> items,
) => _sendItems(context, room, items);

Future<String?> _sendItems(
  BuildContext context,
  Room room,
  List<ShareItem> items,
) async {
  final proceed = await showTrustUserInRoomDialog(context, room);
  if (!proceed) return 'Not sent.';
  final attempts = _attempts[room] ??= {};
  try {
    for (final item in items) {
      final txid = attempts[item] ??= room.client.generateUniqueTransactionId();
      final String? id;
      if (item is TextShareItem) {
        id = await room.sendTextEvent(
          item.value,
          txid: txid,
          parseCommands: false,
        );
      } else if (item is ContentShareItem) {
        id = await room.sendEvent(forwardableContent(item.value), txid: txid);
      } else {
        continue;
      }
      if (id == null) {
        return 'Not sent. Check your connection and try again.';
      }
    }
    // Only now: Try again after a later item failed resends the earlier
    // ones with their own transaction, which the server does not repeat
    // (a forwarded gallery is several messages).
    for (final item in items) {
      attempts.remove(item);
    }
  } catch (error) {
    return humanErrorText(error, action: ErrorAction.send);
  }
  return null;
}

enum _RowState { idle, sending, sent, failed }

/// The picker itself (data + callbacks): [send] forwards to one room and
/// returns an error sentence or null; without it the sheet returns the
/// chosen target ([multiple] must be false then).
class ForwardSheet extends StatefulWidget {
  final PersonalClient personal;
  final bool multiple;
  final Future<String?> Function(BuildContext context, Room room)? send;
  final String? Function(Room room)? unavailableReason;
  final bool Function(Room room)? accepts;
  final String? actionLabel;

  /// Shown when no chat can take the message.
  final String emptyMessage;

  const ForwardSheet({
    super.key,
    required this.personal,
    this.multiple = true,
    this.send,
    this.unavailableReason,
    this.accepts,
    this.actionLabel,
    this.emptyMessage = 'Chats you can send to appear here.',
  });

  @override
  State<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<ForwardSheet> {
  final _search = TextEditingController();
  late List<ForwardTarget> _targets = forwardTargets(
    widget.personal,
    accepts: widget.accepts,
  );
  late final InboxProjection _projection = InboxProjection.snapshot(
    widget.personal,
  );
  final _selected = <String>[];
  final _states = <String, _RowState>{};
  final _errors = <String, String>{};
  final _reasons = <String, String?>{};
  final _rooms = <String, Room?>{};
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadNames());
  }

  /// A chat without its own name is named after its members, which the SDK
  /// loads lazily: opened from a share intent right after start, the sheet
  /// would show bridge IDs ("Sh-whatsapp Lid-…"). Loads them once, then
  /// rebuilds the names.
  Future<void> _loadNames() async {
    final rooms = {
      for (final target in _targets)
        for (final room in [target.representative, ...target.rooms])
          if (room.name.trim().isEmpty) room.id: room,
    }.values.toList();
    if (rooms.isEmpty) return;
    for (var i = 0; i < rooms.length; i += 8) {
      await Future.wait(
        rooms
            .skip(i)
            .take(8)
            .map(
              (room) => room.loadHeroUsers().then<void>(
                (_) {},
                onError: (Object _) {},
              ),
            ),
      );
      if (!mounted) return;
    }
    setState(() {
      _targets = forwardTargets(widget.personal, accepts: widget.accepts);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The room [target] sends through: the first that takes the message.
  Room? _roomFor(ForwardTarget target) {
    if (_rooms.containsKey(target.entityId)) return _rooms[target.entityId];
    final check = widget.unavailableReason;
    Room? room;
    String? reason;
    for (final candidate in target.rooms) {
      final why = check?.call(candidate);
      if (why == null) {
        room = candidate;
        reason = null;
        break;
      }
      reason ??= why;
    }
    _reasons[target.entityId] = room == null ? reason : null;
    return _rooms[target.entityId] = room;
  }

  List<ForwardTarget> get _visible => _query.trim().isEmpty
      ? _targets
      : _targets.where((t) => t.matches(_query)).toList();

  void _toggle(ForwardTarget target) {
    if (_busy) return;
    final state = _states[target.entityId];
    if (state == _RowState.sent || state == _RowState.sending) return;
    if (_roomFor(target) == null) return;
    if (!widget.multiple) {
      if (widget.send == null) {
        Navigator.of(context).pop(target);
        return;
      }
      setState(() {
        _selected
          ..clear()
          ..add(target.entityId);
      });
      unawaited(_sendSelected());
      return;
    }
    setState(() {
      if (!_selected.remove(target.entityId)) _selected.add(target.entityId);
      if (state == _RowState.failed) {
        _states.remove(target.entityId);
        _errors.remove(target.entityId);
      }
    });
  }

  Future<void> _sendSelected() async {
    final send = widget.send;
    if (send == null || _busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final targets = [
      for (final id in _selected)
        if (_states[id] != _RowState.sent)
          ?_targets.where((t) => t.entityId == id).firstOrNull,
    ];
    if (targets.isEmpty) return;
    setState(() {
      _busy = true;
      for (final target in targets) {
        _states[target.entityId] = _RowState.sending;
        _errors.remove(target.entityId);
      }
    });
    final generation = PersonalPrivacy.surfaceGeneration;
    // One chat after the other: a trust question names one chat at a time.
    for (final target in targets) {
      final room = _roomFor(target);
      String? error;
      if (room == null) {
        error = _reasons[target.entityId] ?? 'This chat cannot take it.';
      } else {
        // A dismissed sheet stops before the next chat (its trust
        // question needs the sheet); sends already started finish.
        error = mounted ? await send(context, room) : 'Not sent.';
      }
      if (!mounted) continue;
      setState(() {
        _states[target.entityId] = error == null
            ? _RowState.sent
            : _RowState.failed;
        if (error != null) _errors[target.entityId] = error;
      });
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final sent = [
      for (final id in _selected)
        if (_states[id] == _RowState.sent)
          ?_targets.where((t) => t.entityId == id).firstOrNull,
    ];
    final allSent = sent.length == _selected.length;
    if (!allSent || generation != PersonalPrivacy.surfaceGeneration) return;
    navigator.pop();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          sent.length == 1
              ? 'Forwarded to ${sent.single.name}'
              : 'Forwarded to ${sent.length} chats',
        ),
      ),
    );
  }

  String get _buttonLabel {
    final failed = _selected.any((id) => _states[id] == _RowState.failed);
    if (failed && !_busy) return 'Try again';
    final count = _selected.length;
    final base = widget.actionLabel ?? 'Send';
    return count <= 1 ? base : '$base to $count chats';
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = math.max(
      NotionSize.touchTarget * 4,
      math.min(
        media.size.height * .72,
        media.size.height - media.viewInsets.bottom - media.padding.top,
      ),
    );
    final visible = _visible;
    final showButton = widget.multiple && widget.send != null;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionTextField(
              controller: _search,
              hint: 'Search',
              prefixIcon: Icons.search,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: NotionSpace.xs),
            Expanded(
              child: _targets.isEmpty
                  ? NotionEmptyState(
                      icon: Icons.forward_outlined,
                      title: 'No chats',
                      message: widget.emptyMessage,
                    )
                  : visible.isEmpty
                  ? const NotionEmptyState(
                      icon: Icons.search_off_outlined,
                      title: 'No matching chats',
                      message: 'Try another name or network.',
                    )
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final target = visible[index];
                        final room = _roomFor(target);
                        return _TargetRow(
                          key: ValueKey(target.entityId),
                          target: target,
                          multiple: widget.multiple,
                          selected: _selected.contains(target.entityId),
                          state: _states[target.entityId] ?? _RowState.idle,
                          error: _errors[target.entityId],
                          unavailable: room == null
                              ? _reasons[target.entityId] ??
                                    'This chat cannot take it.'
                              : null,
                          avatar: personalConversationAvatar(
                            widget.personal,
                            entityId: target.entityId,
                            avatar: _projection.avatarFor(
                              target.representative,
                            ),
                            name: target.name,
                            client: widget.personal.client,
                            size: NotionSize.avatar,
                          ),
                          onTap: () => _toggle(target),
                        );
                      },
                    ),
            ),
            if (showButton) ...[
              const SizedBox(height: NotionSpace.sm),
              NotionButton.primary(
                key: const ValueKey('forward-send'),
                label: _buttonLabel,
                icon: Icons.send_rounded,
                expand: true,
                busy: _busy,
                onPressed: _selected.isEmpty || _busy ? null : _sendSelected,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  final ForwardTarget target;
  final bool multiple;
  final bool selected;
  final _RowState state;
  final String? error;
  final String? unavailable;
  final Widget avatar;
  final VoidCallback onTap;
  const _TargetRow({
    super.key,
    required this.target,
    required this.multiple,
    required this.selected,
    required this.state,
    required this.error,
    required this.unavailable,
    required this.avatar,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final colors = tokens.colors;
    final networks = target.networks.toList()
      ..sort((a, b) => notionNetworkLabel(a).compareTo(notionNetworkLabel(b)));
    final enabled = unavailable == null;
    final subtitle =
        error ??
        unavailable ??
        [
          if (target.isGroup) 'Group',
          for (final network in networks) notionNetworkLabel(network),
        ].join(' · ');
    final subtitleStyle = error != null
        ? tokens.typography.captionMuted.copyWith(color: colors.danger)
        : tokens.typography.captionMuted;
    final trailing = switch (state) {
      _RowState.sending => const NotionDelayedSpinner(key: ValueKey('sending')),
      _RowState.sent => Icon(
        Icons.check_circle,
        key: const ValueKey('sent'),
        size: NotionSize.iconMd,
        color: colors.accent,
      ),
      _RowState.failed => Icon(
        Icons.error,
        key: const ValueKey('failed'),
        size: NotionSize.iconMd,
        color: colors.danger,
      ),
      _RowState.idle when multiple => Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        key: ValueKey(selected),
        size: NotionSize.iconMd,
        color: selected ? colors.accent : colors.textTertiary,
      ),
      _RowState.idle => const SizedBox.shrink(key: ValueKey('none')),
    };
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: [target.name, subtitle].join(', '),
      child: Opacity(
        opacity: enabled ? 1 : .5,
        child: NotionPressable(
          enabled: enabled,
          scale: NotionMotion.pressRow,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: NotionRadius.lgAll,
              onTap: enabled ? onTap : null,
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NotionSpace.xs,
                    vertical: NotionSpace.xs,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: NotionSize.avatar,
                        child: avatar,
                      ),
                      const SizedBox(width: NotionSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              target.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.typography.body,
                            ),
                            const SizedBox(height: NotionSpace.xxs),
                            Row(
                              children: [
                                if (error == null && unavailable == null)
                                  for (final network in networks.take(3))
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        end: NotionSpace.xxs,
                                      ),
                                      child: NotionNetworkGlyph(
                                        network: network,
                                        size: NotionSize.iconSm - 2,
                                      ),
                                    ),
                                Expanded(
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: subtitleStyle,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: NotionSpace.xs),
                      NotionMorphSwitcher(rotate: false, child: trailing),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
