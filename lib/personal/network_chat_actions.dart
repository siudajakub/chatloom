// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Network-side chat actions of mautrix bridgev2 (`event/beeper.go`,
/// `bridgev2/portal.go` `handleMatrixDeleteChat` / `handleMatrixBlockUser` /
/// `handleMatrixAcceptMessageRequest`). They are ordinary room events the
/// bridge turns into the network's own action.
const beeperDeleteChatType = 'com.beeper.delete_chat';
const beeperBlockUserType = 'com.beeper.block_user';
const beeperAcceptMessageRequestType = 'com.beeper.accept_message_request';
const _roomFeaturesType = 'com.beeper.room_features';

/// What the bridge of one portal declares about whole-chat actions
/// (`com.beeper.room_features`: `delete_chat`, `delete_chat_for_everyone`,
/// `block_user`, `report_spam`, `message_request`) and the chat's flags in
/// its bridge info (`channel["com.beeper.message_request"]`,
/// `channel["com.beeper.user_blocked"]`, `bridgev2` `getBridgeInfo`).
///
/// Only declarations sent by the room's own bridge bot count (any member may
/// send state), and only when the room has exactly one bridge: a missing,
/// foreign or ambiguous declaration offers nothing. This is a declaration,
/// not proof the network will accept the action; the bridge's
/// `com.beeper.message_send_status` answer decides ([NetworkChatActions]).
@immutable
class NetworkChatFeatures {
  /// Canonical network id (`whatsapp`, `instagram`, …), null when unknown.
  final String? network;

  /// The bridge bot that answers for this room.
  final String? bridgeBot;
  final bool deleteChat;
  final bool deleteChatForEveryone;
  final bool blockUser;
  final bool reportSpam;

  /// The request can be accepted without sending a message
  /// (`message_request.accept_with_button` at least partially supported).
  final bool acceptWithButton;

  /// The bridge flags this chat as a message request (Instagram/Messenger
  /// pending or spam folder).
  final bool messageRequest;

  /// The bridge says the other person is blocked on the network.
  final bool userBlocked;

  const NetworkChatFeatures({
    this.network,
    this.bridgeBot,
    this.deleteChat = false,
    this.deleteChatForEveryone = false,
    this.blockUser = false,
    this.reportSpam = false,
    this.acceptWithButton = false,
    this.messageRequest = false,
    this.userBlocked = false,
  });

  static const none = NetworkChatFeatures();

  static final _cache = Expando<(List<Object?>, NetworkChatFeatures)>(
    'network chat features',
  );

  /// The features of [room], recomputed only when one of the state events
  /// they come from was replaced (the SDK replaces, never mutates, state).
  static NetworkChatFeatures of(Room room) {
    final sources = <Object?>[
      for (final type in bridgeInfoStateTypes)
        for (final event
            in room.states[type]?.values ?? const <StrippedStateEvent>[])
          event,
      for (final event
          in room.states[_roomFeaturesType]?.values ??
              const <StrippedStateEvent>[])
        event,
    ];
    final cached = _cache[room];
    if (cached != null && listEquals(cached.$1, sources)) return cached.$2;
    final value = _parse(room);
    _cache[room] = (sources, value);
    return value;
  }

  static NetworkChatFeatures _parse(Room room) {
    // (state key, bot) of every bridge info its own bot sent.
    final owners = <(String, String)>{};
    Map<String, Object?>? channel;
    String? network;
    for (final type in bridgeInfoStateTypes) {
      final states = room.states[type];
      if (states == null) continue;
      for (final entry in states.entries) {
        final event = entry.value;
        final content = event.content;
        final bot = content['bridgebot'];
        if (bot is! String || bot.isEmpty || event.senderId != bot) continue;
        owners.add((entry.key, bot));
        final info = content['channel'];
        if (info is Map) channel ??= info.cast<String, Object?>();
        final protocol = content['protocol'];
        if (protocol is Map) {
          network ??=
              canonicalNetwork(protocol['id']) ??
              canonicalNetwork(protocol['displayname']);
        }
      }
    }
    if (owners.length != 1) return none;
    final (key, bot) = owners.single;
    final features = room.states[_roomFeaturesType]?[key];
    final declared = features != null && features.senderId == bot
        ? features.content
        : const <String, Object?>{};
    bool flag(Map<String, Object?>? map, String name) => map?[name] == true;
    final request = declared['message_request'];
    final button = request is Map ? request['accept_with_button'] : null;
    return NetworkChatFeatures(
      network: network,
      bridgeBot: bot,
      deleteChat: flag(declared, 'delete_chat'),
      deleteChatForEveryone: flag(declared, 'delete_chat_for_everyone'),
      blockUser: flag(declared, 'block_user'),
      reportSpam: flag(declared, 'report_spam'),
      acceptWithButton: button is int && button > 0,
      messageRequest: flag(channel, 'com.beeper.message_request'),
      userBlocked: flag(channel, 'com.beeper.user_blocked'),
    );
  }

  @override
  String toString() => 'NetworkChatFeatures(redacted)';
}

/// Whether [room] is a bridged message request the user has not accepted.
bool isMessageRequest(Room room) =>
    room.membership == Membership.join &&
    NetworkChatFeatures.of(room).messageRequest;

/// The network's answer to a chat action.
enum NetworkActionOutcome {
  /// The bridge confirmed it (or removed the chat).
  done,

  /// The bridge or the server refused it; [NetworkActionResult.text] says
  /// why in plain words.
  rejected,

  /// No answer in time. The bridge may still act on it later.
  noAnswer,
}

@immutable
class NetworkActionResult {
  final NetworkActionOutcome outcome;
  final String? text;
  const NetworkActionResult(this.outcome, [this.text]);
  bool get done => outcome == NetworkActionOutcome.done;
  @override
  String toString() => 'NetworkActionResult(${outcome.name})';
}

/// Content of `com.beeper.delete_chat` (`BeeperChatDeleteEventContent`,
/// `omitzero` fields left out).
Map<String, Object> deleteChatContent({
  bool forEveryone = false,
  bool fromMessageRequest = false,
}) => {
  if (forEveryone) 'delete_for_everyone': true,
  if (fromMessageRequest) 'from_message_request': true,
};

/// Content of `com.beeper.block_user` (`BeeperBlockUserEventContent`).
Map<String, Object> blockUserContent({
  required bool block,
  bool reportSpam = false,
}) => {'block': block, if (block && reportSpam) 'report_spam': true};

/// Sends the bridge's chat actions and waits for its answer.
///
/// bridgev2 answers each event with a `com.beeper.message_send_status`
/// relating to it (`FAIL_*` with a display message when the network refused)
/// except for a successful delete, which deletes the Matrix room instead.
/// Nothing is retried: a real account is acting on the network.
abstract final class NetworkChatActions {
  static const timeout = Duration(seconds: 45);

  /// Test seam: replaces the Matrix send (no network in tests).
  @visibleForTesting
  static Future<String?> Function(
    Room room,
    String type,
    Map<String, Object> content,
  )?
  sendOverride;

  static final _hidden = Expando<Set<String>>('network chat deletions');
  static final _changes = Expando<StreamController<String>>(
    'network chat action changes',
  );

  /// Room ids whose deletion is in flight: hidden from the inbox at once
  /// (optimistic), restored if the network refuses.
  static bool isDeleting(Room room) =>
      _hidden[room.client]?.contains(room.id) ?? false;

  /// Room ids of [client] whose inbox row changed through an action here.
  static Stream<String> changes(Client client) =>
      (_changes[client] ??= StreamController<String>.broadcast()).stream;

  static void _setHidden(Room room, bool hidden) {
    final set = _hidden[room.client] ??= <String>{};
    final changed = hidden ? set.add(room.id) : set.remove(room.id);
    if (changed) _changes[room.client]?.add(room.id);
  }

  /// Deletes [room]'s chat on the network (`com.beeper.delete_chat`); with
  /// [forEveryone] also for the other side when the bridge declares it. The
  /// row disappears at once and comes back if the network refuses or does
  /// not answer.
  static Future<NetworkActionResult> deleteChat(
    Room room, {
    bool forEveryone = false,
    bool fromMessageRequest = false,
    Duration? wait,
  }) async {
    final features = NetworkChatFeatures.of(room);
    final network = _label(room);
    if (!features.deleteChat) {
      return NetworkActionResult(
        NetworkActionOutcome.rejected,
        '$network can’t delete this chat from ChatLoom.',
      );
    }
    _setHidden(room, true);
    final result = await _send(
      room,
      beeperDeleteChatType,
      deleteChatContent(
        forEveryone: forEveryone && features.deleteChatForEveryone,
        fromMessageRequest: fromMessageRequest,
      ),
      fallback: '$network didn’t delete this chat.',
      settled: (current) =>
          current == null || current.membership != Membership.join,
      wait: wait,
    );
    if (result.done) {
      // Another login kept the portal: the network chat is gone, so leave
      // the Matrix room too (bridgev2 returns success without deleting it).
      final current = room.client.getRoomById(room.id);
      if (current != null && current.membership == Membership.join) {
        await current.leave().catchError((Object _) {});
      }
    } else {
      _setHidden(room, false);
    }
    return result;
  }

  /// Blocks or unblocks the other person of a bridged DM on the network
  /// (`com.beeper.block_user`), optionally reporting spam where declared.
  static Future<NetworkActionResult> setBlocked(
    Room room, {
    required bool block,
    bool reportSpam = false,
    Duration? wait,
  }) {
    final features = NetworkChatFeatures.of(room);
    final network = _label(room);
    if (!features.blockUser) {
      return Future.value(
        NetworkActionResult(
          NetworkActionOutcome.rejected,
          '$network can’t block from ChatLoom here.',
        ),
      );
    }
    return _send(
      room,
      beeperBlockUserType,
      blockUserContent(
        block: block,
        reportSpam: reportSpam && features.reportSpam,
      ),
      fallback: block
          ? '$network didn’t block this person.'
          : '$network didn’t unblock this person.',
      settled: (current) =>
          current != null &&
          NetworkChatFeatures.of(current).userBlocked == block,
      wait: wait,
    );
  }

  /// Accepts a message request (`com.beeper.accept_message_request`).
  static Future<NetworkActionResult> acceptRequest(
    Room room, {
    Duration? wait,
  }) {
    final network = _label(room);
    return _send(
      room,
      beeperAcceptMessageRequestType,
      const {},
      fallback: '$network didn’t accept the request.',
      settled: (current) =>
          current != null && !NetworkChatFeatures.of(current).messageRequest,
      wait: wait,
    );
  }

  static String _label(Room room) => bridgedNetworkLabel(room) ?? 'The network';

  static Future<NetworkActionResult> _send(
    Room room,
    String type,
    Map<String, Object> content, {
    required String fallback,
    required bool Function(Room? current) settled,
    Duration? wait,
  }) async {
    final client = room.client;
    final bots = bridgeBotsOf(room);
    final network = bridgedNetworkLabel(room);
    final verdict = Completer<NetworkActionResult>();
    String? eventId;
    final early = <Event>[];
    void finish(NetworkActionResult result) {
      if (!verdict.isCompleted) verdict.complete(result);
    }

    void consider(Event report) {
      if (report.type != beeperMessageSendStatusType ||
          report.room.id != room.id) {
        return;
      }
      final relation = report.content['m.relates_to'];
      if (relation is! Map || relation['event_id'] != eventId) return;
      final status = BridgeSendStatus.parse(
        report.content,
        sender: report.senderId,
        bridgeBots: bots,
        at: report.originServerTs,
      );
      if (status == null || status.status == 'PENDING') return;
      if (!status.failed) return finish(const NetworkActionResult(.done));
      finish(
        NetworkActionResult(
          .rejected,
          bridgeMessageText(status.message, network: network) ?? fallback,
        ),
      );
    }

    void check() {
      if (eventId != null && settled(client.getRoomById(room.id))) {
        finish(const NetworkActionResult(.done));
      }
    }

    final subscriptions = [
      client.onTimelineEvent.stream.listen((event) {
        if (eventId == null) {
          early.add(event);
        } else {
          consider(event);
        }
      }, onError: (Object _) {}),
      client.onSync.stream.listen((_) => check(), onError: (Object _) {}),
      client.onRoomState.stream
          .where((update) => update.roomId == room.id)
          .listen((_) => check(), onError: (Object _) {}),
    ];
    try {
      final send =
          sendOverride ??
          (Room room, String type, Map<String, Object> content) =>
              room.sendEvent(
                Map<String, dynamic>.of(content),
                type: type,
                displayPendingEvent: false,
              );
      final String? id;
      try {
        id = await send(room, type, content);
      } catch (error) {
        return NetworkActionResult(
          .rejected,
          humanErrorText(error, network: network),
        );
      }
      if (id == null || !id.startsWith(r'$')) {
        return const NetworkActionResult(
          .rejected,
          'Couldn’t reach the server. Check the connection and try again.',
        );
      }
      eventId = id;
      for (final event in early) {
        consider(event);
      }
      early.clear();
      check();
      return await verdict.future.timeout(
        wait ?? timeout,
        onTimeout: () => NetworkActionResult(
          .noAnswer,
          '${network ?? 'The network'} hasn’t answered yet. It may still '
          'do it in a moment.',
        ),
      );
    } finally {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    }
  }
}

/// A network bridge bot of [network] that this device knows from a portal's
/// bridge info (`bridgebot`, sent by that bot), for signing in when no
/// management room is known (BR-11). Null when none is known.
String? knownBridgeBot(Client client, String network) {
  for (final room in client.rooms) {
    for (final type in bridgeInfoStateTypes) {
      for (final event
          in room.states[type]?.values ?? const <StrippedStateEvent>[]) {
        final content = event.content;
        final bot = content['bridgebot'];
        final protocol = content['protocol'];
        if (bot is! String ||
            !bot.isValidMatrixIdStrict() ||
            event.senderId != bot ||
            protocol is! Map) {
          continue;
        }
        final id =
            canonicalNetwork(protocol['id']) ??
            canonicalNetwork(protocol['displayname']);
        if (id == canonicalNetwork(network)) return bot;
      }
    }
  }
  return null;
}

/// The network's name when a pin in [room] stays in ChatLoom (BR-06): no
/// mautrix bridge carries `m.room.pinned_events` to the network, so in a
/// bridged chat a pin is personal. Null for a native Matrix chat.
String? pinStaysInChatLoom(Room room) =>
    isBridgedRoom(room) ? bridgedNetworkLabel(room) ?? 'The network' : null;

/// View-once or timed media from the network (`com.beeper.view_limited`,
/// bridgev2 `view_limited_media`, BR-10): shown, but never saved, shared or
/// forwarded from ChatLoom.
bool isViewLimited(Event event) =>
    event.content['com.beeper.view_limited'] is Map;
